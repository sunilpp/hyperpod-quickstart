# EKS + GPU — Complete Guide

Best for Kubernetes-native teams. No controller node — EKS is the control plane.

## Deploy

```bash
./scripts/deploy.sh eks-gpu YOUR_S3_BUCKET us-west-2
```

Or click the **EKS + GPU** Launch Stack button on the [main page](../README.md).

Takes ~25 minutes. The stack automatically:
1. Creates EKS cluster with managed add-ons (VPC CNI, CoreDNS, kube-proxy, EBS CSI)
2. Installs HyperPod Helm chart via Lambda (device plugins, health monitoring, Kubeflow MPI operator)
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

If your AWS CLI is too old, add access via the **AWS Console**: EKS > Clusters > Access tab > Create access entry.

## Verify

```bash
# Check nodes (may take a few minutes to appear)
kubectl get nodes

# All pods should be Running
kubectl get pods -A

# Verify GPU resources
kubectl get nodes -o json | jq '.items[].status.allocatable | {"nvidia.com/gpu"}'
```

### Expected pod status

| Namespace | Pods | Purpose |
|-----------|------|---------|
| `kube-system` | aws-node, kube-proxy, coredns | Core networking |
| `kube-system` | nvidia-device-plugin | GPU discovery |
| `kube-system` | efa-device-plugin | EFA networking |
| `kube-system` | mpi-operator | MPI job orchestration |
| `kube-system` | ebs-csi-* | Storage |
| `aws-hyperpod` | health-monitoring-agent | Node health |
| `kubeflow` | training-operators | PyTorchJob, MPIJob support |

## Test

```bash
# NCCL benchmark via MPIJob (from your local machine)
./scripts/run-nccl-test-eks.sh <cluster>-eks-cluster 2 1 us-west-2

# Or manually
kubectl apply -f examples/nccl-test/eks/nccl-test-mpijob.yaml
kubectl logs -f $(kubectl get pods -l training.kubeflow.org/job-name=nccl-tests -o name | grep launcher)
```

## Submit Training Jobs

```bash
# PyTorch distributed training
kubectl apply -f examples/submit-pytorch-job/eks/pytorchjob.yaml

# NCCL benchmark
kubectl apply -f examples/nccl-test/eks/nccl-test-mpijob.yaml

# Monitor
kubectl get mpijobs -w
kubectl logs -f <launcher-pod>

# Clean up
kubectl delete mpijob nccl-tests
```

## What Gets Set Up Automatically

| Component | How |
|-----------|-----|
| EKS cluster + addons | CloudFormation `AWS::EKS::Cluster` + `AWS::EKS::Addon` |
| HyperPod Helm chart | Lambda Custom Resource (clones and installs official Helm chart) |
| NVIDIA device plugin | Helm chart DaemonSet |
| EFA device plugin | Helm chart DaemonSet |
| MPI Operator | Helm chart Deployment |
| Health monitoring | Helm chart DaemonSet in `aws-hyperpod` namespace |
| Kubeflow training operators | Helm chart Deployment |
| VPC endpoints (ECR, STS, S3) | CloudFormation in networking template |
| EKS access entry (HYPERPOD_LINUX) | CloudFormation for HyperPod node registration |

## Troubleshooting

| Problem | Check | Fix |
|---------|-------|-----|
| `ImagePullBackOff` | `kubectl describe pod <pod>` | ECR permissions added in latest templates — redeploy |
| kubectl access denied | `aws sts get-caller-identity` | Add IAM access entry (see Connect above) |
| No GPU resources on nodes | `kubectl get pods -A \| grep nvidia` | Check nvidia-device-plugin is Running |
| MPI Operator missing | `kubectl get crd \| grep kubeflow` | Helm chart Lambda may have failed — check CloudWatch logs |
| Nodes not appearing | `aws sagemaker list-cluster-nodes` | HyperPod uses continuous provisioning — wait 5-10 min |
| Pods stuck in ContainerCreating | `kubectl describe pod <pod>` | Usually depends on aws-node (VPC CNI) running first |
