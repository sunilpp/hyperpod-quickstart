#!/usr/bin/env bash
# publish.sh — Package all stack variants, upload to S3, and generate
#              Launch Stack button URLs for the README.
#
# Usage:
#   ./scripts/publish.sh <s3-bucket> [region]
#
# Examples:
#   ./scripts/publish.sh hyperpodstackfiles
#   ./scripts/publish.sh hyperpodstackfiles us-west-2
#
# After running, copy the generated markdown into your README.

set -euo pipefail

S3_BUCKET="${1:-}"
REGION="${2:-us-west-2}"

if [[ -z "$S3_BUCKET" ]]; then
    echo "Usage: $0 <s3-bucket> [region]"
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VARIANTS=(slurm-gpu slurm-trainium eks-gpu eks-trainium)

echo "============================================================"
echo "  Publishing HyperPod Quick Start templates"
echo "  Bucket: $S3_BUCKET | Region: $REGION"
echo "============================================================"
echo ""

# Package and upload each variant
for VARIANT in "${VARIANTS[@]}"; do
    echo "--- Packaging ${VARIANT} ---"

    TEMPLATE_DIR="${REPO_ROOT}/stacks/${VARIANT}"
    S3_PREFIX="hyperpod-quickstart/${VARIANT}"
    PACKAGED="${REPO_ROOT}/packaged-${VARIANT}.yaml"

    # Package nested templates
    aws cloudformation package \
        --template-file "${TEMPLATE_DIR}/template.yaml" \
        --s3-bucket "${S3_BUCKET}" \
        --s3-prefix "${S3_PREFIX}" \
        --output-template-file "${PACKAGED}" \
        --region "${REGION}" 2>/dev/null

    # Upload packaged template
    aws s3 cp "${PACKAGED}" \
        "s3://${S3_BUCKET}/${S3_PREFIX}/template.yaml" \
        --region "${REGION}"

    # Upload lifecycle scripts
    case "${VARIANT}" in
        slurm-gpu)      SCRIPTS_DIR="${REPO_ROOT}/lifecycle-scripts/slurm/gpu" ;;
        slurm-trainium) SCRIPTS_DIR="${REPO_ROOT}/lifecycle-scripts/slurm/trainium" ;;
        eks-*)          SCRIPTS_DIR="${REPO_ROOT}/lifecycle-scripts/eks" ;;
    esac
    aws s3 sync "${SCRIPTS_DIR}/" "s3://${S3_BUCKET}/${S3_PREFIX}/lifecycle-scripts/" \
        --region "${REGION}" 2>/dev/null

    # Clean up local packaged file
    rm -f "${PACKAGED}"

    echo "  Uploaded to s3://${S3_BUCKET}/${S3_PREFIX}/template.yaml"
done

echo ""
echo "============================================================"
echo "  All variants published!"
echo "============================================================"
echo ""

# Generate Launch Stack URLs and README markdown
echo "--- Launch Stack URLs ---"
echo ""

BADGE="https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png"

for VARIANT in "${VARIANTS[@]}"; do
    TEMPLATE_URL="https://s3.amazonaws.com/${S3_BUCKET}/hyperpod-quickstart/${VARIANT}/template.yaml"
    ENCODED_URL=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${TEMPLATE_URL}', safe=''))")

    # Default stack names
    case "${VARIANT}" in
        slurm-gpu)      STACK_NAME="my-hyperpod" ;;
        slurm-trainium) STACK_NAME="my-hyperpod-trn" ;;
        eks-gpu)        STACK_NAME="my-hyperpod-eks" ;;
        eks-trainium)   STACK_NAME="my-hyperpod-eks-trn" ;;
    esac

    # Pre-fill lifecycle script params
    LIFECYCLE_PREFIX="hyperpod-quickstart/${VARIANT}/lifecycle-scripts"
    PARAMS="&param_LifecycleScriptSourceBucket=${S3_BUCKET}&param_LifecycleScriptSourcePrefix=${LIFECYCLE_PREFIX}"

    CONSOLE_URL="https://${REGION}.console.aws.amazon.com/cloudformation/home?region=${REGION}#/stacks/create/review?templateURL=${ENCODED_URL}&stackName=${STACK_NAME}${PARAMS}"

    echo "${VARIANT}:"
    echo "  ${CONSOLE_URL}"
    echo ""
done

echo ""
echo "--- README Markdown (copy-paste into README.md) ---"
echo ""

for VARIANT in "${VARIANTS[@]}"; do
    TEMPLATE_URL="https://s3.amazonaws.com/${S3_BUCKET}/hyperpod-quickstart/${VARIANT}/template.yaml"
    ENCODED_URL=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${TEMPLATE_URL}', safe=''))")

    case "${VARIANT}" in
        slurm-gpu)      STACK_NAME="my-hyperpod"; LABEL="Slurm + GPU" ;;
        slurm-trainium) STACK_NAME="my-hyperpod-trn"; LABEL="Slurm + Trainium" ;;
        eks-gpu)        STACK_NAME="my-hyperpod-eks"; LABEL="EKS + GPU" ;;
        eks-trainium)   STACK_NAME="my-hyperpod-eks-trn"; LABEL="EKS + Trainium" ;;
    esac

    LIFECYCLE_PREFIX="hyperpod-quickstart/${VARIANT}/lifecycle-scripts"
    PARAMS="&param_LifecycleScriptSourceBucket=${S3_BUCKET}&param_LifecycleScriptSourcePrefix=${LIFECYCLE_PREFIX}"
    CONSOLE_URL="https://${REGION}.console.aws.amazon.com/cloudformation/home?region=${REGION}#/stacks/create/review?templateURL=${ENCODED_URL}&stackName=${STACK_NAME}${PARAMS}"

    echo "[![Launch ${LABEL}](${BADGE})](${CONSOLE_URL})"
done

echo ""
echo "--- Table format ---"
echo ""
echo "| | **NVIDIA GPU** | **AWS Trainium** |"
echo "|:---:|:---:|:---:|"

# Slurm row
for ORCHESTRATOR in slurm eks; do
    case "$ORCHESTRATOR" in
        slurm) ROW_LABEL="**Slurm**" ;;
        eks)   ROW_LABEL="**EKS**" ;;
    esac

    GPU_VARIANT="${ORCHESTRATOR}-gpu"
    TRN_VARIANT="${ORCHESTRATOR}-trainium"

    for V in "$GPU_VARIANT" "$TRN_VARIANT"; do
        TEMPLATE_URL="https://s3.amazonaws.com/${S3_BUCKET}/hyperpod-quickstart/${V}/template.yaml"
        ENCODED_URL=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${TEMPLATE_URL}', safe=''))")
        case "${V}" in
            slurm-gpu)      SN="my-hyperpod" ;;
            slurm-trainium) SN="my-hyperpod-trn" ;;
            eks-gpu)        SN="my-hyperpod-eks" ;;
            eks-trainium)   SN="my-hyperpod-eks-trn" ;;
        esac
        LP="hyperpod-quickstart/${V}/lifecycle-scripts"
        PARAMS="&param_LifecycleScriptSourceBucket=${S3_BUCKET}&param_LifecycleScriptSourcePrefix=${LP}"
        eval "${V//-/_}_URL=\"https://${REGION}.console.aws.amazon.com/cloudformation/home?region=${REGION}#/stacks/create/review?templateURL=${ENCODED_URL}&stackName=${SN}${PARAMS}\""
    done

    GPU_URL_VAR="${GPU_VARIANT//-/_}_URL"
    TRN_URL_VAR="${TRN_VARIANT//-/_}_URL"
    echo "| ${ROW_LABEL} | [![Launch](${BADGE})](${!GPU_URL_VAR}) | [![Launch](${BADGE})](${!TRN_URL_VAR}) |"
done

echo ""
echo "============================================================"
echo "  Done! Copy the table above into your README.md"
echo "============================================================"
