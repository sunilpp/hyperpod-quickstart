#!/bin/bash
#SBATCH --job-name=nanogpt
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --gpus-per-node=1
#SBATCH --exclusive
#SBATCH --output=/tmp/nanogpt_%j.out
#SBATCH --error=/tmp/nanogpt_%j.err

# NanoGPT multi-node training on HyperPod
# Usage from controller: sbatch train-nanogpt.sh

export MASTER_ADDR=$(scontrol show hostname $SLURM_NODELIST | head -1)
export MASTER_PORT=29500
export WORLD_SIZE=$SLURM_NTASKS
export LD_LIBRARY_PATH=/usr/local/cuda-13.0/lib:/opt/amazon/openmpi/lib:$LD_LIBRARY_PATH

echo "=== NanoGPT Multi-Node Training ==="
echo "Nodes: $SLURM_JOB_NUM_NODES"
echo "Master: $MASTER_ADDR:$MASTER_PORT"

# Install dependencies
pip install torch numpy tiktoken datasets 2>/dev/null

# Clone nanoGPT
cd /tmp
if [[ ! -d nanoGPT ]]; then
    git clone https://github.com/karpathy/nanoGPT.git
fi
cd nanoGPT

# Prepare data
python data/shakespeare_char/prepare.py 2>/dev/null

# Train
torchrun \
    --nproc_per_node=1 \
    --nnodes=$SLURM_JOB_NUM_NODES \
    --node_rank=$SLURM_NODEID \
    --master_addr=$MASTER_ADDR \
    --master_port=$MASTER_PORT \
    train.py \
    --dataset=shakespeare_char \
    --n_layer=4 \
    --n_head=4 \
    --n_embd=128 \
    --batch_size=8 \
    --block_size=64 \
    --max_iters=200 \
    --eval_interval=50 \
    --device=cuda \
    --compile=False
