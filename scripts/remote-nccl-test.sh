#!/usr/bin/env bash
# remote-nccl-test.sh — Run NCCL benchmark remotely via SSM from your local machine.
#
# Usage:
#   ./scripts/remote-nccl-test.sh <cluster-name> [num-nodes] [gpus-per-node] [region]
#
# Examples:
#   ./scripts/remote-nccl-test.sh my-hyperpod
#   ./scripts/remote-nccl-test.sh my-hyperpod 2 1 us-west-2

set -euo pipefail

CLUSTER_NAME="${1:-}"
NUM_NODES="${2:-2}"
GPUS_PER_NODE="${3:-1}"
REGION="${4:-us-west-2}"

if [[ -z "$CLUSTER_NAME" ]]; then
    echo "Usage: $0 <cluster-name> [num-nodes] [gpus-per-node] [region]"
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "============================================================"
echo "  Remote NCCL Test via SSM"
echo "  Cluster: $CLUSTER_NAME"
echo "  Region:  $REGION"
echo "============================================================"
echo ""

# ── Find the controller instance ID ────────────────────────────────
echo "Finding controller node..."
CONTROLLER_ID=$(aws sagemaker list-cluster-nodes \
    --cluster-name "$CLUSTER_NAME" \
    --region "$REGION" \
    --query 'ClusterNodeSummaries[?InstanceGroupName==`controller-group`].InstanceId' \
    --output text 2>/dev/null)

if [[ -z "$CONTROLLER_ID" || "$CONTROLLER_ID" == "None" ]]; then
    echo "ERROR: Could not find controller node for cluster '$CLUSTER_NAME'"
    exit 1
fi
echo "Controller: $CONTROLLER_ID"
echo ""

# ── Upload the test script to the controller via SSM ───────────────
echo "Uploading NCCL test script..."
SCRIPT_CONTENT=$(cat "$REPO_ROOT/scripts/run-nccl-test.sh")

# Use SSM send-command to upload and run
COMMAND_ID=$(aws ssm send-command \
    --instance-ids "$CONTROLLER_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[
        \"cat > /tmp/run-nccl-test.sh << 'SCRIPTEOF'\n${SCRIPT_CONTENT}\nSCRIPTEOF\",
        \"chmod +x /tmp/run-nccl-test.sh\",
        \"cd /tmp && /tmp/run-nccl-test.sh $NUM_NODES $GPUS_PER_NODE\"
    ]" \
    --timeout-seconds 600 \
    --region "$REGION" \
    --query 'Command.CommandId' \
    --output text 2>/dev/null)

if [[ -z "$COMMAND_ID" || "$COMMAND_ID" == "None" ]]; then
    echo "ERROR: Failed to send SSM command"
    echo ""
    echo "Falling back to interactive SSM session..."
    echo "Run this on the controller:"
    echo "  /tmp/run-nccl-test.sh $NUM_NODES $GPUS_PER_NODE"
    echo ""
    aws ssm start-session --target "$CONTROLLER_ID" --region "$REGION"
    exit 1
fi

echo "SSM Command ID: $COMMAND_ID"
echo "Waiting for results (this may take a few minutes)..."
echo ""

# ── Wait for command to complete ───────────────────────────────────
aws ssm wait command-executed \
    --command-id "$COMMAND_ID" \
    --instance-id "$CONTROLLER_ID" \
    --region "$REGION" 2>/dev/null || true

# ── Get the output ─────────────────────────────────────────────────
STATUS=$(aws ssm get-command-invocation \
    --command-id "$COMMAND_ID" \
    --instance-id "$CONTROLLER_ID" \
    --region "$REGION" \
    --query 'Status' \
    --output text 2>/dev/null)

echo "--- NCCL Test Output ---"
echo ""

aws ssm get-command-invocation \
    --command-id "$COMMAND_ID" \
    --instance-id "$CONTROLLER_ID" \
    --region "$REGION" \
    --query 'StandardOutputContent' \
    --output text 2>/dev/null

STDERR=$(aws ssm get-command-invocation \
    --command-id "$COMMAND_ID" \
    --instance-id "$CONTROLLER_ID" \
    --region "$REGION" \
    --query 'StandardErrorContent' \
    --output text 2>/dev/null)

if [[ -n "$STDERR" && "$STDERR" != "None" ]]; then
    echo ""
    echo "--- Stderr ---"
    echo "$STDERR"
fi

echo ""
echo "============================================================"
echo "  Status: $STATUS"
echo "============================================================"
