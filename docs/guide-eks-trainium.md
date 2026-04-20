# EKS + Trainium — Complete Guide

Best for Kubernetes teams optimizing cost with AWS custom silicon.

## Deploy

```bash
./scripts/deploy.sh eks-trainium YOUR_S3_BUCKET us-west-2
```

Or click the **EKS + Trainium** Launch Stack button on the [main page](../README.md).

**Important:** Set `AvailabilityZoneId` to an AZ with Trainium capacity (e.g., `usw2-az4`).

## Connect

Same as [EKS + GPU](guide-eks-gpu.md#connect) — configure kubectl and add IAM access entry.

```bash
aws eks update-kubeconfig --name <cluster>-eks-cluster --region us-west-2
```

## Test

### Verify the cluster

```bash
# Check nodes
kubectl get nodes

# Verify Neuron devices visible
kubectl get nodes -o json | jq '.items[].status.allocatable | {"aws.amazon.com/neuron"}'

# All pods Running
kubectl get pods -A
```

Expected: `"aws.amazon.com/neuron": "16"` per node (trn1.32xlarge).

### Neuron Compute Test (single-node)

```bash
kubectl apply -f examples/submit-neuron-job/eks/job.yaml
kubectl logs neuron-test-<pod-id>
```

### Distributed Training Test (multi-node)

```bash
kubectl apply -f examples/submit-neuron-job/eks/training-job.yaml
kubectl get pods -w
kubectl logs neuron-ddp-test-master-0
kubectl logs neuron-ddp-test-worker-0
```

## What the Tests Validate

### Neuron Compute Test (`job.yaml`)

**What it does:** Runs a matrix multiply on a single Neuron device using `torch_xla`.

**What it validates:**
- Neuron device plugin correctly exposes devices to pods
- `torch_xla` library works inside the container
- Neuron compiler (`neuronx-cc`) compiles and runs NEFF on the device
- GPU memory is accessible

**Expected output:**
```
XLA device: xla:0
Compiler status PASS
Matrix multiply result shape: torch.Size([1024, 1024])
SUCCESS: Neuron computation working
```

### Distributed Training Test (`training-job.yaml`)

**What it does:** Runs a PyTorchJob with Master+Worker pattern. Each node:
1. Initializes distributed process group via Gloo backend
2. Runs CPU all-reduce to verify cross-node communication
3. Runs Neuron matrix multiply to verify local compute

**What it validates:**
- Multi-node communication works (Gloo all-reduce)
- Neuron compute works on each node independently
- PyTorchJob operator correctly sets up distributed environment
- Both nodes participate (Rank 0/2 + Rank 1/2)

**Expected output (master):**
```
Rank 0/2
Rank 0: all_reduce result=1.0, expected=1.0
Compiler status PASS
Rank 0: Neuron compute OK, shape=torch.Size([1024, 1024])
SUCCESS
```

**Expected output (worker):**
```
Rank 1/2
Rank 1: all_reduce result=1.0, expected=1.0
Compiler status PASS
Rank 1: Neuron compute OK, shape=torch.Size([1024, 1024])
```

## Measured Results

### 2x ml.trn1.32xlarge (EFA)

| Test | Result |
|------|--------|
| Neuron devices per node | 16 (32 NeuronCores) |
| Single-node compute | Neuron compile PASS, matmul SUCCESS |
| Multi-node all-reduce | Result=1.0, Expected=1.0 — SUCCESS |
| Both nodes confirmed | Rank 0/2 + Rank 1/2 |

### What to Expect at Scale

For production Trainium training on EKS, use the patterns from the [AWS reference](https://github.com/aws-samples/awsome-distributed-training/tree/main/3.test_cases/pytorch):

| Workload | Config | Notes |
|----------|--------|-------|
| Llama 3 8B fine-tune | 1x trn1.32xl, TP=8 | Single-node, LoRA/QLoRA |
| Llama 3 8B pre-train | 4x trn1.32xl, TP=8, DP=4 | Multi-node, full training |
| Llama 3 70B pre-train | 16x trn1.32xl, TP=32, PP=8 | Pipeline + tensor parallel |

**Key considerations:**
- Use `neuron_parallel_compile` for graph pre-compilation (saves time on first run)
- etcd-based rendezvous for elastic training (`rdzvBackend: etcd`)
- Pre-cache Neuron compile artifacts on FSx
- trn2.48xlarge has 2x cores and 2x EFA bandwidth vs trn1

## Key Differences from GPU

- **Neuron device plugin** instead of NVIDIA device plugin
- `aws.amazon.com/neuron` resource type instead of `nvidia.com/gpu`
- Uses `torch-neuronx` and `torch_xla` for computation
- Distributed training uses Gloo backend for coordination + NCCOM for Neuron collective operations
- Neuron compiler runs on first execution (adds latency to first batch)
- `health-monitoring-agent-non-nvidia` DaemonSet (not regular health-monitoring-agent)

## Troubleshooting

See [EKS + GPU troubleshooting](guide-eks-gpu.md#troubleshooting) — most issues are shared. Additionally:

| Problem | Fix |
|---------|-----|
| No Neuron resources | Check `neuron-device-plugin-daemonset` is Running |
| Neuron compile error | Verify `NEURON_CC_FLAGS` and instance type match |
| `Unknown backend type XLA` | Use `gloo` backend for `dist.init_process_group` |
| Slow first batch | Normal — Neuron compiler runs once, subsequent batches fast |
| `health-monitoring-agent` not running | Trainium uses `non-nvidia` variant; check that pod |
