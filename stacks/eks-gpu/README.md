# EKS + NVIDIA GPU

Deploys a SageMaker HyperPod cluster with Amazon EKS orchestrator and NVIDIA GPU instances.

## What gets deployed

- VPC with public/private subnets, NAT gateway
- Security group with EFA rules
- Amazon EKS cluster with managed add-ons
- FSx for Lustre shared filesystem
- GPU worker nodes (ml.p5.48xlarge by default)
- Amazon Managed Prometheus + Grafana with GPU dashboards (optional)
- Post-deploy validation (optional)
- NCCL benchmarks (optional)

## Deploy

### Recommended: Launch script

From the repo root, run:

```bash
./scripts/deploy.sh eks-gpu YOUR_S3_BUCKET us-west-2
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
  --stack-name my-hyperpod-eks \
  --template-body file://packaged.yaml \
  --parameters file://params/small.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-west-2
```

## After deployment

```bash
# Configure kubectl
aws eks update-kubeconfig --name my-hyperpod-eks-eks-cluster --region us-west-2

# Check nodes (may take a few minutes for nodes to appear)
kubectl get nodes

# Run NCCL benchmark
./scripts/run-nccl-test-eks.sh my-hyperpod-eks-eks-cluster 2 1 us-west-2

# Submit a test job
kubectl apply -f ../../examples/submit-pytorch-job/eks/pytorchjob.yaml
```

> **Note:** HyperPod Helm chart dependencies (device plugins, health monitoring, Kubeflow)
> are installed automatically via a Lambda Custom Resource during stack creation.
> No manual `helm install` step is needed.

## Cluster sizes

| Size | Workers | GPUs | FSx Storage | Estimated cost |
|------|---------|------|-------------|----------------|
| small | 2x p5.48xlarge | 16x H100 | 1.2 TB | ~$133/hr |
| medium | 8x p5.48xlarge | 64x H100 | 4.8 TB | ~$530/hr |
| large | 32x p5.48xlarge | 256x H100 | 14.4 TB | ~$2,120/hr |
