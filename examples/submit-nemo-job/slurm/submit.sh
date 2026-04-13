#!/bin/bash
#SBATCH --job-name=nemo-gpt-test
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=8
#SBATCH --gres=gpu:8
#SBATCH --partition=gpu
#SBATCH --output=nemo-test-%j.out
#SBATCH --error=nemo-test-%j.err
#SBATCH --time=01:00:00

# =============================================================================
# NeMo Megatron GPT pretraining test
# =============================================================================
# Runs a small GPT model pretraining to verify multi-node NeMo functionality.
# Requires NeMo container image.
#
# Usage: sbatch submit.sh
# =============================================================================

export NCCL_PROTO=simple
export NCCL_DEBUG=WARN
export FI_PROVIDER=efa
export FI_EFA_USE_DEVICE_RDMA=1

CONTAINER_IMAGE="nvcr.io/nvidia/nemo:24.07"
NEMO_CONFIG="gpt3/126m"

echo "=== NeMo GPT Test ==="
echo "Nodes: $SLURM_JOB_NUM_NODES"
echo "Container: $CONTAINER_IMAGE"
echo "====================="

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
