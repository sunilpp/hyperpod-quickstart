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

MASTER_ADDR=$(scontrol show hostname $SLURM_NODELIST | head -1)
MASTER_PORT=29500
GPUS_PER_NODE=1

echo "=== NanoGPT Multi-Node Training ==="
echo "Nodes: $SLURM_JOB_NUM_NODES | Master: $MASTER_ADDR:$MASTER_PORT"

srun bash -c "
export LD_LIBRARY_PATH=/usr/local/cuda-13.0/lib:/opt/amazon/openmpi/lib:\$LD_LIBRARY_PATH

pip install torch numpy tiktoken datasets 2>/dev/null

cd /tmp
git clone https://github.com/karpathy/nanoGPT.git 2>/dev/null || true
cd /tmp/nanoGPT
python data/shakespeare_char/prepare.py 2>/dev/null

torchrun \
    --nproc_per_node=$GPUS_PER_NODE \
    --nnodes=$SLURM_JOB_NUM_NODES \
    --node_rank=\$SLURM_NODEID \
    --master_addr=$MASTER_ADDR \
    --master_port=$MASTER_PORT \
    train.py \
    --dataset=shakespeare_char \
    --n_layer=4 --n_head=4 --n_embd=128 \
    --batch_size=8 --block_size=64 \
    --max_iters=200 --eval_interval=50 \
    --device=cuda --compile=False
"
