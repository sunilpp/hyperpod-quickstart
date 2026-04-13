#!/bin/bash
#SBATCH --job-name=pytorch-ddp-test
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=8
#SBATCH --gres=gpu:8
#SBATCH --partition=gpu
#SBATCH --output=pytorch-test-%j.out
#SBATCH --error=pytorch-test-%j.err
#SBATCH --time=00:30:00

# =============================================================================
# Simple PyTorch DDP test — verifies multi-node GPU communication
# =============================================================================
# This script runs a basic distributed all-reduce operation across all GPUs
# on 2 nodes. If this works, your cluster networking is correctly configured.
#
# Usage: sbatch submit.sh
# =============================================================================

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

# Run a simple DDP all-reduce test
srun python3 -c "
import torch
import torch.distributed as dist
import os

# Initialize process group using NCCL backend
dist.init_process_group(backend='nccl')
rank = dist.get_rank()
world_size = dist.get_world_size()
local_rank = int(os.environ.get('LOCAL_RANK', 0))

# Set device
torch.cuda.set_device(local_rank)
device = torch.device(f'cuda:{local_rank}')

# Create a tensor and all-reduce it
tensor = torch.ones(1024, 1024, device=device) * rank
dist.all_reduce(tensor, op=dist.ReduceOp.SUM)

# Expected value: sum of all ranks = world_size * (world_size - 1) / 2
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
