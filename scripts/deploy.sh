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
case "${STACK_VARIANT}" in
  slurm-gpu)       STACK_NAME="my-hyperpod" ;;
  slurm-trainium)  STACK_NAME="my-hyperpod-trn" ;;
  eks-gpu)         STACK_NAME="my-hyperpod-eks" ;;
  eks-trainium)    STACK_NAME="my-hyperpod-eks-trn" ;;
esac

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

# ── Upload lifecycle scripts to S3 ─────────────────────────────────
LIFECYCLE_PREFIX="${S3_PREFIX}/lifecycle-scripts"

# Determine which lifecycle scripts to upload based on variant
case "${STACK_VARIANT}" in
  slurm-gpu)
    SCRIPTS_DIR="${REPO_ROOT}/lifecycle-scripts/slurm/gpu" ;;
  slurm-trainium)
    SCRIPTS_DIR="${REPO_ROOT}/lifecycle-scripts/slurm/trainium" ;;
  eks-gpu|eks-trainium)
    SCRIPTS_DIR="${REPO_ROOT}/lifecycle-scripts/eks" ;;
esac

echo "Uploading lifecycle scripts from ${SCRIPTS_DIR}..."
aws s3 sync "${SCRIPTS_DIR}/" "s3://${S3_BUCKET}/${LIFECYCLE_PREFIX}/" \
  --region "${REGION}"

# ── Build CloudFormation console URL ────────────────────────────────
TEMPLATE_URL="https://s3.amazonaws.com/${S3_BUCKET}/${S3_PREFIX}/template.yaml"

# URL-encode the template URL (only special characters)
ENCODED_TEMPLATE_URL=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${TEMPLATE_URL}', safe=''))")

CONSOLE_URL="https://${REGION}.console.aws.amazon.com/cloudformation/home?region=${REGION}#/stacks/create/review?templateURL=${ENCODED_TEMPLATE_URL}&stackName=${STACK_NAME}&param_LifecycleScriptSourceBucket=${S3_BUCKET}&param_LifecycleScriptSourcePrefix=${LIFECYCLE_PREFIX}"

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
echo "If the stack fails, diagnose with:"
echo "  ./scripts/stack-errors.sh ${STACK_NAME} ${REGION}"
echo ""
echo "Tip: Enable 'Preserve successfully provisioned resources'"
echo "in the console (under Stack failure options) to keep failed"
echo "stacks alive for debugging."
echo ""

# ── EKS: Note about automated Helm installation ──────────────────
if [[ "$STACK_VARIANT" == eks-* ]]; then
  echo "  Note: HyperPod Helm dependencies (device plugins, health"
  echo "  monitoring, Kubeflow) are installed automatically via a"
  echo "  Lambda Custom Resource during stack creation."
  echo ""
fi

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
