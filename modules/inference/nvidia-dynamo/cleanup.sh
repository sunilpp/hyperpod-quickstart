#!/usr/bin/env bash
# cleanup.sh — Remove NVIDIA Dynamo inference stack from the EKS cluster.
#
# This tears down all Dynamo components in reverse order:
# inference deployments -> operator -> platform services -> NodePool -> namespace
#
# Usage:
#   ./cleanup.sh [--keep-namespace] [--keep-nodepool]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source environment if available
if [[ -f "${SCRIPT_DIR}/dynamo-env.sh" ]]; then
  source "${SCRIPT_DIR}/dynamo-env.sh"
fi

NAMESPACE="${DYNAMO_NAMESPACE:-dynamo-cloud}"
KEEP_NAMESPACE="false"
KEEP_NODEPOOL="false"

while [[ $# -gt 0 ]]; do
  case $1 in
    --keep-namespace) KEEP_NAMESPACE="true"; shift ;;
    --keep-nodepool)  KEEP_NODEPOOL="true"; shift ;;
    -h|--help)
      echo "Usage: $0 [--keep-namespace] [--keep-nodepool]"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
info() { log "INFO  $*"; }
warn() { log "WARN  $*"; }

# Verify kubectl access
if ! kubectl cluster-info &>/dev/null; then
  echo "ERROR: kubectl cannot reach the cluster."
  exit 1
fi

echo ""
echo "============================================================"
echo "  Cleaning up NVIDIA Dynamo inference stack"
echo "  Namespace: ${NAMESPACE}"
echo "============================================================"
echo ""

# ── Step 1: Delete all inference deployments ──────────────────────────
info "Removing inference deployments..."
if kubectl get crd dynamographdeploymentrequests.nvidia.com &>/dev/null; then
  DEPLOYMENTS=$(kubectl get dynamographdeploymentrequests -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $1}')
  for dep in $DEPLOYMENTS; do
    info "  Deleting deployment: ${dep}"
    kubectl delete dynamographdeploymentrequests "$dep" -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
  done
  # Wait for GPU pods to terminate
  info "Waiting for inference pods to terminate..."
  kubectl wait --for=delete pods -l app.kubernetes.io/managed-by=dynamo-operator \
    -n "$NAMESPACE" --timeout=180s 2>/dev/null || true
else
  info "  No Dynamo CRDs found, skipping."
fi

# ── Step 2: Uninstall Dynamo Operator ─────────────────────────────────
info "Uninstalling Dynamo Operator..."
helm uninstall dynamo-operator -n "$NAMESPACE" 2>/dev/null || true

# ── Step 3: Uninstall platform services ───────────────────────────────
info "Uninstalling MinIO..."
helm uninstall dynamo-minio -n "$NAMESPACE" 2>/dev/null || true

info "Uninstalling PostgreSQL..."
helm uninstall dynamo-postgresql -n "$NAMESPACE" 2>/dev/null || true

info "Uninstalling NATS..."
helm uninstall nats -n "$NAMESPACE" 2>/dev/null || true

# ── Step 4: Clean up PVCs ────────────────────────────────────────────
info "Removing persistent volume claims..."
kubectl delete pvc --all -n "$NAMESPACE" 2>/dev/null || true

# ── Step 5: Remove NGC pull secret ───────────────────────────────────
info "Removing NGC image pull secret..."
kubectl delete secret ngc-secret -n "$NAMESPACE" 2>/dev/null || true

# ── Step 6: Remove Karpenter NodePool ────────────────────────────────
if [[ "$KEEP_NODEPOOL" == "false" ]]; then
  info "Removing Karpenter NodePool and EC2NodeClass..."
  kubectl delete nodepool dynamo-inference 2>/dev/null || true
  kubectl delete ec2nodeclass dynamo-inference 2>/dev/null || true

  # Wait for inference nodes to drain and terminate
  info "Waiting for inference nodes to terminate..."
  for i in $(seq 1 30); do
    NODE_COUNT=$(kubectl get nodes -l workload-type=inference --no-headers 2>/dev/null | wc -l | xargs)
    if [[ "$NODE_COUNT" -eq 0 ]]; then
      break
    fi
    info "  ${NODE_COUNT} inference node(s) still terminating... (${i}/30)"
    sleep 10
  done
else
  info "Keeping Karpenter NodePool (--keep-nodepool)."
fi

# ── Step 7: Delete namespace ─────────────────────────────────────────
if [[ "$KEEP_NAMESPACE" == "false" ]]; then
  info "Deleting namespace '${NAMESPACE}'..."
  kubectl delete namespace "$NAMESPACE" --timeout=120s 2>/dev/null || true
else
  info "Keeping namespace '${NAMESPACE}' (--keep-namespace)."
fi

# ── Step 8: Clean up generated files ─────────────────────────────────
if [[ -f "${SCRIPT_DIR}/dynamo-env.sh" ]]; then
  info "Removing generated environment file..."
  rm -f "${SCRIPT_DIR}/dynamo-env.sh"
fi

echo ""
echo "============================================================"
echo "  NVIDIA Dynamo inference stack removed."
echo "============================================================"
echo ""
echo "Note: ECR repositories and container images were NOT deleted."
echo "To remove those manually:"
echo "  aws ecr delete-repository --repository-name dynamo-base --force"
echo ""
