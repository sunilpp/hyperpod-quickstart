# Architecture

## How the stacks are organized

Each of the four entry-point stacks (`stacks/*/template.yaml`) follows the same pattern. They are CloudFormation parent stacks that compose shared nested stacks from `modules/`:

```
stacks/slurm-gpu/template.yaml (Parent Stack)
│
├── modules/networking/template.yaml     ─── VPC, subnets, NAT, routes
├── modules/security/template.yaml       ─── Security group with EFA rules
├── modules/storage/fsx-lustre.yaml      ─── FSx for Lustre filesystem
├── modules/storage/s3-lifecycle.yaml    ─── S3 bucket for lifecycle scripts
├── modules/iam/template.yaml            ─── SageMaker execution role
├── modules/hyperpod/cluster.yaml        ─── SageMaker HyperPod cluster
├── modules/observability/*.yaml         ─── Prometheus + Grafana (optional)
├── modules/validation/template.yaml     ─── Post-deploy health checks (optional)
└── modules/benchmarking/template.yaml   ─── Performance benchmarks (optional)
```

EKS stacks additionally include:
```
├── modules/eks/cluster.yaml             ─── EKS control plane
└── modules/eks/addons.yaml              ─── Managed EKS add-ons
```

## Network architecture

```
┌─────────────────────────────────── VPC (10.0.0.0/16 + 10.1.0.0/16) ──────────────────────────────────┐
│                                                                                                        │
│   ┌────────────────────────────┐          ┌──────────────────────────────────────────────────────────┐ │
│   │    Public Subnet           │          │    Private Subnet (10.1.0.0/16)                         │ │
│   │    (10.0.0.0/24)           │          │                                                          │ │
│   │                            │          │   ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐  │ │
│   │   ┌──────────────┐        │          │   │ Worker 1 │ │ Worker 2 │ │ Worker 3 │ │   ...    │  │ │
│   │   │  NAT Gateway │◄───────┼──────────┤   │  (GPU /  │ │  (GPU /  │ │  (GPU /  │ │          │  │ │
│   │   └──────┬───────┘        │          │   │  Trn)    │ │  Trn)    │ │  Trn)    │ │          │  │ │
│   │          │                 │          │   └────┬─────┘ └────┬─────┘ └────┬─────┘ └──────────┘  │ │
│   │   ┌──────┴───────┐        │          │        │             │             │                      │ │
│   │   │   Internet   │        │          │        └─────────────┴─────────────┘                      │ │
│   │   │   Gateway    │        │          │              EFA Fabric (self-ref SG)                     │ │
│   │   └──────────────┘        │          │                                                          │ │
│   └────────────────────────────┘          │   ┌──────────────────┐    ┌─────────────────────┐       │ │
│                                            │   │  Controller /    │    │   FSx for Lustre    │       │ │
│   ┌────────────────────┐                  │   │  Head Node       │    │   /fsx mount        │       │ │
│   │   S3 VPC Endpoint  │◄─────────────────┤   └──────────────────┘    └─────────────────────┘       │ │
│   └────────────────────┘                  └──────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

**Key design decisions:**
- **/16 private subnet** — HyperPod clusters need many IPs for instances and ENIs (especially with EFA). A /16 gives 65,534 IPs.
- **Self-referencing security group** — Required for EFA. Allows all traffic between nodes in the same SG.
- **S3 VPC endpoint** — Avoids NAT gateway data transfer charges for S3 access (lifecycle scripts, checkpoints).
- **NAT gateway** — Required for package downloads, container image pulls, and AWS API calls from private subnet.

## Observability architecture

```
┌── HyperPod Nodes ──────────────────┐     ┌── AWS Managed Services ──────┐
│                                      │     │                               │
│  ┌────────────────┐                 │     │  ┌─────────────────────────┐ │
│  │ Node Exporter  │──metrics──┐     │     │  │  Amazon Managed         │ │
│  └────────────────┘           │     │     │  │  Prometheus (AMP)       │ │
│  ┌────────────────┐           ├─────┼────►│  │                         │ │
│  │ DCGM Exporter  │──metrics──┤     │     │  └───────────┬─────────────┘ │
│  │ (GPU) or       │           │     │     │              │               │
│  │ Neuron Monitor │           │     │     │  ┌───────────▼─────────────┐ │
│  │ (Trainium)     │           │     │     │  │  Amazon Managed         │ │
│  └────────────────┘           │     │     │  │  Grafana (AMG)          │ │
│  ┌────────────────┐           │     │     │  │                         │ │
│  │ EFA Exporter   │──metrics──┤     │     │  │  ┌───────────────────┐ │ │
│  └────────────────┘           │     │     │  │  │ Cluster Overview  │ │ │
│  ┌────────────────┐           │     │     │  │  │ GPU/Neuron Util.  │ │ │
│  │ Slurm Exporter │──metrics──┘     │     │  │  │ EFA Performance   │ │ │
│  │ (Slurm only)   │                 │     │  │  │ Training Jobs     │ │ │
│  └────────────────┘                 │     │  │  └───────────────────┘ │ │
└──────────────────────────────────────┘     │  └─────────────────────────┘ │
                                              └───────────────────────────────┘
```

## Validation flow

```
Stack Creation
    │
    ▼
Resources created (VPC, SG, FSx, HyperPod, ...)
    │
    ▼
┌─────────────────────────────────────────┐
│  Validation Lambda (Custom Resource)     │
│                                          │
│  1. DescribeCluster → InService?        │
│  2. ListClusterNodes → All Running?     │
│  3. DescribeSubnets → Private?          │
│  4. DescribeSecurityGroups → EFA rules? │
│                                          │
│  All pass → cfnresponse SUCCESS         │
│  Critical fail → cfnresponse FAILED     │
│     (triggers stack rollback)            │
└─────────────────────────────────────────┘
    │
    ▼
Stack Outputs (validation results)
```

## Differences between the four stacks

| Component | Slurm + GPU | Slurm + Trainium | EKS + GPU | EKS + Trainium |
|-----------|:-----------:|:----------------:|:---------:|:--------------:|
| VPC / Networking | Shared | Shared | Shared + EKS subnets | Shared + EKS subnets |
| Security Group | Shared | Shared | Shared | Shared |
| FSx Lustre | Yes | Yes | Yes | Yes |
| EKS Control Plane | No | No | Yes | Yes |
| EKS Add-ons | No | No | Yes | Yes |
| Slurm Controller | Yes (ml.m5.2xlarge) | Yes (ml.m5.2xlarge) | No | No |
| Worker Instances | p5.48xlarge | trn1.32xlarge | p5.48xlarge | trn1.32xlarge |
| Lifecycle: NVIDIA setup | Yes | No | Yes | No |
| Lifecycle: Neuron setup | No | Yes | No | Yes |
| DCGM Exporter | Yes | No | Yes | No |
| Neuron Monitor | No | Yes | No | Yes |
| Slurm Exporter | Yes | Yes | No | No |
| NCCL Benchmarks | Yes | No | Yes | No |
| NCCOM Benchmarks | No | Yes | No | Yes |
