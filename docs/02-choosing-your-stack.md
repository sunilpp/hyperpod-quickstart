# Choosing Your Stack

This Quick Start offers four deployment options -- two orchestrators (EKS and Slurm) crossed with two accelerator types (NVIDIA GPU and AWS Trainium). This guide helps you pick the right combination for your team and workload.

---

## Decision Flowchart

Use this text flowchart to find your recommended stack:

```
Start
  |
  v
Does your team use Kubernetes daily?
  |                     |
  YES                   NO
  |                     |
  v                     v
Do you want the       Does your team run
lowest cost per       HPC/research workloads
training hour?        with Slurm?
  |         |           |           |
  YES       NO          YES         NO (new to both)
  |         |           |           |
  v         v           v           v
EKS +     EKS +      Slurm +     Do you want the lowest
Trainium  GPU        GPU/Trn*    cost per training hour?
                                    |           |
                                    YES         NO
                                    |           |
                                    v           v
                                  Slurm +     Slurm +
                                  Trainium    GPU

* If cost is a priority, choose Trainium. If framework compatibility
  matters more, choose GPU.
```

---

## EKS vs. Slurm

"Orchestrator" means the system that schedules and manages your training jobs on the cluster. This project supports two:

- **Amazon EKS (Elastic Kubernetes Service)** -- a managed Kubernetes service. You submit jobs using `kubectl` and Kubernetes manifests (YAML files).
- **Slurm** -- a widely used job scheduler in the HPC (high-performance computing) world. You submit jobs using `sbatch` and shell scripts.

### Comparison Table

| Feature | EKS | Slurm |
|---------|-----|-------|
| **Job submission** | `kubectl apply -f job.yaml` | `sbatch submit.sh` |
| **Job monitoring** | `kubectl get pods`, `kubectl logs` | `squeue`, `sacct`, `scontrol` |
| **Learning curve** | Steeper if new to Kubernetes | Simpler for batch-style jobs |
| **Multi-tenancy** | Kubernetes namespaces, RBAC, Kueue | Slurm partitions, accounts, fair-share |
| **Container support** | Native (pods are containers) | Via Enroot/Pyxis (`--container-image`) |
| **Ecosystem** | Helm charts, operators (PyTorchJob, MPIJob) | MPI, PMIx, environment modules |
| **Node access** | `kubectl exec` into pods | SSH or SSM to any node directly |
| **Controller cost** | EKS control plane: $0.10/hr | Slurm head node (ml.m5.2xlarge): $0.46/hr |
| **Best for** | Teams already on Kubernetes | HPC teams, researchers, simple setups |

### When to Choose EKS

- Your organization already runs workloads on Kubernetes
- You want to use Kubernetes-native tools like Kueue for job queuing, Helm for deployments, or PyTorchJob for distributed training
- You need to run ML training alongside other Kubernetes workloads in the same cluster
- Your team is comfortable writing Kubernetes manifests

### When to Choose Slurm

- Your team comes from an HPC or research background and already knows `sbatch`/`srun`
- You want the simplest path to submitting distributed training jobs
- You prefer direct SSH access to compute nodes for debugging
- You do not need Kubernetes-specific features

> **Tip:** If your team is completely new to both, Slurm is generally easier to get started with. The `sbatch` workflow is straightforward: write a shell script, submit it, check the output file.

---

## NVIDIA GPU vs. AWS Trainium

"Accelerator" means the specialized hardware that speeds up your training. This project supports two families:

- **NVIDIA GPU** -- the industry-standard GPU used by most ML frameworks. Uses CUDA for computation and NCCL for multi-node communication.
- **AWS Trainium** -- a custom chip designed by AWS specifically for ML training. Uses the Neuron SDK and NCCOM for multi-node communication.

### Comparison Table

| Feature | NVIDIA GPU (p5.48xlarge) | AWS Trainium (trn1.32xlarge) |
|---------|--------------------------|------------------------------|
| **Accelerators per instance** | 8x H100 80 GB | 16 NeuronCores v2 |
| **On-demand price** | ~$65.85/hr | ~$24.78/hr |
| **Price per accelerator** | ~$8.23/hr per GPU | ~$1.55/hr per NeuronCore |
| **Network bandwidth (EFA)** | 3,200 Gbps | 800 Gbps |
| **Framework support** | PyTorch, JAX, TensorFlow, NeMo, DeepSpeed, Megatron, and more | PyTorch (via Neuron SDK), JAX (via Neuron SDK) |
| **CUDA support** | Yes (native) | No (uses XLA/Neuron compiler) |
| **Software stack** | NVIDIA drivers, CUDA, cuDNN, NCCL | AWS Neuron SDK, Neuron compiler, NCCOM |
| **Monitoring** | DCGM Exporter (GPU metrics) | Neuron Monitor (NeuronCore metrics) |
| **Benchmarks** | NCCL all-reduce tests | NCCOM all-reduce tests |
| **Best for** | Maximum compatibility, CUDA-dependent code | Cost-optimized PyTorch training |

### When to Choose NVIDIA GPU

- Your model uses CUDA-specific libraries (custom CUDA kernels, cuDNN, TensorRT)
- You need support for frameworks beyond PyTorch (TensorFlow, JAX without modification)
- You are running NVIDIA-specific tools like NeMo, Megatron-LM, or DeepSpeed
- You need the highest single-node performance for very large models
- You want the broadest community support and documentation

### When to Choose AWS Trainium

- You are training PyTorch models and want to reduce cost significantly (~2.5x better price-performance)
- Your model uses standard PyTorch operations (no custom CUDA kernels)
- You are doing large-scale training where the cost difference adds up quickly
- You are willing to compile your model with the Neuron compiler (adds a compilation step but runs automatically)

> **Warning:** If your code depends on custom CUDA kernels or CUDA-specific libraries, it will not run on Trainium without modification. Check the [AWS Neuron documentation](https://awsdocs-neuron.readthedocs-hosted.com/) for supported operations before choosing Trainium.

---

## The Four Stacks at a Glance

| Stack | Orchestrator | Accelerator | Default Instance | Cost (2 nodes) | Best For |
|-------|-------------|-------------|------------------|-----------------|----------|
| **eks-gpu** | Amazon EKS | NVIDIA GPU | ml.p5.48xlarge | ~$133/hr | Kubernetes teams, GPU workloads |
| **eks-trainium** | Amazon EKS | AWS Trainium | ml.trn1.32xlarge | ~$50/hr | Kubernetes teams, cost-optimized training |
| **slurm-gpu** | Slurm | NVIDIA GPU | ml.p5.48xlarge | ~$133/hr | HPC/research teams, GPU workloads |
| **slurm-trainium** | Slurm | AWS Trainium | ml.trn1.32xlarge | ~$50/hr | HPC/research teams, cost-optimized training |

### What is the same across all stacks

Every stack deploys the same foundational infrastructure:

- VPC with public and private subnets
- NAT gateway for outbound internet access
- S3 VPC endpoint to avoid NAT charges on S3 traffic
- Security group with self-referencing rules for EFA
- FSx for Lustre shared filesystem
- S3 bucket for lifecycle scripts
- IAM execution role for HyperPod
- Optional: Prometheus + Grafana monitoring
- Optional: post-deployment validation
- Optional: network performance benchmarks

### What differs between stacks

| Component | Slurm Stacks | EKS Stacks |
|-----------|-------------|------------|
| EKS control plane | Not deployed | Deployed |
| EKS add-ons | Not deployed | Deployed (CoreDNS, kube-proxy, VPC CNI) |
| Slurm controller node | Deployed (ml.m5.2xlarge) | Not deployed |
| Job submission | `sbatch` / `srun` | `kubectl apply` |

| Component | GPU Stacks | Trainium Stacks |
|-----------|-----------|-----------------|
| Lifecycle scripts | Install NVIDIA drivers, CUDA, NCCL | Install Neuron SDK, Neuron compiler |
| Monitoring exporter | DCGM Exporter | Neuron Monitor |
| Dashboards | GPU utilization, GPU memory, GPU temp | NeuronCore utilization, Neuron memory |
| Benchmarks | NCCL all-reduce | NCCOM all-reduce |

---

## Changing Your Mind Later

You can delete one stack and deploy a different one at any time. Here is what to keep in mind:

- **FSx data is deleted with the stack.** Copy any important data (model checkpoints, datasets) to S3 before deleting.
- **S3 data persists** if you manually created buckets. The lifecycle script bucket created by the stack is deleted with the stack.
- **Grafana dashboards are recreated** automatically with each new stack. You do not need to configure them manually.

> **Tip:** Start with the "small" cluster size (2 worker nodes) to experiment. Once you have confirmed your stack choice works, scale up by redeploying with a larger size. See [Scaling Your Cluster](08-scaling.md) for details.

---

## Next Step

Once you have chosen your stack, proceed to [Deploying Your Cluster](03-deploying.md).
