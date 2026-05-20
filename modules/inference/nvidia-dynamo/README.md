# NVIDIA Dynamo Inference Extension

Deploy [NVIDIA Dynamo](https://github.com/ai-dynamo/dynamo) on your HyperPod/EKS cluster for high-performance LLM inference with disaggregated serving, KV-aware routing, and auto-scaling GPU nodes.

## What is NVIDIA Dynamo?

NVIDIA Dynamo is an open-source, datacenter-scale distributed inference framework. It sits on top of inference engines (vLLM, SGLang, TensorRT-LLM) and orchestrates them into a coordinated multi-node serving system. Key capabilities:

- **Disaggregated Prefill/Decode** — splits LLM inference phases onto separate GPU pools for independent scaling
- **KV-Aware Smart Router** — routes requests to workers that already have relevant KV cache, avoiding redundant computation (2x faster TTFT)
- **SLO Planner** — auto-scales prefill/decode workers based on real-time latency targets
- **KV Block Manager** — offloads KV cache across GPU -> CPU -> SSD -> S3 memory tiers
- **NIXL** — low-latency data transfer library with EFA, NVLink, and GPUDirect support

Performance highlights: **7x throughput per GPU**, **2x faster time-to-first-token**, **80% reduction in SLA breaches** (NVIDIA benchmarks on GB200 NVL72).

## Architecture

This module installs Dynamo as a **post-deploy extension** on an existing HyperPod/EKS cluster. Training and inference workloads run on separate node pools:

```
HyperPod EKS Cluster
│
├── Training Nodes (HyperPod-managed, p5/p4d/g5 — always on)
│   └── Training jobs, NCCL tests (existing stacks/eks-gpu workflow)
│
├── Inference Nodes (Karpenter-managed, G6e — scale to zero when idle)
│   ├── Prefill Workers (GPU, tensor-parallel)
│   └── Decode Workers (GPU, tensor-parallel)
│
└── Platform Services (CPU node, always on)
    ├── Dynamo Operator     — manages DynamoGraphDeploymentRequest CRDs
    ├── Dynamo Frontend     — OpenAI-compatible API server
    ├── Dynamo Smart Router — KV-cache-aware request routing
    ├── NATS + JetStream    — routing coordination for prefix caching
    ├── PostgreSQL          — API store / deployment metadata
    └── MinIO               — build artifact storage
```

## Prerequisites

| Requirement | Details |
|-------------|---------|
| HyperPod EKS cluster | Deployed via `stacks/eks-gpu/` |
| `kubectl` | Configured for the target cluster (`aws eks update-kubeconfig ...`) |
| `helm` | v3.12+ |
| `envsubst` | Usually pre-installed (part of `gettext`) |
| AWS CLI v2 | With ECR, EKS, and EC2 permissions |
| Karpenter | Installed on the cluster ([guide](https://karpenter.sh/docs/getting-started/)) |
| NGC API key | For pulling NVIDIA container images ([sign up](https://ngc.nvidia.com/)) |

## Quick Start

```bash
# 1. Set your NGC API key
export NGC_API_KEY="<your-ngc-api-key>"

# 2. Install the Dynamo platform
cd modules/inference/nvidia-dynamo
./install.sh --cluster-name my-hyperpod-eks --region us-west-2

# 3. Deploy a model (simplest — aggregated, single GPU)
kubectl apply -f examples/deepseek-r1-8b-aggregated.yaml

# 4. Wait for pods to be ready (Karpenter will provision a G6e node)
kubectl get pods -n dynamo-cloud -w

# 5. Run health checks and a sample inference request
./test.sh

# 6. Query the model directly
kubectl port-forward svc/deepseek-8b-agg-frontend 8000:8000 -n dynamo-cloud
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"deepseek-ai/DeepSeek-R1-Distill-Llama-8B",
       "messages":[{"role":"user","content":"Hello!"}],
       "max_tokens":100}'
```

## What install.sh Does

The install script performs these steps in order:

1. **Validates prerequisites** — checks kubectl connectivity, Helm version (>= 3.12), AWS CLI, cluster existence
2. **Creates namespace** `dynamo-cloud`
3. **Adds Helm repos** — NVIDIA NGC (`nvaie`), NATS, Bitnami
4. **Installs NATS** with JetStream — required for KV-aware routing coordination
5. **Installs PostgreSQL** — Dynamo API store backend (credentials auto-generated)
6. **Installs MinIO** — artifact storage (credentials auto-generated)
7. **Installs Dynamo Operator** — manages `DynamoGraphDeploymentRequest` CRDs
8. **Configures Karpenter NodePool** — discovers VPC/SG/IAM role from existing cluster, applies EC2NodeClass and NodePool for G6e inference nodes
9. **Verifies installation** — lists pods, CRDs, and NodePool status
10. **Generates `dynamo-env.sh`** — environment file for subsequent commands

## Example Deployments

| Example | File | GPUs Needed | Mode | Best For |
|---------|------|-------------|------|----------|
| DeepSeek-R1 8B (aggregated) | `examples/deepseek-r1-8b-aggregated.yaml` | 1x L40S | Single worker | Getting started, validation |
| DeepSeek-R1 8B (disaggregated) | `examples/deepseek-r1-8b-disagg.yaml` | 2x L40S | Prefill/decode split + KV routing | Production, lower latency |
| Llama-3 70B (multi-node) | `examples/llama3-70b-multinode.yaml` | 8x L40S (TP=4) | Multi-node disaggregated | Large models |

### Deploying a Model

```bash
# Simple aggregated (1 GPU)
kubectl apply -f examples/deepseek-r1-8b-aggregated.yaml

# Disaggregated with KV-aware routing (2 GPUs)
kubectl apply -f examples/deepseek-r1-8b-disagg.yaml

# Large model multi-node (requires HuggingFace token for gated Llama access)
kubectl create secret generic hf-token --from-literal=token=$HF_TOKEN -n dynamo-cloud
kubectl apply -f examples/llama3-70b-multinode.yaml
```

## GPU Instance Options

The default Karpenter NodePool provisions **G6e** instances (NVIDIA L40S). Override with `--gpu-instance-type`:

| Instance | GPUs | GPU Memory | EFA Interfaces | Use Case |
|----------|------|-----------|----------------|----------|
| **g6e.12xlarge** | 4x L40S | 192 GB | 1 | Small/medium models (default) |
| **g6e.24xlarge** | 4x L40S | 192 GB | 1 | Small/medium models (default) |
| **g6e.48xlarge** | 8x L40S | 384 GB | 4 | Large models, multi-node disagg (default) |
| g6.12xlarge | 4x L4 | 96 GB | 1 | Budget inference, small models |
| g6.48xlarge | 8x L4 | 192 GB | 4 | Budget inference, medium models |
| g5.48xlarge | 8x A10G | 192 GB | 1 | Legacy, EFA only on this size |

```bash
# G6 instances (NVIDIA L4, 24 GB/GPU — cheaper, smaller models)
./install.sh --gpu-instance-type "g6.12xlarge,g6.24xlarge,g6.48xlarge"

# Mix G6e and G6 for cost optimization
./install.sh --gpu-instance-type "g6e.12xlarge,g6e.48xlarge,g6.12xlarge"

# G5 instances (NVIDIA A10G, 24 GB/GPU — EFA only on g5.48xlarge)
./install.sh --gpu-instance-type "g5.48xlarge"
```

## Configuration

### install.sh Options

| Flag | Default | Description |
|------|---------|-------------|
| `--cluster-name` | Auto-detected from kubectl context | EKS cluster name |
| `--region` | `us-west-2` (or `$AWS_DEFAULT_REGION`) | AWS region |
| `--gpu-instance-type` | `g6e.12xlarge,g6e.24xlarge,g6e.48xlarge` | Comma-separated GPU instance types for Karpenter |
| `--max-gpus` | `16` | Hard limit on total GPUs across all inference nodes |
| `--namespace` | `dynamo-cloud` | Kubernetes namespace for all Dynamo components |
| `--operator-version` | `1.1.1` | Dynamo operator Helm chart version |
| `--karpenter-role` | Auto-discovered from existing EC2NodeClass | IAM role name for Karpenter-provisioned nodes |
| `--skip-karpenter` | `false` | Skip Karpenter NodePool creation (use if managing nodes manually) |
| `--dry-run` | `false` | Print what would be done without executing |

### Environment Variables

| Variable | Required | Purpose |
|----------|----------|---------|
| `NGC_API_KEY` | Yes (for operator) | NVIDIA NGC API key for pulling container images |
| `HF_TOKEN` | For gated models | HuggingFace token (Llama, Mistral, etc.) |
| `AWS_DEFAULT_REGION` | No | Fallback region if `--region` not specified |

## How It Works

### Disaggregated Serving

LLM inference has two phases: **prefill** (process input tokens, compute-heavy) and **decode** (generate output tokens, latency-sensitive). Traditional systems run both on the same GPU, causing contention. Dynamo separates them:

- **Prefill workers** — handle the compute-heavy input processing, can use lower tensor parallelism
- **Decode workers** — handle the latency-sensitive token generation, can use higher tensor parallelism
- Each pool scales independently based on workload characteristics

This is especially beneficial for RAG (long inputs, short outputs) and reasoning models (short inputs, long chain-of-thought outputs).

### KV-Aware Smart Routing

The Smart Router tracks KV cache entries across all GPUs in the cluster. When a new request arrives, it calculates an overlap score between the request and cached blocks on each worker, then routes to the worker with the most cache hits. Benefits:

- Multi-turn conversations reuse cache from previous turns
- System prompts are cached once and shared across requests
- Agentic workflows avoid recomputing context on each tool call
- Reduces TTFT by up to 2x (NVIDIA benchmarks)

### Auto-Scaling with Karpenter

Inference GPU nodes are ephemeral — Karpenter provisions them when pods are scheduled and removes them when idle:

- **Scale-up**: Dynamo deployment creates pods requesting `nvidia.com/gpu` -> Karpenter provisions G6e instances in ~60 seconds
- **Scale-down**: `consolidateAfter: 60s` means nodes terminate 60 seconds after the last inference pod exits
- **Cost control**: `--max-gpus 16` hard cap prevents runaway scaling
- **Zero cost when idle**: No inference traffic = no GPU nodes = no charges

### SLO Planner

The Dynamo Planner monitors real-time metrics (request rates, queue depths, TTFT, ITL) and automatically:

- Adjusts the prefill-to-decode worker ratio
- Scales workers up/down to meet SLA targets specified in the `DynamoGraphDeploymentRequest`
- Switches between aggregated and disaggregated modes based on workload patterns

## Monitoring

If the HyperPod observability stack is enabled (`EnableObservability: true`), Dynamo metrics are automatically scraped by Prometheus:

```bash
# Access Grafana (if kube-prometheus-stack is installed)
kubectl port-forward -n kube-prometheus-stack svc/kube-prometheus-stack-grafana 3000:80

# Access Prometheus directly
kubectl port-forward -n kube-prometheus-stack svc/prometheus 9090:80
```

Key metrics to watch:
- `dynamo_request_duration_seconds` — end-to-end inference latency
- `dynamo_tokens_per_second` — throughput per worker
- `dynamo_kv_cache_hit_ratio` — Smart Router cache efficiency
- `dynamo_gpu_utilization` — per-worker GPU usage
- `dynamo_queue_depth` — pending requests (scaling signal)

## Cleanup

```bash
# Remove everything (deployments, platform services, NodePool, namespace)
./cleanup.sh

# Keep the namespace for quick redeployment
./cleanup.sh --keep-namespace

# Keep the Karpenter NodePool (nodes still scale to zero, no cost)
./cleanup.sh --keep-nodepool
```

Note: ECR repositories and container images are NOT automatically deleted. To remove them:
```bash
aws ecr delete-repository --repository-name dynamo-base --force
```

## Troubleshooting

### Pods stuck in Pending

GPU nodes haven't been provisioned yet. Check Karpenter logs and NodePool status:
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -c controller --tail=50
kubectl get nodepools
kubectl get nodeclaims
```

Common causes:
- Instance type not available in the AZ (try a different `--gpu-instance-type`)
- Karpenter IAM role lacks EC2 `RunInstances` permission
- `--max-gpus` limit reached

### Image pull errors (ErrImagePull / ImagePullBackOff)

Ensure NGC API key is set and the pull secret exists:
```bash
export NGC_API_KEY="your-key"
./install.sh  # Re-run to update the pull secret

# Verify the secret exists
kubectl get secret ngc-secret -n dynamo-cloud
```

### Operator CRDs not registered

The operator pod may still be starting. Wait and check:
```bash
kubectl get pods -n dynamo-cloud -l app.kubernetes.io/name=dynamo-operator
kubectl logs -n dynamo-cloud -l app.kubernetes.io/name=dynamo-operator --tail=20
kubectl get crd | grep dynamo
```

### EFA not working for multi-node disaggregated serving

EFA requires instances in the **same AZ** with security group rules allowing EFA traffic:
```bash
# Verify nodes are in the same AZ
kubectl get nodes -l workload-type=inference -o wide

# Verify the security group has self-referencing EFA rules
# (The HyperPod security module configures this automatically)
aws ec2 describe-security-groups --group-ids <sg-id> \
  --query 'SecurityGroups[0].IpPermissions'
```

### Karpenter node role not found

If install.sh warns about the Karpenter node role, provide it explicitly:
```bash
# Find your existing Karpenter role
aws iam list-roles --query 'Roles[?contains(RoleName,`Karpenter`)].RoleName'

# Pass it to install.sh
./install.sh --karpenter-role "YourKarpenterNodeRole"
```

### Platform services not starting (NATS, PostgreSQL, MinIO)

Check for PVC provisioning issues (EBS CSI driver must be installed):
```bash
kubectl get pvc -n dynamo-cloud
kubectl get pods -n dynamo-cloud
kubectl describe pod <stuck-pod> -n dynamo-cloud
```

## File Structure

```
modules/inference/nvidia-dynamo/
├── install.sh                              # Main setup script
├── cleanup.sh                              # Teardown script
├── test.sh                                 # Health check + inference test
├── README.md                               # This file
├── helm-values/
│   ├── dynamo-operator.yaml                # Dynamo Operator config
│   ├── nats.yaml                           # NATS + JetStream config
│   ├── postgresql.yaml                     # PostgreSQL config (auto-gen creds)
│   └── minio.yaml                          # MinIO config (auto-gen creds)
├── karpenter/
│   ├── ec2nodeclass.yaml                   # AMI, security groups, volumes (template)
│   └── nodepool.yaml                       # Instance types, scaling, taints (template)
└── examples/
    ├── deepseek-r1-8b-aggregated.yaml      # Simple: 1 GPU, single worker
    ├── deepseek-r1-8b-disagg.yaml          # Recommended: 2 GPUs, disagg + KV routing
    └── llama3-70b-multinode.yaml           # Advanced: 8 GPUs, TP=4, multi-node
```

## References

- [NVIDIA Dynamo GitHub](https://github.com/ai-dynamo/dynamo)
- [NVIDIA Dynamo Documentation](https://docs.nvidia.com/dynamo/)
- [NVIDIA Dynamo Router Design](https://docs.nvidia.com/dynamo/design-docs/component-design/router-design)
- [AWS Blog: NVIDIA Dynamo on EKS](https://aws.amazon.com/blogs/machine-learning/accelerate-generative-ai-inference-with-nvidia-dynamo-and-amazon-eks/)
- [AI on EKS Blueprint](https://awslabs.github.io/ai-on-eks/docs/blueprints/inference/GPUs/nvidia-dynamo)
- [Karpenter Documentation](https://karpenter.sh/)
- [NVIDIA NGC Container Registry](https://ngc.nvidia.com/)
