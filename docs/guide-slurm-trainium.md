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

# Verify Neuron devices (runs on worker)
srun -N 1 bash -c "/opt/aws/neuron/bin/neuron-ls"

# NCCOM all-reduce benchmark
run-nccom-test 2 32
```

## What the Tests Validate

### Neuron Device Check (`neuron-ls`)

**What it does:** Lists all Neuron devices, their core counts, memory, and connectivity.

**What it validates:**
- Neuron hardware is detected and accessible
- Correct number of devices for the instance type (16 for trn1.32xlarge)
- NeuronCore-to-NeuronCore connectivity topology
- PCIe device binding and NUMA node affinity

**Expected output (trn1.32xlarge):**
```
+--------+--------+----------+--------+
| NEURON | NEURON |  NEURON  | NEURON |
| DEVICE | CORES  | CORE IDS | MEMORY |
+--------+--------+----------+--------+
| 0      | 2      | 0-1      | 32 GB  |
| 1      | 2      | 2-3      | 32 GB  |
...
| 15     | 2      | 30-31    | 32 GB  |
+--------+--------+----------+--------+
```

16 devices x 2 cores = 32 NeuronCores, 512 GB total memory.

### NCCOM All-Reduce (`run-nccom-test`)

**What it does:** Runs collective communication operations across all Neuron devices on multiple nodes using the NCCOM library (Trainium's equivalent of NCCL).

**What it validates:**
- Multi-node EFA communication works
- NCCOM library initializes correctly with Neuron devices
- Data flows between all 32+ Neuron workers across nodes
- Bandwidth scales with message size

**How it works internally:**
1. Uses `nccom-test -S` for built-in Slurm job allocation
2. Sets `OMPI_ALLOW_RUN_AS_ROOT=1` (required on HyperPod)
3. Sets `FI_PROVIDER=efa` for Elastic Fabric Adapter transport
4. Runs all-reduce with bf16 datatype (typical for training)
5. Tests message sizes from 1KB to 128MB

**Output:**
```
      size(B)    count(elems)    type    time:avg(us)    algbw(GB/s)    busbw(GB/s)
       524288          262144    bf16          438.2           1.20           2.36
     16777216         8388608    bf16          844.85          19.86          39.10
    134217728        67108864    bf16         7025.52          19.10          37.01
Avg bus bandwidth:    13.29 GB/s
```

- **busbw** — Bus bandwidth (actual inter-device throughput). Increases with message size.
- Bandwidth is lower for small messages due to latency overhead.

## Measured Results

### 2x ml.trn1.32xlarge (EFA)

| Test | Result |
|------|--------|
| Neuron devices | 16 per node (32 NeuronCores) |
| NCCOM peak busbw | 37.01 GB/s at 128MB (32 workers) |
| NCCOM peak busbw | 59.17 GB/s at 67MB (64 workers) |
| NCCOM avg busbw | 13.29 GB/s |
| Both nodes confirmed | `scontrol show job` — NodeList shows 2 nodes |

### What to Expect on Larger Clusters

| Config | Workers | Expected Peak busbw | Notes |
|--------|---------|--------------------|----|
| 2x trn1.32xlarge | 64 | ~40-60 GB/s | Validated |
| 4x trn1.32xlarge | 128 | ~80-120 GB/s | Bandwidth scales with nodes |
| 8x trn1.32xlarge | 256 | ~100-150 GB/s | Near-linear scaling |
| 2x trn2.48xlarge | 128 | ~200+ GB/s | trn2 has 64 cores, 1600 Gbps EFA |

**Key scaling considerations:**
- Trainium uses NCCOM (not NCCL) — different performance characteristics
- `bf16` is the standard datatype for Trainium training (native support)
- trn2 instances have 2x the cores and 2x the EFA bandwidth of trn1
- At 8+ nodes, ensure all instances are in the same AZ (EFA can't cross AZs)
- Neuron SDK auto-detects instance type and configures parallelism

## Key Differences from GPU

### Communication
- Uses **NCCOM** (not NCCL) for collective communication
- Handled by `torch-neuronx` and `aws-neuronx-collectives` — no manual configuration
- Benchmark tool: `nccom-test` (not `all_reduce_perf`)
- Uses `-S` flag for built-in Slurm support

### Neuron Tools
- All tools at `/opt/aws/neuron/bin/` (not in PATH by default on DLAMI)
- Key commands: `neuron-ls`, `neuron-top`, `neuron-monitor`, `nccom-test`
- Lifecycle script adds path and installs `run-nccom-test` on controller

### Neuron Environment (auto-configured)
| Instance | NeuronCores | Target | Key Setting |
|----------|------------|--------|-------------|
| trn1.32xlarge | 32 | `trn1` | `NEURON_RT_NUM_CORES=32` |
| trn2.48xlarge | 64 | `trn2` | `NEURON_RT_NUM_CORES=64` |
| trn2.3xlarge | 4 | `trn2` | `NEURON_RT_NUM_CORES=4` |

Performance tuning (set automatically):
```
NEURON_FUSE_SOFTMAX=1
NEURON_RT_ASYNC_EXEC_MAX_INFLIGHT_REQUESTS=5
NEURON_RT_STOCHASTIC_ROUNDING_EN=1
OMP_NUM_THREADS=1
MALLOC_ARENA_MAX=70
```

### SDK
- DLAMI has pre-installed Neuron SDK — do **not** pip install over it
- Use virtual environments for version pinning if needed
- Neuron compiler (`neuronx-cc`) compiles models to NEFF format at first run

### NCCOM Test vs NCCL Test

| | GPU (NCCL) | Trainium (NCCOM) |
|---|---|---|
| Tool | `all_reduce_perf` | `nccom-test` |
| Command | `run-nccl-test 2 1` | `run-nccom-test 2 32` |
| Workers arg | GPUs per node | Neuron devices per node |
| Transport | EFA RDMA or TCP | EFA (always) |
| Slurm mode | `mpirun` + hostfile | `-S` flag (built-in) |
| Root workaround | N/A | `OMPI_ALLOW_RUN_AS_ROOT=1` |
| Datatype | float32 | bf16 (native) |

## Cluster Sizes

| Size | Workers | NeuronCores | Memory | Best for |
|------|---------|-------------|--------|----------|
| small | 2x trn1.32xl | 64 | 1 TB | Testing, fine-tuning |
| medium | 8x trn1.32xl | 256 | 4 TB | 7B-13B pre-training |
| large | 32x trn1.32xl | 1024 | 16 TB | 70B+ pre-training |

## Submit Training Jobs

```bash
sbatch examples/submit-neuron-job/slurm/submit.sh
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `neuron-ls` not found | Use full path: `/opt/aws/neuron/bin/neuron-ls` |
| `nccom-test` needs `ompi_info` | Add `/opt/amazon/openmpi/bin` to PATH |
| `mpirun` refuses root | `run-nccom-test` handles automatically |
| `NEURON_RT_ROOT_COMM_ID` required | Use `-S` flag — nccom-test handles via Slurm |
| EFA health check failed | Self-referencing egress rule required (fixed in templates) |
| Low bandwidth on small messages | Expected — bandwidth scales with message size |
| Wrong core count | Check `neuron-ls` output; lifecycle script auto-detects |
