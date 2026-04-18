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

> **One-command launch:** Run `./scripts/deploy.sh <variant> <s3-bucket> [region]` to package templates, upload to S3, and open the CloudFormation console with everything pre-filled. See [Quick Start](#quick-start) below.

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
- **Shared storage** — FSx for Lustre with auto-discovery (nodes mount automatically)
- **Lifecycle scripts** — Automatic node type detection, Slurm configless setup, SSH key distribution, MUNGE auth
- **NCCL benchmarks** — Pre-installed `run-nccl-test` on controller, auto-detects EFA vs TCP
- **EKS Helm automation** — HyperPod dependencies installed via Lambda (no manual helm install)
- **Monitoring** — Amazon Managed Prometheus + Grafana with pre-built dashboards (optional)
- **Health checks** — Post-deployment validation of cluster, subnet, security group (optional)
- **Diagnostics** — Quota checker, stack error driller, lifecycle log viewer

## Prerequisites

1. **AWS Account** with [SageMaker HyperPod access](https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod.html) in a [supported region](https://docs.aws.amazon.com/general/latest/gr/sagemaker.html)
2. **Service quota** for your chosen instance type — run `./scripts/check-quotas.sh` to verify
3. **S3 bucket** for CloudFormation template packaging
4. **IAM Identity Center** (AWS SSO) enabled — required for Grafana access (if observability enabled)

That's it. No CLI tools, no local setup required.

> **See:** [Full prerequisites guide](docs/01-prerequisites.md) for detailed requirements.

## Quick Start

### 0. Check prerequisites

```bash
# Verify your AWS quotas before deploying
./scripts/check-quotas.sh ml.g5.16xlarge 2 us-west-2
```

### 1. Launch the stack

```bash
# Create an S3 bucket for templates (one-time setup)
aws s3 mb s3://YOUR_S3_BUCKET --region us-west-2

# Launch — opens CloudFormation console in your browser
./scripts/deploy.sh slurm-gpu YOUR_S3_BUCKET us-west-2
```

The script packages templates, uploads lifecycle scripts to S3, and opens the CloudFormation console with parameters pre-filled. Review and click **Create stack**.

Supports all four variants: `slurm-gpu`, `slurm-trainium`, `eks-gpu`, `eks-trainium`.

<details>
<summary><b>Alternative: Manual CLI deployment</b></summary>

```bash
# Step 1: Package (uploads nested templates to S3)
aws cloudformation package \
  --template-file stacks/STACK_VARIANT/template.yaml \
  --s3-bucket YOUR_S3_BUCKET \
  --output-template-file packaged.yaml

# Step 2: Deploy the packaged template
aws cloudformation create-stack \
  --stack-name my-hyperpod-cluster \
  --template-body file://packaged.yaml \
  --parameters file://stacks/STACK_VARIANT/params/small.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-west-2
```
</details>

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
# Connect via SSM (from your local machine)
./scripts/remote-nccl-test.sh my-hyperpod-slurm us-west-2

# Or connect via AWS console: Systems Manager > Session Manager
# Target format: sagemaker-cluster:<cluster-id>_controller-group-<instance-id>

# On the controller, check cluster status
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

### 5. Run NCCL benchmark

```bash
# Slurm: pre-installed on controller — just type:
run-nccl-test 2 1

# EKS: submit MPIJob
./scripts/run-nccl-test-eks.sh my-hyperpod-eks-eks-cluster 2 1 us-west-2
```

### 6. Submit your first training job

```bash
# Slurm + GPU example
sbatch examples/submit-pytorch-job/slurm/submit.sh

# EKS + GPU example
kubectl apply -f examples/submit-pytorch-job/eks/pytorchjob.yaml

# Slurm + Trainium example
sbatch examples/submit-neuron-job/slurm/submit.sh
```

See [Running Your First Job](docs/05-running-first-job.md) for detailed walkthrough.

### Troubleshooting

```bash
# Check stack errors (drills into nested stacks)
./scripts/stack-errors.sh my-hyperpod us-west-2

# Check lifecycle script logs (on controller via SSM)
cat /var/log/hyperpod/on_create.log
```

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
├── scripts/                    # Operational scripts
│   ├── deploy.sh               #   Package, upload, open CF console
│   ├── check-quotas.sh         #   Verify AWS service quotas
│   ├── stack-errors.sh         #   Diagnose CloudFormation failures
│   ├── remote-nccl-test.sh     #   SSM into controller for testing
│   ├── run-nccl-test.sh        #   Standalone NCCL benchmark
│   ├── run-nccl-test-eks.sh    #   EKS NCCL benchmark via MPIJob
│   └── install-eks-hyperpod-deps.sh  # Manual EKS Helm fallback
├── lifecycle-scripts/          # Node initialization scripts
│   ├── slurm/gpu/              #   GPU Slurm lifecycle + NCCL test
│   ├── slurm/trainium/         #   Trainium Slurm lifecycle
│   └── eks/                    #   EKS lifecycle (minimal)
├── lambda/                     # Custom resource Lambda functions
├── examples/                   # Sample jobs + NCCL benchmarks
│   ├── nccl-test/              #   NCCL test (Slurm sbatch + EKS MPIJob)
│   ├── submit-pytorch-job/     #   PyTorch distributed training
│   ├── submit-nemo-job/        #   NeMo GPT pretraining
│   └── submit-neuron-job/      #   Neuron/Trainium training
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
