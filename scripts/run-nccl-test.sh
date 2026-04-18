#!/usr/bin/env bash
# run-nccl-test.sh — Run NCCL all-reduce benchmark on HyperPod Slurm cluster.
#
# Run this ON the Slurm controller node (head node).
#
# Usage:
#   ./run-nccl-test.sh [num-nodes] [gpus-per-node]
#
# Examples:
#   ./run-nccl-test.sh          # 2 nodes, 1 GPU each (default)
#   ./run-nccl-test.sh 2 1      # 2 nodes, 1 GPU each
#   ./run-nccl-test.sh 4 8      # 4 nodes, 8 GPUs each (p5.48xlarge)

NUM_NODES="${1:-2}"
GPUS_PER_NODE="${2:-1}"
TOTAL_GPUS=$((NUM_NODES * GPUS_PER_NODE))

echo "============================================================"
echo "  NCCL All-Reduce Benchmark"
echo "  Nodes: $NUM_NODES | GPUs/node: $GPUS_PER_NODE | Total: $TOTAL_GPUS"
echo "============================================================"
echo ""

# ── Find NCCL test binary ───────────────────────────────────────────
NCCL_TEST=""
for candidate in \
    /usr/local/cuda-13.0/efa/test-cuda-13.0/all_reduce_perf \
    /usr/local/cuda-12.9/efa/test-cuda-12.9/all_reduce_perf \
    /opt/nccl-tests/build/all_reduce_perf \
    /tmp/nccl-tests/build/all_reduce_perf; do
    if srun -N 1 -p gpu --quiet bash -c "test -f $candidate" 2>/dev/null; then
        NCCL_TEST="$candidate"
        break
    fi
done

if [[ -z "$NCCL_TEST" ]]; then
    echo "ERROR: Could not find all_reduce_perf binary on worker nodes."
    echo ""
    echo "Searching for it..."
    srun -N 1 -p gpu bash -c "find /usr/local/cuda* /opt -name 'all_reduce_perf' 2>/dev/null"
    exit 1
fi
echo "Binary: $NCCL_TEST"

# ── Find NCCL library path ─────────────────────────────────────────
NCCL_LIB_DIR=""
for candidate in \
    /usr/local/cuda-13.0/lib \
    /usr/local/cuda-12.9/lib \
    /opt/nccl/build/lib; do
    if srun -N 1 -p gpu --quiet bash -c "test -f $candidate/libnccl.so" 2>/dev/null; then
        NCCL_LIB_DIR="$candidate"
        break
    fi
done

if [[ -z "$NCCL_LIB_DIR" ]]; then
    echo "WARNING: Could not find libnccl.so, using default paths"
    NCCL_LIB_DIR="/usr/local/cuda/lib"
fi
echo "NCCL lib: $NCCL_LIB_DIR"

# ── Build hostfile from Slurm ──────────────────────────────────────
HOSTFILE="/tmp/nccl-hostfile-$$"
sinfo -N -h -p gpu -t idle,alloc,mix -o "%N" | head -"$NUM_NODES" > "$HOSTFILE"

NODE_COUNT=$(wc -l < "$HOSTFILE" | tr -d ' ')
if [[ "$NODE_COUNT" -lt "$NUM_NODES" ]]; then
    echo "ERROR: Requested $NUM_NODES nodes but only $NODE_COUNT available"
    echo "Available nodes:"
    cat "$HOSTFILE"
    rm -f "$HOSTFILE"
    exit 1
fi

echo "Nodes:"
cat "$HOSTFILE" | sed 's/^/  /'
echo ""

# ── Set up library paths ───────────────────────────────────────────
FULL_LD_PATH="$NCCL_LIB_DIR:/opt/amazon/efa/lib:/opt/amazon/openmpi/lib:/opt/amazon/ofi-nccl/lib/x86_64-linux-gnu:/usr/local/cuda/lib64"

# ── Find NCCL tuner plugin (optional) ──────────────────────────────
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
echo "--- Starting NCCL test ---"
echo ""

# ── Run the test ───────────────────────────────────────────────────
/opt/amazon/openmpi/bin/mpirun --allow-run-as-root \
    -np "$TOTAL_GPUS" -N "$GPUS_PER_NODE" \
    --hostfile "$HOSTFILE" \
    --mca pml ^ucx \
    --mca btl tcp,self \
    --mca btl_tcp_if_exclude lo,docker0,veth_def_agent \
    -x LD_LIBRARY_PATH="$FULL_LD_PATH" \
    -x NCCL_DEBUG=INFO \
    -x NCCL_BUFFSIZE=8388608 \
    -x NCCL_P2P_NET_CHUNKSIZE=524288 \
    -x NCCL_SOCKET_IFNAME=^docker,lo,veth \
    -x FI_PROVIDER=efa \
    -x FI_EFA_USE_DEVICE_RDMA=1 \
    -x FI_EFA_FORK_SAFE=1 \
    $TUNER_ARGS \
    "$NCCL_TEST" -b 8 -e 16G -f 2 -g 1 -c 1 -n 100

EXIT_CODE=$?

# ── Cleanup ────────────────────────────────────────────────────────
rm -f "$HOSTFILE"

echo ""
if [[ $EXIT_CODE -eq 0 ]]; then
    echo "============================================================"
    echo "  NCCL test completed successfully"
    echo "============================================================"
else
    echo "============================================================"
    echo "  NCCL test FAILED (exit code: $EXIT_CODE)"
    echo "============================================================"
fi

exit $EXIT_CODE
