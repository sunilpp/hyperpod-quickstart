# Slurm + NVIDIA GPU

Deploys a SageMaker HyperPod cluster with Slurm orchestrator and NVIDIA GPU instances.

## What gets deployed

- VPC with public/private subnets, NAT gateway
- Security group with EFA rules
- FSx for Lustre shared filesystem
- Slurm controller node (ml.m5.2xlarge)
- GPU worker nodes (ml.p5.48xlarge by default)
- Amazon Managed Prometheus + Grafana (optional)
- Post-deploy validation (optional)
- NCCL benchmarks (optional)

## Deploy

### Via AWS Console

1. Upload `template.yaml` to CloudFormation
2. Set parameters (or accept defaults)
3. Check "I acknowledge that AWS CloudFormation might create IAM resources with custom names"
4. Create stack

### Via AWS CLI

```bash
aws cloudformation create-stack \
  --stack-name my-hyperpod-cluster \
  --template-body file://template.yaml \
  --parameters file://params/small.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-west-2
```

## After deployment

```bash
# Connect to controller via SSM
aws ssm start-session --target <controller-instance-id>

# Check Slurm status
sinfo
squeue

# Submit a test job
sbatch -N 2 --gres=gpu:8 --wrap="srun nvidia-smi"
```

## Cluster sizes

| Size | Workers | GPUs | FSx Storage | Estimated cost |
|------|---------|------|-------------|----------------|
| small | 2x p5.48xlarge | 16x H100 | 1.2 TB | ~$133/hr |
| medium | 8x p5.48xlarge | 64x H100 | 4.8 TB | ~$530/hr |
| large | 32x p5.48xlarge | 256x H100 | 14.4 TB | ~$2,120/hr |
