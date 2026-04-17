# Deploying Your Cluster

This guide walks you through deploying a SageMaker HyperPod cluster step by step. You can deploy via the AWS Console (no tools needed) or via the AWS CLI.

---

## Before You Begin

Make sure you have completed the [Prerequisites](01-prerequisites.md) and [chosen your stack](02-choosing-your-stack.md).

You need to know:

- **Which stack** to deploy: `eks-gpu`, `eks-trainium`, `slurm-gpu`, or `slurm-trainium`
- **Which region** to deploy in (for example, `us-west-2`)
- **Which Availability Zone ID** has capacity for your instance type (for example, `usw2-az2`)
- **Which cluster size** you want: small (2 nodes), medium (8 nodes), or large (32 nodes)

---

## Option A: Deploy via the AWS Console

This is the simplest method. No tools or CLI required.

### Step 1: Open the CloudFormation Console

Go to the [AWS CloudFormation console](https://console.aws.amazon.com/cloudformation/) and make sure you have selected the correct region in the top-right dropdown.

### Step 2: Create a New Stack

1. First, package the template using the CLI (this uploads nested templates to S3):
   ```bash
   aws cloudformation package \
     --template-file stacks/STACK_VARIANT/template.yaml \
     --s3-bucket YOUR_S3_BUCKET \
     --output-template-file packaged.yaml
   ```
2. Choose **Create stack** > **With new resources (standard)**
3. Under **Specify template**, select **Upload a template file**
4. Upload the **packaged.yaml** file generated in step 1
5. Choose **Next**

> **Note:** You must use the packaged template because this project uses nested stacks. The raw template files contain relative paths that CloudFormation cannot resolve directly.

### Step 3: Configure Stack Parameters

Enter a **Stack name** (for example, `my-hyperpod-cluster`), then fill in the parameters:

#### Cluster Configuration

| Parameter | What to Enter | Example |
|-----------|---------------|---------|
| **ClusterName** | A name for your HyperPod cluster. Letters, numbers, and hyphens only. | `my-hyperpod` |
| **ClusterSize** | Choose `small`, `medium`, or `large`. Start with `small` for testing. | `small` |
| **AvailabilityZoneId** | The AZ ID with capacity for your instance type. | `usw2-az2` |

#### Advanced - Instance Configuration

| Parameter | What to Enter | Default |
|-----------|---------------|---------|
| **WorkerInstanceType** | The ML instance type for worker nodes. | `ml.p5.48xlarge` (GPU) or `ml.trn1.32xlarge` (Trainium) |
| **ControllerInstanceType** | (Slurm only) Instance type for the head node. | `ml.m5.2xlarge` |
| **KubernetesVersion** | (EKS only) Kubernetes version. | `1.31` |

#### Features

| Parameter | What to Enter | Default |
|-----------|---------------|---------|
| **EnableObservability** | Set to `true` to deploy Prometheus + Grafana dashboards. | `true` |
| **EnableValidation** | Set to `true` to run automatic health checks after deployment. | `true` |
| **RunBenchmarks** | Set to `true` to run NCCL/NCCOM network performance benchmarks. | `false` |

### Step 4: Configure Stack Options

1. Under **Permissions**, you can optionally specify an IAM role for CloudFormation to use. If you leave this blank, CloudFormation uses your current permissions.
2. Under **Stack failure options**, keep the default ("Roll back all stack resources").
3. Choose **Next**.

### Step 5: Review and Create

1. Review all your settings
2. At the bottom, check the box: **I acknowledge that AWS CloudFormation might create IAM resources with custom names**
3. Choose **Submit**

### Step 6: Wait for Deployment

The stack typically takes **20 to 30 minutes** to complete. You can monitor progress in the CloudFormation console:

1. Select your stack
2. Open the **Events** tab to see resources being created
3. Wait until the stack status shows **CREATE_COMPLETE**

If the status shows **ROLLBACK_IN_PROGRESS** or **CREATE_FAILED**, see the [Troubleshooting guide](troubleshooting/common-errors.md).

---

## Option B: Deploy via the Launch Script (recommended)

The launch script packages nested templates, uploads them to S3, and opens the CloudFormation console in your browser with the template and stack name pre-filled. You review the parameters and click **Create stack**.

```bash
# Create an S3 bucket for templates (one-time setup)
BUCKET_NAME="my-hyperpod-templates-$(aws sts get-caller-identity --query Account --output text)"
aws s3 mb s3://$BUCKET_NAME --region us-west-2

# Package, upload, and open the CloudFormation console
./scripts/deploy.sh slurm-gpu $BUCKET_NAME us-west-2
```

The script supports all four variants: `slurm-gpu`, `slurm-trainium`, `eks-gpu`, `eks-trainium`.

## Option C: Deploy via the AWS CLI (manual)

If you prefer full CLI control without the browser, you can package and deploy manually.

### Step 1: Package the Templates

Because this project uses nested CloudFormation stacks, you need to package the templates first. The `aws cloudformation package` command automatically uploads nested templates to S3.

```bash
# Create an S3 bucket for templates (one-time setup)
BUCKET_NAME="my-hyperpod-templates-$(aws sts get-caller-identity --query Account --output text)"
aws s3 mb s3://$BUCKET_NAME --region us-west-2

# Package the templates (replace STACK_VARIANT with your choice)
# Options: slurm-gpu, slurm-trainium, eks-gpu, eks-trainium
aws cloudformation package \
  --template-file stacks/STACK_VARIANT/template.yaml \
  --s3-bucket $BUCKET_NAME \
  --output-template-file packaged.yaml
```

### Step 2: Deploy the Stack

```bash
aws cloudformation create-stack \
  --stack-name my-hyperpod-cluster \
  --template-body file://packaged.yaml \
  --parameters \
    ParameterKey=ClusterName,ParameterValue=my-hyperpod \
    ParameterKey=ClusterSize,ParameterValue=small \
    ParameterKey=AvailabilityZoneId,ParameterValue=usw2-az2 \
    ParameterKey=EnableObservability,ParameterValue=true \
    ParameterKey=EnableValidation,ParameterValue=true \
    ParameterKey=RunBenchmarks,ParameterValue=false \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-west-2
```

> **Tip:** You can also use a parameter file instead of inline parameters. Pre-built parameter files are available in `stacks/<variant>/params/`:

```bash
aws cloudformation create-stack \
  --stack-name my-hyperpod-cluster \
  --template-body file://packaged.yaml \
  --parameters file://stacks/slurm-gpu/params/small.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-west-2
```

### Step 3: Monitor the Deployment

```bash
# Watch stack events in real time
aws cloudformation describe-stack-events \
  --stack-name my-hyperpod-cluster \
  --region us-west-2 \
  --query 'StackEvents[*].[Timestamp,ResourceType,LogicalResourceId,ResourceStatus]' \
  --output table

# Wait for the stack to complete (blocks until done)
aws cloudformation wait stack-create-complete \
  --stack-name my-hyperpod-cluster \
  --region us-west-2
```

### Step 4: View the Outputs

Once the stack is complete, retrieve the important outputs:

```bash
aws cloudformation describe-stacks \
  --stack-name my-hyperpod-cluster \
  --region us-west-2 \
  --query 'Stacks[0].Outputs' \
  --output table
```

---

## What the Stack Creates

Here is what gets deployed (takes 20-30 minutes):

| Phase | Resources Created | Time |
|-------|-------------------|------|
| 1. Networking | VPC, subnets, NAT gateway, Internet gateway, S3 endpoint, route tables | ~2 min |
| 2. Security | Security group with self-referencing EFA rules | ~1 min |
| 3. Storage | FSx for Lustre filesystem, S3 lifecycle bucket | ~5 min |
| 4. IAM | Execution roles, policies | ~1 min |
| 5. EKS (EKS stacks only) | EKS control plane, managed add-ons | ~10 min |
| 6. HyperPod cluster | Cluster creation, instance provisioning, lifecycle scripts | ~10-15 min |
| 7. Observability (optional) | Prometheus workspace, Grafana workspace | ~3 min |
| 8. Validation (optional) | Lambda-based health checks | ~2 min |
| 9. Benchmarks (optional) | Benchmark runner Lambda, results in S3 | ~2 min |

---

## Connecting to Your Cluster

Once the stack shows `CREATE_COMPLETE`, you can connect.

### Slurm Clusters

Connect to the head node using SSM Session Manager:

```bash
# Find the controller instance ID from the SageMaker console,
# or from the stack outputs
aws ssm start-session --target <controller-instance-id> --region us-west-2
```

Once connected, verify the cluster is working:

```bash
# Check Slurm cluster status
sinfo

# Check running jobs
squeue

# Check the shared filesystem
ls /fsx

# Check GPUs (GPU stacks)
nvidia-smi

# Check Neuron devices (Trainium stacks)
neuron-ls
```

### EKS Clusters

Configure kubectl and verify the cluster:

```bash
# Update your kubeconfig (the exact command is in the stack Outputs)
aws eks update-kubeconfig --name <cluster-name> --region us-west-2

# Check nodes
kubectl get nodes

# Check system pods
kubectl get pods -A

# Check for GPU resources (GPU stacks)
kubectl describe nodes | grep nvidia.com/gpu

# Check for Neuron resources (Trainium stacks)
kubectl describe nodes | grep aws.amazon.com/neuron
```

---

## Stack Outputs Reference

After deployment, these outputs are available in the CloudFormation console (Outputs tab) or via the CLI:

| Output | Description | Available In |
|--------|-------------|-------------|
| `ClusterArn` | The ARN of your HyperPod cluster | All stacks |
| `ClusterName` | The name of your HyperPod cluster | All stacks |
| `VpcId` | The VPC where everything is deployed | All stacks |
| `FSxDnsName` | DNS name of the shared filesystem | All stacks |
| `LifecycleScriptsBucket` | S3 bucket containing lifecycle scripts | All stacks |
| `GrafanaDashboardUrl` | URL to access Grafana dashboards | When observability is enabled |
| `PrometheusEndpoint` | Prometheus remote write endpoint | When observability is enabled |
| `ValidationResult` | PASS or FAIL from automated health checks | When validation is enabled |
| `BenchmarkResults` | S3 path to benchmark results | When benchmarks are enabled |
| `EKSClusterName` | Name of the EKS cluster | EKS stacks only |
| `EKSClusterEndpoint` | EKS API server endpoint | EKS stacks only |
| `KubeconfigCommand` | Command to configure kubectl | EKS stacks only |

---

## Next Steps

- [Validate your cluster](04-validating.md) to confirm everything is healthy
- [Run your first training job](05-running-first-job.md)
- [Set up monitoring](06-observability.md) to view Grafana dashboards
