#!/bin/bash
# NCCL All-Reduce benchmark for HyperPod Slurm clusters.
# Based on: awsome-distributed-training/micro-benchmarks/nccl-tests/slurm/nccl-tests-ami.sbatch
#
# Usage:
#   sbatch nccl-test.sbatch                     # defaults: all_reduce, auto-detect binary
#   sbatch nccl-test.sbatch allgather           # run a different collective
#   sbatch nccl-test.sbatch allreduce /path/to/binary /path/to/libs
#
# Customize SBATCH directives below for your cluster size.

#SBATCH --job-name=nccl-test
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --output=%x_%j.out
#SBATCH --error=%x_%j.err
#SBATCH --exclusive
#SBATCH --partition=gpu

set -ex

# ── Parse arguments ────────────────────────────────────────────────
TEST_TYPE="${1:-allreduce}"
case "$TEST_TYPE" in
    allreduce|all_reduce)  TEST_BINARY="all_reduce_perf" ;;
    allgather|all_gather)  TEST_BINARY="all_gather_perf" ;;
    reducescatter|reduce_scatter) TEST_BINARY="reduce_scatter_perf" ;;
    alltoall)              TEST_BINARY="alltoall_perf" ;;
    *)                     TEST_BINARY="all_reduce_perf" ;;
esac

# ── Find binary (DLAMI pre-built paths) ────────────────────────────
ALL_REDUCE_BINARY=${2:-}
if [[ -z "$ALL_REDUCE_BINARY" ]]; then
    for candidate in \
        /usr/local/cuda-13.0/efa/test-cuda-13.0/${TEST_BINARY} \
        /usr/local/cuda-12.9/efa/test-cuda-12.9/${TEST_BINARY} \
        /opt/nccl-tests/build/${TEST_BINARY}; do
        if [[ -x "$candidate" ]]; then
            ALL_REDUCE_BINARY="$candidate"
            break
        fi
    done
fi

if [[ -z "$ALL_REDUCE_BINARY" ]]; then
    echo "ERROR: Could not find ${TEST_BINARY}"
    exit 1
fi

ADDITIONAL_LD_LIBRARY_PATH=${3:-/usr/local/cuda-13.0/lib}

# ── Detect GPUs per node ───────────────────────────────────────────
GPUS_PER_NODE=$(nvidia-smi -L 2>/dev/null | wc -l || echo "1")
TOTAL_GPUS=$((GPUS_PER_NODE * SLURM_JOB_NUM_NODES))

echo "Binary: $ALL_REDUCE_BINARY"
echo "Nodes: $SLURM_JOB_NUM_NODES | GPUs/node: $GPUS_PER_NODE | Total: $TOTAL_GPUS"

# ── Print node mapping ─────────────────────────────────────────────
mpirun --allow-run-as-root -N 1 \
    bash -c 'echo "$(hostname) => $(cat /sys/devices/virtual/dmi/id/board_asset_tag 2>/dev/null | tr -d " " || echo unknown)"' || true

# ── Run NCCL test ──────────────────────────────────────────────────
mpirun --allow-run-as-root \
    -n "$TOTAL_GPUS" -N "$GPUS_PER_NODE" \
    --bind-to none \
    -x FI_PROVIDER=efa \
    -x FI_EFA_FORK_SAFE=1 \
    -x LD_LIBRARY_PATH="$ADDITIONAL_LD_LIBRARY_PATH:/opt/amazon/efa/lib:/opt/amazon/openmpi/lib:/opt/amazon/ofi-nccl/lib:/usr/local/lib:/usr/lib:$LD_LIBRARY_PATH" \
    -x NCCL_DEBUG=INFO \
    -x NCCL_SOCKET_IFNAME=^docker,lo,veth \
    -x NCCL_BUFFSIZE=8388608 \
    -x NCCL_P2P_NET_CHUNKSIZE=524288 \
    -x NCCL_TUNER_PLUGIN=/opt/amazon/ofi-nccl/lib/libnccl-ofi-tuner.so \
    --mca pml ^ucx \
    --mca btl tcp,self \
    --mca btl_tcp_if_exclude lo,docker0,veth_def_agent \
    "$ALL_REDUCE_BINARY" -b 8 -e 16G -f 2 -g 1 -c 1 -n 100
