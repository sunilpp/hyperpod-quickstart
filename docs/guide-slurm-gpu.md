# Slurm + GPU — Complete Guide

Best for HPC and research teams. Controller + worker architecture with Slurm job scheduling.

## Deploy

```bash
./scripts/deploy.sh slurm-gpu YOUR_S3_BUCKET us-west-2
```

Or click the **Slurm + GPU** Launch Stack button on the [main page](../README.md).

Set parameters in the CloudFormation console:

| Parameter | Testing | Production |
|-----------|---------|------------|
| `WorkerInstanceType` | `ml.g5.16xlarge` | `ml.p5.48xlarge` |
| `EnableObservability` | `false` | `true` |
| `EnableValidation` | `false` | `true` |

Wait ~20 minutes for `CREATE_COMPLETE`.

## Connect

```bash
# SSM into the controller (from your local machine)
./scripts/remote-nccl-test.sh <cluster-name> us-west-2
```

This auto-discovers the controller instance and opens an SSM session using the correct HyperPod target format (`sagemaker-cluster:<id>_controller-group-<instance-id>`).

## Test

On the controller:

```bash
# Verify cluster
sinfo

# NCCL all-reduce benchmark
run-nccl-test 2 1

# Multi-node training test (nanoGPT on Shakespeare)
run-nanogpt 2 1
```

Both commands are pre-installed during cluster creation and auto-detect EFA vs TCP.

## What the Tests Validate

### NCCL All-Reduce (`run-nccl-test`)

**What it does:** Sends increasingly large tensors between GPUs across nodes using NCCL collective operations. Measures bandwidth and checks for data corruption.

**What it validates:**
- GPU-to-GPU communication works across nodes
- EFA or TCP transport is correctly configured
- NCCL library initializes with the right plugins
- MPI process launch via hostfile works
- No data corruption (all `#wrong` values should be 0)

**How it works internally:**
1. Builds a deduplicated hostfile from Slurm with `slots=N`
2. Detects EFA RDMA capability — sets `NCCL_NET_PLUGIN=none` for non-EFA instances
3. Launches `all_reduce_perf` via `mpirun` with `--mca pml ob1 --mca btl tcp,self`
4. Runs 100 iterations per message size from 8B to 16GB

**Output:**
```
#       size      algbw   busbw  #wrong
   134217728      3.01    3.01       0    # 128MB message
  4294967296      3.01    3.01       0    # 4.3GB message
```

- **algbw** — Algorithm bandwidth (data size / time)
- **busbw** — Bus bandwidth (actual inter-GPU throughput)
- **#wrong** — Data corruption count (must be 0)

### nanoGPT Training (`run-nanogpt`)

**What it does:** Trains a small 0.8M-parameter GPT model on Shakespeare text across multiple nodes. Uses PyTorch DDP (DistributedDataParallel) with gradient synchronization.

**What it validates:**
- Full distributed training pipeline works (data loading, forward, backward, gradient sync, optimizer step)
- `torchrun` correctly sets RANK, WORLD_SIZE, MASTER_ADDR
- NCCL or Gloo backend handles gradient all-reduce
- Checkpoints save correctly
- Loss decreases (model is learning)

**How it works internally:**
1. Installs dependencies (torch, tiktoken) on all workers
2. Prepares Shakespeare dataset on each node
3. Launches `torchrun` via `srun` with auto-detected backend (NCCL for EFA, Gloo for TCP)
4. Trains for 200 iterations with eval every 50 steps

**Output:**
```
iter 0:   loss 4.1700   # start
iter 100: loss 3.4629   # -17%
iter 200: loss 3.0461   # -27%
```

Loss should decrease monotonically. If it doesn't, check GPU communication.

## Measured Results

### 2x ml.g5.16xlarge (TCP, no EFA)

| Test | Result |
|------|--------|
| NCCL peak busbw | 3.02 GB/s (saturates 25 Gbps link) |
| NCCL avg busbw | 1.18 GB/s |
| NCCL errors | 0 |
| nanoGPT final loss | 3.03 (from 4.17) |
| nanoGPT iter time | ~143ms |

### What to Expect on Larger Instances

| Instance | GPUs | Expected NCCL busbw | EFA | Notes |
|----------|------|--------------------|----|-------|
| 2x g5.16xlarge | 2 total | ~3 GB/s | No | TCP only, good for testing |
| 2x g5.48xlarge | 16 total | ~12 GB/s | Yes (SENDRECV) | First EFA-capable g5 |
| 2x p4d.24xlarge | 16 total | ~300 GB/s | Yes (RDMA) | Production training |
| 2x p5.48xlarge | 16 total | ~400 GB/s | Yes (RDMA) | Best performance |
| 8x p5.48xlarge | 64 total | ~400 GB/s | Yes (RDMA) | Large-scale training |
| 32x p5.48xlarge | 256 total | ~400 GB/s per pair | Yes (RDMA) | Need placement groups + topology-aware scheduling |

**Key scaling considerations:**
- Bandwidth is per-node-pair, not aggregate — adding more nodes doesn't reduce per-pair bandwidth
- At 8+ p5 nodes, use cluster placement groups for lowest latency
- At 32+ nodes, consider topology-aware NCCL testing to detect bad nodes
- Non-EFA instances (g5.16xlarge) are fine for testing but not for production training

## Instance Types

| Instance | GPUs | GPU Memory | EFA | Network | NCCL Transport | Cost/hr |
|----------|------|-----------|-----|---------|---------------|---------|
| `ml.g5.16xlarge` | 1x A10G | 24 GB | No | 25 Gbps TCP | Sockets | ~$7 |
| `ml.g5.48xlarge` | 8x A10G | 192 GB | Yes | 100 Gbps | EFA SENDRECV | ~$20 |
| `ml.p4d.24xlarge` | 8x A100 | 320 GB | Yes | 400 Gbps | EFA RDMA | ~$40 |
| `ml.p5.48xlarge` | 8x H100 | 640 GB | Yes | 3200 Gbps | EFA RDMA | ~$66 |

## Cluster Sizes

| Size | Workers | Best for |
|------|---------|----------|
| small | 2 | Testing, learning |
| medium | 8 | 7B-13B model training |
| large | 32 | 70B+ model training |

## Submit Training Jobs

```bash
# Pre-installed on controller
run-nanogpt 2 1

# Or use sbatch for background jobs
sbatch examples/nccl-test/slurm/train-nanogpt.sh
sbatch examples/submit-pytorch-job/slurm/submit.sh
```

## What Gets Set Up Automatically

The lifecycle script (`lifecycle-scripts/slurm/gpu/on_create.sh`) handles:

- **Node detection** — Identifies controller vs worker via IMDSv2 + resource_config.json
- **Slurm configless mode** — Workers connect via `--conf-server` (no DNS SRV needed)
- **MUNGE authentication** — Verified running before Slurm daemons start
- **SSH key distribution** — Shared on FSx (if mounted) or distributed via `srun`
- **FSx Lustre auto-discovery** — Queries FSx API by cluster name tag
- **NCCL tuning** — `NCCL_BUFFSIZE=8MB`, `NCCL_P2P_NET_CHUNKSIZE=512KB` (per AWS guidance)
- **EFA RDMA detection** — Only sets `FI_EFA_USE_DEVICE_RDMA=1` on supported instances
- **PATH setup** — `/opt/slurm/bin`, `/opt/amazon/openmpi/bin` added globally
- **Test scripts** — `run-nccl-test` and `run-nanogpt` symlinked to `/usr/local/bin/`

## Lifecycle Script Logs

```bash
cat /var/log/hyperpod/on_create.log
```

Expected output for a healthy deployment:
```
Instance group: controller-group
Node type: controller
MUNGE is running
slurm.conf found after 1s
Slurm controller is ready
SSH key distributed to 2 worker(s)
NCCL test ready: run-nccl-test [nodes] [gpus-per-node]
```

## Troubleshooting

| Problem | Check | Fix |
|---------|-------|-----|
| `sinfo` shows no workers | Lifecycle log on worker | Verify `--conf-server` injection |
| NCCL aborts with EFA error | Instance doesn't support EFA | `run-nccl-test` auto-handles; for manual runs use `NCCL_NET_PLUGIN=none` |
| SSH permission denied | Keys not distributed | Check FSx mount or srun key distribution in log |
| `run-nccl-test` not found | Old deployment | Use `/opt/slurm/bin/run-nccl-test` or redeploy |
| nanoGPT data not found | Data not prepared | `run-nanogpt` handles; for manual use `python3 data/shakespeare_char/prepare.py` |
| Low NCCL bandwidth | Non-EFA instance | Expected on g5.16xlarge; use p4d/p5 for production |
| EFA health check failed | Security group egress | Fixed in current templates (self-referencing egress rule) |
