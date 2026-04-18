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

### Recommended: Launch script

From the repo root, run:

```bash
./scripts/deploy.sh slurm-gpu YOUR_S3_BUCKET us-west-2
```

This packages nested templates, uploads to S3, and opens the CloudFormation console with everything pre-filled.

### Via AWS CLI

```bash
# Package nested templates (required)
aws cloudformation package \
  --template-file template.yaml \
  --s3-bucket YOUR_S3_BUCKET \
  --output-template-file packaged.yaml

# Deploy
aws cloudformation create-stack \
  --stack-name my-hyperpod-cluster \
  --template-body file://packaged.yaml \
  --parameters file://params/small.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-west-2
```

## After deployment

```bash
# Connect to controller (from your local machine)
./scripts/remote-nccl-test.sh my-hyperpod-slurm us-west-2

# On the controller:
sinfo                    # Check cluster status
run-nccl-test 2 1        # NCCL benchmark (auto-detects EFA vs TCP)
run-nanogpt 2 1          # nanoGPT distributed training test
```

## Cluster sizes

| Size | Workers | GPUs | FSx Storage | Estimated cost |
|------|---------|------|-------------|----------------|
| small | 2x p5.48xlarge | 16x H100 | 1.2 TB | ~$133/hr |
| medium | 8x p5.48xlarge | 64x H100 | 4.8 TB | ~$530/hr |
| large | 32x p5.48xlarge | 256x H100 | 14.4 TB | ~$2,120/hr |
