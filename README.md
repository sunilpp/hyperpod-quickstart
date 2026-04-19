# HyperPod Quick Start

An opinionated reference architecture for multi-node GPU training on AWS. Encodes the configuration patterns — EFA transport selection, NCCL tuning, Slurm configless setup, storage auto-discovery — that most commonly trip teams up when scaling from single-node to distributed training. The one-click deploys are a convenience; the real content is in the design choices below.

## One-Click Deploy

| | **NVIDIA GPU** (p5, p4d, g5) | **AWS Trainium** (trn1, trn2) |
|:---:|:---:|:---:|
| **Slurm** | [![Launch Stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](https://us-west-2.console.aws.amazon.com/cloudformation/home?region=us-west-2#/stacks/create/review?templateURL=https%3A%2F%2Fs3.amazonaws.com%2Fhyperpodstackfiles%2Fhyperpod-quickstart%2Fslurm-gpu%2Ftemplate.yaml&stackName=my-hyperpod&param_LifecycleScriptSourceBucket=hyperpodstackfiles&param_LifecycleScriptSourcePrefix=hyperpod-quickstart/slurm-gpu/lifecycle-scripts) | [![Launch Stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](https://us-west-2.console.aws.amazon.com/cloudformation/home?region=us-west-2#/stacks/create/review?templateURL=https%3A%2F%2Fs3.amazonaws.com%2Fhyperpodstackfiles%2Fhyperpod-quickstart%2Fslurm-trainium%2Ftemplate.yaml&stackName=my-hyperpod-trn&param_LifecycleScriptSourceBucket=hyperpodstackfiles&param_LifecycleScriptSourcePrefix=hyperpod-quickstart/slurm-trainium/lifecycle-scripts) |
| **Amazon EKS** | [![Launch Stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](https://us-west-2.console.aws.amazon.com/cloudformation/home?region=us-west-2#/stacks/create/review?templateURL=https%3A%2F%2Fs3.amazonaws.com%2Fhyperpodstackfiles%2Fhyperpod-quickstart%2Feks-gpu%2Ftemplate.yaml&stackName=my-hyperpod-eks&param_LifecycleScriptSourceBucket=hyperpodstackfiles&param_LifecycleScriptSourcePrefix=hyperpod-quickstart/eks-gpu/lifecycle-scripts) | [![Launch Stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](https://us-west-2.console.aws.amazon.com/cloudformation/home?region=us-west-2#/stacks/create/review?templateURL=https%3A%2F%2Fs3.amazonaws.com%2Fhyperpodstackfiles%2Fhyperpod-quickstart%2Feks-trainium%2Ftemplate.yaml&stackName=my-hyperpod-eks-trn&param_LifecycleScriptSourceBucket=hyperpodstackfiles&param_LifecycleScriptSourcePrefix=hyperpod-quickstart/eks-trainium/lifecycle-scripts) |

> Using a different S3 bucket or region? Run `./scripts/publish.sh YOUR_BUCKET us-west-2`

| Guide | |
|-------|---|
| [Slurm + GPU](docs/guide-slurm-gpu.md) | Deploy, connect, NCCL test, distributed training, troubleshooting |
| [Slurm + Trainium](docs/guide-slurm-trainium.md) | Neuron SDK auto-detection, NCCOM configuration |
| [EKS + GPU](docs/guide-eks-gpu.md) | Automated Helm chart, MPIJob testing, kubectl setup |
| [EKS + Trainium](docs/guide-eks-trainium.md) | Neuron device plugin on Kubernetes |

---

## Design Choices

### Why four variants

Most reference architectures pick one orchestrator. This one spans both because the choice between Slurm and EKS is a team-culture decision, not a technical one — and the underlying infra (VPC, security groups, EFA, FSx, IAM) is identical. The four variants share a common `modules/` layer; only the top-level stack templates and lifecycle scripts differ. This means a fix to networking or IAM propagates to all variants without duplication.

### Why auto-detect EFA transport in lifecycle scripts

The number-one source of silent multi-node performance regressions: a user sets `FI_EFA_USE_DEVICE_RDMA=1` on an instance that doesn't support RDMA, or forgets to set `NCCL_NET_PLUGIN=none` on a non-EFA instance. Both result in either a hard crash or falling back to a slow path without any warning.

The lifecycle scripts detect EFA capability at boot time (`fi_info -p efa | grep FI_EP_RDM`) and set the environment accordingly. The `run-nccl-test` and `run-nanogpt` commands do the same at runtime. A user doesn't need to know whether their instance has EFA — the right thing happens automatically.

### Why Lambda Custom Resource for Helm chart deployment

EKS-orchestrated HyperPod requires device plugins, health monitoring agents, and Kubeflow operators installed via Helm *before* the HyperPod cluster resource is created. CloudFormation doesn't support Helm natively. The alternatives:

- **Manual step between stack creation phases** — breaks the one-click promise and is error-prone
- **UserData shell-out** — fragile at scale, hard to roll back, no idempotency
- **Lambda with pre-built kubectl/helm layer** — fully automated, idempotent, rolls back cleanly

We use the same Lambda layer that the AWS reference architecture (`awsome-distributed-training`) uses, maintaining compatibility.

### Why lifecycle scripts for Slurm but container env for EKS

Same NCCL tuning knobs, different injection points. Slurm nodes are long-lived VMs where lifecycle scripts configure the environment once at boot. EKS pods are ephemeral — NCCL settings are injected via container environment variables in the MPIJob manifest. The actual values (`NCCL_BUFFSIZE=8388608`, `NCCL_P2P_NET_CHUNKSIZE=524288`, etc.) are identical.

### Why FSx auto-discovery instead of parameter passing

The AWS reference requires users to manually copy FSx DNS and mount names into `provisioning_parameters.json`. This is fragile — the values are CloudFormation outputs that change on every deployment. Instead, the lifecycle scripts query the FSx API by cluster name tag at boot time and mount automatically. Zero manual configuration.

### Why observability defaults to optional

Prometheus + Grafana require IAM Identity Center (AWS SSO), which many test accounts don't have configured. Making it optional avoids blocking first-time deployments on an SSO prerequisite while keeping it one parameter flip for production.

---

## EFA Transport and NCCL Configuration

This is the section that determines whether your multi-node training runs at 3 GB/s or 400 GB/s. The scripts encode these decisions automatically, but understanding them matters for debugging.

### Transport selection logic

```
Instance has EFA?
├── Yes: fi_info -p efa shows FI_EP_RDM?
│   ├── Yes (p4d, p5): EFA RDMA
│   │   FI_PROVIDER=efa
│   │   FI_EFA_USE_DEVICE_RDMA=1
│   │   NCCL backend: nccl
│   │
│   └── No (g5.48xlarge): EFA SENDRECV
│       FI_PROVIDER=efa
│       FI_EFA_USE_DEVICE_RDMA=0
│       NCCL backend: nccl
│
└── No (g5.16xlarge): TCP Sockets
    NCCL_NET_PLUGIN=none
    NCCL_SOCKET_IFNAME=ens6
    Training backend: gloo (PyTorch DDP)
```

### NCCL environment variables (set on all GPU nodes)

```bash
# Buffer and chunk sizes (per AWS performance guidance)
NCCL_BUFFSIZE=8388608              # 8MB — increases send queue depth for non-blocking comms
NCCL_P2P_NET_CHUNKSIZE=524288      # 512KB — improves Send/Recv/Gather/Scatter performance
NCCL_SOCKET_IFNAME=^docker,lo,veth # Exclude virtual interfaces from NCCL

# Deliberately NOT set (per AWS docs, these degrade performance):
# NCCL_ALGO=Ring,Tree              # Let NCCL auto-select
# NCCL_PROTO=Simple                # Let NCCL auto-select
# NCCL_TREE_THRESHOLD=0            # Let NCCL auto-select
```

### MPI configuration for NCCL tests

```bash
/opt/amazon/openmpi/bin/mpirun --allow-run-as-root \
    -np $TOTAL --hostfile $HOSTFILE --bind-to none \
    --mca pml ob1 --mca btl tcp,self \           # Use ob1 PML (not UCX — avoids parser issues)
    --mca btl_tcp_if_exclude lo,docker0 \         # Exclude loopback
    -x LD_LIBRARY_PATH=... \                      # CUDA, EFA, OpenMPI, OFI libs
    -x NCCL_DEBUG=INFO \                          # Verbose NCCL logging
    $EFA_ARGS $NCCL_NET_ARGS \                    # Auto-detected per instance type
    $BINARY -b 8 -e 16G -f 2 -g 1 -c 1 -n 100   # 8B to 16GB, 100 iterations
```

### Instance capabilities

| Instance | GPUs | EFA | RDMA | Network | NCCL Transport | Expected busbw |
|----------|------|-----|------|---------|---------------|----------------|
| `ml.g5.16xlarge` | 1x A10G | No | No | 25 Gbps | TCP Socket | ~3 GB/s |
| `ml.g5.48xlarge` | 8x A10G | Yes | No | 100 Gbps | EFA SENDRECV | ~12 GB/s |
| `ml.p4d.24xlarge` | 8x A100 | Yes | Yes | 400 Gbps | EFA RDMA | ~300 GB/s |
| `ml.p5.48xlarge` | 8x H100 | Yes | Yes | 3200 Gbps | EFA RDMA | ~400 GB/s |

---

## Measured Performance

### NCCL all-reduce: 2x ml.g5.16xlarge (TCP, no EFA)

```
#       size         count    type   redop     time   algbw   busbw  #wrong
   134217728      33554432   float     sum   44510.9    3.02    3.02       0
  4294967296    1073741824   float     sum  1427063     3.01    3.01       0
# Avg bus bandwidth: 1.18 GB/s
# Out of bounds values: 0 OK
```

Peak: **3.02 GB/s** — saturates the 25 Gbps network link. Zero errors across all message sizes from 8B to 4.3GB.

### nanoGPT distributed training: 2x ml.g5.16xlarge

```
Model: 0.80M parameters (4 layers, 4 heads, 128 embed)
Dataset: Shakespeare characters
Backend: Gloo (TCP)
iter 0:   loss 4.1700   # start
iter 100: loss 3.4629   # -17%
iter 200: loss 3.0461   # -27%
Iteration time: ~143ms
```

Loss decreases monotonically. Both nodes train in sync with gradient synchronization across the network. Checkpoints saved at iterations 50, 100, 150, 200.

### p5.48xlarge benchmarks

*Placeholder — run `run-nccl-test 2 8` on a p5 cluster and capture results here. Expected: ~400 GB/s busbw on 128MB+ messages, ~230 GB/s algbw on 2GB messages.*

---

## Known Failure Modes

Lessons from debugging — these are the failure modes that don't appear in the docs.

### EFA RDMA abort on non-RDMA instances

`FI_EFA_USE_DEVICE_RDMA=1` causes a hard `abort()` — not a fallback, not a warning — on instances without RDMA support (g5.16xlarge, g5.48xlarge). The process dies immediately during MPI_Init. **Mitigation:** auto-detect with `fi_info` before setting. The lifecycle scripts handle this, but if you're running MPI manually, check first.

### NCCL uses Libfabric/EFA even when you tell MPI to use TCP

NCCL has its own network stack independent of MPI. Setting `--mca btl tcp,self` only affects MPI's control channel, not NCCL's data path. NCCL loads `libnccl-net.so` (the OFI plugin) and tries EFA regardless. On non-EFA instances, this causes `Unresponsive receiver (reachable by EFA device but handshake failed)`. **Mitigation:** set `NCCL_NET_PLUGIN=none` to force NCCL to use TCP sockets. The `run-nccl-test` script does this automatically.

### Slurm configless mode requires --conf-server on workers

HyperPod's Slurm uses configless mode with DNS SRV records for controller discovery. But the DNS SRV records aren't always configured in the VPC. Without `--conf-server <controller-ip>` on the worker's `slurmd` service, workers loop forever with `resolve_ctls_from_dns_srv: res_nsearch error: Unknown host`. **Mitigation:** the lifecycle script injects `--conf-server` into `slurmd.service` via `envsubst` or `sed` fallback.

### HyperPod instance IDs don't match SSM instance IDs

`aws sagemaker list-cluster-nodes` returns IDs like `i-0ad12c4e86af71ce0`, but SSM requires the HyperPod-specific target format: `sagemaker-cluster:<cluster-id>_<group>-<instance-id>`. Using the raw instance ID with `aws ssm start-session --target` gives `TargetNotConnected`. **Mitigation:** `remote-nccl-test.sh` builds the correct target automatically.

### IMDSv2 on HyperPod nodes

HyperPod enforces IMDSv2 (token-based instance metadata). Lifecycle scripts that use `curl http://169.254.169.254/...` without first obtaining a token get empty responses. This silently breaks node type detection, causing controllers to be identified as workers. **Mitigation:** `get_metadata()` helper tries IMDSv2 with token first, falls back to IMDSv1.

### Stack deletion blocked by non-empty S3 bucket

CloudFormation can't delete an S3 bucket that contains objects, and versioning makes it worse (delete markers count as objects). A failed deployment leaves orphaned buckets that block re-creation. **Mitigation:** the Lambda Custom Resource empties the bucket (including all versions and delete markers) on stack delete.

---

## What This Deliberately Doesn't Solve

- **Cross-AZ training** — EFA traffic cannot cross Availability Zones. All workers deploy in a single AZ.
- **Multi-tenant isolation** — Single security group, single IAM role. Fine for single-team clusters; needs RBAC/namespaces for multi-tenant.
- **GPU health checking** — Beyond HyperPod's built-in node recovery. DCGM-based prolog checks are on the [roadmap](ROADMAP.md).
- **Custom AMI building** — Uses the HyperPod DLAMI. Tradeoff: slower iteration on system packages, but zero AMI maintenance burden.
- **Production multi-controller HA** — Single Slurm controller. The AWS reference supports multi-head with RDS-backed accounting; that's in the roadmap.
- **Sub-8-node and 64+-node scale** — The architecture decisions target the 2-32 node range. Larger clusters need topology-aware scheduling, placement groups, and more sophisticated health checking.

---

## What Gets Configured Automatically

| Component | Slurm | EKS |
|-----------|-------|-----|
| VPC + subnets + NAT + VPC endpoints | CloudFormation | CloudFormation |
| Security group (self-referencing for EFA) | CloudFormation | CloudFormation |
| FSx Lustre (auto-discovery + mount) | Lifecycle script | Lifecycle script |
| Node type detection (IMDSv2 + resource config) | Lifecycle script | N/A |
| Slurm configless mode (--conf-server) | Lifecycle script | N/A |
| MUNGE authentication | Lifecycle script | N/A |
| SSH key distribution (FSx-based or Slurm-based) | Lifecycle script | N/A (Kubernetes handles) |
| NCCL environment tuning | Lifecycle script | Container env vars |
| EFA RDMA auto-detection | Lifecycle script + run-nccl-test | MPIJob manifest |
| HyperPod Helm chart (device plugins, Kubeflow) | N/A | Lambda Custom Resource |
| NCCL test + nanoGPT training commands | Pre-installed on controller | MPIJob manifests |

---

## Architecture

```
CloudFormation Stack
├── NetworkingStack ─── VPC, subnets, NAT, VPC endpoints (ECR, STS, S3, CloudWatch)
├── SecurityStack ───── Security group with self-referencing EFA rules
├── StorageStack ────── FSx Lustre filesystem
├── S3Stack ─────────── Lifecycle scripts bucket + upload/cleanup Lambda
├── IAMStack ────────── Execution role (S3, ECR, EC2, FSx, SSM, EKS, CloudWatch)
├── EKSStack ────────── EKS cluster + addons (EKS stacks only)
├── HelmChartStack ──── HyperPod Helm dependencies via Lambda (EKS only)
├── HyperPodStack ───── SageMaker HyperPod cluster
├── ObservabilityStack ─ Prometheus + Grafana (optional)
└── ValidationStack ──── Post-deploy health checks (optional)
```

## Prerequisites

```bash
git clone https://github.com/sunilpp/hyperpod-quickstart.git && cd hyperpod-quickstart
aws s3 mb s3://YOUR_S3_BUCKET --region us-west-2
./scripts/check-quotas.sh ml.g5.16xlarge 2 us-west-2
```

Requirements: AWS account with [HyperPod access](https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod.html), service quota for your instance type, AWS CLI configured.

## Scripts Reference

| Script | Purpose |
|--------|---------|
| `deploy.sh <variant> <bucket> [region]` | Package + deploy one stack variant |
| `publish.sh <bucket> [region]` | Package + publish all 4 variants to S3 |
| `check-quotas.sh <instance> <count> [region]` | Verify 9 AWS service quotas |
| `stack-errors.sh <stack> [region]` | Drill into nested CloudFormation errors |
| `remote-nccl-test.sh <cluster> [region]` | SSM into Slurm controller (correct target format) |
| `run-nccl-test [nodes] [gpus]` | NCCL all-reduce benchmark (pre-installed on controller) |
| `run-nanogpt [nodes] [gpus]` | Multi-node nanoGPT training test (pre-installed) |
| `run-nccl-test-eks.sh <cluster> [nodes] [gpus] [region]` | EKS NCCL benchmark via MPIJob |

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `ResourceLimitExceeded` | `./scripts/check-quotas.sh` — request increases |
| `ImagePullBackOff` on EKS | ECR permissions in latest templates — redeploy |
| NCCL EFA abort on g5 | Auto-handled; for manual runs use `NCCL_NET_PLUGIN=none` |
| Orphaned IAM roles | Delete from previous failed stacks |
| S3 bucket blocks delete | Auto-handled by cleanup Lambda |

## Roadmap

See [ROADMAP.md](ROADMAP.md): GPU health checks (DCGM prolog), multi-user management, Slurm accounting, Enroot/Pyxis containers, multi-controller HA, topology-aware NCCL testing.

---

Built by [Sunil Padmanabhan](https://github.com/sunilpp). Patterns reflect work with customers scaling multi-node training across GPU and custom silicon, including NCCL performance optimization, EFA transport debugging, and HyperPod lifecycle automation. Architecture based on the [AWS Distributed Training Reference](https://github.com/awslabs/awsome-distributed-training).

License: Apache-2.0
