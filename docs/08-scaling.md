# Scaling Your Cluster

This guide explains how to change the size of your HyperPod cluster by updating the CloudFormation stack parameters.

---

## Cluster Sizes

The Quick Start offers three pre-configured sizes:

| Size | Worker Nodes | FSx Storage | EBS per Node | Best For |
|------|-------------|-------------|-------------|----------|
| **small** | 2 | 1.2 TB | 500 GB | Development, testing, learning |
| **medium** | 8 | 4.8 TB | 500 GB | Moderate training runs |
| **large** | 32 | 14.4 TB | 1,000 GB | Large-scale distributed training |

> **Tip:** Always start with `small` to verify your setup works, then scale up when you need more capacity.

---

## Scaling Up (or Down)

You change the cluster size by updating the CloudFormation stack. This modifies the `ClusterSize` parameter, which in turn changes the number of worker instances and the FSx storage capacity.

### Option A: Update via the Console

1. Open the [CloudFormation console](https://console.aws.amazon.com/cloudformation/)
2. Select your stack
3. Choose **Update**
4. Select **Use current template** and choose **Next**
5. Change the **ClusterSize** parameter to the new size (for example, `small` to `medium`)
6. Click through the remaining steps and choose **Submit**

### Option B: Update via the CLI

```bash
aws cloudformation update-stack \
  --stack-name my-hyperpod-cluster \
  --use-previous-template \
  --parameters \
    ParameterKey=ClusterName,UsePreviousValue=true \
    ParameterKey=ClusterSize,ParameterValue=medium \
    ParameterKey=AvailabilityZoneId,UsePreviousValue=true \
    ParameterKey=EnableObservability,UsePreviousValue=true \
    ParameterKey=EnableValidation,UsePreviousValue=true \
    ParameterKey=RunBenchmarks,UsePreviousValue=true \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-west-2
```

### What Happens During the Update

| Resource | Behavior on Scale-Up | Behavior on Scale-Down |
|----------|---------------------|----------------------|
| Worker instances | New nodes are added | Excess nodes are terminated |
| FSx Lustre | **Replaced** (new filesystem created) | **Replaced** (new filesystem created) |
| VPC, subnets, security groups | No change | No change |
| Observability stack | No change | No change |
| Validation | Re-runs with new expected node count | Re-runs with new expected node count |

> **Warning:** Scaling changes the FSx Lustre filesystem. FSx for Lustre does not support in-place resizing through CloudFormation, so the old filesystem is deleted and a new one is created. **Copy all important data from `/fsx` to S3 before scaling.**

### How to Back Up FSx Data Before Scaling

```bash
# On the head node (Slurm) or from any node with access
aws s3 sync /fsx/my-data s3://my-backup-bucket/fsx-backup/ --region us-west-2
```

Or, if you only need to save specific directories (like model checkpoints):

```bash
aws s3 cp /fsx/checkpoints/ s3://my-backup-bucket/checkpoints/ --recursive
```

After the update completes, restore the data:

```bash
aws s3 sync s3://my-backup-bucket/fsx-backup/ /fsx/my-data --region us-west-2
```

---

## Changing the Instance Type

You can also change the instance type by updating the `WorkerInstanceType` parameter. For example, switching from `ml.p5.48xlarge` to `ml.p4d.24xlarge`.

```bash
aws cloudformation update-stack \
  --stack-name my-hyperpod-cluster \
  --use-previous-template \
  --parameters \
    ParameterKey=ClusterName,UsePreviousValue=true \
    ParameterKey=ClusterSize,UsePreviousValue=true \
    ParameterKey=WorkerInstanceType,ParameterValue=ml.p4d.24xlarge \
    ParameterKey=AvailabilityZoneId,UsePreviousValue=true \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-west-2
```

> **Warning:** Changing the instance type replaces all worker nodes. Back up any data on local EBS volumes (not `/fsx`) before updating. Also verify that you have sufficient [service quota](01-prerequisites.md#3-service-quotas) for the new instance type.

---

## Monitoring the Update

```bash
# Watch stack events
aws cloudformation describe-stack-events \
  --stack-name my-hyperpod-cluster \
  --region us-west-2 \
  --query 'StackEvents[*].[Timestamp,ResourceType,LogicalResourceId,ResourceStatus]' \
  --output table

# Wait for update to complete
aws cloudformation wait stack-update-complete \
  --stack-name my-hyperpod-cluster \
  --region us-west-2
```

Updates typically take **15 to 25 minutes**, depending on the changes.

---

## Enabling or Disabling Features

You can also toggle features on or off during an update:

### Enable Benchmarks on an Existing Cluster

```bash
aws cloudformation update-stack \
  --stack-name my-hyperpod-cluster \
  --use-previous-template \
  --parameters \
    ParameterKey=ClusterName,UsePreviousValue=true \
    ParameterKey=ClusterSize,UsePreviousValue=true \
    ParameterKey=AvailabilityZoneId,UsePreviousValue=true \
    ParameterKey=RunBenchmarks,ParameterValue=true \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-west-2
```

### Disable Observability to Save Costs

```bash
aws cloudformation update-stack \
  --stack-name my-hyperpod-cluster \
  --use-previous-template \
  --parameters \
    ParameterKey=ClusterName,UsePreviousValue=true \
    ParameterKey=ClusterSize,UsePreviousValue=true \
    ParameterKey=AvailabilityZoneId,UsePreviousValue=true \
    ParameterKey=EnableObservability,ParameterValue=false \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-west-2
```

> **Warning:** Disabling observability deletes the Prometheus workspace and Grafana workspace, including all stored metrics and custom dashboards. Export anything you need first.

---

## Custom Sizes (Beyond the Pre-Configured Options)

The pre-configured sizes (small, medium, large) cover common use cases. If you need a custom number of nodes, you have two options:

### Option 1: Modify the Template Mappings

Edit the `ClusterSizeMap` mapping in the template for your stack variant (for example, `stacks/slurm-gpu/template.yaml`):

```yaml
Mappings:
  ClusterSizeMap:
    small:
      WorkerCount: "4"      # Changed from 2 to 4
      FSxCapacity: "2400"   # Adjusted proportionally
      EBSVolume: "500"
```

Then redeploy the stack with the modified template.

> **Tip:** FSx for Lustre capacity must be a multiple of 1,200 GiB (for SCRATCH_2 or PERSISTENT_1 with 125 MB/s/TiB). See the [FSx for Lustre documentation](https://docs.aws.amazon.com/fsx/latest/LustreGuide/managing-storage-capacity.html) for valid values.

### Option 2: Use the SageMaker API Directly

For fine-grained control, update the HyperPod cluster directly without modifying the CloudFormation stack:

```bash
aws sagemaker update-cluster \
  --cluster-name <cluster-name> \
  --instance-groups '[{
    "InstanceGroupName": "worker-group",
    "InstanceType": "ml.p5.48xlarge",
    "InstanceCount": 16,
    "LifeCycleConfig": {
      "SourceS3Uri": "s3://<lifecycle-bucket>/lifecycle-scripts",
      "OnCreate": "on_create.sh"
    },
    "ExecutionRole": "arn:aws:iam::<account-id>:role/<role-name>",
    "ThreadsPerCore": 1
  }]' \
  --region us-west-2
```

> **Warning:** If you modify the cluster directly via the SageMaker API, the CloudFormation stack will be out of sync with the actual cluster state. Future stack updates may try to revert your changes. Use this approach only when you need a node count that cannot be expressed through the template mappings.

---

## Scaling Considerations

### Service Quotas

Before scaling up, verify your service quota can handle the new size. For example, going from `small` (2 nodes) to `large` (32 nodes) of `ml.p5.48xlarge` requires a quota of at least 32 instances.

```bash
# Check your current quota
aws service-quotas list-service-quotas \
  --service-code sagemaker \
  --region us-west-2 \
  --query "Quotas[?contains(QuotaName, 'p5')]" \
  --output table
```

### Availability Zone Capacity

Larger clusters require more instances in a single AZ. If the AZ does not have enough capacity, the update will fail. Consider:
- Requesting capacity reservations from AWS for large clusters
- Deploying during off-peak hours when capacity is more available
- Starting the scale-up early so you have time to troubleshoot if it fails

### Cost Impact

Scaling has a direct impact on cost. See the [Cost Management guide](09-cost-management.md) for detailed estimates:

| Size Change | GPU (p5.48xlarge) Cost Change | Trainium (trn1.32xlarge) Cost Change |
|------------|-------------------------------|--------------------------------------|
| small to medium | +$397/hr (~$9,528/day) | +$148/hr (~$3,552/day) |
| medium to large | +$1,590/hr (~$38,160/day) | +$594/hr (~$14,256/day) |
| small to large | +$1,987/hr (~$47,688/day) | +$742/hr (~$17,808/day) |

### After Scaling

Once the update completes:

1. **Verify all new nodes are running:**
   ```bash
   # Slurm
   sinfo

   # EKS
   kubectl get nodes
   ```

2. **Re-run benchmarks** to verify network performance at the new scale. See [Benchmarking](07-benchmarking.md).

3. **Check that `/fsx` is mounted** on all new nodes and contains your restored data.

---

## Next Steps

- [Understand your costs](09-cost-management.md) before and after scaling
- [Run benchmarks](07-benchmarking.md) after scaling to verify network performance
- [Clean up](10-teardown.md) when you are done
