# AWS SageMaker HyperPod Quick Start

Deploy a fully configured SageMaker HyperPod cluster in under 30 minutes. One command to deploy, one command to connect, one command to test.

## Choose Your Stack

| | **NVIDIA GPU** (p5, p4d, g5) | **AWS Trainium** (trn1, trn2) |
|:---:|:---:|:---:|
| **Slurm** | [Get Started](#slurm--nvidia-gpu) | [Get Started](#slurm--aws-trainium) |
| **Amazon EKS** | [Get Started](#eks--nvidia-gpu) | [Get Started](#eks--aws-trainium) |

> **Not sure?** Slurm for HPC/research teams. EKS for Kubernetes-native teams. Trainium for lowest cost. GPU for maximum compatibility.

## Prerequisites

```bash
# 1. Check your AWS quotas
./scripts/check-quotas.sh ml.g5.16xlarge 2 us-west-2

# 2. Create an S3 bucket for templates (one-time)
aws s3 mb s3://YOUR_S3_BUCKET --region us-west-2
```

You also need an AWS account with [HyperPod access](https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod.html) in a [supported region](https://docs.aws.amazon.com/general/latest/gr/sagemaker.html).

---

## Slurm + NVIDIA GPU

Best for HPC and research teams. Controller + worker architecture with Slurm job scheduling.

### Deploy

```bash
./scripts/deploy.sh slurm-gpu YOUR_S3_BUCKET us-west-2
```

Set parameters in the CloudFormation console:

| Parameter | Recommended for testing | Production |
|-----------|------------------------|------------|
| `WorkerInstanceType` | `ml.g5.16xlarge` | `ml.p5.48xlarge` |
| `EnableObservability` | `false` | `true` |
| `EnableValidation` | `false` | `true` |

Wait ~20 minutes for `CREATE_COMPLETE`.

### Connect

```bash
# SSM into the controller (from your local machine)
./scripts/remote-nccl-test.sh <cluster-name> us-west-2
```

### Test

On the controller:

```bash
# Verify cluster
sinfo

# NCCL all-reduce benchmark (auto-detects EFA vs TCP)
run-nccl-test 2 1

# Multi-node training test (nanoGPT on Shakespeare)
run-nanogpt 2 1
```

### Interpret Results

**NCCL test output:**
```
#       size      algbw   busbw
   134217728      3.01    3.01    # Peak bandwidth at 128MB
```
- g5.16xlarge (TCP): expect ~3 GB/s
- p5.48xlarge (EFA RDMA): expect ~400 GB/s

**nanoGPT output:**
```
iter 0: loss 4.1700    # Starting loss
iter 199: loss 3.0486  # Loss should decrease steadily
```

### Submit Training Jobs

```bash
sbatch examples/submit-pytorch-job/slurm/submit.sh
sbatch examples/nccl-test/slurm/train-nanogpt.sh
```

### Instance Types

| Instance | GPUs | EFA | Network | Cost/hr |
|----------|------|-----|---------|---------|
| `ml.g5.16xlarge` | 1x A10G | No | 25 Gbps TCP | ~$7 |
| `ml.g5.48xlarge` | 8x A10G | Yes | 100 Gbps | ~$20 |
| `ml.p4d.24xlarge` | 8x A100 | Yes | 400 Gbps | ~$40 |
| `ml.p5.48xlarge` | 8x H100 | Yes | 3200 Gbps | ~$66 |

### Cluster Sizes

| Size | Workers | GPUs (p5) | FSx Storage | Cost (p5)/hr |
|------|---------|-----------|-------------|-------------|
| small | 2 | 16x H100 | 1.2 TB | ~$133 |
| medium | 8 | 64x H100 | 4.8 TB | ~$530 |
| large | 32 | 256x H100 | 14.4 TB | ~$2,120 |

---

## Slurm + AWS Trainium

Best for cost-efficient distributed training with AWS custom silicon.

### Deploy

```bash
./scripts/deploy.sh slurm-trainium YOUR_S3_BUCKET us-west-2
```

### Connect

```bash
./scripts/remote-nccl-test.sh <cluster-name> us-west-2
```

### Test

```bash
sinfo
srun -N 1 neuron-ls    # Verify Neuron devices
```

### Key Differences from GPU

- Uses NCCOM (not NCCL) for collective communication — handled automatically by `torch-neuronx`
- Neuron environment auto-detected (trn1 vs trn2 core counts)
- DLAMI has pre-installed Neuron SDK — do not pip install over it

### Cluster Sizes

| Size | Workers | NeuronCores | FSx Storage | Cost/hr |
|------|---------|-------------|-------------|---------|
| small | 2x trn1.32xl | 32 | 1.2 TB | ~$50 |
| medium | 8x trn1.32xl | 128 | 4.8 TB | ~$200 |
| large | 32x trn1.32xl | 512 | 14.4 TB | ~$797 |

---

## EKS + NVIDIA GPU

Best for Kubernetes-native teams. No controller node — EKS is the control plane.

### Deploy

```bash
./scripts/deploy.sh eks-gpu YOUR_S3_BUCKET us-west-2
```

HyperPod Helm chart dependencies (device plugins, health monitoring, Kubeflow MPI operator) are installed automatically via a Lambda Custom Resource. No manual `helm install` needed.

### Connect

```bash
# Configure kubectl (one-time)
aws eks update-kubeconfig --name <cluster>-eks-cluster --region us-west-2

# Add your IAM user (one-time)
aws eks create-access-entry --cluster-name <cluster>-eks-cluster \
    --principal-arn arn:aws:iam::<account>:user/<username> \
    --type STANDARD --region us-west-2
aws eks associate-access-policy --cluster-name <cluster>-eks-cluster \
    --principal-arn arn:aws:iam::<account>:user/<username> \
    --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
    --access-scope type=cluster --region us-west-2
```

### Test

```bash
# Verify nodes and GPU resources
kubectl get nodes
kubectl get nodes -o json | jq '.items[].status.allocatable | {"nvidia.com/gpu"}'

# Run NCCL benchmark via MPIJob
./scripts/run-nccl-test-eks.sh <cluster>-eks-cluster 2 1 us-west-2
```

### Submit Training Jobs

```bash
kubectl apply -f examples/submit-pytorch-job/eks/pytorchjob.yaml
kubectl apply -f examples/nccl-test/eks/nccl-test-mpijob.yaml
```

---

## EKS + AWS Trainium

Best for Kubernetes teams optimizing cost with AWS custom silicon.

### Deploy

```bash
./scripts/deploy.sh eks-trainium YOUR_S3_BUCKET us-west-2
```

### Connect

Same as [EKS + GPU](#connect-2) — configure kubectl and add IAM access entry.

### Test

```bash
kubectl get nodes
kubectl describe nodes | grep aws.amazon.com/neuron
kubectl apply -f examples/submit-neuron-job/eks/job.yaml
```

---

## Troubleshooting

```bash
# Diagnose stack failures (drills into nested stacks)
./scripts/stack-errors.sh <stack-name> us-west-2

# Check lifecycle logs (Slurm — on controller via SSM)
cat /var/log/hyperpod/on_create.log

# Check pod issues (EKS)
kubectl describe pod -n <namespace> <pod-name>
kubectl logs <pod-name>
```

**Common issues:**

| Problem | Cause | Fix |
|---------|-------|-----|
| `TemplateURL must be a supported URL` | Templates not packaged | Use `deploy.sh` (runs `cfn package` automatically) |
| `ResourceLimitExceeded` | Service quota too low | Run `./scripts/check-quotas.sh` and request increases |
| `ec2:DeleteNetworkInterface` error | Missing IAM permission | Already fixed in current templates |
| `ImagePullBackOff` on EKS | Nodes can't reach ECR | VPC endpoints added in current templates |
| `NCCL_NET_PLUGIN=none` needed | Non-EFA instance (g5) | `run-nccl-test` auto-detects this |
| Orphaned IAM roles blocking deploy | Previous failed stack | Delete orphaned roles manually |

## Clean Up

```bash
aws cloudformation delete-stack --stack-name <stack-name> --region us-west-2
```

> **Warning:** This deletes everything including FSx data. Copy important data to S3 first.

## What Gets Deployed

```
┌─────────────────────────────────────────────────────────────────┐
│                    CloudFormation Stack                         │
│                                                                 │
│  ┌──────────┐  ┌──────────┐  ┌───────────┐  ┌──────────────┐  │
│  │   VPC    │  │ Security │  │    IAM    │  │  FSx Lustre  │  │
│  │ Subnets  │  │  Group   │  │   Roles   │  │   Storage    │  │
│  │ NAT/IGW  │  │  (EFA)   │  │           │  │              │  │
│  │ Endpoints│  │          │  │           │  │              │  │
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

## Scripts Reference

| Script | Purpose | Run from |
|--------|---------|----------|
| `deploy.sh` | Package + deploy stack | Local machine |
| `check-quotas.sh` | Verify AWS quotas | Local machine |
| `stack-errors.sh` | Diagnose CF failures | Local machine |
| `remote-nccl-test.sh` | SSM into controller | Local machine |
| `run-nccl-test` | NCCL benchmark | Controller (SSM) |
| `run-nanogpt` | Training test | Controller (SSM) |
| `run-nccl-test-eks.sh` | EKS NCCL benchmark | Local machine |

## Repository Structure

```
hyperpod-quickstart/
├── stacks/                     # CloudFormation entry points
│   ├── slurm-gpu/              #   Slurm + NVIDIA GPU
│   ├── slurm-trainium/         #   Slurm + AWS Trainium
│   ├── eks-gpu/                #   EKS + NVIDIA GPU
│   └── eks-trainium/           #   EKS + AWS Trainium
├── modules/                    # Shared nested stack templates
├── scripts/                    # Deploy, test, and diagnostic scripts
├── lifecycle-scripts/          # Node initialization (per variant)
├── examples/                   # NCCL tests + training job samples
├── ROADMAP.md                  # Planned improvements
└── docs/                       # Detailed documentation
```

## Roadmap

See [ROADMAP.md](ROADMAP.md) for planned improvements including GPU health checks, multi-user management, Slurm accounting, container runtime (Enroot/Pyxis), and multi-controller HA.

## License

Apache-2.0. See [LICENSE](LICENSE).

Built on patterns from the [AWS Distributed Training Reference Architecture](https://github.com/awslabs/awsome-distributed-training).
