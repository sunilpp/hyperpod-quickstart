# EKS + GPU — Complete Guide

Best for Kubernetes-native teams. No controller node — EKS is the control plane.

## Deploy

```bash
./scripts/deploy.sh eks-gpu YOUR_S3_BUCKET us-west-2
```

Or click the **EKS + GPU** Launch Stack button on the [main page](../README.md).

Takes ~25 minutes. The stack automatically:
1. Creates EKS cluster with managed add-ons (VPC CNI with nodeAgent disabled, CoreDNS, kube-proxy)
2. Installs HyperPod Helm chart via Lambda (NVIDIA device plugin, EFA plugin, health monitoring, MPI operator, Kubeflow training operator)
3. Creates HyperPod cluster with GPU worker nodes

No manual `helm install` step needed.

## Connect

```bash
# Configure kubectl (one-time)
aws eks update-kubeconfig --name <cluster>-eks-cluster --region us-west-2
```

### Add your IAM access (one-time, requires AWS CLI v2.13+)

```bash
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

If your AWS CLI is too old, add via **AWS Console**: EKS > Clusters > Access tab > Create access entry.

## Test

### Verify the cluster

```bash
# Check nodes
kubectl get nodes

# All pods should be Running (ebs-csi-controller may show errors — non-critical)
kubectl get pods -A

# Verify GPU resources
kubectl get nodes -o json | jq '.items[].status.allocatable | {"nvidia.com/gpu"}'
```

### NCCL Benchmark

```bash
# From your local machine
./scripts/run-nccl-test-eks.sh <cluster>-eks-cluster 2 1 us-west-2
```

### PyTorch DDP Training Test

```bash
kubectl apply -f examples/submit-pytorch-job/eks/pytorchjob.yaml
kubectl get pods -w
kubectl logs pytorch-ddp-test-master-0
```

## What the Tests Validate

### NCCL All-Reduce (MPIJob)

**What it does:** Submits a Kubeflow MPIJob that runs `all_reduce_perf` across worker pods using the `public.ecr.aws/hpc-cloud/nccl-tests:latest` container.

**What it validates:**
- NVIDIA device plugin correctly exposes GPUs to pods
- MPI operator launches and coordinates multi-pod jobs
- Container-to-container networking via VPC CNI
- NCCL library works inside containers
- EFA (if available) or TCP transport

**Output includes bandwidth table:**
```
#       size      algbw   busbw  #wrong
   134217728      1.47    1.47       0
```

### PyTorch DDP Test (PyTorchJob)

**What it does:** Runs a PyTorchJob with Master+Worker pattern. Each node computes `rank * ones(1024)`, then all-reduces to verify cross-node communication. Also auto-detects EFA vs TCP backend.

**What it validates:**
- Kubeflow PyTorchJob operator sets RANK, WORLD_SIZE, MASTER_ADDR correctly
- Gloo backend (TCP) or NCCL backend (EFA) works for gradient sync
- GPU compute on each node
- Multi-node training pipeline functional

**Expected output:**
```
Rank 0/2: Result=1.0, Expected=1.0
SUCCESS
```

## Measured Results

### 2x ml.g5.16xlarge (TCP, containerized)

| Test | Result |
|------|--------|
| NCCL peak busbw | 1.49 GB/s |
| PyTorch DDP | SUCCESS — Result=1.0, Expected=1.0 |
| Both nodes | Confirmed (Rank 0/2, Rank 1/2) |

**Note:** EKS bandwidth (~1.5 GB/s) is lower than Slurm (~3 GB/s) on the same instance due to container networking overhead via VPC CNI. On EFA-capable instances (p4d, p5), the difference is minimal.

### What to Expect on Larger Instances

| Instance | GPUs | Expected NCCL busbw | Notes |
|----------|------|--------------------|----|
| 2x g5.16xlarge | 2 total | ~1.5 GB/s | TCP, container overhead |
| 2x g5.48xlarge | 16 total | ~10 GB/s | EFA SENDRECV |
| 2x p4d.24xlarge | 16 total | ~280 GB/s | EFA RDMA, near Slurm parity |
| 2x p5.48xlarge | 16 total | ~380 GB/s | EFA RDMA, production |
| 8x p5.48xlarge | 64 total | ~380 GB/s per pair | Needs Kueue for scheduling |

**Scaling considerations:**
- EKS adds ~10-15% overhead vs Slurm on non-EFA instances due to VPC CNI pod networking
- On EFA instances, the overhead is negligible (<2%) — EFA bypasses the CNI data path
- At scale, use Kueue (Task Governance) for resource quotas and fair scheduling
- Container images should be pre-cached on nodes for faster pod startup

## Submit Training Jobs

```bash
# PyTorch DDP test
kubectl apply -f examples/submit-pytorch-job/eks/pytorchjob.yaml

# NCCL benchmark
kubectl apply -f examples/nccl-test/eks/nccl-test-mpijob.yaml

# Monitor
kubectl get pytorchjobs
kubectl get mpijobs
kubectl logs <launcher-pod>

# Clean up
kubectl delete pytorchjob pytorch-ddp-test
kubectl delete mpijob nccl-tests
```

## What Gets Set Up Automatically

| Component | How |
|-----------|-----|
| EKS cluster + addons | CloudFormation |
| VPC CNI (nodeAgent disabled) | EKS managed addon |
| HyperPod Helm chart | Lambda Custom Resource |
| NVIDIA device plugin | Helm DaemonSet |
| EFA device plugin | Helm DaemonSet |
| MPI Operator | Helm Deployment |
| Kubeflow Training Operator | Helm Deployment |
| Health monitoring agent | Helm DaemonSet |
| VPC endpoints (ECR, STS, S3) | CloudFormation |
| IAM: ECR pull + VPC CNI permissions | CloudFormation |
| EKS access entry (HYPERPOD_LINUX) | CloudFormation |

## Troubleshooting

| Problem | Check | Fix |
|---------|-------|-----|
| `ImagePullBackOff` | `kubectl describe pod <pod>` | ECR permissions + VPC endpoints in latest templates |
| kubectl access denied | `aws sts get-caller-identity` | Add IAM access entry (see Connect) |
| No GPU resources | `kubectl get pods -A \| grep nvidia` | nvidia-device-plugin must be Running |
| MPI Operator missing | `kubectl get crd \| grep kubeflow` | Helm chart Lambda may have failed |
| Nodes not appearing | `aws sagemaker list-cluster-nodes` | Continuous provisioning — wait 5-10 min |
| Pods stuck ContainerCreating | `kubectl describe pod <pod>` | Usually depends on aws-node (VPC CNI) |
| `aws-node` 1/2 or CrashLoop | nodeAgent issue | Fixed: `nodeAgent: false` in addon config |
| `ebs-csi-controller` Error | Missing IAM permissions | Non-critical — doesn't affect training |
| Launcher pod not found | Label selector mismatch | Script auto-retries; check `kubectl get pods \| grep nccl` |
