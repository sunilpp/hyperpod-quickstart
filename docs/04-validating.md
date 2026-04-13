# Validating Your Cluster

After your stack finishes deploying, you should verify that everything is working correctly. This Quick Start includes automatic validation that runs as part of the deployment, plus manual checks you can perform yourself.

---

## Automatic Validation

If you left `EnableValidation` set to `true` (the default), a Lambda function runs automatically at the end of the deployment and checks the following:

| Check | What It Verifies | Severity |
|-------|------------------|----------|
| **Cluster Status** | The HyperPod cluster is in `InService` state | Critical -- stack fails if this check fails |
| **Node Count** | All expected worker nodes are in `Running` state | Critical -- stack fails if too few nodes are running |
| **Subnet Privacy** | The private subnet does not assign public IPs | Critical -- stack fails if subnet is public |
| **Security Group** | A self-referencing ingress rule exists (required for EFA) | Warning -- logged but does not fail the stack |

### Viewing Validation Results

**In the CloudFormation console:**

1. Open the [CloudFormation console](https://console.aws.amazon.com/cloudformation/)
2. Select your stack
3. Go to the **Outputs** tab
4. Look for the `ValidationResult` output -- it shows `PASS` or `FAIL`
5. Additional outputs (`ClusterStatus`, `NodeCount`, `SubnetCheck`, `SecurityGroupCheck`) provide details

**Via the AWS CLI:**

```bash
aws cloudformation describe-stacks \
  --stack-name my-hyperpod-cluster \
  --region us-west-2 \
  --query 'Stacks[0].Outputs[?OutputKey==`ValidationResult`].OutputValue' \
  --output text
```

### What Happens If Validation Fails

If a critical check fails, the validation Lambda returns a `FAILED` status to CloudFormation. This causes the entire stack to **roll back** -- all resources are deleted.

Before redeploying, check the validation Lambda logs to understand what went wrong:

```bash
# View validation Lambda logs
aws logs tail /aws/lambda/<cluster-name>-cluster-validation \
  --region us-west-2 \
  --since 1h
```

Common reasons for validation failure and their fixes:

| Failure | Cause | Fix |
|---------|-------|-----|
| Cluster not InService | Lifecycle script error | Check CloudWatch Logs at `/aws/sagemaker/Clusters/<cluster-name>` |
| Nodes not Running | Instance capacity issue | Try a different AZ or request a quota increase |
| Subnet is public | (Should not happen with this template) | File an issue on the repo |

---

## Manual Checks

Whether or not automatic validation passed, you can perform these additional manual checks to confirm your cluster is fully operational.

### Check 1: Cluster Status via AWS CLI

```bash
aws sagemaker describe-cluster \
  --cluster-name my-hyperpod \
  --region us-west-2 \
  --query '{Status: ClusterStatus, Name: ClusterName}' \
  --output table
```

Expected output:

```
--------------------------------------
|          DescribeCluster           |
+--------+--------------------------+
|  Name  |  my-hyperpod             |
|  Status|  InService               |
+--------+--------------------------+
```

### Check 2: All Nodes Running

```bash
aws sagemaker list-cluster-nodes \
  --cluster-name my-hyperpod \
  --region us-west-2 \
  --query 'ClusterNodeSummaries[*].{Name:InstanceGroupName,ID:InstanceId,Status:InstanceStatus.Status}' \
  --output table
```

Every node should show `Running`. If a node shows `Pending` or `ShuttingDown`, wait a few minutes and check again.

### Check 3: Slurm Cluster Health (Slurm Stacks)

Connect to the head node via SSM and run these checks:

```bash
# Connect to the head node
aws ssm start-session --target <controller-instance-id> --region us-west-2
```

Once on the head node:

```bash
# 1. Check that Slurm sees all nodes
sinfo
```

Expected output (for a small, 2-node GPU cluster):

```
PARTITION AVAIL  TIMELIMIT  NODES  STATE NODELIST
gpu*         up   infinite      2   idle worker-group-[1-2]
```

All nodes should show `idle` state. If a node shows `down` or `drain`, see the troubleshooting section below.

```bash
# 2. Check the Slurm controller service
systemctl status slurmctld

# 3. Check the shared filesystem
df -h /fsx
ls /fsx
```

### Check 4: EKS Cluster Health (EKS Stacks)

```bash
# 1. Configure kubectl
aws eks update-kubeconfig --name <cluster-name> --region us-west-2

# 2. Check that all nodes are Ready
kubectl get nodes
```

Expected output:

```
NAME                          STATUS   ROLES    AGE   VERSION
ip-10-1-0-10.ec2.internal    Ready    <none>   10m   v1.31.0
ip-10-1-0-11.ec2.internal    Ready    <none>   10m   v1.31.0
```

All nodes should show `Ready`. If a node shows `NotReady`, wait a few minutes -- it may still be initializing.

```bash
# 3. Check system pods
kubectl get pods -A
```

All pods should be `Running` or `Completed`. Pay special attention to:
- `kube-system` namespace: CoreDNS, kube-proxy, VPC CNI should all be running
- Any pods in `CrashLoopBackOff` or `Error` state need investigation

```bash
# 4. Check GPU resources are detected (GPU stacks)
kubectl get nodes -o json | jq '.items[].status.capacity["nvidia.com/gpu"]'

# 5. Check Neuron resources are detected (Trainium stacks)
kubectl get nodes -o json | jq '.items[].status.capacity["aws.amazon.com/neuron"]'
```

### Check 5: GPU Health (GPU Stacks)

**On Slurm -- from the head node:**

```bash
# Run nvidia-smi on all worker nodes
srun --nodes=2 --ntasks-per-node=1 nvidia-smi
```

You should see output from each node listing 8 GPUs with no errors.

**On EKS:**

```bash
# Run nvidia-smi in a temporary pod
kubectl run gpu-test --image=nvidia/cuda:12.1.0-base-ubuntu22.04 \
  --restart=Never --rm -it \
  --limits='nvidia.com/gpu=1' \
  -- nvidia-smi
```

### Check 6: Trainium Health (Trainium Stacks)

**On Slurm -- from the head node:**

```bash
# Run neuron-ls on all worker nodes
srun --nodes=2 --ntasks-per-node=1 neuron-ls
```

You should see Neuron devices listed on each node.

**On EKS:**

```bash
# Check Neuron devices via a temporary pod
kubectl run neuron-test \
  --image=763104351884.dkr.ecr.us-west-2.amazonaws.com/pytorch-training-neuronx:2.1.2-neuronx-py310-sdk2.20.2-ubuntu20.04 \
  --restart=Never --rm -it \
  --limits='aws.amazon.com/neuron=1' \
  -- neuron-ls
```

### Check 7: Shared Filesystem

**On Slurm:**

```bash
# On the head node
df -h /fsx
# Verify all workers can see it
srun --nodes=2 --ntasks-per-node=1 df -h /fsx
```

**On EKS:**

Verify the FSx PersistentVolume is bound:

```bash
kubectl get pv
kubectl get pvc
```

### Check 8: Network Connectivity (EFA)

**On Slurm:**

```bash
# Check EFA devices on workers
srun --nodes=2 --ntasks-per-node=1 fi_info -p efa
```

You should see EFA provider information on each node. If `fi_info` reports no EFA devices, the security group may be misconfigured.

---

## Validation Summary Checklist

- [ ] Automatic validation shows `PASS` in stack outputs
- [ ] Cluster status is `InService`
- [ ] All worker nodes are `Running`
- [ ] Slurm: `sinfo` shows all nodes `idle` / EKS: `kubectl get nodes` shows all `Ready`
- [ ] Accelerators detected: `nvidia-smi` or `neuron-ls` shows expected devices
- [ ] Shared filesystem `/fsx` is mounted and accessible from all nodes
- [ ] EFA devices are detected on worker nodes

---

## Next Steps

Once your cluster passes all checks:

- [Run your first training job](05-running-first-job.md)
- [Set up monitoring dashboards](06-observability.md)
- [Run network benchmarks](07-benchmarking.md) to verify performance
