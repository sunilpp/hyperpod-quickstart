# Troubleshooting: Networking Issues

This page covers network-related problems that can affect SageMaker HyperPod cluster deployment and operation. Networking issues are among the most common causes of cluster failures, so this guide is thorough.

---

## Network Architecture Reference

For context, here is how the Quick Start configures networking:

```
VPC: 10.0.0.0/16 + 10.1.0.0/16 (secondary CIDR)

Public Subnet (10.0.0.0/24):
  - Internet Gateway for inbound/outbound internet traffic
  - NAT Gateway (with Elastic IP) for private subnet internet access

Private Subnet (10.1.0.0/16):
  - All HyperPod instances (controller + workers)
  - FSx for Lustre filesystem
  - Default route: 0.0.0.0/0 -> NAT Gateway
  - S3 route: S3 prefix list -> S3 VPC Gateway Endpoint

Security Group:
  - Ingress: All traffic from self (same SG) -- EFA, NCCL, Slurm, Lustre
  - Egress: All traffic to 0.0.0.0/0 -- internet access via NAT, AWS APIs
```

---

## NAT Gateway Issues

The NAT gateway allows instances in the private subnet to reach the internet. If it is not working, lifecycle scripts fail, container images cannot be pulled, and AWS API calls from nodes fail.

### Symptom: Lifecycle Scripts Fail with Connection Timeouts

**Example log messages:**

```
E: Unable to fetch some archives, maybe run apt-get update or try with --fix-missing?
pip install: Connection timed out
curl: (28) Connection timed out after 30001 milliseconds
docker pull: net/http: request canceled while waiting for connection
```

**Diagnosing the problem:**

1. **Verify the NAT gateway exists and is active:**
   ```bash
   aws ec2 describe-nat-gateways --region us-west-2 \
     --filter "Name=state,Values=available" \
     --query 'NatGateways[*].{ID:NatGatewayId,SubnetId:SubnetId,State:State}' \
     --output table
   ```

2. **Verify the NAT gateway is in the public subnet (not the private subnet):**
   ```bash
   # Get the NAT gateway's subnet
   NAT_SUBNET=$(aws ec2 describe-nat-gateways --region us-west-2 \
     --query 'NatGateways[0].SubnetId' --output text)

   # Check if that subnet has a route to an Internet gateway
   aws ec2 describe-route-tables --region us-west-2 \
     --filters "Name=association.subnet-id,Values=$NAT_SUBNET" \
     --query 'RouteTables[0].Routes[?GatewayId!=null && starts_with(GatewayId, `igw-`)]' \
     --output table
   ```
   You should see a route with `DestinationCidrBlock: 0.0.0.0/0` pointing to an `igw-*` gateway.

3. **Verify the private subnet routes through the NAT gateway:**
   ```bash
   aws ec2 describe-route-tables --region us-west-2 \
     --filters "Name=association.subnet-id,Values=<private-subnet-id>" \
     --query 'RouteTables[0].Routes' --output table
   ```
   You should see: `Destination: 0.0.0.0/0 -> NatGatewayId: nat-xxxxx`

**Fix:**

The Quick Start templates create all of this correctly. If you see issues:
- The stack creation may have been interrupted before routing was complete -- delete and redeploy
- Someone may have manually modified the route tables -- restore the NAT gateway route

### Symptom: High NAT Gateway Data Transfer Costs

**Cause:** Large amounts of data flowing through the NAT gateway, typically from:
- Pulling container images from ECR
- Downloading packages during lifecycle scripts
- AWS API calls

**Fix:**

The stack already includes an **S3 VPC endpoint** to avoid NAT charges for S3 traffic. For additional savings, consider adding VPC endpoints for other frequently accessed services:

```bash
# ECR Docker endpoint (for container image pulls)
aws ec2 create-vpc-endpoint \
  --vpc-id <vpc-id> \
  --service-name com.amazonaws.us-west-2.ecr.dkr \
  --vpc-endpoint-type Interface \
  --subnet-ids <private-subnet-id> \
  --security-group-ids <security-group-id> \
  --region us-west-2

# ECR API endpoint
aws ec2 create-vpc-endpoint \
  --vpc-id <vpc-id> \
  --service-name com.amazonaws.us-west-2.ecr.api \
  --vpc-endpoint-type Interface \
  --subnet-ids <private-subnet-id> \
  --security-group-ids <security-group-id> \
  --region us-west-2
```

---

## DNS Resolution

### Symptom: "Could not resolve host" Errors

**Example log messages:**

```
curl: (6) Could not resolve host: pypi.org
Unable to resolve host: s3.amazonaws.com
mount.lustre: Name or service not known
```

**Diagnosing the problem:**

1. **Verify DNS support is enabled on the VPC:**
   ```bash
   aws ec2 describe-vpc-attribute \
     --vpc-id <vpc-id> \
     --attribute enableDnsSupport \
     --region us-west-2
   ```
   Should return `"Value": true`.

2. **Verify DNS hostnames are enabled:**
   ```bash
   aws ec2 describe-vpc-attribute \
     --vpc-id <vpc-id> \
     --attribute enableDnsHostnames \
     --region us-west-2
   ```
   Should return `"Value": true`.

3. **Test DNS from a node (if you can connect):**
   ```bash
   nslookup pypi.org
   nslookup s3.us-west-2.amazonaws.com
   cat /etc/resolv.conf
   ```

**Fix:**

The Quick Start templates enable both `EnableDnsSupport` and `EnableDnsHostnames` on the VPC. If DNS still fails:
- Check that `/etc/resolv.conf` on the node points to the VPC DNS resolver (the second IP in the VPC CIDR, typically `10.0.0.2`)
- Check if a custom DHCP option set has overridden the default DNS server
- Verify the NAT gateway is working (DNS for external hosts like `pypi.org` requires internet access)

---

## EFA Requirements

EFA (Elastic Fabric Adapter) is critical for distributed training performance. Without EFA, inter-node communication falls back to TCP, which is dramatically slower (often 10-100x).

### Symptom: Training Is Unexpectedly Slow

If your distributed training is running but much slower than expected, EFA may not be active.

**Diagnosing the problem:**

1. **Check if EFA is available on the node:**
   ```bash
   fi_info -p efa
   ```
   If this returns `No data available` or an error, EFA is not configured.

2. **Check NCCL logs for EFA usage (GPU stacks):**
   Look for these lines in your training output (with `NCCL_DEBUG=INFO`):
   ```
   NCCL INFO NET/OFI Using aws-ofi-nccl 1.x.x    # GOOD - EFA is active
   NCCL INFO NET/Socket                             # BAD - TCP fallback
   ```

3. **Verify the instance type supports EFA:**
   ```bash
   aws ec2 describe-instance-types \
     --instance-types p5.48xlarge \
     --query 'InstanceTypes[0].NetworkInfo.{EfaSupported:EfaSupported,MaxEfaInterfaces:EfaInfo.MaximumEfaInterfaces}' \
     --region us-west-2
   ```

   All default instance types in this Quick Start support EFA:

   | Instance Type | EFA Interfaces | EFA Bandwidth |
   |---------------|---------------|---------------|
   | `ml.p5.48xlarge` | 32 | 3,200 Gbps |
   | `ml.p4d.24xlarge` | 4 | 400 Gbps |
   | `ml.g5.48xlarge` | 1 | 100 Gbps |
   | `ml.trn1.32xlarge` | 8 | 800 Gbps |

### Symptom: "EFA device not found" or "No provider found"

**Cause:** The EFA driver is not installed or the security group does not allow EFA traffic.

**Fix:**

1. **Check EFA driver installation:**
   ```bash
   # On the worker node
   fi_info -p efa
   modinfo efa
   ```
   If the EFA kernel module is not loaded, it was not installed during the lifecycle script. Check `/var/log/hyperpod/on_create.log` for errors.

2. **Verify the security group has the self-referencing rule:**
   ```bash
   aws ec2 describe-security-groups \
     --group-ids <security-group-id> \
     --region us-west-2 \
     --query 'SecurityGroups[0].IpPermissions'
   ```

   You must see a rule like:
   ```json
   {
     "IpProtocol": "-1",
     "UserIdGroupPairs": [
       { "GroupId": "<security-group-id>" }
     ]
   }
   ```

   The protocol must be `-1` (all traffic), not just TCP/UDP. EFA uses custom protocols beyond standard TCP/UDP.

   If this rule is missing:
   ```bash
   aws ec2 authorize-security-group-ingress \
     --group-id <security-group-id> \
     --protocol -1 \
     --source-group <security-group-id> \
     --region us-west-2
   ```

3. **Verify EFA interfaces are allocated to the instances:**
   ```bash
   aws ec2 describe-network-interfaces \
     --filters "Name=interface-type,Values=efa" \
     --region us-west-2 \
     --query 'NetworkInterfaces[*].{ID:NetworkInterfaceId,Instance:Attachment.InstanceId,Status:Status}' \
     --output table
   ```

### Symptom: EFA Works but Performance Is Lower Than Expected

**Possible causes:**

- Not all EFA interfaces are being used. For `ml.p5.48xlarge`, ensure NCCL is configured to use all 32 EFA interfaces.
- Environment variables are not set correctly:
  ```bash
  export FI_PROVIDER=efa
  export FI_EFA_USE_DEVICE_RDMA=1
  export NCCL_PROTO=simple
  ```
- Network congestion from other workloads in the same AZ.

Run the [benchmarks](../07-benchmarking.md) to get a precise measurement and compare against expected baselines.

---

## S3 VPC Endpoint

The stack creates an S3 Gateway VPC endpoint so that traffic to S3 does not flow through the NAT gateway (saving data transfer costs and reducing latency).

### Symptom: S3 Access Is Slow or Times Out

**Diagnosing the problem:**

```bash
# Verify the S3 VPC endpoint exists
aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=<vpc-id>" "Name=service-name,Values=*s3*" \
  --region us-west-2 \
  --query 'VpcEndpoints[*].{ID:VpcEndpointId,Service:ServiceName,State:State}' \
  --output table
```

The endpoint should be in `available` state.

**If the endpoint is missing:**

```bash
aws ec2 create-vpc-endpoint \
  --vpc-id <vpc-id> \
  --service-name com.amazonaws.us-west-2.s3 \
  --vpc-endpoint-type Gateway \
  --route-table-ids <private-route-table-id> \
  --region us-west-2
```

**If the endpoint exists but S3 is still slow or unreachable:**

1. Verify the endpoint is associated with the correct route table:
   ```bash
   aws ec2 describe-vpc-endpoints \
     --vpc-endpoint-ids <endpoint-id> \
     --region us-west-2 \
     --query 'VpcEndpoints[0].RouteTableIds'
   ```

2. Check that the private subnet's route table has a route for the S3 prefix list:
   ```bash
   aws ec2 describe-route-tables \
     --route-table-ids <private-route-table-id> \
     --region us-west-2 \
     --query 'RouteTables[0].Routes[?VpcEndpointId!=null]' \
     --output table
   ```

3. Check that the IAM role has S3 permissions (the endpoint does not bypass IAM -- it only bypasses NAT).

---

## Security Group Rules

### Symptom: Nodes Cannot Communicate with Each Other

**Example errors:**

```
NCCL WARN Connect to 10.1.0.15:12345 failed: Connection refused
slurmctld: error: slurmd at 10.1.0.20 not responding
mount.lustre: 10.1.0.100@tcp:/mount Connection timed out
```

**Cause:** The security group is missing the self-referencing ingress rule that allows all traffic between cluster members.

**Required security group configuration:**

| Direction | Protocol | Port | Source/Destination | Purpose |
|-----------|----------|------|-------------------|---------|
| Ingress | All (`-1`) | All | Self (same security group) | EFA, NCCL, NCCOM, Slurm daemons, Lustre |
| Egress | All (`-1`) | All | `0.0.0.0/0` | Internet via NAT, AWS API calls |

**Verifying the rules:**

```bash
aws ec2 describe-security-groups \
  --group-ids <security-group-id> \
  --region us-west-2 \
  --output json
```

Check that `IpPermissions` contains an entry with:
- `"IpProtocol": "-1"` (all protocols)
- `"UserIdGroupPairs"` containing `{"GroupId": "<security-group-id>"}` (self-reference)

**Adding the missing rule:**

```bash
aws ec2 authorize-security-group-ingress \
  --group-id <security-group-id> \
  --protocol -1 \
  --source-group <security-group-id> \
  --region us-west-2
```

> **Warning:** Do not restrict the self-referencing rule to specific ports or protocols. EFA uses custom transport protocols that are not TCP or UDP. The rule must allow all traffic (`-1`).

### Symptom: Cannot Connect to Nodes via SSM Session Manager

**Cause:** The nodes cannot reach the SSM service endpoints.

**Diagnosing:**

SSM requires outbound HTTPS (port 443) to these endpoints:
- `ssm.<region>.amazonaws.com`
- `ssmmessages.<region>.amazonaws.com`
- `ec2messages.<region>.amazonaws.com`

The default egress rule (all traffic to 0.0.0.0/0) covers this. If you have restricted egress rules, add these endpoints.

**Fix (if egress is restricted):**

Create VPC endpoints for SSM so traffic does not need to go through the NAT gateway:

```bash
for SERVICE in ssm ssmmessages ec2messages; do
  aws ec2 create-vpc-endpoint \
    --vpc-id <vpc-id> \
    --service-name com.amazonaws.us-west-2.$SERVICE \
    --vpc-endpoint-type Interface \
    --subnet-ids <private-subnet-id> \
    --security-group-ids <security-group-id> \
    --private-dns-enabled \
    --region us-west-2
done
```

---

## VPC Configuration Issues

### Symptom: Stack Fails Creating the VPC or Subnets

**Common causes:**

1. **VPC limit reached:**
   ```bash
   # Check how many VPCs you have
   aws ec2 describe-vpcs --region us-west-2 --query 'Vpcs | length(@)'
   ```
   Default limit is 5 VPCs per region. Request an increase via Service Quotas if needed.

2. **CIDR conflict:** The Quick Start uses `10.0.0.0/16` and `10.1.0.0/16`. If you have VPC peering with an existing VPC that uses overlapping CIDRs, creation may fail.

3. **Secondary CIDR block limit:** AWS allows up to 5 CIDRs per VPC by default. The template adds a secondary CIDR for the private subnet.

### Symptom: Pods Cannot Reach External Services (EKS Stacks)

**Cause:** The VPC CNI plugin may have issues or pods may not have network connectivity.

**Diagnosing:**

```bash
# Check VPC CNI pods
kubectl get pods -n kube-system -l k8s-app=aws-node

# Check VPC CNI logs
kubectl logs -n kube-system -l k8s-app=aws-node --tail=50

# Check if pods have IPs
kubectl get pods -o wide
```

**Fix:**

- The /16 private subnet provides 65,534 IPs, which should be more than sufficient
- If you see `Insufficient IPs` errors, check the ENI limits for your instance type
- Restart the VPC CNI daemon set if it is in a bad state:
  ```bash
  kubectl rollout restart daemonset aws-node -n kube-system
  ```

---

## Network Diagnostic Commands

Use these commands from a cluster node to diagnose networking issues:

```bash
# === Connectivity Tests ===

# Test internet access (via NAT gateway)
curl -s --max-time 5 https://httpbin.org/ip && echo "Internet: OK" || echo "Internet: FAIL"

# Test S3 access (via VPC endpoint)
aws s3 ls --region us-west-2 >/dev/null 2>&1 && echo "S3: OK" || echo "S3: FAIL"

# Test DNS resolution
nslookup s3.us-west-2.amazonaws.com >/dev/null 2>&1 && echo "DNS: OK" || echo "DNS: FAIL"

# Test EFA availability
fi_info -p efa >/dev/null 2>&1 && echo "EFA: OK" || echo "EFA: NOT AVAILABLE"

# === Network Configuration ===

# Show network interfaces
ip addr show

# Show routing table
ip route show

# Show DNS configuration
cat /etc/resolv.conf

# === Inter-Node Tests ===

# Ping another node (replace with actual IP)
ping -c 3 <other-node-ip>

# Test for packet loss between nodes (100 rapid pings)
ping -c 100 -i 0.01 <other-node-ip> | tail -1

# Test TCP connectivity to a specific port
nc -zv <other-node-ip> 12345

# === EFA Tests ===

# List EFA devices
fi_info -p efa

# Quick EFA loopback test
fi_pingpong -p efa -e rdm
```

### Full Diagnostic Script

Save this as a script and run it on any cluster node for a comprehensive network check:

```bash
#!/bin/bash
echo "=== Network Diagnostic Report ==="
echo "Date: $(date)"
echo "Hostname: $(hostname)"
echo ""

echo "--- Internet Connectivity ---"
curl -s --max-time 5 https://httpbin.org/ip && echo " [OK]" || echo " [FAIL]"

echo ""
echo "--- DNS Resolution ---"
for host in s3.us-west-2.amazonaws.com pypi.org; do
  nslookup $host >/dev/null 2>&1 && echo "$host [OK]" || echo "$host [FAIL]"
done

echo ""
echo "--- S3 Access ---"
aws s3 ls --region us-west-2 >/dev/null 2>&1 && echo "S3 list [OK]" || echo "S3 list [FAIL]"

echo ""
echo "--- EFA Status ---"
fi_info -p efa 2>/dev/null | head -5 || echo "EFA not available"

echo ""
echo "--- Network Interfaces ---"
ip -brief addr show

echo ""
echo "--- Route Table ---"
ip route show

echo ""
echo "--- DNS Config ---"
cat /etc/resolv.conf

echo ""
echo "=== End of Report ==="
```

---

## Getting More Help

If network diagnostics do not resolve your issue:

1. **Check VPC Flow Logs** for blocked traffic:
   ```bash
   aws logs tail /aws/vpc/flowlogs/<cluster-name>-vpc \
     --region us-west-2 \
     --since 1h \
     --filter-pattern "REJECT"
   ```
   Look for `REJECT` entries to find blocked traffic and identify which security group or NACL is blocking it.

2. **Check the [Common Errors guide](common-errors.md)** for non-networking issues

3. **Contact AWS Support** if you suspect an infrastructure issue (EFA hardware failure, AZ networking problems)

4. **Open an issue** on the GitHub repository with:
   - The output of the diagnostic commands above
   - The stack variant and region
   - CloudFormation events showing the failure
   - Relevant CloudWatch log excerpts
