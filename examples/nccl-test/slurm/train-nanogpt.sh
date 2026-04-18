#!/bin/bash
#SBATCH --job-name=nanogpt
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --gpus-per-node=1
#SBATCH --exclusive
#SBATCH --output=/tmp/nanogpt_%j.out
#SBATCH --error=/tmp/nanogpt_%j.err

# NanoGPT multi-node training on HyperPod
# Usage: sbatch train-nanogpt.sh
#
# Works on both EFA (p5) and non-EFA (g5) instances.
# Automatically detects transport and backend.

MASTER_ADDR=$(scontrol show hostname $SLURM_NODELIST | head -1)
MASTER_PORT=29500
GPUS_PER_NODE=1

# Detect EFA RDMA capability
BACKEND_ARG=""
EXPORT_ARGS="ALL"
if command -v fi_info &>/dev/null && fi_info -p efa -c FI_EP_RDM 2>/dev/null | grep -q "provider: efa"; then
    echo "Backend: NCCL (EFA RDMA)"
else
    echo "Backend: Gloo (TCP)"
    BACKEND_ARG="--backend=gloo"
    EXPORT_ARGS="ALL,NCCL_NET_PLUGIN=none,NCCL_SOCKET_IFNAME=ens6,FI_EFA_USE_DEVICE_RDMA=0"
fi

echo "=== NanoGPT Multi-Node Training ==="
echo "Nodes: $SLURM_JOB_NUM_NODES | Master: $MASTER_ADDR:$MASTER_PORT"

# Setup: install deps and prepare data on all nodes
srun bash -c "
pip install torch numpy tiktoken datasets 2>/dev/null
apt-get install -y -qq git 2>/dev/null
cd /tmp && git clone https://github.com/karpathy/nanoGPT.git 2>/dev/null || true
cd /tmp/nanoGPT && python3 data/shakespeare_char/prepare.py 2>/dev/null
"

# Train
srun --export=$EXPORT_ARGS bash -c "
MASTER_ADDR=$MASTER_ADDR
cd /tmp/nanoGPT
torchrun --nproc_per_node=$GPUS_PER_NODE --nnodes=$SLURM_JOB_NUM_NODES --node_rank=\$SLURM_NODEID --master_addr=$MASTER_ADDR --master_port=$MASTER_PORT train.py --dataset=shakespeare_char --n_layer=4 --n_head=4 --n_embd=128 --batch_size=8 --block_size=64 --max_iters=200 --eval_interval=50 --device=cuda --compile=False $BACKEND_ARG
"
