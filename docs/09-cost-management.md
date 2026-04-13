# Cost Management

HyperPod clusters run continuously -- you are charged for every hour the instances are running, whether or not you are actively training. This guide helps you understand, monitor, and optimize your costs.

---

## Cost Breakdown by Component

### Instance Costs (The Dominant Component)

Instances make up the vast majority of your bill (typically 95% or more).

| Instance Type | Per-Hour Cost | Accelerators | Typical Use |
|---------------|---------------|-------------|------------|
| `ml.p5.48xlarge` | ~$65.85 | 8x H100 80 GB | Large-scale GPU training |
| `ml.p4d.24xlarge` | ~$32.77 | 8x A100 40 GB | GPU training |
| `ml.g5.48xlarge` | ~$16.29 | 8x A10G 24 GB | Smaller GPU workloads |
| `ml.trn1.32xlarge` | ~$24.78 | 16 NeuronCores v2 | Cost-efficient training |
| `ml.trn2.48xlarge` | ~$38.00 | 32 NeuronCores v3 | Next-gen Trainium |
| `ml.m5.2xlarge` | ~$0.46 | None (CPU) | Slurm controller |

*Prices are approximate on-demand rates for US West (Oregon) `us-west-2`. Prices vary by region.*

### Per-Stack Cost Estimates

#### Slurm + GPU (ml.p5.48xlarge)

| Component | Small (2 nodes) | Medium (8 nodes) | Large (32 nodes) |
|-----------|-----------------|-------------------|-------------------|
| Worker instances | $131.70/hr | $526.80/hr | $2,107.20/hr |
| Slurm controller | $0.46/hr | $0.46/hr | $0.46/hr |
| FSx for Lustre | ~$0.24/hr | ~$0.96/hr | ~$2.88/hr |
| NAT gateway | $0.045/hr | $0.045/hr | $0.045/hr |
| Monitoring (AMP + AMG) | ~$0.11/hr | ~$0.31/hr | ~$1.01/hr |
| **Total** | **~$133/hr** | **~$529/hr** | **~$2,112/hr** |
| **Daily** | **~$3,192** | **~$12,696** | **~$50,688** |
| **Monthly (30 days)** | **~$95,760** | **~$380,880** | **~$1,520,640** |

#### Slurm + Trainium (ml.trn1.32xlarge)

| Component | Small (2 nodes) | Medium (8 nodes) | Large (32 nodes) |
|-----------|-----------------|-------------------|-------------------|
| Worker instances | $49.56/hr | $198.24/hr | $792.96/hr |
| Slurm controller | $0.46/hr | $0.46/hr | $0.46/hr |
| Other (FSx, NAT, monitoring) | ~$0.42/hr | ~$1.37/hr | ~$3.94/hr |
| **Total** | **~$50/hr** | **~$200/hr** | **~$797/hr** |
| **Daily** | **~$1,200** | **~$4,800** | **~$19,128** |
| **Monthly (30 days)** | **~$36,000** | **~$144,000** | **~$573,840** |

#### EKS Variants

EKS stacks are nearly identical in cost to Slurm stacks. The EKS control plane costs $0.10/hr, while the Slurm controller (ml.m5.2xlarge) costs $0.46/hr. Net difference: EKS is about $0.36/hr cheaper.

### Non-Instance Costs

These are small compared to instances but worth understanding:

| Resource | Pricing | Estimated Monthly Cost |
|----------|---------|----------------------|
| **NAT Gateway** | $0.045/hr + $0.045/GB data processed | ~$33/month (fixed) + data transfer |
| **FSx for Lustre** | ~$0.145/GB-month (250 MB/s/TiB) | ~$174/month for 1.2 TB |
| **Amazon Managed Prometheus** | ~$0.03/10K metric samples ingested | $50-500/month depending on cluster size |
| **Amazon Managed Grafana** | $9/active user/month | $9/month per user who logs in |
| **S3** | $0.023/GB-month | Minimal (lifecycle scripts only) |
| **CloudWatch Logs** | $0.50/GB ingested | $5-50/month |

---

## Optimization Strategies

### 1. Delete When Idle (Highest Impact)

This is the single most impactful cost optimization. HyperPod clusters cannot be paused -- if you are not training, you are paying for idle instances.

```bash
# Delete the stack when not in use
aws cloudformation delete-stack --stack-name my-hyperpod-cluster --region us-west-2
```

> **Tip:** Treat cluster creation and deletion as routine operations, not special events. The stack deploys in 20-30 minutes. Keep your data in S3 and redeploy when you need to train.

### 2. Start Small

Always start with the `small` cluster size (2 worker nodes). Use it to:
- Verify your training script works
- Test data loading and preprocessing
- Profile GPU/NeuronCore utilization
- Estimate how long your full training run will take

Only scale up when you have confirmed your workload can actually use more nodes effectively.

### 3. Choose Trainium for PyTorch Workloads

Trainium offers approximately **2.5x better price-performance** compared to NVIDIA GPUs for standard PyTorch training:

| Metric | p5.48xlarge (GPU) | trn1.32xlarge (Trainium) | Advantage |
|--------|-------------------|--------------------------|-----------|
| Cost per hour (2 nodes) | ~$133 | ~$50 | Trainium is 2.7x cheaper |
| Typical training throughput | 1.0x (baseline) | ~0.8x | GPU is ~20% faster per instance |
| Cost per training step | 1.0x (baseline) | ~0.4x | Trainium is ~2.5x cheaper per step |

*Approximate values for typical transformer models. Actual results depend on your specific model and batch size.*

### 4. Use SageMaker Savings Plans

[SageMaker Savings Plans](https://aws.amazon.com/savingsplans/ml-pricing/) can reduce instance costs by up to 64% in exchange for a 1- or 3-year commitment:

| Plan Duration | Payment Option | Discount |
|---------------|---------------|----------|
| 1-year | No upfront | Up to 20% off |
| 1-year | All upfront | Up to 30% off |
| 3-year | No upfront | Up to 47% off |
| 3-year | All upfront | Up to 64% off |

> **Tip:** Even a 1-year no-upfront Savings Plan saves significant money if you plan to run HyperPod clusters regularly. There is no upfront cost -- you just commit to a minimum hourly spend.

### 5. Monitor Utilization

Use the [Grafana dashboards](06-observability.md) to ensure your GPUs/NeuronCores are actually being used:

- **GPU Utilization < 10% for 30 minutes** triggers the `GPUUnderutilized` alert
- **Target:** GPU utilization should be above 80% during active training
- If utilization is consistently low, your workload may not need the current cluster size

Key things to look for:
- Long periods of low utilization between training jobs
- GPUs idle during data loading (indicates a data pipeline bottleneck, not a compute bottleneck)
- Only a fraction of GPUs active (indicates your training code may not be fully distributed)

### 6. Disable Unnecessary Features

If you do not need monitoring or benchmarks, disable them:

```bash
aws cloudformation update-stack \
  --stack-name my-hyperpod-cluster \
  --use-previous-template \
  --parameters \
    ParameterKey=EnableObservability,ParameterValue=false \
    ParameterKey=RunBenchmarks,ParameterValue=false \
    ParameterKey=ClusterName,UsePreviousValue=true \
    ParameterKey=ClusterSize,UsePreviousValue=true \
    ParameterKey=AvailabilityZoneId,UsePreviousValue=true \
    ParameterKey=TemplateBaseUrl,UsePreviousValue=true \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-west-2
```

Savings: ~$60-200/month from Prometheus + Grafana costs.

> **Tip:** Keep observability enabled at least during initial setup and your first few training runs. The dashboards are invaluable for identifying issues. You can disable them later once your workflow is stable.

### 7. Reduce NAT Gateway Costs

The S3 VPC endpoint (included in the stack) already avoids NAT charges for S3 traffic. For further savings:

- Add VPC endpoints for ECR if you pull many container images
- Add VPC endpoints for CloudWatch if you generate many logs
- Pre-stage large datasets on FSx instead of downloading them through NAT each time

---

## Tracking Costs

### AWS Cost Explorer

1. Open [AWS Cost Explorer](https://console.aws.amazon.com/cost-management/home#/cost-explorer)
2. Filter by **Service** = "Amazon SageMaker"
3. Group by **Usage Type** to see instance-level costs
4. Set the date range to cover your cluster's lifetime

### Using Tags for Cost Attribution

All resources created by the stack are tagged with `Name: <ClusterName>-*`. You can use these tags in Cost Explorer:

1. In Cost Explorer, choose **Tag** as the group-by dimension
2. Select the `Name` tag
3. Filter for your cluster name prefix

> **Tip:** If you run multiple clusters or share an account with other teams, consider adding custom tags to the CloudFormation stack for better cost attribution.

### Setting Up Cost Anomaly Detection

[AWS Cost Anomaly Detection](https://console.aws.amazon.com/cost-management/home#/anomaly-detection) can alert you if HyperPod spending spikes unexpectedly. This is especially useful if someone forgets to delete an idle cluster.

1. Open Cost Anomaly Detection in the AWS console
2. Create a new monitor
3. Set it to monitor "AWS services" and select SageMaker
4. Configure alert thresholds (for example, alert if daily cost exceeds $5,000)
5. Add an email or SNS notification

### Setting Up a Budget

Create an AWS Budget to get alerts before costs exceed a threshold:

```bash
aws budgets create-budget \
  --account-id $(aws sts get-caller-identity --query Account --output text) \
  --budget '{
    "BudgetName": "HyperPod-Monthly",
    "BudgetLimit": {"Amount": "10000", "Unit": "USD"},
    "BudgetType": "COST",
    "TimeUnit": "MONTHLY",
    "CostFilters": {"Service": ["Amazon SageMaker"]}
  }' \
  --notifications-with-subscribers '[{
    "Notification": {
      "NotificationType": "ACTUAL",
      "ComparisonOperator": "GREATER_THAN",
      "Threshold": 80,
      "ThresholdType": "PERCENTAGE"
    },
    "Subscribers": [{
      "SubscriptionType": "EMAIL",
      "Address": "your-email@example.com"
    }]
  }]'
```

---

## Example Cost Scenarios

### Scenario 1: Weekly Training Runs

You train for 8 hours every weekday, then delete the cluster.

| Stack | Hours/Week | Weekly Cost | Monthly Cost (4 weeks) |
|-------|-----------|-------------|------------------------|
| Slurm + GPU (small) | 40 | $133 x 40 = **$5,320** | **$21,280** |
| Slurm + Trainium (small) | 40 | $50 x 40 = **$2,000** | **$8,000** |

### Scenario 2: Always-On Development Cluster

You keep a small cluster running 24/7 for experimentation.

| Stack | Monthly Cost |
|-------|-------------|
| Slurm + GPU (small) | 720 hrs x $133 = **$95,760** |
| Slurm + Trainium (small) | 720 hrs x $50 = **$36,000** |

> **Warning:** An always-on GPU cluster costs nearly $100,000/month even at the smallest size. Make sure this is justified by your team's usage patterns. Consider using [SageMaker Training Jobs](https://docs.aws.amazon.com/sagemaker/latest/dg/how-it-works-training.html) for ephemeral workloads if you do not need a persistent cluster.

### Scenario 3: Large-Scale Training Burst

You scale to 32 nodes for a 48-hour training run, then delete.

| Stack | Cost for 48 Hours |
|-------|-------------------|
| Slurm + GPU (large) | 48 hrs x $2,112 = **$101,376** |
| Slurm + Trainium (large) | 48 hrs x $797 = **$38,256** |

### Scenario 4: Savings Plan Impact

A 1-year all-upfront Savings Plan (30% discount) on Scenario 1:

| Stack | Monthly Without SP | Monthly With SP | Savings |
|-------|-------------------|-----------------|---------|
| Slurm + GPU (small) | $21,280 | $14,896 | **$6,384/month** |
| Slurm + Trainium (small) | $8,000 | $5,600 | **$2,400/month** |

---

## Next Steps

- [Clean up your cluster](10-teardown.md) when you are done to stop incurring charges
- [Scale your cluster](08-scaling.md) to match your actual workload needs
- [Monitor utilization](06-observability.md) to identify waste
