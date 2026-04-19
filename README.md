# AWS SageMaker HyperPod Quick Start

Deploy a fully configured SageMaker HyperPod cluster in under 30 minutes. One click to deploy, one command to connect, one command to test.

## One-Click Deploy

| | **NVIDIA GPU** (p5, p4d, g5) | **AWS Trainium** (trn1, trn2) |
|:---:|:---:|:---:|
| **Slurm** | [![Launch Stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](https://us-west-2.console.aws.amazon.com/cloudformation/home?region=us-west-2#/stacks/create/review?templateURL=https%3A%2F%2Fs3.amazonaws.com%2Fhyperpodstackfiles%2Fhyperpod-quickstart%2Fslurm-gpu%2Ftemplate.yaml&stackName=my-hyperpod&param_LifecycleScriptSourceBucket=hyperpodstackfiles&param_LifecycleScriptSourcePrefix=hyperpod-quickstart/slurm-gpu/lifecycle-scripts) | [![Launch Stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](https://us-west-2.console.aws.amazon.com/cloudformation/home?region=us-west-2#/stacks/create/review?templateURL=https%3A%2F%2Fs3.amazonaws.com%2Fhyperpodstackfiles%2Fhyperpod-quickstart%2Fslurm-trainium%2Ftemplate.yaml&stackName=my-hyperpod-trn&param_LifecycleScriptSourceBucket=hyperpodstackfiles&param_LifecycleScriptSourcePrefix=hyperpod-quickstart/slurm-trainium/lifecycle-scripts) |
| **Amazon EKS** | [![Launch Stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](https://us-west-2.console.aws.amazon.com/cloudformation/home?region=us-west-2#/stacks/create/review?templateURL=https%3A%2F%2Fs3.amazonaws.com%2Fhyperpodstackfiles%2Fhyperpod-quickstart%2Feks-gpu%2Ftemplate.yaml&stackName=my-hyperpod-eks&param_LifecycleScriptSourceBucket=hyperpodstackfiles&param_LifecycleScriptSourcePrefix=hyperpod-quickstart/eks-gpu/lifecycle-scripts) | [![Launch Stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](https://us-west-2.console.aws.amazon.com/cloudformation/home?region=us-west-2#/stacks/create/review?templateURL=https%3A%2F%2Fs3.amazonaws.com%2Fhyperpodstackfiles%2Fhyperpod-quickstart%2Feks-trainium%2Ftemplate.yaml&stackName=my-hyperpod-eks-trn&param_LifecycleScriptSourceBucket=hyperpodstackfiles&param_LifecycleScriptSourcePrefix=hyperpod-quickstart/eks-trainium/lifecycle-scripts) |

> Click any button to open CloudFormation with all parameters pre-filled. Review and click **Create stack**.
>
> Using a different S3 bucket or region? Run `./scripts/publish.sh YOUR_BUCKET us-west-2` to generate buttons for your setup.

## Stack Guides

| Guide | Description |
|-------|-------------|
| [Slurm + GPU](docs/guide-slurm-gpu.md) | Complete guide: deploy, connect, NCCL test, training, troubleshooting |
| [Slurm + Trainium](docs/guide-slurm-trainium.md) | Trainium-specific setup with Neuron SDK auto-detection |
| [EKS + GPU](docs/guide-eks-gpu.md) | Kubernetes deployment with automated Helm chart, MPIJob testing |
| [EKS + Trainium](docs/guide-eks-trainium.md) | EKS with Neuron device plugin |

---

## Prerequisites

```bash
# 1. Clone this repo
git clone https://github.com/sunilpp/hyperpod-quickstart.git && cd hyperpod-quickstart

# 2. Create an S3 bucket for templates (one-time)
aws s3 mb s3://YOUR_S3_BUCKET --region us-west-2

# 3. Check your AWS quotas
./scripts/check-quotas.sh ml.g5.16xlarge 2 us-west-2
```

**Requirements:**
- AWS account with [HyperPod access](https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod.html) in a [supported region](https://docs.aws.amazon.com/general/latest/gr/sagemaker.html)
- Service quota for your chosen instance type
- AWS CLI configured
- S3 bucket for CloudFormation template packaging

## Common Parameters

All stacks share these CloudFormation parameters:

| Parameter | Description | Default |
|-----------|-------------|---------|
| `ClusterName` | Name for your cluster | `my-hyperpod` |
| `ClusterSize` | `small` (2 nodes), `medium` (8), `large` (32) | `small` |
| `AvailabilityZoneId` | AZ with capacity for your instance type | `usw2-az2` |
| `WorkerInstanceType` | ML instance type for workers | varies by stack |
| `EnableObservability` | Prometheus + Grafana dashboards | `true` |
| `EnableValidation` | Post-deploy health checks | `true` |

## Instance Types and Networking

### GPU Instances

| Instance | GPUs | EFA | Network | NCCL Transport | Cost/hr |
|----------|------|-----|---------|---------------|---------|
| `ml.g5.16xlarge` | 1x A10G (24GB) | No | 25 Gbps TCP | Sockets | ~$7 |
| `ml.g5.48xlarge` | 8x A10G (192GB) | Yes | 100 Gbps EFA | SENDRECV | ~$20 |
| `ml.p4d.24xlarge` | 8x A100 (320GB) | Yes | 400 Gbps EFA | RDMA | ~$40 |
| `ml.p5.48xlarge` | 8x H100 (640GB) | Yes | 3200 Gbps EFA | RDMA | ~$66 |

### Trainium Instances

| Instance | NeuronCores | EFA | Network | Cost/hr |
|----------|------------|-----|---------|---------|
| `ml.trn1.32xlarge` | 32 | Yes | 800 Gbps | ~$25 |
| `ml.trn2.48xlarge` | 64 | Yes | 1600 Gbps | ~$45 |

### Cluster Sizes

| Size | Workers | FSx Storage | Best for |
|------|---------|-------------|----------|
| **small** | 2 | 1.2 TB | Development, testing, learning |
| **medium** | 8 | 4.8 TB | Moderate training runs |
| **large** | 32 | 14.4 TB | Large-scale distributed training |

## Networking and EFA

[Amazon Elastic Fabric Adapter (EFA)](https://aws.amazon.com/hpc/efa/) provides low-latency, high-throughput networking for distributed training. Key details:

- **EFA RDMA** — Direct GPU-to-GPU data transfer bypassing the CPU. Available on p4d, p5 instances. Delivers ~400 GB/s bandwidth.
- **EFA SENDRECV** — Available on g5.48xlarge. Lower bandwidth (~12 GB/s) but still faster than TCP.
- **TCP Sockets** — Fallback for non-EFA instances (g5.16xlarge). ~3 GB/s bandwidth.
- **Auto-detection** — All scripts (`run-nccl-test`, `run-nanogpt`) auto-detect EFA capability and configure the right transport. No manual setup needed.

### What gets configured automatically

| Component | Slurm | EKS |
|-----------|-------|-----|
| VPC + subnets + NAT | CloudFormation | CloudFormation |
| Security group (self-referencing for EFA) | CloudFormation | CloudFormation |
| VPC endpoints (ECR, STS, S3, CloudWatch) | CloudFormation | CloudFormation |
| FSx Lustre (auto-discovery + mount) | Lifecycle script | Lifecycle script |
| NCCL environment tuning | Lifecycle script | Container env |
| EFA RDMA detection | Lifecycle script + run-nccl-test | MPIJob manifest |
| SSH key distribution | Lifecycle script (via FSx or Slurm) | N/A (Kubernetes handles) |
| Slurm configless mode | Lifecycle script | N/A |
| HyperPod Helm chart | N/A | Lambda Custom Resource |

## Cost Estimates

| Stack | Small (2 nodes) | Medium (8 nodes) | Large (32 nodes) |
|-------|-----------------|-------------------|-------------------|
| **GPU** (p5.48xlarge) | ~$133/hr | ~$530/hr | ~$2,120/hr |
| **GPU** (g5.16xlarge) | ~$14/hr | ~$56/hr | ~$224/hr |
| **Trainium** (trn1.32xlarge) | ~$50/hr | ~$198/hr | ~$792/hr |

*Includes instances, FSx storage, NAT gateway. Actual costs vary by region. See [Cost Management](docs/09-cost-management.md).*

## Troubleshooting

```bash
# Diagnose stack failures (drills into nested stacks)
./scripts/stack-errors.sh <stack-name> us-west-2

# Check lifecycle logs (Slurm — on controller via SSM)
cat /var/log/hyperpod/on_create.log

# Check pod issues (EKS)
kubectl describe pod -n <namespace> <pod-name>
```

| Problem | Fix |
|---------|-----|
| `ResourceLimitExceeded` | Run `./scripts/check-quotas.sh` and request quota increases |
| `TemplateURL must be a supported URL` | Use `deploy.sh` — runs `cfn package` automatically |
| `ImagePullBackOff` on EKS | ECR permissions added in latest templates — redeploy |
| Orphaned IAM roles | Delete manually from previous failed stacks |
| Stack stuck in `ROLLBACK_FAILED` | `aws cloudformation delete-stack --stack-name <name>` |
| S3 bucket not empty on delete | Handled automatically by cleanup Lambda |

## Scripts Reference

| Script | Purpose | Run from |
|--------|---------|----------|
| `deploy.sh <variant> <bucket> [region]` | Package + deploy one stack | Local |
| `publish.sh <bucket> [region]` | Package + deploy all 4 stacks | Local |
| `check-quotas.sh <instance> <count> [region]` | Verify AWS quotas | Local |
| `stack-errors.sh <stack> [region]` | Diagnose CF failures | Local |
| `remote-nccl-test.sh <cluster> [region]` | SSM into Slurm controller | Local |
| `run-nccl-test [nodes] [gpus]` | NCCL benchmark | Controller (SSM) |
| `run-nanogpt [nodes] [gpus]` | Training test | Controller (SSM) |
| `run-nccl-test-eks.sh <cluster> [nodes] [gpus] [region]` | EKS NCCL via MPIJob | Local |

## Clean Up

```bash
aws cloudformation delete-stack --stack-name <stack-name> --region us-west-2
```

> **Warning:** This deletes everything including FSx data. Copy important data to S3 first.

## Architecture

```
CloudFormation Stack
├── NetworkingStack ─── VPC, subnets, NAT, VPC endpoints (ECR, STS, S3)
├── SecurityStack ───── Security group with self-referencing EFA rules
├── StorageStack ────── FSx Lustre filesystem
├── S3Stack ─────────── Lifecycle scripts bucket + upload Lambda
├── IAMStack ────────── Execution role (S3, ECR, EC2, FSx, SSM, EKS)
├── EKSStack ────────── EKS cluster + addons (EKS stacks only)
├── HelmChartStack ──── HyperPod Helm dependencies (EKS stacks only)
├── HyperPodStack ───── SageMaker HyperPod cluster
├── ObservabilityStack ─ Prometheus + Grafana (optional)
└── ValidationStack ──── Post-deploy health checks (optional)
```

## Repository Structure

```
hyperpod-quickstart/
├── stacks/                     # CloudFormation entry points (one per variant)
├── modules/                    # Shared nested stack templates
├── scripts/                    # Deploy, test, and diagnostic scripts
├── lifecycle-scripts/          # Node initialization (per variant)
├── examples/                   # NCCL tests + training job samples
├── docs/                       # Stack guides + detailed documentation
├── ROADMAP.md                  # Planned improvements
└── README.md                   # This file
```

## Roadmap

See [ROADMAP.md](ROADMAP.md) for planned improvements: GPU health checks, multi-user management, Slurm accounting, Enroot/Pyxis containers, multi-controller HA, and more.

## License

Apache-2.0. Built on patterns from the [AWS Distributed Training Reference Architecture](https://github.com/awslabs/awsome-distributed-training).
