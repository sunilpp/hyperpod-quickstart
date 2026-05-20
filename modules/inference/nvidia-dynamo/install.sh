#!/usr/bin/env bash
# install.sh — Deploy NVIDIA Dynamo inference stack on an existing HyperPod/EKS cluster.
#
# This script installs the NVIDIA Dynamo platform components on top of
# a running EKS cluster provisioned by the HyperPod quickstart stacks.
# It uses Karpenter to manage G6e inference GPU nodes that scale to zero
# when idle.
#
# Prerequisites:
#   - HyperPod EKS cluster is deployed and healthy
#   - kubectl is configured for the target cluster
#   - helm v3.12+ installed
#   - AWS CLI v2 configured with appropriate permissions
#
# Usage:
#   ./install.sh [--cluster-name <name>] [--region <region>] [--gpu-instance-type <type>]
#
# Examples:
#   ./install.sh
#   ./install.sh --cluster-name my-hyperpod-eks --region us-west-2
#   ./install.sh --gpu-instance-type g6e.12xlarge

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Defaults ───────────────────────────────────────────────────────────
NAMESPACE="dynamo-cloud"
KARPENTER_NAMESPACE="kube-system"
REGION="${AWS_DEFAULT_REGION:-us-west-2}"
CLUSTER_NAME=""
GPU_INSTANCE_TYPES="g6e.12xlarge,g6e.24xlarge,g6e.48xlarge"
MAX_GPUS=16
DYNAMO_OPERATOR_VERSION="1.1.1"
KARPENTER_NODE_ROLE=""
SKIP_KARPENTER_NODEPOOL="false"
DRY_RUN="false"

# ── Argument parsing ───────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --cluster-name)     CLUSTER_NAME="$2"; shift 2 ;;
    --region)           REGION="$2"; shift 2 ;;
    --gpu-instance-type) GPU_INSTANCE_TYPES="$2"; shift 2 ;;
    --max-gpus)         MAX_GPUS="$2"; shift 2 ;;
    --namespace)        NAMESPACE="$2"; shift 2 ;;
    --operator-version) DYNAMO_OPERATOR_VERSION="$2"; shift 2 ;;
    --karpenter-role)   KARPENTER_NODE_ROLE="$2"; shift 2 ;;
    --skip-karpenter)   SKIP_KARPENTER_NODEPOOL="true"; shift ;;
    --dry-run)          DRY_RUN="true"; shift ;;
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --cluster-name <name>       EKS cluster name (auto-detected if omitted)"
      echo "  --region <region>           AWS region (default: us-west-2)"
      echo "  --gpu-instance-type <types> Comma-separated GPU instance types"
      echo "                              (default: g6e.12xlarge,g6e.24xlarge,g6e.48xlarge)"
      echo "  --max-gpus <n>              Max GPUs across inference nodes (default: 16)"
      echo "  --namespace <ns>            Kubernetes namespace (default: dynamo-cloud)"
      echo "  --operator-version <ver>    Dynamo operator version (default: 1.1.1)"
      echo "  --karpenter-role <name>     IAM role for Karpenter nodes (auto-detected)"
      echo "  --skip-karpenter            Skip Karpenter NodePool creation"
      echo "  --dry-run                   Print what would be done without executing"
      echo "  -h, --help                  Show this help"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Helpers ────────────────────────────────────────────────────────────
log()   { echo "[$(date '+%H:%M:%S')] $*"; }
info()  { log "INFO  $*"; }
warn()  { log "WARN  $*"; }
error() { log "ERROR $*"; exit 1; }

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] $*"
  else
    "$@"
  fi
}

# ── Step 1: Validate prerequisites ────────────────────────────────────
info "Validating prerequisites..."

for cmd in kubectl helm aws; do
  command -v "$cmd" &>/dev/null || error "'$cmd' is required but not found in PATH"
done

# Verify helm version >= 3.12
HELM_VERSION=$(helm version --short 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+' | head -1)
if [[ -z "$HELM_VERSION" ]]; then
  error "Could not determine Helm version"
fi
HELM_MAJOR=$(echo "$HELM_VERSION" | cut -d. -f1 | sed 's/v//')
HELM_MINOR=$(echo "$HELM_VERSION" | cut -d. -f2)
if [[ $HELM_MAJOR -lt 3 ]] || { [[ $HELM_MAJOR -eq 3 ]] && [[ $HELM_MINOR -lt 12 ]]; }; then
  error "Helm 3.12+ required. Found: ${HELM_VERSION}"
fi

# Verify kubectl connectivity
if ! kubectl cluster-info &>/dev/null; then
  error "kubectl cannot reach the cluster. Run: aws eks update-kubeconfig --name <cluster> --region ${REGION}"
fi

# Auto-detect cluster name from kubectl context if not provided
if [[ -z "$CLUSTER_NAME" ]]; then
  CLUSTER_NAME=$(kubectl config current-context 2>/dev/null | grep -oE '[^/]+$' || true)
  if [[ -z "$CLUSTER_NAME" ]]; then
    error "Could not auto-detect cluster name. Use --cluster-name"
  fi
  info "Auto-detected cluster: ${CLUSTER_NAME}"
fi

# Verify the cluster exists
if ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" &>/dev/null; then
  error "EKS cluster '${CLUSTER_NAME}' not found in region ${REGION}"
fi

info "Prerequisites validated."

# ── Step 2: Create namespace ──────────────────────────────────────────
info "Creating namespace '${NAMESPACE}'..."
run kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | run kubectl apply -f -

# ── Step 3: Add Helm repos ───────────────────────────────────────────
info "Adding Helm repositories..."
run helm repo add nvaie https://helm.ngc.nvidia.com/nvaie --force-update 2>/dev/null || true
run helm repo add nats https://nats-io.github.io/k8s/helm/charts/ --force-update 2>/dev/null || true
run helm repo add bitnami https://charts.bitnami.com/bitnami --force-update 2>/dev/null || true
run helm repo update

# ── Step 4: Install NATS (required for KV-aware routing) ─────────────
info "Installing NATS with JetStream..."
if helm status nats -n "$NAMESPACE" &>/dev/null; then
  info "NATS already installed, upgrading..."
fi
run helm upgrade --install nats nats/nats \
  -n "$NAMESPACE" \
  -f "${SCRIPT_DIR}/helm-values/nats.yaml" \
  --wait --timeout 5m

# ── Step 5: Install PostgreSQL (Dynamo API store backend) ─────────────
info "Installing PostgreSQL..."
if helm status dynamo-postgresql -n "$NAMESPACE" &>/dev/null; then
  info "PostgreSQL already installed, upgrading..."
fi
run helm upgrade --install dynamo-postgresql bitnami/postgresql \
  -n "$NAMESPACE" \
  -f "${SCRIPT_DIR}/helm-values/postgresql.yaml" \
  --wait --timeout 5m

# ── Step 6: Install MinIO (artifact storage) ─────────────────────────
info "Installing MinIO..."
if helm status dynamo-minio -n "$NAMESPACE" &>/dev/null; then
  info "MinIO already installed, upgrading..."
fi
run helm upgrade --install dynamo-minio bitnami/minio \
  -n "$NAMESPACE" \
  -f "${SCRIPT_DIR}/helm-values/minio.yaml" \
  --wait --timeout 5m

# ── Step 7: Install NVIDIA Dynamo Operator ────────────────────────────
info "Installing NVIDIA Dynamo Operator v${DYNAMO_OPERATOR_VERSION}..."

# Check if NGC API key is set for pulling operator images
if [[ -z "${NGC_API_KEY:-}" ]]; then
  warn "NGC_API_KEY not set. If the operator image pull fails, set it with:"
  warn "  export NGC_API_KEY=<your-key>"
  warn "  Then re-run this script."
fi

# Create image pull secret if NGC key is available
if [[ -n "${NGC_API_KEY:-}" ]]; then
  info "Creating NGC image pull secret..."
  run kubectl create secret docker-registry ngc-secret \
    --docker-server=nvcr.io \
    --docker-username='$oauthtoken' \
    --docker-password="${NGC_API_KEY}" \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml | run kubectl apply -f -
fi

run helm upgrade --install dynamo-operator nvaie/dynamo-operator \
  -n "$NAMESPACE" \
  -f "${SCRIPT_DIR}/helm-values/dynamo-operator.yaml" \
  --version "${DYNAMO_OPERATOR_VERSION}" \
  --wait --timeout 10m

# ── Step 8: Apply Karpenter NodePool for inference GPUs ───────────────
if [[ "$SKIP_KARPENTER_NODEPOOL" == "false" ]]; then
  info "Checking Karpenter availability..."

  if kubectl get crd nodepools.karpenter.sh &>/dev/null; then
    info "Applying Karpenter NodePool for inference GPUs..."

    # Get VPC and subnet info from EKS cluster
    CLUSTER_VPC=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
      --query 'cluster.resourcesVpcConfig.vpcId' --output text)
    [[ -z "$CLUSTER_VPC" || "$CLUSTER_VPC" == "None" ]] && error "Failed to retrieve VPC ID for cluster ${CLUSTER_NAME}"

    CLUSTER_SG=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
      --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
    [[ -z "$CLUSTER_SG" || "$CLUSTER_SG" == "None" ]] && error "Failed to retrieve security group for cluster ${CLUSTER_NAME}"

    # Discover Karpenter node role if not explicitly provided
    if [[ -z "$KARPENTER_NODE_ROLE" ]]; then
      # Try to find existing Karpenter EC2NodeClass role
      KARPENTER_NODE_ROLE=$(kubectl get ec2nodeclass -o jsonpath='{.items[0].spec.role}' 2>/dev/null || true)
      if [[ -z "$KARPENTER_NODE_ROLE" ]]; then
        # Fall back to common Karpenter role naming convention
        KARPENTER_NODE_ROLE="KarpenterNodeRole-${CLUSTER_NAME}"
        warn "No existing Karpenter EC2NodeClass found. Using role: ${KARPENTER_NODE_ROLE}"
        warn "Override with --karpenter-role if your role has a different name."
      else
        info "Discovered existing Karpenter node role: ${KARPENTER_NODE_ROLE}"
      fi
    fi

    info "Cluster VPC: ${CLUSTER_VPC}, Security Group: ${CLUSTER_SG}"

    # Build the instance type values list for the NodePool template
    IFS=',' read -ra INSTANCE_ARRAY <<< "$GPU_INSTANCE_TYPES"
    INSTANCE_TYPES=""
    for inst in "${INSTANCE_ARRAY[@]}"; do
      inst="$(echo "$inst" | xargs)"  # trim whitespace
      INSTANCE_TYPES="${INSTANCE_TYPES}            - \"${inst}\"
"
    done
    export INSTANCE_TYPES CLUSTER_NAME CLUSTER_VPC CLUSTER_SG KARPENTER_NODE_ROLE MAX_GPUS

    # Apply EC2NodeClass (envsubst handles all ${VAR} placeholders)
    if ! envsubst '${CLUSTER_NAME} ${CLUSTER_VPC} ${CLUSTER_SG} ${KARPENTER_NODE_ROLE}' \
         < "${SCRIPT_DIR}/karpenter/ec2nodeclass.yaml" | run kubectl apply -f -; then
      error "Failed to apply EC2NodeClass"
    fi

    # Apply NodePool with dynamic instance types and GPU limits
    if ! envsubst '${MAX_GPUS} ${INSTANCE_TYPES}' \
         < "${SCRIPT_DIR}/karpenter/nodepool.yaml" | run kubectl apply -f -; then
      error "Failed to apply NodePool"
    fi

    info "Karpenter NodePool 'dynamo-inference' applied."
  else
    warn "Karpenter CRDs not found. Skipping NodePool creation."
    warn "If using HyperPod-managed nodes, ensure GPU nodes are available."
    warn "Install Karpenter: https://karpenter.sh/docs/getting-started/"
  fi
else
  info "Skipping Karpenter NodePool creation (--skip-karpenter)."
fi

# ── Step 9: Verify installation ──────────────────────────────────────
info "Verifying installation..."

echo ""
echo "=== Dynamo Platform Components ==="
kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | while read -r line; do
  echo "  $line"
done

echo ""
echo "=== Dynamo CRDs ==="
kubectl get crd 2>/dev/null | grep -i dynamo || echo "  (waiting for operator to register CRDs)"

echo ""
echo "=== Karpenter NodePool ==="
kubectl get nodepool dynamo-inference 2>/dev/null || echo "  (not configured)"

# ── Step 10: Generate environment file ────────────────────────────────
ENV_FILE="${SCRIPT_DIR}/dynamo-env.sh"
if [[ "$DRY_RUN" == "true" ]]; then
  info "[DRY-RUN] Would generate environment file: ${ENV_FILE}"
else
cat > "$ENV_FILE" << EOF
# NVIDIA Dynamo environment — generated by install.sh on $(date)
# Source this file before running deploy/test commands:
#   source ${ENV_FILE}

export DYNAMO_NAMESPACE="${NAMESPACE}"
export EKS_CLUSTER_NAME="${CLUSTER_NAME}"
export AWS_REGION="${REGION}"
export GPU_INSTANCE_TYPES="${GPU_INSTANCE_TYPES}"
export DYNAMO_OPERATOR_VERSION="${DYNAMO_OPERATOR_VERSION}"

# Set your NGC API key for pulling NVIDIA container images:
# export NGC_API_KEY="<your-ngc-api-key>"

# Set your HuggingFace token for gated models (e.g., Llama):
# export HF_TOKEN="<your-huggingface-token>"
EOF
fi

echo ""
echo "============================================================"
echo "  NVIDIA Dynamo inference stack installed successfully!"
echo "============================================================"
echo ""
echo "Environment file: ${ENV_FILE}"
echo "  source ${ENV_FILE}"
echo ""
echo "Next steps:"
echo "  1. Deploy an inference graph:"
echo "     kubectl apply -f ${SCRIPT_DIR}/examples/deepseek-r1-8b-disagg.yaml"
echo ""
echo "  2. Monitor pods:"
echo "     kubectl get pods -n ${NAMESPACE} -w"
echo ""
echo "  3. Test the deployment:"
echo "     ${SCRIPT_DIR}/test.sh"
echo ""
echo "  4. Access the model API:"
echo "     kubectl port-forward svc/dynamo-frontend 8000:8000 -n ${NAMESPACE}"
echo "     curl http://localhost:8000/v1/models"
echo ""
echo "To tear down:"
echo "  ${SCRIPT_DIR}/cleanup.sh"
echo ""
