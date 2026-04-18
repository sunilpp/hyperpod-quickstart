# Slurm + AWS Trainium

Deploys a SageMaker HyperPod cluster with Slurm orchestrator and AWS Trainium instances for cost-efficient PyTorch training.

## What gets deployed

- VPC with public/private subnets, NAT gateway
- Security group with EFA rules
- FSx for Lustre shared filesystem
- Slurm controller node (ml.m5.2xlarge)
- Trainium worker nodes (ml.trn1.32xlarge by default)
- Neuron SDK environment on shared FSx
- Amazon Managed Prometheus + Grafana with Neuron dashboards (optional)
- Post-deploy validation (optional)
- NCCOM benchmarks (optional)

## Deploy

### Recommended: Launch script

From the repo root, run:

```bash
./scripts/deploy.sh slurm-trainium YOUR_S3_BUCKET us-west-2
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
  --stack-name my-hyperpod-trn \
  --template-body file://packaged.yaml \
  --parameters file://params/small.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-west-2
```

## After deployment

```bash
# Connect to controller (from your local machine)
./scripts/remote-nccl-test.sh my-hyperpod-trn us-west-2

# On the controller:
sinfo                    # Check cluster status
srun -N 1 neuron-ls      # Verify Neuron devices
```

## Cluster sizes

| Size | Workers | NeuronCores | FSx Storage | Estimated cost |
|------|---------|-------------|-------------|----------------|
| small | 2x trn1.32xlarge | 32 | 1.2 TB | ~$50/hr |
| medium | 8x trn1.32xlarge | 128 | 4.8 TB | ~$200/hr |
| large | 32x trn1.32xlarge | 512 | 14.4 TB | ~$797/hr |
