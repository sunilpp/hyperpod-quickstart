#!/usr/bin/env bash
# remote-nccl-test.sh — Run NCCL benchmark remotely via SSM from your local machine.
#
# Usage:
#   ./scripts/remote-nccl-test.sh <cluster-name> <s3-bucket> [num-nodes] [gpus-per-node] [region]
#
# Examples:
#   ./scripts/remote-nccl-test.sh my-hyperpod my-cfn-bucket
#   ./scripts/remote-nccl-test.sh my-hyperpod my-cfn-bucket 2 1 us-west-2

set -euo pipefail

CLUSTER_NAME="${1:-}"
S3_BUCKET="${2:-}"
NUM_NODES="${3:-2}"
GPUS_PER_NODE="${4:-1}"
REGION="${5:-us-west-2}"

if [[ -z "$CLUSTER_NAME" || -z "$S3_BUCKET" ]]; then
    echo "Usage: $0 <cluster-name> <s3-bucket> [num-nodes] [gpus-per-node] [region]"
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

# ── Upload test script to S3 ──────────────────────────────────────
S3_SCRIPT_PATH="s3://${S3_BUCKET}/hyperpod-quickstart/scripts/run-nccl-test.sh"
echo "Uploading test script to $S3_SCRIPT_PATH..."
aws s3 cp "$REPO_ROOT/scripts/run-nccl-test.sh" "$S3_SCRIPT_PATH" --region "$REGION"

# ── Run via SSM ───────────────────────────────────────────────────
echo "Executing NCCL test on controller (this may take several minutes)..."
echo ""

COMMAND_ID=$(aws ssm send-command \
    --instance-ids "$CONTROLLER_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "{\"commands\":[
        \"aws s3 cp ${S3_SCRIPT_PATH} /tmp/run-nccl-test.sh --region ${REGION}\",
        \"chmod +x /tmp/run-nccl-test.sh\",
        \"/tmp/run-nccl-test.sh ${NUM_NODES} ${GPUS_PER_NODE}\"
    ],\"executionTimeout\":[\"600\"]}" \
    --timeout-seconds 600 \
    --region "$REGION" \
    --query 'Command.CommandId' \
    --output text)

if [[ -z "$COMMAND_ID" || "$COMMAND_ID" == "None" ]]; then
    echo "ERROR: Failed to send SSM command."
    echo ""
    echo "Try running manually via SSM session:"
    echo "  aws ssm start-session --target $CONTROLLER_ID --region $REGION"
    echo "  /tmp/run-nccl-test.sh $NUM_NODES $GPUS_PER_NODE"
    exit 1
fi

echo "SSM Command: $COMMAND_ID"
echo "Waiting for results..."
echo ""

# ── Poll for completion ───────────────────────────────────────────
while true; do
    STATUS=$(aws ssm get-command-invocation \
        --command-id "$COMMAND_ID" \
        --instance-id "$CONTROLLER_ID" \
        --region "$REGION" \
        --query 'Status' \
        --output text 2>/dev/null || echo "Pending")

    case "$STATUS" in
        Success|Failed|TimedOut|Cancelled)
            break
            ;;
        *)
            sleep 10
            ;;
    esac
done

# ── Get the output ────────────────────────────────────────────────
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
    echo "$STDERR" | tail -50
fi

echo ""
echo "============================================================"
echo "  Status: $STATUS"
echo "============================================================"
