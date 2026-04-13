# Running Your First Training Job

This guide walks you through submitting your first job on each stack variant. The `examples/` directory in this repository contains ready-to-use scripts and manifests that verify multi-node communication is working correctly.

---

## Which Example Should I Use?

| Example | What It Tests | Works On |
|---------|---------------|----------|
| `submit-pytorch-job` | Multi-node PyTorch DDP all-reduce over NCCL | Slurm + GPU, EKS + GPU |
| `submit-nemo-job` | NeMo Megatron GPT pretraining (small 126M model) | Slurm + GPU, EKS + GPU |
| `submit-neuron-job` | Distributed all-reduce on Trainium NeuronCores | Slurm + Trainium, EKS + Trainium |

> **Tip:** Start with the **PyTorch DDP test** (GPU) or **Neuron test** (Trainium). These are simple verification scripts that complete in under 5 minutes. The NeMo example is a more realistic training workload that takes longer.

---

## Slurm + GPU: PyTorch DDP Test

This example runs a basic all-reduce operation across 2 nodes with 8 GPUs each (16 GPUs total). If the all-reduce produces the expected result, your multi-node GPU networking is working.

### Step 1: Connect to the Head Node

```bash
aws ssm start-session --target <controller-instance-id> --region us-west-2
```

### Step 2: Copy the Example Script

If the examples directory is available on the shared filesystem:

```bash
ls /fsx/examples/submit-pytorch-job/slurm/
```

If not, create the script manually:

```bash
cat > /fsx/pytorch-ddp-test.sh << 'SCRIPT'
#!/bin/bash
#SBATCH --job-name=pytorch-ddp-test
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=8
#SBATCH --gres=gpu:8
#SBATCH --partition=gpu
#SBATCH --output=pytorch-test-%j.out
#SBATCH --error=pytorch-test-%j.err
#SBATCH --time=00:30:00

# NCCL configuration for optimal EFA performance
export NCCL_PROTO=simple
export NCCL_ALGO=ring,tree
export NCCL_DEBUG=INFO
export FI_PROVIDER=efa
export FI_EFA_USE_DEVICE_RDMA=1

echo "=== PyTorch DDP Test ==="
echo "Nodes: $SLURM_JOB_NUM_NODES"
echo "Tasks per node: $SLURM_NTASKS_PER_NODE"
echo "Total GPUs: $(($SLURM_JOB_NUM_NODES * $SLURM_NTASKS_PER_NODE))"
echo "========================"

srun python3 -c "
import torch
import torch.distributed as dist
import os

dist.init_process_group(backend='nccl')
rank = dist.get_rank()
world_size = dist.get_world_size()
local_rank = int(os.environ.get('LOCAL_RANK', 0))

torch.cuda.set_device(local_rank)
device = torch.device(f'cuda:{local_rank}')

tensor = torch.ones(1024, 1024, device=device) * rank
dist.all_reduce(tensor, op=dist.ReduceOp.SUM)

expected = world_size * (world_size - 1) / 2
actual = tensor[0][0].item()

if rank == 0:
    print(f'World size: {world_size}')
    print(f'All-reduce result: {actual} (expected: {expected})')
    if abs(actual - expected) < 0.01:
        print('SUCCESS: Multi-node GPU communication is working!')
    else:
        print('FAILURE: All-reduce produced unexpected result')

dist.destroy_process_group()
"
SCRIPT
```

### Step 3: Submit the Job

```bash
sbatch /fsx/pytorch-ddp-test.sh
```

### Step 4: Monitor the Job

```bash
# Check job status
squeue

# Watch the output file (replace JOBID with the actual job ID)
tail -f pytorch-test-JOBID.out
```

### Step 5: Verify Success

Once the job completes, check the output:

```bash
cat pytorch-test-JOBID.out
```

You should see:

```
=== PyTorch DDP Test ===
Nodes: 2
Tasks per node: 8
Total GPUs: 16
========================
World size: 16
All-reduce result: 120.0 (expected: 120.0)
SUCCESS: Multi-node GPU communication is working!
```

> **Tip:** The NCCL_DEBUG=INFO setting produces verbose logging. Look for lines like `NCCL INFO NET/OFI Using aws-ofi-nccl` to confirm EFA is being used. If you see `NCCL INFO NET/Socket`, EFA is not active and performance will be poor.

---

## Slurm + GPU: NeMo GPT Pretraining

This example runs a small GPT model (126M parameters) using NVIDIA NeMo. It is a more realistic training workload.

### Prerequisites

This example requires the NeMo container image. The script uses Enroot/Pyxis for container execution via the `--container-image` flag.

### Submit the Job

```bash
# From the head node
sbatch /fsx/examples/submit-nemo-job/slurm/submit.sh
```

Or create it manually:

```bash
cat > /fsx/nemo-test.sh << 'SCRIPT'
#!/bin/bash
#SBATCH --job-name=nemo-gpt-test
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=8
#SBATCH --gres=gpu:8
#SBATCH --partition=gpu
#SBATCH --output=nemo-test-%j.out
#SBATCH --error=nemo-test-%j.err
#SBATCH --time=01:00:00

export NCCL_PROTO=simple
export NCCL_DEBUG=WARN
export FI_PROVIDER=efa
export FI_EFA_USE_DEVICE_RDMA=1

CONTAINER_IMAGE="nvcr.io/nvidia/nemo:24.07"

srun --container-image="$CONTAINER_IMAGE" \
     --container-mounts="/fsx:/fsx" \
     python3 -m nemo.collections.nlp.models.language_modeling.megatron_gpt_pretraining \
     --config-name=megatron_gpt_config \
     trainer.devices=8 \
     trainer.num_nodes=$SLURM_JOB_NUM_NODES \
     trainer.max_steps=100 \
     trainer.val_check_interval=50 \
     model.micro_batch_size=2 \
     model.global_batch_size=32 \
     model.encoder_seq_length=2048 \
     model.hidden_size=768 \
     model.num_layers=12 \
     model.num_attention_heads=12 \
     exp_manager.exp_dir=/fsx/nemo-experiments
SCRIPT

sbatch /fsx/nemo-test.sh
```

### What to Expect

- The container image download may take a few minutes on the first run
- Training should produce log lines showing loss decreasing over 100 steps
- Checkpoints are saved to `/fsx/nemo-experiments`

---

## Slurm + Trainium: Neuron Distributed Test

This example runs a basic distributed all-reduce on Trainium NeuronCores across 2 nodes.

### Submit the Job

```bash
# From the head node
sbatch /fsx/examples/submit-neuron-job/slurm/submit.sh
```

Or create it manually:

```bash
cat > /fsx/neuron-test.sh << 'SCRIPT'
#!/bin/bash
#SBATCH --job-name=neuron-test
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --partition=trainium
#SBATCH --exclusive
#SBATCH --output=neuron-test-%j.out
#SBATCH --error=neuron-test-%j.err
#SBATCH --time=00:30:00

export NEURON_RT_NUM_CORES=32
export FI_PROVIDER=efa
export FI_EFA_USE_DEVICE_RDMA=1

source /fsx/envs/neuron-env/bin/activate 2>/dev/null || true

srun python3 -c "
import torch
import torch_xla.core.xla_model as xm
import torch_xla.distributed.xla_backend

import torch.distributed as dist
dist.init_process_group(backend='xla')
rank = dist.get_rank()
world_size = dist.get_world_size()

device = xm.xla_device()
tensor = torch.ones(1024, 1024, device=device) * rank
dist.all_reduce(tensor, op=dist.ReduceOp.SUM)

xm.mark_step()
expected = world_size * (world_size - 1) / 2
actual = tensor[0][0].item()

if rank == 0:
    print(f'World size: {world_size}')
    print(f'All-reduce result: {actual} (expected: {expected})')
    print('SUCCESS' if abs(actual - expected) < 0.01 else 'FAILURE')

dist.destroy_process_group()
"
SCRIPT

sbatch /fsx/neuron-test.sh
```

### Key Differences from GPU Jobs

- **`--ntasks-per-node=1`** instead of 8 -- the Neuron runtime manages NeuronCore allocation internally
- **`--partition=trainium`** instead of `gpu`
- Uses **torch_xla** backend instead of NCCL
- Requires the **Neuron SDK** to be installed (handled by the lifecycle scripts)

---

## EKS + GPU: PyTorch DDP Test

This example uses the Kubeflow PyTorch Training Operator to run the same DDP test on Kubernetes.

### Step 1: Verify the PyTorch Operator is Installed

```bash
kubectl get crd pytorchjobs.kubeflow.org
```

If the CRD does not exist, install the PyTorch Training Operator:

```bash
kubectl apply -k "github.com/kubeflow/training-operator/manifests/overlays/standalone"
```

### Step 2: Submit the Job

```bash
kubectl apply -f examples/submit-pytorch-job/eks/pytorchjob.yaml
```

Or apply inline:

```yaml
apiVersion: kubeflow.org/v1
kind: PyTorchJob
metadata:
  name: pytorch-ddp-test
  namespace: default
spec:
  pytorchReplicaSpecs:
    Worker:
      replicas: 2
      restartPolicy: OnFailure
      template:
        spec:
          containers:
            - name: pytorch
              image: 763104351884.dkr.ecr.us-west-2.amazonaws.com/pytorch-training:2.1.0-gpu-py310-cu121-ubuntu20.04-sagemaker
              command:
                - python3
                - -c
                - |
                  import torch
                  import torch.distributed as dist
                  import os

                  dist.init_process_group(backend='nccl')
                  rank = dist.get_rank()
                  world_size = dist.get_world_size()
                  local_rank = int(os.environ.get('LOCAL_RANK', 0))

                  torch.cuda.set_device(local_rank)
                  device = torch.device(f'cuda:{local_rank}')

                  tensor = torch.ones(1024, 1024, device=device) * rank
                  dist.all_reduce(tensor, op=dist.ReduceOp.SUM)

                  expected = world_size * (world_size - 1) / 2
                  if rank == 0:
                      actual = tensor[0][0].item()
                      print(f'World size: {world_size}, Result: {actual}, Expected: {expected}')
                      print('SUCCESS' if abs(actual - expected) < 0.01 else 'FAILURE')

                  dist.destroy_process_group()
              resources:
                limits:
                  nvidia.com/gpu: 8
              env:
                - name: NCCL_DEBUG
                  value: INFO
                - name: FI_PROVIDER
                  value: efa
                - name: FI_EFA_USE_DEVICE_RDMA
                  value: "1"
```

### Step 3: Monitor the Job

```bash
# Check job status
kubectl get pytorchjobs

# Watch pods
kubectl get pods -l training.kubeflow.org/job-name=pytorch-ddp-test -w

# View logs from worker 0
kubectl logs pytorch-ddp-test-worker-0 -f
```

### Step 4: Clean Up

```bash
kubectl delete pytorchjob pytorch-ddp-test
```

---

## EKS + GPU: NeMo GPT Pretraining

This example uses the Kubeflow MPI Operator.

```bash
kubectl apply -f examples/submit-nemo-job/eks/job.yaml
```

Monitor the job:

```bash
kubectl get mpijobs
kubectl logs nemo-gpt-test-launcher -f
```

> **Tip:** Make sure the FSx PersistentVolumeClaim (`fsx-pvc`) is bound before submitting this job. The NeMo job mounts `/fsx` for saving checkpoints.

---

## EKS + Trainium: Neuron Test

```bash
kubectl apply -f examples/submit-neuron-job/eks/job.yaml
```

Monitor the job:

```bash
kubectl get jobs
kubectl logs neuron-test-<pod-hash> -f
```

You should see:

```
XLA device: xla:0
Matrix multiply result shape: torch.Size([1024, 1024])
SUCCESS: Neuron computation working!
```

---

## Understanding the Environment Variables

These environment variables appear in all GPU examples. Here is what they do:

| Variable | Value | Purpose |
|----------|-------|---------|
| `NCCL_PROTO` | `simple` | Selects the NCCL protocol. `simple` works best with EFA. |
| `NCCL_ALGO` | `ring,tree` | Allows NCCL to choose between ring and tree algorithms for collectives. |
| `NCCL_DEBUG` | `INFO` or `WARN` | Controls NCCL logging verbosity. Use `INFO` for debugging, `WARN` for production. |
| `FI_PROVIDER` | `efa` | Tells libfabric to use the EFA provider for networking. |
| `FI_EFA_USE_DEVICE_RDMA` | `1` | Enables RDMA (remote direct memory access) on EFA for better performance. |

For Trainium examples:

| Variable | Value | Purpose |
|----------|-------|---------|
| `NEURON_RT_NUM_CORES` | `32` | Number of NeuronCores to use per node. |
| `FI_PROVIDER` | `efa` | Same as above -- EFA for inter-node communication. |
| `FI_EFA_USE_DEVICE_RDMA` | `1` | Same as above. |

---

## Troubleshooting Job Failures

### Job stays in PENDING state (Slurm)

```bash
# Check why the job is pending
scontrol show job <JOBID> | grep Reason
```

Common reasons:
- `Resources` -- not enough nodes available. Check `sinfo` for node states.
- `PartitionNodeLimit` -- requesting more nodes than the partition allows.

### Pod stays in Pending state (EKS)

```bash
kubectl describe pod <pod-name>
```

Look at the **Events** section for messages like:
- `Insufficient nvidia.com/gpu` -- the GPU device plugin is not running or GPUs are all allocated
- `Insufficient aws.amazon.com/neuron` -- the Neuron device plugin is not running

### NCCL errors

If you see `NCCL WARN` messages about connection failures:
- Verify the security group has self-referencing ingress rules
- Check that EFA is available: `fi_info -p efa` on the nodes
- See the [Networking Troubleshooting guide](troubleshooting/networking-issues.md)

### Neuron compilation errors

If you see compilation errors on Trainium:
- Make sure the Neuron SDK is installed (check lifecycle script logs)
- Verify the Neuron compiler version matches the PyTorch version
- Check `/var/log/hyperpod/on_create.log` for lifecycle script errors

---

## Next Steps

- [Monitor your cluster](06-observability.md) with Grafana dashboards
- [Run benchmarks](07-benchmarking.md) to verify network performance
- [Scale up](08-scaling.md) when you are ready for larger training runs
