#!/usr/bin/env bash
# run-nccom-test.sh — Run NCCOM all-reduce benchmark on Trainium clusters.
#
# Run this ON the Slurm controller node (head node).
# Based on: awsome-distributed-training/micro-benchmarks/nccom-tests/slurm/nccom-tests.sbatch
#
# Usage:
#   ./run-nccom-test.sh [num-nodes] [workers-per-node]
#
# Examples:
#   ./run-nccom-test.sh          # 2 nodes, 32 workers each (default)
#   ./run-nccom-test.sh 2 32     # 2 nodes, 32 workers each
#   ./run-nccom-test.sh 4 32     # 4 nodes, 32 workers each

NUM_NODES="${1:-2}"
WORKERS_PER_NODE="${2:-32}"
TOTAL_WORKERS=$((NUM_NODES * WORKERS_PER_NODE))

echo "============================================================"
echo "  NCCOM All-Reduce Benchmark (Trainium)"
echo "  Nodes: $NUM_NODES | Workers/node: $WORKERS_PER_NODE | Total: $TOTAL_WORKERS"
echo "============================================================"

export PATH=/opt/aws/neuron/bin:/opt/amazon/openmpi/bin:$PATH
export FI_PROVIDER=efa
export OMPI_ALLOW_RUN_AS_ROOT=1
export OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1

nccom-test -S \
    --nworkers $TOTAL_WORKERS \
    --nnodes $NUM_NODES \
    --minbytes 1KB \
    --maxbytes 128MB \
    --stepfactor 2 \
    --iters 5 \
    --warmup_iters 5 \
    --datatype bf16 \
    all_reduce
