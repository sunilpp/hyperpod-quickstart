#!/usr/bin/env bash
# stack-errors.sh — Find root cause errors in CloudFormation stack failures.
#
# Drills into nested stacks to find the actual error messages, not just
# "Resource creation cancelled" or "Embedded stack was not successfully created".
#
# Usage:
#   ./scripts/stack-errors.sh <stack-name> [region]
#
# Examples:
#   ./scripts/stack-errors.sh my-hyperpod
#   ./scripts/stack-errors.sh my-hyperpod us-east-1

set -euo pipefail

STACK_NAME="${1:-}"
REGION="${2:-us-west-2}"

if [[ -z "$STACK_NAME" ]]; then
  echo "Usage: $0 <stack-name> [region]"
  exit 1
fi

echo ""
echo "============================================================"
echo "  CloudFormation Stack Error Report"
echo "  Stack: $STACK_NAME"
echo "  Region: $REGION"
echo "============================================================"

# Collect failed events from a stack, filtering out cascade cancellations
get_root_errors() {
  local stack="$1"
  local depth="${2:-0}"
  local indent=""
  for ((i=0; i<depth; i++)); do indent+="  "; done

  # Get all CREATE_FAILED events
  local events
  events=$(aws cloudformation describe-stack-events \
    --stack-name "$stack" \
    --region "$REGION" \
    --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`].[LogicalResourceId,ResourceType,ResourceStatusReason]' \
    --output json 2>/dev/null) || return 0

  # Parse each failed event
  echo "$events" | python3 -c "
import sys, json

events = json.load(sys.stdin)
depth = $depth
indent = '  ' * depth

for e in events:
    resource_id, resource_type, reason = e[0], e[1], e[2] or ''

    # Skip cascade cancellations
    if reason == 'Resource creation cancelled':
        continue

    # Check if it's a nested stack failure (drill down)
    if resource_type == 'AWS::CloudFormation::Stack' and 'was not successfully created' in reason:
        print(f'{indent}[NESTED] {resource_id}:')
        # Extract the ARN from the reason
        continue

    # This is a real root cause error
    print(f'{indent}[ERROR] {resource_id} ({resource_type})')
    print(f'{indent}        {reason}')
    print()
" 2>/dev/null

  # Find nested stack ARNs that failed and drill into them
  local nested_arns
  nested_arns=$(aws cloudformation describe-stack-events \
    --stack-name "$stack" \
    --region "$REGION" \
    --query 'StackEvents[?ResourceStatus==`CREATE_FAILED` && ResourceType==`AWS::CloudFormation::Stack`].PhysicalResourceId' \
    --output json 2>/dev/null) || return 0

  echo "$nested_arns" | python3 -c "
import sys, json
arns = json.load(sys.stdin)
for arn in arns:
    if arn and arn != 'null' and arn != 'None':
        print(arn)
" 2>/dev/null | while read -r nested_arn; do
    if [[ -n "$nested_arn" ]]; then
      local nested_name
      nested_name=$(echo "$nested_arn" | sed 's|.*/||' | cut -d/ -f1)
      echo "${indent}  Nested stack: $nested_name"
      get_root_errors "$nested_arn" $((depth + 1))
    fi
  done
}

echo ""

# Check if stack exists
STACK_STATUS=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query 'Stacks[0].StackStatus' \
  --output text 2>/dev/null) || {
  echo "Stack '$STACK_NAME' not found in $REGION."
  echo ""
  echo "It may have been deleted during rollback. To preserve failed stacks"
  echo "for debugging, deploy with --disable-rollback:"
  echo ""
  echo "  aws cloudformation create-stack \\"
  echo "    --stack-name $STACK_NAME \\"
  echo "    --template-body file://packaged.yaml \\"
  echo "    --capabilities CAPABILITY_NAMED_IAM \\"
  echo "    --disable-rollback \\"
  echo "    --region $REGION"
  echo ""
  exit 1
}

echo "Stack status: $STACK_STATUS"
echo ""

if [[ "$STACK_STATUS" != *FAILED* && "$STACK_STATUS" != *ROLLBACK* ]]; then
  echo "Stack is not in a failed state. No errors to report."
  exit 0
fi

echo "--- Root Cause Errors ---"
echo ""
get_root_errors "$STACK_NAME" 0

echo ""
echo "============================================================"
echo "  Tip: Deploy with --disable-rollback to keep failed stacks"
echo "  alive for inspection. Then delete manually when done:"
echo ""
echo "    aws cloudformation delete-stack --stack-name $STACK_NAME --region $REGION"
echo "============================================================"
