# Slurm + Trainium — Complete Guide

Best for cost-efficient distributed training with AWS custom silicon.

## Deploy

```bash
./scripts/deploy.sh slurm-trainium YOUR_S3_BUCKET us-west-2
```

Or click the **Slurm + Trainium** Launch Stack button on the [main page](../README.md).

**Important:** Set `AvailabilityZoneId` to an AZ with Trainium capacity (e.g., `usw2-az4`).

## Connect

```bash
./scripts/remote-nccl-test.sh <cluster-name> us-west-2
```

## Test

On the controller:

```bash
# Verify workers
sinfo

# Verify Neuron devices (runs on worker via Slurm)
srun -N 1 bash -c "/opt/aws/neuron/bin/neuron-ls"

# NCCOM all-reduce benchmark (pre-installed on controller)
run-nccom-test 2 32
```

### Interpret Results

```
   size(B)    count(elems)    type    time:avg(us)    algbw(GB/s)    busbw(GB/s)
    134217728    67108864    bf16         7025.52          19.10          37.01
Avg bus bandwidth:    13.29 GB/s
```

| Metric | Expected (2x trn1.32xl) |
|--------|------------------------|
| Peak busbw | ~37-60 GB/s |
| Avg busbw | ~11-15 GB/s |

Bandwidth increases with message size and scales with more nodes.

### Measured Performance (2x trn1.32xlarge)

```
Workers: 32 per node (16 Neuron devices x 2 cores)
Message range: 1KB to 128MB
Datatype: bf16
Peak busbw: 37.01 GB/s at 128MB
Avg busbw: 13.29 GB/s
Both nodes confirmed via scontrol show job
```

## Key Differences from GPU

### Communication
- Uses **NCCOM** (not NCCL) for collective communication
- Handled automatically by `torch-neuronx` — no manual configuration needed
- Uses `nccom-test` instead of NCCL's `all_reduce_perf`
- EFA is available and required on all Trainium instances

### Neuron Tools
- Neuron tools are at `/opt/aws/neuron/bin/` (not in PATH by default)
- Key commands: `neuron-ls`, `neuron-top`, `neuron-monitor`, `nccom-test`
- The lifecycle script adds `/opt/aws/neuron/bin/` to PATH

### Neuron Environment
Auto-detected and configured based on instance type:

| Instance | NeuronCores | Target | Auto-configured |
|----------|------------|--------|----------------|
| trn1.32xlarge | 32 | `trn1` | `NEURON_RT_NUM_CORES=32` |
| trn2.48xlarge | 64 | `trn2` | `NEURON_RT_NUM_CORES=64` |
| trn2.3xlarge | 4 | `trn2` | `NEURON_RT_NUM_CORES=4` |

Performance tuning variables set automatically:
- `NEURON_FUSE_SOFTMAX=1`
- `NEURON_RT_ASYNC_EXEC_MAX_INFLIGHT_REQUESTS=5`
- `NEURON_RT_STOCHASTIC_ROUNDING_EN=1`
- `OMP_NUM_THREADS=1`
- `MALLOC_ARENA_MAX=70`

### SDK
- DLAMI has pre-installed Neuron SDK — do **not** pip install over it
- Use the pre-installed versions for guaranteed compatibility

### NCCOM Test vs NCCL Test

| | GPU (NCCL) | Trainium (NCCOM) |
|---|---|---|
| Tool | `all_reduce_perf` (pre-built on DLAMI) | `nccom-test` (at `/opt/aws/neuron/bin/`) |
| Controller command | `run-nccl-test 2 1` | `run-nccom-test 2 32` |
| Workers arg | GPUs per node | Neuron devices per node (32 for trn1) |
| Transport | EFA RDMA or TCP | EFA (always) |
| Slurm mode | Uses `mpirun` with hostfile | Uses `-S` flag (built-in Slurm support) |
| Root workaround | N/A | Needs `OMPI_ALLOW_RUN_AS_ROOT=1` |

## Submit Training Jobs

```bash
sbatch examples/submit-neuron-job/slurm/submit.sh
```

## What Gets Set Up Automatically

Same as [Slurm + GPU](guide-slurm-gpu.md#what-gets-set-up-automatically), plus:
- Neuron core count auto-detection (trn1 vs trn2)
- Neuron performance environment variables
- `run-nccom-test` pre-installed on controller
- `/opt/aws/neuron/bin/` added to PATH

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `neuron-ls` not found | Use full path: `/opt/aws/neuron/bin/neuron-ls` |
| `nccom-test` needs `ompi_info` | Add `/opt/amazon/openmpi/bin` to PATH |
| `mpirun` refuses root | Set `OMPI_ALLOW_RUN_AS_ROOT=1` and `OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1` |
| `NEURON_RT_ROOT_COMM_ID` required | Use `-S` flag — nccom-test handles it via Slurm |
| EFA health check failed | Security group needs self-referencing egress rule (fixed in current templates) |
| Wrong core count | Check `neuron-ls` output; lifecycle script auto-detects |
| Low bandwidth | Use larger message sizes (`--maxbytes 128MB`); bandwidth scales with size |
