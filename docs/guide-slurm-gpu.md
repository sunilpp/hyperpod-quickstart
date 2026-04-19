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

# NCCL all-reduce benchmark (auto-detects EFA vs TCP)
run-nccl-test 2 1

# Multi-node training test (nanoGPT on Shakespeare)
run-nanogpt 2 1
```

Both commands are pre-installed during cluster creation and auto-detect:
- EFA RDMA capability (uses NCCL with EFA on p5, TCP sockets on g5)
- GPU count per node
- Slurm partition names
- Distributed training backend (NCCL for EFA, Gloo for TCP)

## Interpret Results

### NCCL Benchmark

```
#       size      algbw   busbw
   134217728      3.01    3.01    # Peak bandwidth at 128MB message size
```

| Instance | Expected Bandwidth | Transport |
|----------|-------------------|-----------|
| g5.16xlarge | ~3 GB/s | TCP sockets |
| g5.48xlarge | ~12 GB/s | EFA SENDRECV |
| p4d.24xlarge | ~400 GB/s | EFA RDMA |
| p5.48xlarge | ~400 GB/s | EFA RDMA |

Key metrics:
- **algbw** — Algorithm bandwidth (data size / time)
- **busbw** — Bus bandwidth (inter-GPU communication speed)
- **#wrong** — Should always be 0

### nanoGPT Training

```
iter 0: loss 4.1700    # Starting loss
iter 199: loss 3.0486  # Should decrease steadily
step 200: train loss 3.0292, val loss 3.0371
```

The loss should decrease from ~4.17 to ~3.0 over 200 iterations. If loss doesn't decrease, check GPU connectivity.

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

- **Node detection** — Identifies controller vs worker via instance metadata (IMDSv2) and resource_config.json
- **Slurm configless mode** — Workers connect to controller via `--conf-server` (no DNS SRV needed)
- **MUNGE authentication** — Verified running before Slurm daemons start
- **SSH key distribution** — Shared keys on FSx (if mounted) or distributed via `srun` after workers register
- **FSx Lustre auto-discovery** — Queries FSx API by cluster name tag, mounts at `/fsx`
- **NCCL tuning** — `NCCL_BUFFSIZE=8MB`, `NCCL_P2P_NET_CHUNKSIZE=512KB`, no NCCL_ALGO/PROTO (per AWS guidance)
- **EFA RDMA detection** — Only sets `FI_EFA_USE_DEVICE_RDMA=1` on instances that support it
- **Test scripts** — `run-nccl-test` and `run-nanogpt` installed at `/usr/local/bin/`

## Lifecycle Script Logs

```bash
# On the controller via SSM
cat /var/log/hyperpod/on_create.log
```

Expected output for a healthy deployment:
```
Instance group: controller-group
Node type: controller
FSx Lustre auto-discovered / not configured
MUNGE is running
slurm.conf found after 1s
Slurm controller is ready
SSH key distributed to 2 worker(s)
NCCL test ready: run-nccl-test [nodes] [gpus-per-node]
```

## Troubleshooting

| Problem | Check | Fix |
|---------|-------|-----|
| `sinfo` shows no workers | `cat /var/log/hyperpod/on_create.log` on worker | Verify `--conf-server` was injected into slurmd.service |
| NCCL test aborts with EFA error | Instance doesn't support EFA RDMA | `run-nccl-test` auto-detects; use `NCCL_NET_PLUGIN=none` for manual runs |
| SSH permission denied between nodes | Keys not distributed | Check if FSx mounted; if not, verify srun key distribution in lifecycle log |
| `run-nccl-test` not found | Deployed before latest lifecycle script | Use full path `/opt/slurm/bin/run-nccl-test` or redeploy |
| nanoGPT "No such file" | Data not prepared on all nodes | `run-nanogpt` handles this; for manual runs, prep data on all nodes first |
