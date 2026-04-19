# Slurm + Trainium — Complete Guide

Best for cost-efficient distributed training with AWS custom silicon.

## Deploy

```bash
./scripts/deploy.sh slurm-trainium YOUR_S3_BUCKET us-west-2
```

Or click the **Slurm + Trainium** Launch Stack button on the [main page](../README.md).

## Connect

```bash
./scripts/remote-nccl-test.sh <cluster-name> us-west-2
```

## Test

```bash
sinfo                    # Verify workers
srun -N 1 neuron-ls      # Verify Neuron devices
```

## Key Differences from GPU

### Communication
- Uses **NCCOM** (not NCCL) for collective communication
- Handled automatically by `torch-neuronx` — no manual configuration needed
- EFA is available on all Trainium instances

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

## Submit Training Jobs

```bash
sbatch examples/submit-neuron-job/slurm/submit.sh
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `neuron-ls` not found | Neuron SDK not installed on this AMI — check instance type |
| Wrong core count detected | Check `neuron-ls` output; lifecycle script auto-detects from this |
| NCCOM errors | Verify EFA is working: `fi_info -p efa` |
