# Frequently Asked Questions

## General

### What is the difference between HyperPod and regular SageMaker Training?

SageMaker Training jobs are ephemeral — infrastructure is provisioned per job and torn down after. HyperPod provides persistent clusters that stay running, giving you:
- Faster job start times (no provisioning delay)
- Automatic node recovery (failed nodes are replaced without losing the job)
- Shared filesystem (FSx Lustre) for datasets and checkpoints
- Full SSH access to nodes for debugging

### Which AWS regions support HyperPod?

HyperPod is available in: us-east-1, us-east-2, us-west-2, eu-west-1, eu-central-1, ap-northeast-1, ap-southeast-1, ap-southeast-2. Check the [AWS documentation](https://docs.aws.amazon.com/general/latest/gr/sagemaker.html) for the latest list.

### How long does deployment take?

Typically 20–30 minutes. The longest step is HyperPod cluster creation, which involves provisioning instances and running lifecycle scripts.

## Choosing a Stack

### When should I use EKS vs Slurm?

**Choose EKS if:**
- Your team already uses Kubernetes
- You want to run ML training alongside other K8s workloads
- You prefer Kubernetes-native tools (kubectl, Helm, Kueue)

**Choose Slurm if:**
- Your team comes from an HPC background
- You prefer sbatch/srun job submission
- You want the simplest path to distributed training

### When should I use GPU vs Trainium?

**Choose GPU (NVIDIA) if:**
- You need maximum framework compatibility (PyTorch, JAX, TensorFlow, etc.)
- Your model uses CUDA-specific libraries
- You need the absolute highest single-node performance

**Choose Trainium if:**
- You're training PyTorch models and want to reduce cost
- You're doing large-scale training where cost efficiency matters most
- You're willing to use the Neuron SDK for compilation

### Can I switch between stacks later?

You can delete one stack and deploy another. Your data on S3 can be preserved, but the FSx filesystem is deleted with the stack. Copy important data to S3 before deleting.

## Cost

### How much does it cost to run?

See the cost table in the [README](README.md#cost-estimates). The dominant cost is the instances themselves. A "small" GPU cluster (2x p5.48xlarge) costs approximately $133/hour.

### Can I stop the cluster to save money?

HyperPod clusters cannot be paused — instances run continuously. To stop costs, delete the CloudFormation stack. Use [SageMaker Training Jobs](https://docs.aws.amazon.com/sagemaker/latest/dg/how-it-works-training.html) for ephemeral workloads.

### Are there any hidden costs?

Beyond instances, you pay for:
- NAT Gateway (~$0.045/hr + data transfer)
- FSx for Lustre (~$0.145/GB-month for 250 MB/s throughput)
- Amazon Managed Prometheus (~$0.03/10K metric samples)
- Amazon Managed Grafana (~$9/user/month)
- S3 storage (minimal — lifecycle scripts only)

## Troubleshooting

### My stack failed to create. What do I do?

1. Go to CloudFormation console → select your stack → Events tab
2. Find the first resource with status `CREATE_FAILED`
3. Read the "Status reason" — this usually tells you the exact issue
4. Common causes:
   - **Insufficient service quota** — request an increase for the instance type
   - **AZ capacity** — try a different AvailabilityZoneId
   - **Lifecycle script error** — check CloudWatch Logs at `/aws/sagemaker/Clusters/<cluster-name>`

### How do I connect to the cluster nodes?

**Slurm:** Use SSM Session Manager:
```bash
aws ssm start-session --target <instance-id>
```

**EKS:** Use kubectl:
```bash
aws eks update-kubeconfig --name <cluster-name>
kubectl get nodes
kubectl exec -it <pod-name> -- /bin/bash
```

### Where are the lifecycle script logs?

CloudWatch Logs group: `/aws/sagemaker/Clusters/<cluster-name>/LifecycleConfig`

On the node: `/var/log/hyperpod/on_create.log`

### My nodes show "Unhealthy" status. What do I do?

1. Check CloudWatch logs for lifecycle script errors
2. Connect to the node via SSM and check:
   - `nvidia-smi` (GPU) or `neuron-ls` (Trainium)
   - `systemctl status slurmctld` (Slurm controller)
   - `systemctl status slurmd` (Slurm workers)
3. If a node is persistently unhealthy, HyperPod will automatically replace it (if NodeRecovery=Automatic)

### Can I customize the lifecycle scripts?

Yes. The scripts are in `lifecycle-scripts/` and uploaded to S3 during stack creation. To customize:
1. Edit the scripts in `lifecycle-scripts/`
2. Update the stack (or re-upload to S3 manually)
3. For existing clusters, use `update-cluster-software` to re-run lifecycle scripts
