# Troubleshooting: Common Errors

This page covers the most common issues encountered when deploying and using SageMaker HyperPod clusters with this Quick Start. Each error includes symptoms, causes, and step-by-step fixes.

---

## Quota Issues

### Error: "You've reached the limit on the number of instances"

**Symptoms:**

- CloudFormation event shows `CREATE_FAILED` on the HyperPod cluster resource
- Status reason contains `ResourceLimitExceeded` or mentions instance limits

**Cause:** Your AWS account does not have enough service quota for the requested instance type in the selected region.

**Fix:**

1. Open the [Service Quotas console](https://console.aws.amazon.com/servicequotas/home)
2. In the left sidebar, select **AWS services**, then search for **Amazon SageMaker**
3. Find the quota for your instance type (search for the instance type name plus "HyperPod")
4. Check the **Applied quota value** -- it must be greater than or equal to the number of instances you are requesting
5. Choose **Request increase at account level**
6. Enter the needed quantity and submit

```bash
# Check your current SageMaker quotas via CLI
aws service-quotas list-service-quotas \
  --service-code sagemaker \
  --region us-west-2 \
  --query "Quotas[?contains(QuotaName, 'p5') || contains(QuotaName, 'trn1')].[QuotaName,Value]" \
  --output table
```

> **Tip:** Quota increase requests for GPU instances (especially p5) can take 1-5 business days. For Trainium instances, approval is usually faster. Submit your request before you need the capacity.

After your quota is increased, delete the failed stack and redeploy:

```bash
aws cloudformation delete-stack --stack-name my-hyperpod-cluster --region us-west-2
aws cloudformation wait stack-delete-complete --stack-name my-hyperpod-cluster --region us-west-2

# Redeploy
aws cloudformation create-stack \
  --stack-name my-hyperpod-cluster \
  --template-body file://stacks/slurm-gpu/template.yaml \
  --parameters file://stacks/slurm-gpu/params/small.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-west-2
```

---

## Availability Zone Capacity

### Error: "Insufficient capacity in the specified AZ"

**Symptoms:**

- Stack creation fails during HyperPod cluster creation
- Status reason mentions capacity, instance availability, or `InsufficientInstanceCapacity`

**Cause:** The Availability Zone you specified does not have enough instances of your chosen type available right now.

**Fix:**

1. Find which AZs support your instance type:
   ```bash
   aws ec2 describe-instance-type-offerings \
     --location-type availability-zone-id \
     --filters Name=instance-type,Values=p5.48xlarge \
     --region us-west-2 \
     --query 'InstanceTypeOfferings[*].Location' \
     --output text
   ```

2. Delete the failed stack:
   ```bash
   aws cloudformation delete-stack --stack-name my-hyperpod-cluster --region us-west-2
   aws cloudformation wait stack-delete-complete --stack-name my-hyperpod-cluster --region us-west-2
   ```

3. Redeploy with a different AZ:
   ```bash
   aws cloudformation create-stack \
     --stack-name my-hyperpod-cluster \
     --template-body file://stacks/slurm-gpu/template.yaml \
     --parameters \
       ParameterKey=ClusterName,ParameterValue=my-hyperpod \
       ParameterKey=ClusterSize,ParameterValue=small \
       ParameterKey=AvailabilityZoneId,ParameterValue=usw2-az1 \
     --capabilities CAPABILITY_NAMED_IAM \
     --region us-west-2
   ```

**Common AZ IDs with GPU and Trainium capacity:**

| Region | Suggested AZ IDs to Try |
|--------|------------------------|
| `us-west-2` | `usw2-az2`, `usw2-az1`, `usw2-az4` |
| `us-east-1` | `use1-az6`, `use1-az4`, `use1-az2` |
| `us-east-2` | `use2-az2`, `use2-az1` |

> **Tip:** Capacity issues are more common with large cluster sizes and during peak hours. Try deploying during off-peak times (evenings and weekends US time) or reduce the cluster size.

---

## Lifecycle Script Failures

### Error: Cluster Nodes Show "Unhealthy" or Cluster Fails to Reach "InService"

**Symptoms:**

- CloudFormation creation times out or validation fails
- Cluster status is `Failed` or stays in `Creating` for over 30 minutes
- Validation reports nodes not in `Running` state

**Cause:** The lifecycle script (`on_create.sh`) that runs on each node during initialization encountered an error.

### Diagnosing the Issue

**Step 1: Check CloudWatch Logs**

```bash
# List log streams for your cluster
aws logs describe-log-streams \
  --log-group-name /aws/sagemaker/Clusters/<cluster-name> \
  --region us-west-2 \
  --query 'logStreams[*].logStreamName' \
  --output text

# Read the most recent logs
aws logs tail /aws/sagemaker/Clusters/<cluster-name> \
  --region us-west-2 \
  --since 2h
```

**Step 2: If you can connect to the node, check the local log**

```bash
aws ssm start-session --target <instance-id> --region us-west-2

# On the node
cat /var/log/hyperpod/on_create.log
```

### Common Lifecycle Script Failures

| Error in Log | Cause | Fix |
|-------------|-------|-----|
| `apt-get: unable to resolve host` | DNS resolution failed | Check NAT gateway and VPC DNS settings. See [Networking Issues](networking-issues.md). |
| `pip install: connection timed out` | No internet access from private subnet | Verify NAT gateway is in the public subnet and route table is correct. |
| `nvidia-smi: command not found` | NVIDIA driver installation failed | Check if the correct instance type is used; review full lifecycle log for errors. |
| `neuron-ls: command not found` | Neuron SDK installation failed | Verify you are using a Trainium instance type (trn1 or trn2). |
| `mount.lustre: No such device` | Lustre kernel module not loaded | Check if FSx filesystem is in `AVAILABLE` state; verify security group allows Lustre traffic. |
| `mount.lustre: Connection timed out` | Cannot reach FSx filesystem | Check security group self-referencing rule; verify FSx is in the same subnet. |
| `slurmd: error: Unable to register` | Worker cannot contact Slurm controller | Check that the controller node started first; verify inter-node networking. |

### Fixing Lifecycle Scripts

If you need to modify the lifecycle scripts after identifying the issue:

1. Edit the scripts in `lifecycle-scripts/` in your local clone
2. Re-upload to S3:
   ```bash
   aws s3 sync lifecycle-scripts/ s3://<lifecycle-bucket>/lifecycle-scripts/ --region us-west-2
   ```
3. Re-run on existing nodes using the SageMaker API:
   ```bash
   aws sagemaker update-cluster-software \
     --cluster-name <cluster-name> \
     --region us-west-2
   ```

---

## Node Joining Issues

### Error: Slurm Nodes in "down" State

**Symptoms:**

- `sinfo` shows nodes in `down` or `drain` state
- Jobs stay in `PENDING` state with reason `Nodes required for job are DOWN`

**Diagnosing:**

```bash
# On the head node, check which nodes are down
sinfo -N -l

# Check why a node is down
scontrol show node <node-name>
```

**Fix:**

1. **Check the Slurm controller:**
   ```bash
   systemctl status slurmctld
   journalctl -u slurmctld --since "1 hour ago"
   ```

2. **Check the worker node:**
   ```bash
   # Connect via SSM
   aws ssm start-session --target <worker-instance-id> --region us-west-2

   # On the worker
   systemctl status slurmd
   journalctl -u slurmd --since "1 hour ago"
   ```

3. **Resume drained nodes (if the underlying issue is resolved):**
   ```bash
   scontrol update NodeName=<node-name> State=RESUME
   ```

4. **If the node is persistently down**, HyperPod auto-recovery will replace it automatically (if `NodeRecovery=Automatic`). Check:
   ```bash
   aws sagemaker list-cluster-nodes \
     --cluster-name <cluster-name> \
     --region us-west-2 \
     --query 'ClusterNodeSummaries[*].{Name:InstanceGroupName,ID:InstanceId,Status:InstanceStatus.Status}' \
     --output table
   ```

### Error: EKS Nodes in "NotReady" State

**Symptoms:**

- `kubectl get nodes` shows one or more nodes as `NotReady`

**Fix:**

1. **Describe the node:**
   ```bash
   kubectl describe node <node-name>
   ```
   Look in the **Conditions** section for `Ready=False` and the associated message.

2. **Check kubelet logs:**
   ```bash
   aws ssm start-session --target <instance-id> --region us-west-2
   journalctl -u kubelet --since "1 hour ago"
   ```

3. **Common causes and fixes:**

   | Condition Message | Cause | Fix |
   |-------------------|-------|-----|
   | `NetworkPluginNotReady` | VPC CNI not running | Check `aws-node` pods: `kubectl get pods -n kube-system -l k8s-app=aws-node` |
   | `KubeletNotReady` | Kubelet cannot reach API server | Check NAT gateway and routing |
   | `DiskPressure` | Node ran out of disk space | Check `df -h` on the node; clean up or increase EBS volume |

---

## FSx Mount Failures

### Error: "/fsx Not Mounted" or "mount.lustre: Connection timed out"

**Symptoms:**

- Jobs fail because `/fsx` is not available
- `df -h /fsx` shows no filesystem
- Lifecycle script log shows Lustre mount errors

**Fix:**

1. **Verify the FSx filesystem is available:**
   ```bash
   aws fsx describe-file-systems --region us-west-2 \
     --query 'FileSystems[*].{ID:FileSystemId,Status:Lifecycle,DNS:DNSName}' \
     --output table
   ```
   Status should be `AVAILABLE`. If it is `CREATING`, wait for it to finish.

2. **Verify the node can reach the filesystem:**
   ```bash
   # On the node
   ping <fsx-dns-name>
   ```

3. **Check the security group:** The self-referencing security group rule covers Lustre traffic. If this rule is missing, add it. See [Networking Issues](networking-issues.md).

4. **Check the Lustre kernel module:**
   ```bash
   modprobe lustre
   lctl list_nids
   ```

5. **Try mounting manually:**
   ```bash
   sudo mount -t lustre <fsx-dns-name>@tcp:/<mount-name> /fsx
   ```

   The FSx DNS name and mount name are available in the CloudFormation stack outputs (`FSxDnsName` and `FSxMountName`).

---

## Stack Rollback Debugging

### Error: Stack Shows "ROLLBACK_IN_PROGRESS" or "ROLLBACK_COMPLETE"

**Symptoms:**

- The stack failed to create and is rolling back (deleting all created resources)
- After rollback, the stack is in `ROLLBACK_COMPLETE` state and cannot be updated

**Step 1: Find the Root Cause**

```bash
aws cloudformation describe-stack-events \
  --stack-name my-hyperpod-cluster \
  --region us-west-2 \
  --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`].[Timestamp,ResourceType,LogicalResourceId,ResourceStatusReason]' \
  --output table
```

Look at the **first** `CREATE_FAILED` event (the one with the earliest timestamp). This is the root cause -- subsequent failures cascade from it.

**Step 2: Check Nested Stack Failures**

If the failed resource is a nested stack (`AWS::CloudFormation::Stack`), drill into it:

```bash
# The PhysicalResourceId of a nested stack is its stack ID
aws cloudformation describe-stack-events \
  --stack-name <nested-stack-id> \
  --region us-west-2 \
  --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`].[ResourceType,LogicalResourceId,ResourceStatusReason]' \
  --output table
```

**Step 3: Match to Common Causes**

| First Failed Resource | Likely Cause | Fix |
|----------------------|-------------|-----|
| `NetworkingStack` | VPC or subnet creation issue | Check account VPC limit (default: 5 per region) |
| `StorageStack` | FSx creation failed | Check FSx quotas; verify AZ supports Lustre |
| `IAMStack` | IAM role creation issue | Ensure your user has `iam:*` permissions |
| `EKSStack` | EKS cluster creation failed | Check EKS service quota; verify Kubernetes version is supported |
| `HyperPodStack` | Instance capacity or lifecycle failure | See Lifecycle Script Failures and AZ Capacity sections |
| `ObservabilityStack` | Prometheus/Grafana creation failed | Check that IAM Identity Center is enabled |
| `ValidationStack` | Cluster health checks failed | See [Validating](../04-validating.md) for details |

**Step 4: Delete and Redeploy**

A stack in `ROLLBACK_COMPLETE` state cannot be updated. Delete it first:

```bash
aws cloudformation delete-stack --stack-name my-hyperpod-cluster --region us-west-2
aws cloudformation wait stack-delete-complete --stack-name my-hyperpod-cluster --region us-west-2
```

Fix the root cause, then create a new stack.

---

## IAM Permission Errors

### Error: "User is not authorized to perform: iam:CreateRole"

**Symptoms:**

- Stack fails during IAM role creation
- Status reason includes `AccessDenied` or `is not authorized to perform`

**Fix:**

The IAM user or role deploying the stack needs the permissions listed in the [Prerequisites guide](../01-prerequisites.md#4-iam-permissions). The quickest fix is to use the `AdministratorAccess` managed policy.

For least-privilege, ensure these IAM actions at minimum:
- `iam:CreateRole`, `iam:DeleteRole`
- `iam:AttachRolePolicy`, `iam:DetachRolePolicy`
- `iam:PutRolePolicy`, `iam:DeleteRolePolicy`
- `iam:PassRole`
- `iam:GetRole`

---

## CloudFormation Template URL Errors

### Error: "Template URL must reference a valid S3 object"

**Symptoms:**

- Stack fails immediately on the first nested stack
- Status reason references an invalid or unreachable template URL

**Cause:** The nested stack templates are not uploaded to S3, or the `TemplateBaseUrl` parameter is incorrect.

**Fix:**

1. Upload the module templates to S3:
   ```bash
   aws s3 sync modules/ s3://<your-bucket>/modules/ --region us-west-2
   ```

2. Set `TemplateBaseUrl` to the correct S3 URL:
   ```
   https://s3.amazonaws.com/<your-bucket>/modules
   ```

> **Tip:** Make sure the S3 URL does not end with a trailing slash. The template appends paths like `/networking/template.yaml` to the base URL.

---

## NCCL Timeout During Training

### Error: "NCCL WARN Timeout" or "Connection refused"

**Symptoms:**

- Training job hangs and eventually times out
- NCCL debug logs show connection failures between nodes

**Fix:**

1. **Verify EFA is working:**
   ```bash
   # On a worker node
   fi_info -p efa
   ```

2. **Verify the security group has self-referencing ingress:**
   ```bash
   aws ec2 describe-security-groups \
     --group-ids <security-group-id> \
     --region us-west-2 \
     --query 'SecurityGroups[0].IpPermissions[*].UserIdGroupPairs[*].GroupId' \
     --output text
   ```
   The security group ID should appear in its own ingress rules.

3. **Enable detailed NCCL logging:**
   ```bash
   export NCCL_DEBUG=INFO
   export NCCL_DEBUG_SUBSYS=ALL
   ```

4. **Verify all nodes can reach each other:**
   ```bash
   # On Slurm
   srun -N 2 hostname
   srun -N 2 ping -c 1 <other-node-ip>
   ```

See the [Networking Issues guide](networking-issues.md) for more network-specific troubleshooting.

---

## Getting More Help

If your issue is not covered here:

1. **Check the [Networking Issues guide](networking-issues.md)** for network-specific problems
2. **Check CloudWatch Logs** for detailed error messages:
   - `/aws/sagemaker/Clusters/<cluster-name>` -- HyperPod lifecycle logs
   - `/aws/lambda/<cluster-name>-*` -- Lambda function logs (validation, benchmarks)
   - `/aws/vpc/flowlogs/*` -- VPC network flow logs
3. **Check the [AWS SageMaker HyperPod documentation](https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod.html)**
4. **Open an issue** on the GitHub repository with:
   - The stack variant you used (for example, `slurm-gpu`)
   - The region and Availability Zone ID
   - The first `CREATE_FAILED` event from CloudFormation
   - Any relevant CloudWatch log excerpts
