#!/bin/bash
#SBATCH --job-name=neuron-test
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --partition=trainium
#SBATCH --exclusive
#SBATCH --output=neuron-test-%j.out
#SBATCH --error=neuron-test-%j.err
#SBATCH --time=00:30:00

# =============================================================================
# Neuron distributed training test — verifies Trainium communication
# =============================================================================
# Runs a basic distributed all-reduce on NeuronCores across 2 nodes.
#
# Usage: sbatch submit.sh
# =============================================================================

# Neuron environment
export NEURON_RT_NUM_CORES=32
export FI_PROVIDER=efa
export FI_EFA_USE_DEVICE_RDMA=1

# Activate shared Neuron environment
source /fsx/envs/neuron-env/bin/activate 2>/dev/null || true

echo "=== Neuron Distributed Test ==="
echo "Nodes: $SLURM_JOB_NUM_NODES"
echo "Neuron devices per node: $(neuron-ls 2>/dev/null | grep -c 'Device' || echo 'unknown')"
echo "==============================="

srun python3 -c "
import torch
import torch_xla.core.xla_model as xm
import torch_xla.distributed.xla_backend

# Initialize XLA distributed
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
