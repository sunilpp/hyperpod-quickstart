#!/usr/bin/env bash
# run-nccl-test-eks.sh — Run NCCL benchmark on HyperPod EKS cluster.
#
# Submits an MPIJob to the EKS cluster, waits for results, and streams logs.
# Prerequisites: kubectl configured for the EKS cluster, MPI operator installed.
#
# Usage:
#   ./scripts/run-nccl-test-eks.sh <eks-cluster-name> [num-workers] [gpus-per-node] [region]
#
# Examples:
#   ./scripts/run-nccl-test-eks.sh my-hyperpod-eks-eks-cluster
#   ./scripts/run-nccl-test-eks.sh my-hyperpod-eks-eks-cluster 2 1 us-west-2
#   ./scripts/run-nccl-test-eks.sh my-hyperpod-eks-eks-cluster 4 8 us-west-2

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

EKS_CLUSTER="${1:-}"
NUM_WORKERS="${2:-2}"
GPUS_PER_NODE="${3:-1}"
REGION="${4:-us-west-2}"

if [[ -z "$EKS_CLUSTER" ]]; then
    echo "Usage: $0 <eks-cluster-name> [num-workers] [gpus-per-node] [region]"
    exit 1
fi

TOTAL_GPUS=$((NUM_WORKERS * GPUS_PER_NODE))

echo "============================================================"
echo "  NCCL Test on EKS"
echo "  Cluster:  $EKS_CLUSTER"
echo "  Workers:  $NUM_WORKERS | GPUs/node: $GPUS_PER_NODE | Total: $TOTAL_GPUS"
echo "============================================================"
echo ""

# ── Check prerequisites ────────────────────────────────────────────
if ! command -v kubectl &>/dev/null; then
    echo "ERROR: kubectl is required"
    exit 1
fi

# ── Configure kubectl ─────────────────────────────────────────────
echo "Configuring kubectl..."
aws eks update-kubeconfig --name "$EKS_CLUSTER" --region "$REGION" 2>/dev/null

# ── Check MPI operator is installed ───────────────────────────────
if ! kubectl get crd mpijobs.kubeflow.org &>/dev/null; then
    echo "ERROR: MPI Operator not installed. Run install-eks-hyperpod-deps.sh first."
    exit 1
fi

# ── Clean up any previous test ────────────────────────────────────
kubectl delete mpijob nccl-tests 2>/dev/null || true
sleep 2

# ── Generate manifest with correct values ─────────────────────────
MANIFEST=$(cat "$REPO_ROOT/examples/nccl-test/eks/nccl-test-mpijob.yaml" | \
    sed "s/slotsPerWorker: 1/slotsPerWorker: $GPUS_PER_NODE/" | \
    sed "s/\"2\"  # Total GPUs/\"$TOTAL_GPUS\"/" | \
    sed "s/\"1\"  # GPUs per node/\"$GPUS_PER_NODE\"/" | \
    sed "s/replicas: 2  # Number of worker nodes/replicas: $NUM_WORKERS/" | \
    sed "s/nvidia.com\/gpu: 1/nvidia.com\/gpu: $GPUS_PER_NODE/g")

echo "Submitting NCCL test MPIJob..."
echo "$MANIFEST" | kubectl apply -f -

# ── Wait for launcher pod ─────────────────────────────────────────
echo "Waiting for launcher pod..."
for i in $(seq 1 120); do
    # Try multiple label selectors (varies by MPI operator version)
    LAUNCHER=$(kubectl get pods -l training.kubeflow.org/job-name=nccl-tests -o name 2>/dev/null | grep launcher | head -1)
    if [[ -z "$LAUNCHER" ]]; then
        LAUNCHER=$(kubectl get pods 2>/dev/null | grep nccl-tests-launcher | awk '{print "pod/"$1}' | head -1)
    fi
    if [[ -n "$LAUNCHER" ]]; then
        PHASE=$(kubectl get "$LAUNCHER" -o jsonpath='{.status.phase}' 2>/dev/null)
        if [[ "$PHASE" == "Running" || "$PHASE" == "Succeeded" || "$PHASE" == "Failed" ]]; then
            break
        fi
    fi
    sleep 5
done

if [[ -z "$LAUNCHER" ]]; then
    echo "ERROR: Launcher pod not found after 10 minutes"
    kubectl get pods | grep nccl
    exit 1
fi

echo "Launcher: $LAUNCHER (status: $PHASE)"
echo ""
echo "--- NCCL Test Output ---"
echo ""

# ── Stream logs ───────────────────────────────────────────────────
kubectl logs -f "$LAUNCHER" 2>/dev/null || kubectl logs "$LAUNCHER" 2>/dev/null

# ── Check result ──────────────────────────────────────────────────
FINAL_PHASE=$(kubectl get "$LAUNCHER" -o jsonpath='{.status.phase}' 2>/dev/null)
echo ""
echo "============================================================"
echo "  Status: $FINAL_PHASE"
echo "============================================================"

# ── Cleanup ───────────────────────────────────────────────────────
echo ""
read -p "Delete the MPIJob? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    kubectl delete mpijob nccl-tests
    echo "Cleaned up."
fi
