# HyperPod Quick Start — Improvement Roadmap

Based on AWS reference implementation (awsome-distributed-training) and official HyperPod documentation at awslabs.github.io/ai-on-sagemaker-hyperpod.

## Current State

Working:
- Slurm GPU cluster deploys end-to-end (controller detection, configless Slurm, MUNGE)
- EKS GPU cluster deploys with automated Helm chart installation
- FSx auto-discovery
- SSH key distribution (FSx-based or Slurm-based)
- NCCL test pre-installed on controller
- Deployment scripts (deploy.sh, check-quotas.sh, stack-errors.sh)
- 4 stack variants (slurm-gpu, slurm-trainium, eks-gpu, eks-trainium)

Not yet production-ready:
- No GPU health checks
- No observability agents on nodes
- No multi-user support
- No Slurm accounting
- No container runtime (Enroot/Pyxis)
- No log rotation
- Limited troubleshooting tooling

---

## Phase 1: Make It Reliable (Week 1-2)

Goal: A cluster that self-heals and tells you when something is wrong.

### 1.1 GPU Health Check System
**Effort:** 3 days | **Impact:** Critical

What: DCGM-based GPU diagnostics that run automatically before jobs.

- Slurm prolog script runs DCGM Level 2 check before each job
- Caches results for 1 hour to avoid redundant checks
- Sets Slurm node features: `HealthCheck:Passed` / `HealthCheck:Failed`
- Failed nodes auto-drained, users can constrain: `sbatch -C "HealthCheck:Passed"`
- Health check orchestrator for manual full-cluster scans

Source: `awsome-distributed-training/health_check/`

### 1.2 Node-Level Observability Agents
**Effort:** 3 days | **Impact:** High

What: Prometheus exporters on every node, feeding into AMP.

| Agent | Where | Metrics |
|-------|-------|---------|
| Node Exporter | All nodes | CPU, memory, disk, network, NUMA |
| DCGM Exporter | GPU workers | GPU util, memory, temp, ECC errors |
| EFA Exporter | EFA workers | RDMA throughput, packet drops |
| Slurm Exporter | Controller | Queue depth, job states, node states |
| OpenTelemetry | All nodes | Forwards all metrics to AMP via SigV4 |

Lifecycle script installs agents based on node type. Pre-built Grafana dashboards in `modules/observability/dashboards/`.

Source: `awsome-distributed-training/observability/`

### 1.3 Comprehensive Troubleshooting Toolkit
**Effort:** 1 day | **Impact:** Medium

What: Scripts from the AWS troubleshooting guide, pre-installed on controller.

- `cluster-diag` — one-command cluster health dump (sinfo, GPU status, EFA, disk, memory)
- `dump-cluster-info` — export all node details to CSV
- `find-instance-id` — map Slurm node name to EC2 instance ID
- Pre-built troubleshooting runbook in docs

Source: `awsome-distributed-training/tools/`, AWS troubleshooting guide

---

## Phase 2: Make It Secure (Week 3-4)

Goal: Multi-user access control and job isolation.

### 2.1 Multi-User Management
**Effort:** 2 days | **Impact:** High

What: Named user accounts with proper isolation.

- `shared_users.txt` — define users with UID and home directory
- Lifecycle script creates users on all nodes
- SSH keypairs per user on FSx (`/fsx/<username>/.ssh/`)
- Ubuntu user configured by default
- Home directories on FSx for persistence

Source: `awsome-distributed-training/add_users.sh`, `gen-keypair-ubuntu.sh`

### 2.2 Slurm Accounting with MariaDB
**Effort:** 2 days | **Impact:** High

What: Track GPU hours per user, set quotas, enable chargebacks.

- MariaDB on controller (or RDS for HA)
- `slurmdbd` daemon for accounting data
- `sacct` shows job history with resource usage
- Fair-share scheduling based on usage
- User associations with default accounts

Source: `awsome-distributed-training/setup_mariadb_accounting.sh`

### 2.3 PAM-Based SSH Access Control
**Effort:** 2 days | **Impact:** High

What: Users can only SSH to nodes where they have running jobs.

- `pam_slurm_adopt` — adopts SSH sessions into job cgroups
- Cgroup enforcement for memory/device limits
- Admin bypass list for operators
- Prevents resource squatting between jobs

Source: `awsome-distributed-training/utils/pam_adopt_cgroup_wheel.sh`

### 2.4 SSM Run As Configuration
**Effort:** 1 day | **Impact:** Medium

What: SSM sessions run as the user's OS account, not root.

- Maps IAM roles to OS users via SSM Run As
- Per-user audit trail in SSM session logs
- Prevents privilege escalation via SSM

Source: AWS HyperPod documentation (prerequisites section)

---

## Phase 3: Make It Production-Ready (Week 5-6)

Goal: Operational excellence for sustained production use.

### 3.1 Container Runtime (Enroot/Pyxis)
**Effort:** 1 day | **Impact:** High

What: Run training in containers via Slurm without Docker.

- Enroot — rootless container execution
- Pyxis — Slurm plugin for `--container-image` flag
- Pull from ECR, DockerHub, or local squashfs
- Example: `srun --container-image nvcr.io/nvidia/pytorch:24.07 python train.py`

Source: `awsome-distributed-training/utils/install_enroot_pyxis.sh`

### 3.2 Multi-Controller HA
**Effort:** 4 days | **Impact:** Critical for production

What: Eliminate controller as single point of failure.

- Primary/backup controller with automatic failover
- Shared state on FSx (spool, config, accounting DB)
- SNS notifications on failover events
- RDS-backed `slurmdbd` for persistent accounting
- Munge key synchronization across controllers

Source: `awsome-distributed-training/multi_headnode_setup/`

### 3.3 Slurm Log Rotation
**Effort:** 0.5 day | **Impact:** Medium

What: Prevent disk exhaustion from Slurm logs.

- Rotate at 50MB, keep 2 copies
- SIGUSR2 for graceful log switch
- Applies to slurmctld, slurmd, slurmdbd

Source: `awsome-distributed-training/utils/enable_slurm_log_rotation.sh`

### 3.4 S3 Bucket Mounting
**Effort:** 0.5 day | **Impact:** Medium

What: Direct S3 access from cluster nodes.

- Mount S3 bucket at `/mnt/<bucket-name>`
- Systemctl service for persistent mount
- Read datasets directly without copying to FSx
- Requires IAM permissions in execution role

Source: `awsome-distributed-training/utils/mount-s3.sh`

### 3.5 FSx OpenZFS Support
**Effort:** 1 day | **Impact:** Medium

What: NFS-based shared filesystem option for home directories.

- Mount at `/home` for user home directory persistence
- Better for small-file workloads than Lustre
- Snapshot and backup capabilities
- Complement FSx Lustre (training data) with OpenZFS (home dirs)

---

## Phase 4: EKS-Specific Enhancements (Week 7-8)

Goal: Feature parity for EKS orchestration.

### 4.1 Task Governance (Kueue)
**Effort:** 2 days | **Impact:** High

What: Resource quotas and fair scheduling for EKS workloads.

- Kueue for workload queueing
- Per-team GPU quotas
- Priority-based scheduling
- Preemption policies

### 4.2 HyperPod Training Operator
**Effort:** 2 days | **Impact:** High

What: Simplified distributed training job submission on EKS.

- Custom Kubernetes operator for training jobs
- Auto-configures distributed training environment
- Integrates with HyperPod node health monitoring

### 4.3 SageMaker Managed MLflow
**Effort:** 1 day | **Impact:** Medium

What: Experiment tracking and model registry.

- Track training runs, metrics, artifacts
- Model versioning and deployment
- Integration with SageMaker pipelines

### 4.4 S3 CSI Driver
**Effort:** 1 day | **Impact:** Medium

What: Mount S3 buckets as Kubernetes volumes.

- Mountpoint for Amazon S3 CSI driver
- PersistentVolumeClaim-based S3 access
- No need to copy data to cluster storage

---

## Phase 5: Advanced Optimization (Ongoing)

### 5.1 NCCL Inspector Integration
**Effort:** 1 day | **Impact:** Medium

What: Profiling NCCL operations during training.

- Slurm task prolog injects NCCL Inspector env vars
- Metrics exported via node exporter textfile collector
- Visualize communication patterns in Grafana

### 5.2 Topology-Aware NCCL Testing
**Effort:** 1 day | **Impact:** Medium

What: Detect bad nodes and network paths.

- Pairwise NCCL tests between all node pairs
- Topology-sorted hostfiles for optimal placement
- Automated outlier detection (>5% deviation flagged)
- CSV result export for analysis

### 5.3 Placement Groups
**Effort:** 0.5 day | **Impact:** High for large clusters

What: Cluster placement group for lowest network latency.

- EC2 cluster placement group in networking template
- Pass to HyperPod for instance co-location
- Critical for p5/p4d with EFA at scale

### 5.4 Terraform Support
**Effort:** 5 days | **Impact:** Medium

What: Terraform alternative to CloudFormation.

- Terraform modules mirroring CFN templates
- Better for teams using multi-cloud IaC
- State management via S3 backend

### 5.5 Cost Optimization
**Effort:** 2 days | **Impact:** High

What: Reduce costs without sacrificing capability.

- Flexible Training Plans for guaranteed capacity at lower cost
- Right-sizing recommendations per workload
- Auto-scaling worker groups
- Cost dashboards in Grafana
- Reserved capacity integration

---

## Priority Matrix

| Phase | Feature | Effort | Impact | Depends On |
|-------|---------|--------|--------|------------|
| 1 | GPU Health Checks | 3d | Critical | Working cluster |
| 1 | Observability Agents | 3d | High | Working cluster |
| 1 | Troubleshooting Toolkit | 1d | Medium | None |
| 2 | Multi-User Management | 2d | High | FSx mounted |
| 2 | Slurm Accounting | 2d | High | Multi-user |
| 2 | PAM SSH Control | 2d | High | Multi-user |
| 2 | SSM Run As | 1d | Medium | Multi-user |
| 3 | Enroot/Pyxis | 1d | High | None |
| 3 | Multi-Controller HA | 4d | Critical | Accounting + FSx |
| 3 | Log Rotation | 0.5d | Medium | None |
| 3 | S3 Mounting | 0.5d | Medium | IAM role update |
| 3 | OpenZFS | 1d | Medium | CFN template |
| 4 | Task Governance | 2d | High | EKS working |
| 4 | Training Operator | 2d | High | EKS working |
| 4 | MLflow | 1d | Medium | EKS working |
| 5 | NCCL Inspector | 1d | Medium | Observability |
| 5 | Topology NCCL | 1d | Medium | NCCL working |
| 5 | Placement Groups | 0.5d | High | None |
| 5 | Terraform | 5d | Medium | Stable CFN |
| 5 | Cost Optimization | 2d | High | Accounting |

**Total estimated effort: ~35 engineering days**

---

## Quick Wins (Can do today)

These take less than half a day each:

1. Log rotation script in lifecycle
2. MOTD with cluster info on login
3. Cluster info dump tool on controller
4. Placement group in networking template
5. S3 mount support in lifecycle script
