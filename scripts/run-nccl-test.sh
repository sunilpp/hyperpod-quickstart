#!/usr/bin/env bash
# run-nccl-test.sh — Run NCCL all-reduce benchmark on HyperPod Slurm cluster.
#
# Run this ON the Slurm controller node (head node).
# Based on: https://awslabs.github.io/ai-on-sagemaker-hyperpod/docs/slurm-orchestration/validation-and-testing/performance-testing/nccl-tests
#
# Usage:
#   ./run-nccl-test.sh [num-nodes] [gpus-per-node] [test-type]
#
# Examples:
#   ./run-nccl-test.sh              # 2 nodes, auto-detect GPUs, all_reduce
#   ./run-nccl-test.sh 2 1          # 2 nodes, 1 GPU each
#   ./run-nccl-test.sh 4 8          # 4 nodes, 8 GPUs each (p5.48xlarge)
#   ./run-nccl-test.sh 2 8 allgather

NUM_NODES="${1:-2}"
GPUS_PER_NODE="${2:-0}"
TEST_TYPE="${3:-allreduce}"

# Map test name to binary name
case "$TEST_TYPE" in
    allreduce|all_reduce)  TEST_BINARY="all_reduce_perf" ;;
    allgather|all_gather)  TEST_BINARY="all_gather_perf" ;;
    reducescatter|reduce_scatter) TEST_BINARY="reduce_scatter_perf" ;;
    alltoall)              TEST_BINARY="alltoall_perf" ;;
    broadcast)             TEST_BINARY="broadcast_perf" ;;
    reduce)                TEST_BINARY="reduce_perf" ;;
    scatter)               TEST_BINARY="scatter_perf" ;;
    gather)                TEST_BINARY="gather_perf" ;;
    sendrecv)              TEST_BINARY="sendrecv_perf" ;;
    *)                     TEST_BINARY="all_reduce_perf" ;;
esac

echo "============================================================"
echo "  NCCL Benchmark: $TEST_TYPE"
echo "  Nodes: $NUM_NODES"
echo "============================================================"
echo ""

# ── Auto-detect GPUs per node if not specified ─────────────────────
if [[ "$GPUS_PER_NODE" -eq 0 ]]; then
    GPUS_PER_NODE=$(srun -N 1 -p gpu --quiet bash -c "nvidia-smi -L 2>/dev/null | wc -l" 2>/dev/null || echo "1")
    if [[ "$GPUS_PER_NODE" -eq 0 ]]; then
        GPUS_PER_NODE=1
    fi
    echo "Auto-detected $GPUS_PER_NODE GPU(s) per node"
fi

TOTAL_GPUS=$((NUM_NODES * GPUS_PER_NODE))
echo "GPUs/node: $GPUS_PER_NODE | Total GPUs: $TOTAL_GPUS"
echo ""

# ── Find NCCL test binary (DLAMI pre-built paths first) ───────────
NCCL_TEST=""
for candidate in \
    /usr/local/cuda-13.0/efa/test-cuda-13.0/${TEST_BINARY} \
    /usr/local/cuda-12.9/efa/test-cuda-12.9/${TEST_BINARY} \
    /opt/nccl-tests/build/${TEST_BINARY} \
    /tmp/nccl-tests/build/${TEST_BINARY}; do
    if srun -N 1 -p gpu --quiet bash -c "test -x $candidate" 2>/dev/null; then
        NCCL_TEST="$candidate"
        break
    fi
done

if [[ -z "$NCCL_TEST" ]]; then
    echo "ERROR: Could not find $TEST_BINARY binary on worker nodes."
    echo ""
    echo "Searching..."
    srun -N 1 -p gpu bash -c "find /usr/local/cuda* /opt -name '${TEST_BINARY}' 2>/dev/null"
    echo ""
    echo "The DLAMI should have pre-built NCCL tests at:"
    echo "  /usr/local/cuda-13.0/efa/test-cuda-13.0/${TEST_BINARY}"
    exit 1
fi
echo "Binary: $NCCL_TEST"

# ── Detect library paths ──────────────────────────────────────────
# Use the same CUDA version directory as the binary
CUDA_LIB_DIR=$(echo "$NCCL_TEST" | grep -o '/usr/local/cuda-[0-9.]*' || echo "/usr/local/cuda")
ADDITIONAL_LD_PATH="${CUDA_LIB_DIR}/lib"

echo "CUDA lib: $ADDITIONAL_LD_PATH"

# ── Build hostfile from Slurm ──────────────────────────────────────
HOSTFILE="/tmp/nccl-hostfile-$$"
sinfo -N -h -p gpu -t idle,alloc,mix -o "%N" | head -"$NUM_NODES" > "$HOSTFILE"

NODE_COUNT=$(wc -l < "$HOSTFILE" | tr -d ' ')
if [[ "$NODE_COUNT" -lt "$NUM_NODES" ]]; then
    echo "ERROR: Requested $NUM_NODES nodes but only $NODE_COUNT available"
    sinfo -p gpu
    rm -f "$HOSTFILE"
    exit 1
fi

echo "Nodes:"
cat "$HOSTFILE" | sed 's/^/  /'
echo ""

# ── Print hostname-to-instance mapping ─────────────────────────────
echo "--- Node Mapping ---"
mpirun --allow-run-as-root -N 1 --hostfile "$HOSTFILE" \
    bash -c 'echo "$(hostname) => $(cat /sys/devices/virtual/dmi/id/board_asset_tag 2>/dev/null | tr -d " " || echo "unknown")"' 2>/dev/null || true
echo ""

# ── Find NCCL tuner plugin (optional, improves performance) ───────
TUNER_ARGS=""
for tuner in \
    /opt/amazon/ofi-nccl/lib/libnccl-ofi-tuner.so \
    /opt/amazon/ofi-nccl/lib/x86_64-linux-gnu/libnccl-ofi-tuner.so; do
    if srun -N 1 -p gpu --quiet bash -c "test -f $tuner" 2>/dev/null; then
        TUNER_ARGS="-x NCCL_TUNER_PLUGIN=$tuner"
        echo "Tuner: $tuner"
        break
    fi
done

echo ""
echo "--- Starting NCCL $TEST_TYPE test ---"
echo ""

# ── Run the test ──────────────────────────────────────────────────
# Based on: awsome-distributed-training/micro-benchmarks/nccl-tests/slurm/nccl-tests-ami.sbatch
/opt/amazon/openmpi/bin/mpirun --allow-run-as-root \
    -np "$TOTAL_GPUS" -N "$GPUS_PER_NODE" \
    --hostfile "$HOSTFILE" \
    --bind-to none \
    -x FI_PROVIDER=efa \
    -x FI_EFA_FORK_SAFE=1 \
    -x LD_LIBRARY_PATH="$ADDITIONAL_LD_PATH:/opt/amazon/efa/lib:/opt/amazon/openmpi/lib:/opt/amazon/ofi-nccl/lib:/usr/local/lib:/usr/lib" \
    -x NCCL_DEBUG=INFO \
    -x NCCL_SOCKET_IFNAME=^docker,lo,veth \
    -x NCCL_BUFFSIZE=8388608 \
    -x NCCL_P2P_NET_CHUNKSIZE=524288 \
    $TUNER_ARGS \
    --mca pml ^ucx \
    --mca btl tcp,self \
    --mca btl_tcp_if_exclude lo,docker0,veth_def_agent \
    "$NCCL_TEST" -b 8 -e 16G -f 2 -g 1 -c 1 -n 100

EXIT_CODE=$?

# ── Cleanup ────────────────────────────────────────────────────────
rm -f "$HOSTFILE"

echo ""
if [[ $EXIT_CODE -eq 0 ]]; then
    echo "============================================================"
    echo "  NCCL $TEST_TYPE test completed successfully"
    echo "============================================================"
else
    echo "============================================================"
    echo "  NCCL $TEST_TYPE test FAILED (exit code: $EXIT_CODE)"
    echo "============================================================"
fi

exit $EXIT_CODE
