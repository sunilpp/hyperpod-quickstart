# AWS SageMaker HyperPod Quick Start

Deploy a fully configured SageMaker HyperPod cluster in under 30 minutes. One click to deploy, one command to connect, one command to test.

## One-Click Deploy

| | **NVIDIA GPU** (p5, p4d, g5) | **AWS Trainium** (trn1, trn2) |
|:---:|:---:|:---:|
| **Slurm** | [![Launch Stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](https://us-west-2.console.aws.amazon.com/cloudformation/home?region=us-west-2#/stacks/create/review?templateURL=https%3A%2F%2Fs3.amazonaws.com%2Fhyperpodstackfiles%2Fhyperpod-quickstart%2Fslurm-gpu%2Ftemplate.yaml&stackName=my-hyperpod&param_LifecycleScriptSourceBucket=hyperpodstackfiles&param_LifecycleScriptSourcePrefix=hyperpod-quickstart/slurm-gpu/lifecycle-scripts) | [![Launch Stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](https://us-west-2.console.aws.amazon.com/cloudformation/home?region=us-west-2#/stacks/create/review?templateURL=https%3A%2F%2Fs3.amazonaws.com%2Fhyperpodstackfiles%2Fhyperpod-quickstart%2Fslurm-trainium%2Ftemplate.yaml&stackName=my-hyperpod-trn&param_LifecycleScriptSourceBucket=hyperpodstackfiles&param_LifecycleScriptSourcePrefix=hyperpod-quickstart/slurm-trainium/lifecycle-scripts) |
| **Amazon EKS** | [![Launch Stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](https://us-west-2.console.aws.amazon.com/cloudformation/home?region=us-west-2#/stacks/create/review?templateURL=https%3A%2F%2Fs3.amazonaws.com%2Fhyperpodstackfiles%2Fhyperpod-quickstart%2Feks-gpu%2Ftemplate.yaml&stackName=my-hyperpod-eks&param_LifecycleScriptSourceBucket=hyperpodstackfiles&param_LifecycleScriptSourcePrefix=hyperpod-quickstart/eks-gpu/lifecycle-scripts) | [![Launch Stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](https://us-west-2.console.aws.amazon.com/cloudformation/home?region=us-west-2#/stacks/create/review?templateURL=https%3A%2F%2Fs3.amazonaws.com%2Fhyperpodstackfiles%2Fhyperpod-quickstart%2Feks-trainium%2Ftemplate.yaml&stackName=my-hyperpod-eks-trn&param_LifecycleScriptSourceBucket=hyperpodstackfiles&param_LifecycleScriptSourcePrefix=hyperpod-quickstart/eks-trainium/lifecycle-scripts) |

> Click any button above to open CloudFormation with all parameters pre-filled. Review settings and click **Create stack**.
>
> **Using a different S3 bucket or region?** Run `./scripts/publish.sh YOUR_BUCKET us-west-2` to generate buttons for your setup.

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
- AWS account with [HyperPod access](https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod.html)
- Service quota for your chosen instance type
- AWS CLI configured

## Choose Your Stack

| | **NVIDIA GPU** (p5, p4d, g5) | **AWS Trainium** (trn1, trn2) |
|:---:|:---:|:---:|
| **Slurm** | [Slurm + GPU](#slurm--gpu) | [Slurm + Trainium](#slurm--trainium) |
| **Amazon EKS** | [EKS + GPU](#eks--gpu) | [EKS + Trainium](#eks--trainium) |

> **Quick rule of thumb:** Slurm for HPC/research. EKS for Kubernetes teams. Trainium for lowest cost. GPU for max compatibility.

## Common Parameters

All stacks share these parameters (set in CloudFormation console):

| Parameter | Description | Default |
|-----------|-------------|---------|
| `ClusterName` | Name for your cluster | `my-hyperpod` |
| `ClusterSize` | `small` (2 nodes), `medium` (8), `large` (32) | `small` |
| `AvailabilityZoneId` | AZ with capacity for your instance type | `usw2-az2` |
| `WorkerInstanceType` | ML instance type for workers | varies by stack |
| `EnableObservability` | Prometheus + Grafana dashboards | `true` |
| `EnableValidation` | Post-deploy health checks | `true` |

## Common Troubleshooting

```bash
# Diagnose stack failures (drills into nested stacks automatically)
./scripts/stack-errors.sh <stack-name> us-west-2

# Check lifecycle logs (Slurm — on controller via SSM)
cat /var/log/hyperpod/on_create.log

# Check pod issues (EKS)
kubectl describe pod -n <namespace> <pod-name>
```

| Problem | Fix |
|---------|-----|
| `ResourceLimitExceeded` | Run `./scripts/check-quotas.sh` and request quota increases |
| `TemplateURL must be a supported URL` | Use `deploy.sh` — it runs `cfn package` automatically |
| Orphaned IAM roles blocking deploy | Delete orphan roles from previous failed stacks |
| Stack stuck in `ROLLBACK_FAILED` | `aws cloudformation delete-stack --stack-name <name>` |

## Clean Up

```bash
aws cloudformation delete-stack --stack-name <stack-name> --region us-west-2
```

> **Warning:** This deletes everything including FSx data. Copy important data to S3 first.

---

## Stack Guides

<details>
<summary><h3 id="slurm--gpu">Slurm + GPU</h3></summary>

Best for HPC and research teams. Controller + worker architecture with Slurm job scheduling.

#### Deploy

```bash
./scripts/deploy.sh slurm-gpu YOUR_S3_BUCKET us-west-2
```

Review parameters in the CloudFormation console and click **Create stack**. Takes ~20 minutes.

| Parameter | Testing | Production |
|-----------|---------|------------|
| `WorkerInstanceType` | `ml.g5.16xlarge` | `ml.p5.48xlarge` |
| `EnableObservability` | `false` | `true` |
| `EnableValidation` | `false` | `true` |

#### Connect

```bash
./scripts/remote-nccl-test.sh <cluster-name> us-west-2
```

This auto-discovers the controller and opens an SSM session.

#### Test

On the controller:

```bash
sinfo                    # Verify workers are online
run-nccl-test 2 1        # NCCL all-reduce benchmark
run-nanogpt 2 1          # Multi-node training test
```

Both commands auto-detect EFA vs TCP and choose the right transport/backend.

#### Interpret Results

**NCCL benchmark:**
```
#       size      algbw   busbw
   134217728      3.01    3.01    # Peak bandwidth
```
- g5.16xlarge (TCP): ~3 GB/s — correct, saturating 25 Gbps network
- p5.48xlarge (EFA): ~400 GB/s

**nanoGPT training:**
```
iter 0: loss 4.1700    # Starting loss
iter 199: loss 3.0486  # Should decrease steadily
```

#### Submit Training Jobs

```bash
sbatch examples/submit-pytorch-job/slurm/submit.sh
sbatch examples/nccl-test/slurm/train-nanogpt.sh
```

#### Instance Types

| Instance | GPUs | EFA | Network | Cost/hr |
|----------|------|-----|---------|---------|
| `ml.g5.16xlarge` | 1x A10G | No | 25 Gbps TCP | ~$7 |
| `ml.g5.48xlarge` | 8x A10G | Yes | 100 Gbps | ~$20 |
| `ml.p4d.24xlarge` | 8x A100 | Yes | 400 Gbps | ~$40 |
| `ml.p5.48xlarge` | 8x H100 | Yes | 3200 Gbps | ~$66 |

#### Cluster Sizes

| Size | Workers | FSx | Best for |
|------|---------|-----|----------|
| small | 2 | 1.2 TB | Testing |
| medium | 8 | 4.8 TB | Moderate training |
| large | 32 | 14.4 TB | Large-scale distributed |

#### What Gets Set Up Automatically

- Slurm configless mode with `--conf-server` for worker discovery
- MUNGE authentication between nodes
- SSH key distribution (via FSx or Slurm)
- FSx Lustre auto-discovery and mount
- NCCL environment tuning (per AWS best practices)
- EFA RDMA detection (enabled on supported instances)
- `run-nccl-test` and `run-nanogpt` pre-installed on controller

</details>

<details>
<summary><h3 id="slurm--trainium">Slurm + Trainium</h3></summary>

Best for cost-efficient distributed training with AWS custom silicon.

#### Deploy

```bash
./scripts/deploy.sh slurm-trainium YOUR_S3_BUCKET us-west-2
```

#### Connect

```bash
./scripts/remote-nccl-test.sh <cluster-name> us-west-2
```

#### Test

```bash
sinfo                    # Verify workers
srun -N 1 neuron-ls      # Verify Neuron devices
```

#### Key Differences from GPU

- Uses **NCCOM** (not NCCL) for collective communication — handled automatically by `torch-neuronx`
- Neuron environment auto-detected: trn1 (32 cores), trn2.48xl (64 cores), trn2.3xl (4 cores)
- Performance tuning vars set automatically: `NEURON_FUSE_SOFTMAX`, `NEURON_RT_ASYNC_EXEC_MAX_INFLIGHT_REQUESTS`, etc.
- DLAMI has pre-installed Neuron SDK — do **not** pip install over it

#### Cluster Sizes

| Size | Workers | NeuronCores | FSx | Cost/hr |
|------|---------|-------------|-----|---------|
| small | 2x trn1.32xl | 32 | 1.2 TB | ~$50 |
| medium | 8x trn1.32xl | 128 | 4.8 TB | ~$200 |
| large | 32x trn1.32xl | 512 | 14.4 TB | ~$797 |

#### Submit Training Jobs

```bash
sbatch examples/submit-neuron-job/slurm/submit.sh
```

</details>

<details>
<summary><h3 id="eks--gpu">EKS + GPU</h3></summary>

Best for Kubernetes-native teams. No controller node — EKS is the control plane. HyperPod Helm dependencies (device plugins, health monitoring, Kubeflow) are installed automatically.

#### Deploy

```bash
./scripts/deploy.sh eks-gpu YOUR_S3_BUCKET us-west-2
```

Takes ~25 minutes (EKS control plane + Helm chart + HyperPod).

#### Connect

```bash
# Configure kubectl
aws eks update-kubeconfig --name <cluster>-eks-cluster --region us-west-2

# Add your IAM user access (one-time, requires AWS CLI v2.13+)
aws eks create-access-entry \
    --cluster-name <cluster>-eks-cluster \
    --principal-arn arn:aws:iam::<account>:user/<username> \
    --type STANDARD --region us-west-2

aws eks associate-access-policy \
    --cluster-name <cluster>-eks-cluster \
    --principal-arn arn:aws:iam::<account>:user/<username> \
    --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
    --access-scope type=cluster --region us-west-2
```

#### Verify

```bash
kubectl get nodes                          # Should show worker nodes
kubectl get pods -A                        # All pods should be Running
kubectl get nodes -o json | \
  jq '.items[].status.allocatable | {"nvidia.com/gpu"}'  # GPU count
```

#### Test

```bash
# NCCL benchmark via MPIJob
./scripts/run-nccl-test-eks.sh <cluster>-eks-cluster 2 1 us-west-2
```

#### Submit Training Jobs

```bash
kubectl apply -f examples/submit-pytorch-job/eks/pytorchjob.yaml
kubectl apply -f examples/nccl-test/eks/nccl-test-mpijob.yaml

# Monitor
kubectl logs -f <launcher-pod-name>
```

#### EKS-Specific Troubleshooting

| Problem | Fix |
|---------|-----|
| `ImagePullBackOff` | VPC endpoints for ECR are included — redeploy if using old stack |
| `kubectl` access denied | Add IAM access entry (see Connect above) |
| No GPU resources on nodes | Check `nvidia-device-plugin` pods: `kubectl get pods -A \| grep nvidia` |
| MPI Operator missing | Helm chart should auto-install; check `kubectl get crd \| grep kubeflow` |

</details>

<details>
<summary><h3 id="eks--trainium">EKS + Trainium</h3></summary>

Best for Kubernetes teams optimizing cost with AWS custom silicon.

#### Deploy

```bash
./scripts/deploy.sh eks-trainium YOUR_S3_BUCKET us-west-2
```

#### Connect

Same as [EKS + GPU](#eks--gpu) — configure kubectl and add IAM access entry.

#### Test

```bash
kubectl get nodes
kubectl describe nodes | grep aws.amazon.com/neuron
```

#### Submit Training Jobs

```bash
kubectl apply -f examples/submit-neuron-job/eks/job.yaml
```

</details>

---

## Architecture

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
└─────────────────────────────────────────────────────────────────┘
```

## Scripts Reference

| Script | Purpose | Run from |
|--------|---------|----------|
| `deploy.sh <variant> <bucket> [region]` | Package + deploy stack | Local |
| `check-quotas.sh <instance> <count> [region]` | Verify AWS quotas | Local |
| `stack-errors.sh <stack> [region]` | Diagnose CF failures | Local |
| `remote-nccl-test.sh <cluster> [region]` | SSM into controller | Local |
| `run-nccl-test [nodes] [gpus]` | NCCL benchmark | Controller |
| `run-nanogpt [nodes] [gpus]` | Training test | Controller |
| `run-nccl-test-eks.sh <cluster> [nodes] [gpus] [region]` | EKS NCCL benchmark | Local |

## Repository Structure

```
hyperpod-quickstart/
├── stacks/                     # CloudFormation entry points (one per variant)
├── modules/                    # Shared nested stack templates
├── scripts/                    # Deploy, test, and diagnostic scripts
├── lifecycle-scripts/          # Node initialization (per variant)
├── examples/                   # NCCL tests + training job samples
├── ROADMAP.md                  # Planned improvements
└── docs/                       # Detailed documentation
```

## Roadmap

See [ROADMAP.md](ROADMAP.md) for planned improvements: GPU health checks, multi-user management, Slurm accounting, Enroot/Pyxis containers, multi-controller HA, and more.

## License

Apache-2.0. Built on patterns from the [AWS Distributed Training Reference Architecture](https://github.com/awslabs/awsome-distributed-training).
