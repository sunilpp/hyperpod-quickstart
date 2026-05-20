#!/usr/bin/env bash
# test.sh — Validate NVIDIA Dynamo inference deployment health.
#
# Checks platform components, forwards to frontend service, and runs
# a sample inference request.
#
# Usage:
#   ./test.sh [deployment-name]
#
# Examples:
#   ./test.sh                        # Auto-detect deployment
#   ./test.sh deepseek-8b-disagg     # Test specific deployment

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source environment if available
if [[ -f "${SCRIPT_DIR}/dynamo-env.sh" ]]; then
  source "${SCRIPT_DIR}/dynamo-env.sh"
fi

NAMESPACE="${DYNAMO_NAMESPACE:-dynamo-cloud}"
DEPLOYMENT_NAME="${1:-}"
PORT=8000
PF_PID=""

# ── Helpers ────────────────────────────────────────────────────────────
log()     { echo "[$(date '+%H:%M:%S')] $*"; }
pass()    { echo "[$(date '+%H:%M:%S')] PASS  $*"; }
fail()    { echo "[$(date '+%H:%M:%S')] FAIL  $*"; }
cleanup() { [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null; }
trap cleanup EXIT

# ── Step 1: Check platform components ─────────────────────────────────
log "=== Checking Dynamo Platform Components ==="

FAILED=0

# Check NATS
if kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=nats --no-headers 2>/dev/null | grep -q Running; then
  pass "NATS is running"
else
  fail "NATS is not running"
  FAILED=$((FAILED + 1))
fi

# Check PostgreSQL
if kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=postgresql --no-headers 2>/dev/null | grep -q Running; then
  pass "PostgreSQL is running"
else
  fail "PostgreSQL is not running"
  FAILED=$((FAILED + 1))
fi

# Check MinIO
if kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=minio --no-headers 2>/dev/null | grep -q Running; then
  pass "MinIO is running"
else
  fail "MinIO is not running"
  FAILED=$((FAILED + 1))
fi

# Check Dynamo Operator
if kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=dynamo-operator --no-headers 2>/dev/null | grep -q Running; then
  pass "Dynamo Operator is running"
else
  fail "Dynamo Operator is not running"
  FAILED=$((FAILED + 1))
fi

echo ""

# ── Step 2: Check Karpenter NodePool ──────────────────────────────────
log "=== Checking Karpenter NodePool ==="

if kubectl get nodepool dynamo-inference &>/dev/null; then
  pass "NodePool 'dynamo-inference' exists"
  READY_NODES=$(kubectl get nodes -l workload-type=inference --no-headers 2>/dev/null | wc -l | xargs)
  log "  Inference nodes currently active: ${READY_NODES}"
else
  log "  NodePool 'dynamo-inference' not found (Karpenter may not be installed)"
fi

echo ""

# ── Step 3: Check inference deployments ──────────────────────────────
log "=== Checking Inference Deployments ==="

DEPLOYMENTS=$(kubectl get dynamographdeploymentrequests -n "$NAMESPACE" --no-headers 2>/dev/null)
if [[ -z "$DEPLOYMENTS" ]]; then
  log "  No inference deployments found."
  log "  Deploy one with: kubectl apply -f ${SCRIPT_DIR}/examples/deepseek-r1-8b-disagg.yaml"
  echo ""
  if [[ $FAILED -gt 0 ]]; then
    log "Platform check: ${FAILED} component(s) not healthy."
    exit 1
  fi
  log "Platform components are healthy. Deploy a model to continue testing."
  exit 0
fi

echo "$DEPLOYMENTS" | while read -r line; do
  log "  $line"
done

# Auto-detect deployment name if not provided
if [[ -z "$DEPLOYMENT_NAME" ]]; then
  DEPLOYMENT_NAME=$(echo "$DEPLOYMENTS" | head -1 | awk '{print $1}')
  log "Auto-detected deployment: ${DEPLOYMENT_NAME}"
fi

echo ""

# ── Step 4: Check deployment pods ────────────────────────────────────
log "=== Checking Pods for '${DEPLOYMENT_NAME}' ==="

PODS=$(kubectl get pods -n "$NAMESPACE" -l "app=${DEPLOYMENT_NAME}" --no-headers 2>/dev/null)
if [[ -z "$PODS" ]]; then
  # Try broader label match
  PODS=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep "$DEPLOYMENT_NAME")
fi

if [[ -z "$PODS" ]]; then
  fail "No pods found for deployment '${DEPLOYMENT_NAME}'"
  exit 1
fi

echo "$PODS" | while read -r line; do
  POD_NAME=$(echo "$line" | awk '{print $1}')
  POD_STATUS=$(echo "$line" | awk '{print $3}')
  if [[ "$POD_STATUS" == "Running" ]]; then
    pass "$POD_NAME ($POD_STATUS)"
  else
    fail "$POD_NAME ($POD_STATUS)"
  fi
done

echo ""

# ── Step 5: Port-forward and test API ─────────────────────────────────
log "=== Testing Inference API ==="

# Find frontend service (prefer label selector, fall back to name grep)
FRONTEND_SVC=$(kubectl get svc -n "$NAMESPACE" -l "app=${DEPLOYMENT_NAME}" --no-headers 2>/dev/null | grep -i frontend | head -1 | awk '{print $1}')
if [[ -z "$FRONTEND_SVC" ]]; then
  FRONTEND_SVC=$(kubectl get svc -n "$NAMESPACE" --no-headers 2>/dev/null | grep -E "(frontend|${DEPLOYMENT_NAME})" | grep -v headless | head -1 | awk '{print $1}')
fi

if [[ -z "$FRONTEND_SVC" ]]; then
  fail "No frontend service found for '${DEPLOYMENT_NAME}'"
  exit 1
fi

# Check port availability
if lsof -i :"${PORT}" 2>/dev/null | grep -q LISTEN; then
  warn "Port ${PORT} already in use, attempting ${PORT}1 instead"
  PORT="${PORT}1"
fi

log "Port-forwarding ${FRONTEND_SVC}:${PORT}..."
kubectl port-forward "svc/${FRONTEND_SVC}" "${PORT}:8000" -n "$NAMESPACE" >/dev/null 2>&1 &
PF_PID=$!

# Wait for port to become available (up to 15 seconds)
for i in $(seq 1 30); do
  if curl -s -o /dev/null "http://localhost:${PORT}" 2>/dev/null; then
    break
  fi
  sleep 0.5
done

# Health check
log "Testing /health endpoint..."
HEALTH=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${PORT}/health" 2>/dev/null)
if [[ "$HEALTH" == "200" ]]; then
  pass "Health check returned 200"
else
  fail "Health check returned ${HEALTH}"
  exit 1
fi

# List models
log "Testing /v1/models endpoint..."
MODELS=$(curl -s "http://localhost:${PORT}/v1/models" 2>/dev/null)
if echo "$MODELS" | python3 -m json.tool &>/dev/null; then
  pass "Models endpoint returned valid JSON"
  echo "$MODELS" | python3 -m json.tool 2>/dev/null | head -20
else
  fail "Models endpoint did not return valid JSON"
fi

echo ""

# Inference test — auto-detect model name from /v1/models
MODEL_ID=$(echo "$MODELS" | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null || echo "")
if [[ -z "$MODEL_ID" ]]; then
  MODEL_ID="deepseek-ai/DeepSeek-R1-Distill-Llama-8B"
  warn "Could not detect model ID, using default: ${MODEL_ID}"
fi

log "Testing inference (chat completion) with model: ${MODEL_ID}..."
RESPONSE=$(curl -s -X POST "http://localhost:${PORT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"${MODEL_ID}\",
    \"messages\": [{\"role\": \"user\", \"content\": \"What is 2+2? Reply in one word.\"}],
    \"max_tokens\": 10,
    \"temperature\": 0.1
  }" 2>/dev/null)

if echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'])" 2>/dev/null; then
  pass "Inference request succeeded"
else
  fail "Inference request failed"
  echo "Response: $RESPONSE"
fi

echo ""
echo "============================================================"
if [[ $FAILED -eq 0 ]]; then
  log "All tests passed!"
else
  log "${FAILED} check(s) failed. Review output above."
fi
echo "============================================================"
