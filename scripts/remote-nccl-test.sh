#!/usr/bin/env bash
# remote-nccl-test.sh — Open SSM session to controller and print instructions.
#
# Usage:
#   ./scripts/remote-nccl-test.sh <cluster-name> [region]
#
# Examples:
#   ./scripts/remote-nccl-test.sh my-hyperpod-slurm
#   ./scripts/remote-nccl-test.sh my-hyperpod-slurm us-west-2

set -euo pipefail

CLUSTER_NAME="${1:-}"
REGION="${2:-us-west-2}"

if [[ -z "$CLUSTER_NAME" ]]; then
    echo "Usage: $0 <cluster-name> [region]"
    exit 1
fi

echo "============================================================"
echo "  Connect to HyperPod Cluster"
echo "  Cluster: $CLUSTER_NAME"
echo "  Region:  $REGION"
echo "============================================================"
echo ""

# ── Get cluster ARN and extract cluster ID ─────────────────────────
CLUSTER_ARN=$(aws sagemaker describe-cluster \
    --cluster-name "$CLUSTER_NAME" \
    --region "$REGION" \
    --query 'ClusterArn' \
    --output text 2>/dev/null)

if [[ -z "$CLUSTER_ARN" || "$CLUSTER_ARN" == "None" ]]; then
    echo "ERROR: Cluster '$CLUSTER_NAME' not found"
    exit 1
fi

# Extract cluster ID from ARN (last segment after /)
CLUSTER_ID=$(echo "$CLUSTER_ARN" | sed 's|.*/||')

# ── Find controller instance ──────────────────────────────────────
CONTROLLER_INSTANCE=$(aws sagemaker list-cluster-nodes \
    --cluster-name "$CLUSTER_NAME" \
    --region "$REGION" \
    --query 'ClusterNodeSummaries[?InstanceGroupName==`controller-group`] | [0].[InstanceGroupName,InstanceId]' \
    --output text 2>/dev/null)

CONTROLLER_GROUP=$(echo "$CONTROLLER_INSTANCE" | awk '{print $1}')
CONTROLLER_ID=$(echo "$CONTROLLER_INSTANCE" | awk '{print $2}')

if [[ -z "$CONTROLLER_ID" || "$CONTROLLER_ID" == "None" ]]; then
    echo "ERROR: Controller not found"
    exit 1
fi

# Build SSM target in HyperPod format
SSM_TARGET="sagemaker-cluster:${CLUSTER_ID}_${CONTROLLER_GROUP}-${CONTROLLER_ID}"

echo "Controller: $CONTROLLER_ID"
echo "SSM Target: $SSM_TARGET"
echo ""
echo "============================================================"
echo "  Once connected, run the NCCL test:"
echo ""
echo "    run-nccl-test 2 1"
echo ""
echo "  Or submit as a batch job:"
echo ""
echo "    sbatch -N 2 /opt/slurm/bin/run-nccl-test"
echo "    cat /tmp/nccl-test_<jobid>.out"
echo "============================================================"
echo ""

# ── Connect ───────────────────────────────────────────────────────
aws ssm start-session \
    --target "$SSM_TARGET" \
    --region "$REGION"
