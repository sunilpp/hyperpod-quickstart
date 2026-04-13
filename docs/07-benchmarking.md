# Benchmarking Your Cluster

After deploying and validating your cluster, you can run network performance benchmarks to verify that inter-node communication is performing as expected. This is important because distributed training performance depends heavily on network bandwidth between nodes.

---

## What Gets Benchmarked

| Compute Type | Benchmark Tool | What It Tests |
|-------------|---------------|---------------|
| **NVIDIA GPU** | NCCL Tests (all-reduce) | GPU-to-GPU communication bandwidth across nodes via EFA |
| **AWS Trainium** | NCCOM Tests (all-reduce) | NeuronCore-to-NeuronCore communication bandwidth across nodes via EFA |

The **all-reduce** operation is the most common collective in distributed training. It sums a tensor across all devices and distributes the result back. If all-reduce is fast, your distributed training will scale well across nodes.

---

## Automatic Benchmarks (During Deployment)

If you set `RunBenchmarks` to `true` when deploying the stack, a Lambda function runs after the cluster is created and generates benchmark instructions (and attempts to run benchmarks automatically via SSM).

### Viewing Automatic Benchmark Results

The results are stored in S3:

```bash
# Get the S3 path from the stack outputs
aws cloudformation describe-stacks \
  --stack-name my-hyperpod-cluster \
  --region us-west-2 \
  --query 'Stacks[0].Outputs[?OutputKey==`BenchmarkResults`].OutputValue' \
  --output text

# Download and view results
aws s3 ls s3://<bucket>/benchmark-results/
aws s3 cp s3://<bucket>/benchmark-results/ ./benchmark-results/ --recursive
```

The `instructions.json` file contains the benchmark name, the command to run manually, and the expected performance baseline.

> **Tip:** If automated execution was not possible (for example, due to SSM access requirements on the cluster nodes), the instructions file tells you the exact command to run manually. See the next section.

---

## Running Benchmarks Manually

Manual benchmarks give you more control and are the recommended approach for thorough performance verification.

### NCCL All-Reduce Benchmark (GPU Clusters)

The NCCL tests suite measures collective operation performance. The most important test is `all_reduce_perf`.

#### On Slurm

```bash
# Connect to the head node
aws ssm start-session --target <controller-instance-id> --region us-west-2

# Run all-reduce benchmark across 2 nodes, 8 GPUs per node
srun --mpi=pmix -N 2 --ntasks-per-node=8 \
  /opt/nccl-tests/build/all_reduce_perf \
  -b 8 -e 4G -f 2 -g 1
```

**What the flags mean:**

| Flag | Meaning |
|------|---------|
| `--mpi=pmix` | Use PMIx for MPI process management |
| `-N 2` | Use 2 nodes |
| `--ntasks-per-node=8` | 8 tasks (one per GPU) per node |
| `-b 8` | Start with 8-byte messages |
| `-e 4G` | End with 4 GB messages |
| `-f 2` | Multiply message size by 2 each step |
| `-g 1` | 1 GPU per task (8 tasks x 1 GPU = 8 GPUs per node) |

#### On EKS

Create a benchmark job manifest:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: nccl-benchmark
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: nccl-test
          image: 763104351884.dkr.ecr.us-west-2.amazonaws.com/pytorch-training:2.1.0-gpu-py310-cu121-ubuntu20.04-sagemaker
          command: ["/opt/nccl-tests/build/all_reduce_perf"]
          args: ["-b", "8", "-e", "4G", "-f", "2", "-g", "8"]
          resources:
            limits:
              nvidia.com/gpu: 8
          env:
            - name: NCCL_DEBUG
              value: INFO
            - name: FI_PROVIDER
              value: efa
            - name: FI_EFA_USE_DEVICE_RDMA
              value: "1"
  backoffLimit: 1
```

```bash
kubectl apply -f nccl-benchmark.yaml
kubectl logs -f job/nccl-benchmark
```

> **Tip:** If `/opt/nccl-tests/build/all_reduce_perf` does not exist, the NCCL tests may need to be built from source:
> ```bash
> git clone https://github.com/NVIDIA/nccl-tests.git
> cd nccl-tests
> make MPI=1 CUDA_HOME=/usr/local/cuda NCCL_HOME=/usr/lib/x86_64-linux-gnu
> ```

### NCCOM All-Reduce Benchmark (Trainium Clusters)

#### On Slurm

```bash
# Connect to the head node
aws ssm start-session --target <controller-instance-id> --region us-west-2

# Run NCCOM all-reduce benchmark across 2 nodes
srun -N 2 --ntasks-per-node=1 \
  nccom-test all_reduce --data-type fp32 --size 4G
```

#### On EKS

```bash
kubectl apply -f examples/nccom-benchmark-job.yaml
kubectl logs -f job/nccom-benchmark
```

---

## Understanding the Results

### NCCL All-Reduce Output

A typical NCCL all-reduce output looks like this:

```
#                                                              out-of-place                       in-place
#       size         count      type   redop    root     time   algbw   busbw #wrong     time   algbw   busbw #wrong
#        (B)    (elements)                               (us)  (GB/s)  (GB/s)            (us)  (GB/s)  (GB/s)
           8             2     float     sum      -1     32.1    0.00    0.00      0     30.8    0.00    0.00      0
          16             4     float     sum      -1     31.5    0.00    0.00      0     30.4    0.00    0.00      0
         ...
  4294967296    1073741824     float     sum      -1   36524   117.6   220.5      0   36498   117.7   220.7      0
```

**Key columns explained:**

| Column | What It Means |
|--------|---------------|
| `size` | Message size in bytes |
| `count` | Number of elements |
| `time (us)` | Time for the operation in microseconds |
| `algbw (GB/s)` | Algorithm bandwidth -- total data moved divided by time |
| `busbw (GB/s)` | Bus bandwidth -- normalized for the number of GPUs. **This is the most meaningful metric to compare against baselines.** |
| `#wrong` | Number of incorrect results. Should always be 0. |

Focus on the **last row** (largest message size, typically 4 GB) and the **busbw** column.

To convert GB/s to Gbps: multiply by 8. For example, 220 GB/s = 1,760 Gbps.

### Expected Performance Baselines

These are approximate expected **bus bandwidth** values for large messages (4 GB) with properly configured EFA:

| Instance Type | Expected Bus BW (GB/s) | Expected Bus BW (Gbps) | EFA Link Speed |
|---------------|------------------------|------------------------|----------------|
| `ml.p5.48xlarge` (H100) | ~380-420 | ~3,040-3,360 | 3,200 Gbps |
| `ml.p4d.24xlarge` (A100) | ~140-160 | ~1,120-1,280 | 400 Gbps |
| `ml.g5.48xlarge` (A10G) | ~20-25 | ~160-200 | 100 Gbps |
| `ml.trn1.32xlarge` | ~80-100 | ~640-800 | 800 Gbps |

> **Warning:** If your results are significantly below these baselines (less than 50% of expected), something is wrong. Common causes:
> - **EFA not active:** NCCL fell back to TCP. Check that `FI_PROVIDER=efa` is set and look for `NET/OFI` in NCCL debug output.
> - **Security group misconfigured:** Missing self-referencing ingress rule. See [Networking Issues](troubleshooting/networking-issues.md).
> - **Not enough EFA interfaces:** Verify EFA interfaces are allocated with `fi_info -p efa`.

### NCCOM All-Reduce Output

NCCOM output is similar in structure. Look for the bandwidth numbers at large message sizes (4 GB) and compare against the Trainium baseline above.

---

## Additional Benchmark Tests

### Point-to-Point Bandwidth (GPU Only)

Test raw bidirectional bandwidth between two specific nodes:

```bash
# On Slurm
srun --mpi=pmix -N 2 --ntasks-per-node=1 \
  /opt/nccl-tests/build/sendrecv_perf \
  -b 8 -e 4G -f 2 -g 8
```

This measures the maximum bandwidth the EFA link can deliver between two nodes.

### EFA Loopback Test

Test that individual EFA devices are functional:

```bash
# On any worker node
fi_pingpong -p efa -e rdm
```

This verifies basic EFA connectivity without involving the full NCCL stack.

### Multi-Node Scaling Test

Run the all-reduce benchmark with different node counts to verify scaling:

```bash
# 2 nodes
srun --mpi=pmix -N 2 --ntasks-per-node=8 /opt/nccl-tests/build/all_reduce_perf -b 4G -e 4G -g 1

# 4 nodes (if available)
srun --mpi=pmix -N 4 --ntasks-per-node=8 /opt/nccl-tests/build/all_reduce_perf -b 4G -e 4G -g 1

# 8 nodes (if available)
srun --mpi=pmix -N 8 --ntasks-per-node=8 /opt/nccl-tests/build/all_reduce_perf -b 4G -e 4G -g 1
```

Bus bandwidth should remain roughly constant as you add more nodes. If it drops significantly, there may be a network bottleneck.

---

## Saving Benchmark Results

### To the Shared Filesystem

```bash
# Redirect output to a file on /fsx
srun --mpi=pmix -N 2 --ntasks-per-node=8 \
  /opt/nccl-tests/build/all_reduce_perf \
  -b 8 -e 4G -f 2 -g 1 \
  2>&1 | tee /fsx/benchmark-results/nccl-allreduce-$(date +%Y%m%d).log
```

### To S3

```bash
aws s3 cp /fsx/benchmark-results/ \
  s3://<your-bucket>/benchmark-results/ \
  --recursive
```

---

## When to Re-Run Benchmarks

Run benchmarks again when:

- You **scale the cluster** (add or remove nodes)
- Nodes are **replaced by HyperPod auto-recovery** (the replacement node should perform identically)
- You **change the instance type**
- You suspect **network performance degradation** during training
- **Before starting a large, expensive training run** (to confirm the cluster is healthy)

---

## Monitoring Benchmark Metrics in Grafana

After running benchmarks, check the **EFA Performance** dashboard in Grafana to see:
- Peak EFA throughput during the benchmark
- Any EFA errors that occurred
- Network utilization patterns

This gives you a visual complement to the raw benchmark numbers.

---

## Next Steps

- [Scale your cluster](08-scaling.md) once you have confirmed performance
- [Monitor training jobs](06-observability.md) in the Grafana dashboards
- Review [cost management](09-cost-management.md) before running large jobs
