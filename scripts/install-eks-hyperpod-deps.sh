#!/usr/bin/env bash
# install-eks-hyperpod-deps.sh — Install HyperPod dependencies on an EKS cluster.
#
# Must be run AFTER the EKS cluster is created but BEFORE the HyperPod cluster
# is created. The deploy.sh script calls this automatically for EKS variants.
#
# Prerequisites: helm, kubectl, aws CLI
#
# Usage:
#   ./scripts/install-eks-hyperpod-deps.sh <eks-cluster-name> [region]
#
# Examples:
#   ./scripts/install-eks-hyperpod-deps.sh my-hyperpod-eks-eks-cluster us-west-2

set -euo pipefail

EKS_CLUSTER="${1:-}"
REGION="${2:-us-west-2}"

if [[ -z "$EKS_CLUSTER" ]]; then
    echo "Usage: $0 <eks-cluster-name> [region]"
    exit 1
fi

echo "============================================================"
echo "  Installing HyperPod dependencies on EKS cluster"
echo "  Cluster: $EKS_CLUSTER"
echo "  Region:  $REGION"
echo "============================================================"
echo ""

# ── Check prerequisites ────────────────────────────────────────────
for cmd in helm kubectl aws; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd is required but not installed."
        exit 1
    fi
done

# ── Configure kubectl ──────────────────────────────────────────────
echo "Configuring kubectl..."
aws eks update-kubeconfig --name "$EKS_CLUSTER" --region "$REGION"

# Verify connectivity
if ! kubectl cluster-info &>/dev/null; then
    echo "ERROR: Cannot connect to EKS cluster $EKS_CLUSTER"
    exit 1
fi
echo "kubectl connected to $EKS_CLUSTER"
echo ""

# ── Clone HyperPod Helm chart ─────────────────────────────────────
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

echo "Downloading HyperPod Helm chart..."
git clone --depth 1 https://github.com/aws/sagemaker-hyperpod-cli.git "$TMPDIR/hyperpod-cli" 2>/dev/null

CHART_DIR="$TMPDIR/hyperpod-cli/helm_chart/HyperPodHelmChart"
if [[ ! -d "$CHART_DIR" ]]; then
    echo "ERROR: Helm chart not found at expected path"
    exit 1
fi

# ── Install Helm chart ─────────────────────────────────────────────
echo "Updating Helm chart dependencies..."
helm dependencies update "$CHART_DIR"

echo ""
echo "Installing HyperPod dependencies..."
helm upgrade --install hyperpod-dependencies "$CHART_DIR" \
    --namespace kube-system \
    --wait \
    --timeout 10m

echo ""
echo "Verifying installation..."
kubectl get pods -n kube-system -l app.kubernetes.io/managed-by=Helm --no-headers 2>/dev/null | head -10
kubectl get pods -n aws-hyperpod --no-headers 2>/dev/null || true
kubectl get pods -n mpi-operator --no-headers 2>/dev/null || true

echo ""
echo "============================================================"
echo "  HyperPod EKS dependencies installed successfully"
echo "============================================================"
