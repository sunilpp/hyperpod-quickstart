# Cost Estimates

All prices are approximate, based on US West (Oregon) `us-west-2` on-demand pricing. Actual costs vary by region. See [AWS Pricing](https://aws.amazon.com/sagemaker/pricing/) for current rates.

## Instance costs (dominant component)

| Instance Type | Per-Hour | Accelerators | Use Case |
|---------------|----------|--------------|----------|
| ml.p5.48xlarge | ~$65.85 | 8x H100 80GB | Large-scale GPU training |
| ml.p4d.24xlarge | ~$32.77 | 8x A100 40GB | GPU training |
| ml.g5.48xlarge | ~$16.29 | 8x A10G 24GB | Smaller GPU workloads |
| ml.trn1.32xlarge | ~$24.78 | 16 NeuronCores v2 | Cost-efficient training |
| ml.trn2.48xlarge | ~$38.00 | 32 NeuronCores v3 | Next-gen Trainium |
| ml.m5.2xlarge | ~$0.46 | None (CPU) | Slurm controller |

## Per-stack estimates

### Slurm + GPU (p5.48xlarge)

| Component | Small (2) | Medium (8) | Large (32) |
|-----------|-----------|------------|------------|
| Workers | $131.70/hr | $526.80/hr | $2,107.20/hr |
| Controller | $0.46/hr | $0.46/hr | $0.46/hr |
| FSx Lustre | ~$0.24/hr | ~$0.96/hr | ~$2.88/hr |
| NAT Gateway | $0.045/hr | $0.045/hr | $0.045/hr |
| Monitoring | ~$0.11/hr | ~$0.31/hr | ~$1.01/hr |
| **Total** | **~$133/hr** | **~$529/hr** | **~$2,112/hr** |

### Slurm + Trainium (trn1.32xlarge)

| Component | Small (2) | Medium (8) | Large (32) |
|-----------|-----------|------------|------------|
| Workers | $49.56/hr | $198.24/hr | $792.96/hr |
| Controller | $0.46/hr | $0.46/hr | $0.46/hr |
| Other | ~$0.42/hr | ~$1.37/hr | ~$3.94/hr |
| **Total** | **~$50/hr** | **~$200/hr** | **~$797/hr** |

### EKS variants

Same as above plus EKS control plane ($0.10/hr), minus Slurm controller ($0.46/hr). Net ~$0.36/hr cheaper.

## Cost tips

1. **Delete when idle** — clusters run continuously; delete the stack when not training
2. **Start small** — use the "small" size to test, scale up when needed
3. **Choose Trainium** — ~2.5x better price-performance for PyTorch workloads
4. **Use Savings Plans** — SageMaker Savings Plans can reduce costs up to 64%
5. **Monitor utilization** — use included Grafana dashboards to spot idle instances
