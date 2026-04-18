#!/usr/bin/env bash
# check-quotas.sh — Verify AWS service quotas required for HyperPod deployment.
#
# Usage:
#   ./scripts/check-quotas.sh [instance-type] [instance-count] [region]
#
# Examples:
#   ./scripts/check-quotas.sh
#   ./scripts/check-quotas.sh ml.g5.16xlarge 2 us-west-2
#   ./scripts/check-quotas.sh ml.p5.48xlarge 8 us-east-1

set -euo pipefail

INSTANCE_TYPE="${1:-ml.p5.48xlarge}"
INSTANCE_COUNT="${2:-2}"
REGION="${3:-us-west-2}"

# Strip "ml." prefix for display and quota search
INSTANCE_SHORT="${INSTANCE_TYPE#ml.}"

PASS=0
FAIL=0
WARN=0

check() {
  local label="$1"
  local service="$2"
  local search="$3"
  local required="$4"

  # Get applied quota value
  local value
  value=$(aws service-quotas list-service-quotas \
    --service-code "$service" \
    --region "$REGION" \
    --query "Quotas[?contains(QuotaName, \`$search\`)].Value | [0]" \
    --output json 2>/dev/null | tr -d ' \n')

  # Fall back to default quota if no applied value
  if [[ "$value" == "null" || -z "$value" ]]; then
    value=$(aws service-quotas list-aws-default-service-quotas \
      --service-code "$service" \
      --region "$REGION" \
      --query "Quotas[?contains(QuotaName, \`$search\`)].Value | [0]" \
      --output json 2>/dev/null | tr -d ' \n')
  fi

  if [[ "$value" == "null" || -z "$value" ]]; then
    printf "  %-60s  [?] NOT FOUND\n" "$label"
    WARN=$((WARN + 1))
  elif python3 -c "exit(0 if $value >= $required else 1)" 2>/dev/null; then
    printf "  %-60s  [PASS]  %s >= %s\n" "$label" "$value" "$required"
    PASS=$((PASS + 1))
  else
    printf "  %-60s  [FAIL]  %s < %s required\n" "$label" "$value" "$required"
    FAIL=$((FAIL + 1))
  fi
}

echo ""
echo "============================================================"
echo "  HyperPod Prerequisite Quota Check"
echo "============================================================"
echo "  Instance type:  $INSTANCE_TYPE"
echo "  Instance count: $INSTANCE_COUNT"
echo "  Region:         $REGION"
echo "============================================================"
echo ""

echo "--- SageMaker HyperPod Quotas ---"

check "Max instances per HyperPod cluster" \
  "sagemaker" "Maximum number instances allowed per SageMaker HyperPod cluster" \
  "$((INSTANCE_COUNT + 1))"

check "Total instances across HyperPod clusters" \
  "sagemaker" "Total number of instances allowed across SageMaker HyperPod clusters" \
  "$((INSTANCE_COUNT + 1))"

check "Max EBS volume size (GB)" \
  "sagemaker" "Maximum size of EBS volume in GB for a SageMaker HyperPod cluster" \
  500

check "$INSTANCE_TYPE for cluster usage" \
  "sagemaker" "$INSTANCE_SHORT for cluster usage" \
  "$INSTANCE_COUNT"

# Also check controller instance type (ml.m5.2xlarge for Slurm)
check "ml.m5.2xlarge for cluster usage (controller)" \
  "sagemaker" "m5.2xlarge for cluster usage" \
  1

echo ""
echo "--- VPC Quotas ---"

check "VPCs per Region" \
  "vpc" "VPCs per Region" 1

check "Internet gateways per Region" \
  "vpc" "Internet gateways per Region" 1

check "Network interfaces per Region" \
  "vpc" "Network interfaces per Region" "$((INSTANCE_COUNT * 2))"

echo ""
echo "--- EC2 Quotas ---"

check "EC2-VPC Elastic IPs" \
  "ec2" "EC2-VPC Elastic IPs" 1

echo ""
echo "============================================================"
if [[ $FAIL -gt 0 ]]; then
  echo "  RESULT: $FAIL check(s) FAILED, $PASS passed, $WARN unknown"
  echo ""
  echo "  Request quota increases at:"
  echo "  https://console.aws.amazon.com/servicequotas/home?region=${REGION}"
  echo "============================================================"
  exit 1
elif [[ $WARN -gt 0 ]]; then
  echo "  RESULT: All passed but $WARN quota(s) could not be verified"
  echo "  Check manually in the Service Quotas console."
  echo "============================================================"
  exit 0
else
  echo "  RESULT: All $PASS checks PASSED"
  echo "============================================================"
  exit 0
fi
