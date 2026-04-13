# Cleaning Up

When you are done with your HyperPod cluster, delete the CloudFormation stack to remove all resources and stop incurring charges. This guide walks through the process and explains how to verify that nothing is left behind.

---

## Before You Delete

### Save Your Data

Deleting the stack permanently removes the FSx for Lustre filesystem and all data on it. Copy anything you need to S3 first:

```bash
# Connect to the head node (Slurm) or any pod with access (EKS)
# Copy model checkpoints
aws s3 sync /fsx/checkpoints/ s3://my-backup-bucket/checkpoints/ --region us-west-2

# Copy training logs
aws s3 sync /fsx/logs/ s3://my-backup-bucket/logs/ --region us-west-2

# Copy datasets if they are not already in S3
aws s3 sync /fsx/datasets/ s3://my-backup-bucket/datasets/ --region us-west-2
```

> **Warning:** There is no way to recover data from a deleted FSx filesystem. Double-check that you have copied everything important before proceeding.

### Export Grafana Dashboards

If you created custom Grafana dashboards, export them as JSON:

1. Open Grafana
2. Navigate to each custom dashboard
3. Click the gear icon (dashboard settings)
4. Choose **JSON Model**
5. Copy and save the JSON locally

The pre-built dashboards do not need to be exported -- they are automatically recreated when you deploy a new stack.

### Cancel Running Jobs

If you have active training jobs, cancel them first to allow a clean shutdown:

**Slurm:**

```bash
# List running jobs
squeue

# Cancel all your jobs
scancel --user=$USER

# Or cancel a specific job
scancel <JOBID>
```

**EKS:**

```bash
# List running jobs
kubectl get jobs -A
kubectl get pytorchjobs -A
kubectl get mpijobs -A

# Delete specific jobs
kubectl delete pytorchjob <job-name>
kubectl delete job <job-name>
```

---

## Delete the Stack

### Option A: Via the Console

1. Open the [CloudFormation console](https://console.aws.amazon.com/cloudformation/)
2. Select your stack (for example, `my-hyperpod-cluster`)
3. Choose **Delete**
4. Confirm by choosing **Delete** again

### Option B: Via the CLI

```bash
aws cloudformation delete-stack \
  --stack-name my-hyperpod-cluster \
  --region us-west-2
```

Wait for deletion to complete:

```bash
aws cloudformation wait stack-delete-complete \
  --stack-name my-hyperpod-cluster \
  --region us-west-2
```

This typically takes **10 to 20 minutes**.

---

## What Gets Deleted

The stack delete removes all resources it created:

| Resource | Deleted? | Notes |
|----------|----------|-------|
| HyperPod cluster | Yes | All instances are terminated |
| VPC, subnets, route tables | Yes | |
| NAT gateway + Elastic IP | Yes | |
| Internet gateway | Yes | |
| Security group | Yes | |
| FSx for Lustre filesystem | Yes | **All data on /fsx is permanently lost** |
| S3 lifecycle bucket | Yes | Including lifecycle scripts and benchmark results |
| IAM roles and policies | Yes | |
| EKS cluster (EKS stacks) | Yes | Including all Kubernetes resources |
| Prometheus workspace | Yes | All stored metrics are lost |
| Grafana workspace | Yes | All dashboards and settings are lost |
| Lambda functions | Yes | |
| CloudWatch Log Groups | Yes | |
| S3 VPC endpoint | Yes | |
| VPC Flow Logs | Yes | |

---

## Monitoring the Deletion

### Via the Console

1. Select your stack in CloudFormation
2. Watch the **Events** tab for `DELETE_IN_PROGRESS` and `DELETE_COMPLETE` events
3. The stack disappears from the list when fully deleted (select "Deleted" in the filter dropdown to see it afterward)

### Via the CLI

```bash
aws cloudformation describe-stack-events \
  --stack-name my-hyperpod-cluster \
  --region us-west-2 \
  --query 'StackEvents[*].[Timestamp,ResourceType,LogicalResourceId,ResourceStatus]' \
  --output table
```

---

## Handling Delete Failures

Sometimes a stack delete fails, leaving the stack in `DELETE_FAILED` state. Here is how to handle common causes:

### Cause: S3 Bucket Not Empty

CloudFormation cannot delete an S3 bucket that contains objects.

**Fix:**

```bash
# Find the bucket name from the stack resources
aws cloudformation describe-stack-resources \
  --stack-name my-hyperpod-cluster \
  --region us-west-2 \
  --query "StackResources[?ResourceType=='AWS::S3::Bucket'].PhysicalResourceId" \
  --output text

# Empty the bucket
aws s3 rm s3://<bucket-name> --recursive --region us-west-2

# Retry the delete
aws cloudformation delete-stack \
  --stack-name my-hyperpod-cluster \
  --region us-west-2
```

### Cause: ENIs Still Attached

Network interfaces created by Lambda functions or EKS pods may take time to detach after the resource is deleted.

**Fix:** Wait 15-30 minutes and retry the delete. The ENIs are usually cleaned up automatically.

```bash
# Wait, then retry
aws cloudformation delete-stack \
  --stack-name my-hyperpod-cluster \
  --region us-west-2
```

### Cause: Security Group Dependencies

If another resource (not managed by this stack) references the security group, it cannot be deleted.

**Fix:** Identify and remove the dependency:

```bash
# Find what is using the security group
aws ec2 describe-network-interfaces \
  --filters Name=group-id,Values=<security-group-id> \
  --region us-west-2 \
  --query 'NetworkInterfaces[*].{ID:NetworkInterfaceId,Description:Description,Status:Status}' \
  --output table
```

Delete or detach the identified network interfaces, then retry the stack delete.

### Cause: IAM Role in Use

If an IAM role is being used by another service, it cannot be deleted.

**Fix:** Identify and remove the role from the service that is using it, then retry.

### Last Resort: Retain Failed Resources

If you cannot resolve the dependency, you can tell CloudFormation to skip the problematic resources:

```bash
aws cloudformation delete-stack \
  --stack-name my-hyperpod-cluster \
  --retain-resources <LogicalResourceId1> <LogicalResourceId2> \
  --region us-west-2
```

> **Warning:** Retained resources are NOT deleted and may continue to incur charges. You must delete them manually afterward. To find the logical resource ID, check the DELETE_FAILED event in the stack events.

---

## Verify No Orphaned Resources

After the stack is fully deleted, run these checks to ensure nothing was left behind:

### Check for Remaining HyperPod Clusters

```bash
aws sagemaker list-clusters --region us-west-2 \
  --query 'ClusterSummaries[*].{Name:ClusterName,Status:ClusterStatus}' \
  --output table
```

If your cluster still appears, delete it manually:

```bash
aws sagemaker delete-cluster --cluster-name <cluster-name> --region us-west-2
```

### Check for Remaining VPCs

```bash
aws ec2 describe-vpcs --region us-west-2 \
  --filters "Name=tag:Name,Values=*hyperpod*" \
  --query 'Vpcs[*].{ID:VpcId,Name:Tags[?Key==`Name`].Value|[0]}' \
  --output table
```

### Check for Remaining FSx Filesystems

```bash
aws fsx describe-file-systems --region us-west-2 \
  --query 'FileSystems[*].{ID:FileSystemId,Type:FileSystemType,Status:Lifecycle}' \
  --output table
```

### Check for Remaining EKS Clusters

```bash
aws eks list-clusters --region us-west-2
```

### Check for Remaining NAT Gateways

```bash
aws ec2 describe-nat-gateways --region us-west-2 \
  --filter "Name=state,Values=available" \
  --query 'NatGateways[*].{ID:NatGatewayId,VPC:VpcId,State:State}' \
  --output table
```

### Check for Unassociated Elastic IPs

Unassociated Elastic IPs cost $0.005/hr ($3.60/month). Release any that are not in use:

```bash
aws ec2 describe-addresses --region us-west-2 \
  --query 'Addresses[?AssociationId==null].{IP:PublicIp,AllocationId:AllocationId}' \
  --output table

# Release if found
aws ec2 release-address --allocation-id <allocation-id> --region us-west-2
```

### Check for Remaining Prometheus Workspaces

```bash
aws amp list-workspaces --region us-west-2 \
  --query 'workspaces[*].{ID:workspaceId,Alias:alias,Status:status.statusCode}' \
  --output table
```

### Check for Remaining Grafana Workspaces

```bash
aws grafana list-workspaces --region us-west-2 \
  --query 'workspaces[*].{ID:id,Name:name,Status:status}' \
  --output table
```

---

## Cleanup Script

Here is a script that checks for common orphaned resources. Save it and run after stack deletion:

```bash
#!/bin/bash
# cleanup-check.sh - Verify no orphaned resources remain
REGION="${1:-us-west-2}"
PREFIX="${2:-hyperpod}"

echo "Checking for orphaned resources in $REGION with prefix '$PREFIX'..."
echo ""

echo "--- HyperPod Clusters ---"
aws sagemaker list-clusters --region $REGION \
  --query "ClusterSummaries[?contains(ClusterName, '$PREFIX')].{Name:ClusterName,Status:ClusterStatus}" \
  --output table 2>/dev/null || echo "  (none or access denied)"

echo ""
echo "--- VPCs ---"
aws ec2 describe-vpcs --region $REGION \
  --filters "Name=tag:Name,Values=*${PREFIX}*" \
  --query 'Vpcs[*].{ID:VpcId,Name:Tags[?Key==`Name`].Value|[0]}' \
  --output table 2>/dev/null || echo "  (none or access denied)"

echo ""
echo "--- FSx Filesystems ---"
aws fsx describe-file-systems --region $REGION \
  --query "FileSystems[*].{ID:FileSystemId,Status:Lifecycle}" \
  --output table 2>/dev/null || echo "  (none or access denied)"

echo ""
echo "--- NAT Gateways ---"
aws ec2 describe-nat-gateways --region $REGION \
  --filter "Name=state,Values=available" \
  --query 'NatGateways[*].{ID:NatGatewayId,VPC:VpcId}' \
  --output table 2>/dev/null || echo "  (none or access denied)"

echo ""
echo "--- Unassociated Elastic IPs ---"
aws ec2 describe-addresses --region $REGION \
  --query 'Addresses[?AssociationId==null].{IP:PublicIp,AllocationId:AllocationId}' \
  --output table 2>/dev/null || echo "  (none or access denied)"

echo ""
echo "--- Prometheus Workspaces ---"
aws amp list-workspaces --region $REGION \
  --query "workspaces[?contains(alias, '$PREFIX')].{ID:workspaceId,Alias:alias}" \
  --output table 2>/dev/null || echo "  (none or access denied)"

echo ""
echo "--- Grafana Workspaces ---"
aws grafana list-workspaces --region $REGION \
  --query "workspaces[?contains(name, '$PREFIX')].{ID:id,Name:name}" \
  --output table 2>/dev/null || echo "  (none or access denied)"

echo ""
echo "Done. If any resources appear above, delete them manually."
```

Usage:

```bash
chmod +x cleanup-check.sh
./cleanup-check.sh us-west-2 my-hyperpod
```

---

## Deleting the Template S3 Bucket

If you created an S3 bucket to host the nested CloudFormation templates (during [CLI deployment](03-deploying.md)), that bucket is not part of the stack and must be deleted separately:

```bash
# Empty and delete the template bucket
aws s3 rb s3://my-hyperpod-templates-123456789012 --force --region us-west-2
```

---

## Redeploying Later

If you want to deploy a cluster again in the future, simply follow the [Deploying guide](03-deploying.md) again. Your S3 backups and any external resources will be available for the new cluster. Restore your FSx data after deployment:

```bash
aws s3 sync s3://my-backup-bucket/fsx-backup/ /fsx/ --region us-west-2
```
