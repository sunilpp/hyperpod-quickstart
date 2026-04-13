# AWS SageMaker HyperPod Quick Start

One-click CloudFormation deployment of fully configured SageMaker HyperPod clusters with built-in monitoring, health checks, and benchmarking.

## What is HyperPod?

[Amazon SageMaker HyperPod](https://aws.amazon.com/sagemaker/hyperpod/) is a purpose-built infrastructure for distributed machine learning training. It provides resilient clusters with automatic node recovery, pre-configured networking, and deep integration with popular ML frameworks. This repo gives you production-ready CloudFormation templates to deploy a complete HyperPod environment in under 30 minutes.

## Choose Your Setup

Pick the combination that matches your team and workload:

| | **NVIDIA GPU** (p5, p4d, g5) | **AWS Trainium** (trn1, trn2) |
|:---:|:---:|:---:|
| **Amazon EKS** | [![Launch Stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](#eks-gpu) | [![Launch Stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](#eks-trainium) |
| **Slurm** | [![Launch Stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](#slurm-gpu) | [![Launch Stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](#slurm-trainium) |

> **Not sure which to pick?** Read the [Choosing Your Stack](docs/02-choosing-your-stack.md) guide.
>
> **Quick rule of thumb:**
> - Your team uses Kubernetes daily → **EKS**
> - Your team runs HPC/research workloads → **Slurm**
> - You want the lowest cost per training hour → **Trainium**
> - You need maximum framework compatibility → **NVIDIA GPU**

## What Gets Deployed

Each stack creates a complete, ready-to-use environment:

```
┌─────────────────────────────────────────────────────────────────┐
│                    CloudFormation Stack                         │
│                                                                 │
│  ┌──────────┐  ┌──────────┐  ┌───────────┐  ┌──────────────┐  │
│  │   VPC    │  │ Security │  │    IAM    │  │  FSx Lustre  │  │
│  │ Subnets  │  │  Group   │  │   Roles   │  │   Storage    │  │
│  │ NAT/IGW  │  │  (EFA)   │  │           │  │              │  │
│  └──────────┘  └──────────┘  └───────────┘  └──────────────┘  │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │              SageMaker HyperPod Cluster                  │  │
│  │  ┌────────────────┐  ┌─────────────────────────────┐    │  │
│  │  │  Controller /  │  │     Worker Instances         │    │  │
│  │  │  EKS Cluster   │  │  (GPU or Trainium nodes)    │    │  │
│  │  └────────────────┘  └─────────────────────────────┘    │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│  ┌────────────┐  ┌──────────────┐  ┌───────────────────────┐  │
│  │ Prometheus │  │   Grafana    │  │   Validation &        │  │
│  │ Monitoring │  │  Dashboards  │  │   Health Checks       │  │
│  └────────────┘  └──────────────┘  └───────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### Included out of the box

- **Networking** — VPC, private/public subnets, NAT gateway, VPC endpoints
- **Shared storage** — FSx for Lustre high-performance filesystem
- **Monitoring** — Amazon Managed Prometheus + Grafana with pre-built dashboards
- **Health checks** — Automatic post-deployment validation (subnet, security group, node health)
- **Benchmarks** — Optional NCCL/NCCOM performance tests to verify cluster networking

## Prerequisites

1. **AWS Account** with [SageMaker HyperPod access](https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod.html) in a [supported region](https://docs.aws.amazon.com/general/latest/gr/sagemaker.html)
2. **Service quota** for your chosen instance type ([request increase](https://console.aws.amazon.com/servicequotas/home))
3. **IAM Identity Center** (AWS SSO) enabled — required for Grafana access

That's it. No CLI tools, no local setup required.

> **See:** [Full prerequisites guide](docs/01-prerequisites.md) for detailed requirements.

## Quick Start

### 1. Launch the stack

Click the "Launch Stack" button above for your chosen configuration, or:

```bash
# Using AWS CLI (replace STACK_VARIANT with: eks-gpu, eks-trainium, slurm-gpu, or slurm-trainium)
aws cloudformation create-stack \
  --stack-name my-hyperpod-cluster \
  --template-body file://stacks/STACK_VARIANT/template.yaml \
  --parameters file://stacks/STACK_VARIANT/params/small.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-west-2
```

### 2. Configure parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `ClusterName` | Name for your HyperPod cluster | `my-hyperpod` |
| `ClusterSize` | T-shirt size: small, medium, or large | `small` |
| `AvailabilityZoneId` | AZ with capacity for your instance type | `usw2-az2` |
| `EnableObservability` | Deploy Prometheus + Grafana dashboards | `true` |
| `EnableValidation` | Run post-deployment health checks | `true` |
| `RunBenchmarks` | Run NCCL/NCCOM performance benchmarks | `false` |

### Cluster sizes

| Size | Worker Instances | FSx Storage | Best for |
|------|-----------------|-------------|----------|
| **Small** | 2 | 1.2 TB | Development, testing, learning |
| **Medium** | 8 | 4.8 TB | Moderate training runs |
| **Large** | 32 | 14.4 TB | Large-scale distributed training |

### 3. Wait for deployment (~20–30 minutes)

Monitor progress in the [CloudFormation console](https://console.aws.amazon.com/cloudformation/).

### 4. Connect to your cluster

Once the stack shows `CREATE_COMPLETE`, find these in the **Outputs** tab:

| Output | What it is |
|--------|-----------|
| `ClusterArn` | Your HyperPod cluster ARN |
| `GrafanaDashboardUrl` | Link to monitoring dashboards |
| `ValidationResult` | Health check pass/fail summary |
| `FSxDnsName` | Shared filesystem DNS for mounting |

**For Slurm clusters:**
```bash
# Connect via SSM Session Manager
aws ssm start-session --target <controller-instance-id>

# Check cluster status
sinfo
squeue
```

**For EKS clusters:**
```bash
# Update kubeconfig
aws eks update-kubeconfig --name <cluster-name> --region <region>

# Check cluster status
kubectl get nodes
kubectl get pods -A
```

### 5. Submit your first job

```bash
# Slurm + GPU example
sbatch examples/submit-pytorch-job/slurm/submit.sh

# EKS + GPU example
kubectl apply -f examples/submit-pytorch-job/eks/pytorchjob.yaml

# Slurm + Trainium example
sbatch examples/submit-neuron-job/slurm/submit.sh
```

See [Running Your First Job](docs/05-running-first-job.md) for detailed walkthrough.

## Repository Structure

```
hyperpod-quickstart/
├── stacks/                     # Entry-point templates (one per combination)
│   ├── eks-gpu/                #   EKS + NVIDIA GPU
│   ├── eks-trainium/           #   EKS + AWS Trainium
│   ├── slurm-gpu/              #   Slurm + NVIDIA GPU
│   └── slurm-trainium/         #   Slurm + AWS Trainium
├── modules/                    # Shared nested stack templates
│   ├── networking/             #   VPC, subnets, NAT, endpoints
│   ├── security/               #   Security groups (EFA-enabled)
│   ├── storage/                #   FSx Lustre, S3 lifecycle bucket
│   ├── iam/                    #   Execution roles, policies
│   ├── eks/                    #   EKS cluster, add-ons
│   ├── hyperpod/               #   SageMaker HyperPod cluster
│   ├── observability/          #   Prometheus, Grafana, dashboards
│   ├── validation/             #   Post-deploy health checks
│   └── benchmarking/           #   NCCL/NCCOM performance tests
├── lifecycle-scripts/          # Node initialization scripts
├── lambda/                     # Custom resource Lambda functions
├── examples/                   # Sample training job submissions
└── docs/                       # Comprehensive documentation
```

## Documentation

| Guide | Description |
|-------|-------------|
| [Prerequisites](docs/01-prerequisites.md) | AWS account setup, quotas, permissions |
| [Choosing Your Stack](docs/02-choosing-your-stack.md) | Decision guide: EKS vs Slurm, GPU vs Trainium |
| [Deploying](docs/03-deploying.md) | Step-by-step deployment walkthrough |
| [Validating](docs/04-validating.md) | How to verify your cluster is healthy |
| [Running Jobs](docs/05-running-first-job.md) | Submit your first training job |
| [Monitoring](docs/06-observability.md) | Using Prometheus + Grafana dashboards |
| [Benchmarking](docs/07-benchmarking.md) | Verifying cluster network performance |
| [Scaling](docs/08-scaling.md) | Resizing your cluster |
| [Cost Management](docs/09-cost-management.md) | Understanding and optimizing costs |
| [Teardown](docs/10-teardown.md) | Cleaning up all resources |
| [Troubleshooting](docs/troubleshooting/common-errors.md) | Common issues and fixes |

## Stack Details

### <a name="eks-gpu"></a>EKS + NVIDIA GPU

Best for Kubernetes-native teams running PyTorch, JAX, or NeMo on NVIDIA hardware.

- **Default instance:** `ml.p5.48xlarge` (8x H100 GPUs, 3.2 Tbps EFA)
- **Orchestrator:** Amazon EKS with managed add-ons
- **Monitoring:** DCGM exporter, GPU utilization dashboards
- **Benchmarks:** NCCL all-reduce, point-to-point bandwidth

[Detailed guide](stacks/eks-gpu/README.md) | [Template](stacks/eks-gpu/template.yaml)

### <a name="eks-trainium"></a>EKS + AWS Trainium

Best for Kubernetes teams optimizing cost with AWS custom silicon.

- **Default instance:** `ml.trn1.32xlarge` (16 NeuronCores, 800 Gbps EFA)
- **Orchestrator:** Amazon EKS with Neuron device plugin
- **Monitoring:** Neuron Monitor, NeuronCore utilization dashboards
- **Benchmarks:** NCCOM all-reduce

[Detailed guide](stacks/eks-trainium/README.md) | [Template](stacks/eks-trainium/template.yaml)

### <a name="slurm-gpu"></a>Slurm + NVIDIA GPU

Best for HPC and research teams familiar with Slurm job scheduling.

- **Default instance:** `ml.p5.48xlarge` (8x H100 GPUs, 3.2 Tbps EFA)
- **Orchestrator:** Slurm (controller + workers)
- **Monitoring:** DCGM exporter, Slurm job metrics, GPU dashboards
- **Benchmarks:** NCCL all-reduce, point-to-point bandwidth

[Detailed guide](stacks/slurm-gpu/README.md) | [Template](stacks/slurm-gpu/template.yaml)

### <a name="slurm-trainium"></a>Slurm + AWS Trainium

Best for HPC teams optimizing training cost with AWS custom silicon.

- **Default instance:** `ml.trn1.32xlarge` (16 NeuronCores, 800 Gbps EFA)
- **Orchestrator:** Slurm (controller + workers)
- **Monitoring:** Neuron Monitor, Slurm metrics, NeuronCore dashboards
- **Benchmarks:** NCCOM all-reduce

[Detailed guide](stacks/slurm-trainium/README.md) | [Template](stacks/slurm-trainium/template.yaml)

## Clean Up

Delete the CloudFormation stack to remove **all** resources and stop incurring charges:

```bash
aws cloudformation delete-stack --stack-name my-hyperpod-cluster --region us-west-2
```

> **Warning:** This deletes everything including data on FSx. Copy important data to S3 first.
> See [Teardown Guide](docs/10-teardown.md) for details.

## Cost Estimates

| Stack | Small (2 nodes) | Medium (8 nodes) | Large (32 nodes) |
|-------|-----------------|-------------------|-------------------|
| **EKS + GPU** (p5.48xlarge) | ~$133/hr | ~$530/hr | ~$2,120/hr |
| **EKS + Trainium** (trn1.32xlarge) | ~$50/hr | ~$198/hr | ~$792/hr |
| **Slurm + GPU** (p5.48xlarge) | ~$133/hr | ~$530/hr | ~$2,119/hr |
| **Slurm + Trainium** (trn1.32xlarge) | ~$50/hr | ~$198/hr | ~$792/hr |

*Estimates include instances, FSx storage, NAT gateway, and monitoring. Actual costs vary by region. See [Cost Management](docs/09-cost-management.md).*

## Contributing

We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

This project is licensed under the Apache-2.0 License. See [LICENSE](LICENSE).

## Acknowledgments

Built on patterns from the [AWS Distributed Training Reference Architecture](https://github.com/awslabs/awsome-distributed-training).
