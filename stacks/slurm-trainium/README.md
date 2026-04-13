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

```bash
aws cloudformation create-stack \
  --stack-name my-hyperpod-trn \
  --template-body file://template.yaml \
  --parameters file://params/small.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-west-2
```

## After deployment

```bash
# Connect to controller
aws ssm start-session --target <controller-instance-id>

# Verify Neuron devices
srun -N 1 neuron-ls

# Activate shared Neuron environment
source /fsx/envs/neuron-env/bin/activate

# Submit a test job
sbatch -N 2 --wrap="srun neuron-ls"
```

## Cluster sizes

| Size | Workers | NeuronCores | FSx Storage | Estimated cost |
|------|---------|-------------|-------------|----------------|
| small | 2x trn1.32xlarge | 32 | 1.2 TB | ~$50/hr |
| medium | 8x trn1.32xlarge | 128 | 4.8 TB | ~$200/hr |
| large | 32x trn1.32xlarge | 512 | 14.4 TB | ~$797/hr |
