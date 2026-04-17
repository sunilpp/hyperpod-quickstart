#!/usr/bin/env bash
# deploy.sh — Package nested templates, upload to S3, and open the
#              CloudFormation console with everything pre-filled.
#
# Usage:
#   ./scripts/deploy.sh <stack-variant> <s3-bucket> [region]
#
# Examples:
#   ./scripts/deploy.sh slurm-gpu my-cfn-bucket
#   ./scripts/deploy.sh eks-trainium my-cfn-bucket us-east-1
#
# Stack variants: slurm-gpu, slurm-trainium, eks-gpu, eks-trainium

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ── Argument parsing ────────────────────────────────────────────────
usage() {
  echo "Usage: $0 <stack-variant> <s3-bucket> [region]"
  echo ""
  echo "Stack variants: slurm-gpu | slurm-trainium | eks-gpu | eks-trainium"
  echo ""
  echo "Arguments:"
  echo "  stack-variant   One of: slurm-gpu, slurm-trainium, eks-gpu, eks-trainium"
  echo "  s3-bucket       S3 bucket name for uploading packaged templates"
  echo "  region          AWS region (default: us-west-2)"
  exit 1
}

if [[ $# -lt 2 ]]; then
  usage
fi

STACK_VARIANT="$1"
S3_BUCKET="$2"
REGION="${3:-us-west-2}"

# ── Validate stack variant ──────────────────────────────────────────
TEMPLATE_DIR="${REPO_ROOT}/stacks/${STACK_VARIANT}"
if [[ ! -f "${TEMPLATE_DIR}/template.yaml" ]]; then
  echo "Error: Unknown stack variant '${STACK_VARIANT}'."
  echo "Valid options: slurm-gpu, slurm-trainium, eks-gpu, eks-trainium"
  exit 1
fi

# ── Default stack names per variant ─────────────────────────────────
declare -A DEFAULT_NAMES=(
  [slurm-gpu]="my-hyperpod"
  [slurm-trainium]="my-hyperpod-trn"
  [eks-gpu]="my-hyperpod-eks"
  [eks-trainium]="my-hyperpod-eks-trn"
)
STACK_NAME="${DEFAULT_NAMES[$STACK_VARIANT]}"

# ── Package templates ───────────────────────────────────────────────
PACKAGED_FILE="${REPO_ROOT}/packaged.yaml"
S3_PREFIX="hyperpod-quickstart/${STACK_VARIANT}"

echo "Packaging ${STACK_VARIANT} templates..."
aws cloudformation package \
  --template-file "${TEMPLATE_DIR}/template.yaml" \
  --s3-bucket "${S3_BUCKET}" \
  --s3-prefix "${S3_PREFIX}" \
  --output-template-file "${PACKAGED_FILE}" \
  --region "${REGION}"

echo "Uploading packaged template to s3://${S3_BUCKET}/${S3_PREFIX}/template.yaml..."
aws s3 cp "${PACKAGED_FILE}" \
  "s3://${S3_BUCKET}/${S3_PREFIX}/template.yaml" \
  --region "${REGION}"

# ── Build CloudFormation console URL ────────────────────────────────
TEMPLATE_URL="https://s3.amazonaws.com/${S3_BUCKET}/${S3_PREFIX}/template.yaml"

# URL-encode the template URL (only special characters)
ENCODED_TEMPLATE_URL=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${TEMPLATE_URL}', safe=''))")

CONSOLE_URL="https://${REGION}.console.aws.amazon.com/cloudformation/home?region=${REGION}#/stacks/create/review?templateURL=${ENCODED_TEMPLATE_URL}&stackName=${STACK_NAME}"

echo ""
echo "============================================================"
echo "  Templates packaged and uploaded successfully!"
echo "============================================================"
echo ""
echo "Template S3 URL:"
echo "  ${TEMPLATE_URL}"
echo ""
echo "CloudFormation Console URL:"
echo "  ${CONSOLE_URL}"
echo ""

# ── Open in browser ─────────────────────────────────────────────────
if command -v open &>/dev/null; then
  echo "Opening CloudFormation console in your browser..."
  open "${CONSOLE_URL}"
elif command -v xdg-open &>/dev/null; then
  echo "Opening CloudFormation console in your browser..."
  xdg-open "${CONSOLE_URL}"
else
  echo "Open the URL above in your browser to launch the stack."
fi
