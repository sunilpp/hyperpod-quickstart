# Monitoring Your Cluster

When `EnableObservability` is set to `true` (the default), the stack deploys Amazon Managed Prometheus (AMP) and Amazon Managed Grafana (AMG) with pre-built dashboards and alert rules. This guide explains how to access and use them.

---

## Architecture Overview

```
HyperPod Nodes                          AWS Managed Services
+-------------------+                   +----------------------------+
| Node Exporter     |---metrics--->     | Amazon Managed Prometheus  |
| DCGM Exporter     |---metrics--->     |   (stores all metrics)     |
|  (GPU) or         |                   +-------------+--------------+
| Neuron Monitor    |                                 |
|  (Trainium)       |                   +-------------v--------------+
| EFA Exporter      |---metrics--->     | Amazon Managed Grafana     |
| Slurm Exporter    |---metrics--->     |   (visualization)          |
|  (Slurm only)     |                   +----------------------------+
+-------------------+
```

**How it works:** Exporters running on each cluster node collect metrics (CPU, memory, GPU utilization, network, etc.) and send them to Amazon Managed Prometheus. Grafana connects to Prometheus as a data source and visualizes the metrics in dashboards.

---

## Accessing Grafana

### Step 1: Find the Grafana URL

The Grafana URL is in the stack outputs:

**Console:** CloudFormation > your stack > Outputs tab > `GrafanaDashboardUrl`

**CLI:**

```bash
aws cloudformation describe-stacks \
  --stack-name my-hyperpod-cluster \
  --region us-west-2 \
  --query 'Stacks[0].Outputs[?OutputKey==`GrafanaDashboardUrl`].OutputValue' \
  --output text
```

### Step 2: Assign a User to Grafana

Before you can log in, you must assign an IAM Identity Center user to the Grafana workspace:

1. Open the [Amazon Managed Grafana console](https://console.aws.amazon.com/grafana/)
2. Select the workspace named `<ClusterName>-grafana`
3. Under the **Authentication** tab, choose **Configure users and user groups**
4. Choose **Assign new user or group**
5. Select your IAM Identity Center user
6. Set their role to **Admin** (so you can manage dashboards)
7. Choose **Assign users and groups**

### Step 3: Log In

1. Open the Grafana URL from Step 1
2. You will be redirected to the IAM Identity Center login page
3. Sign in with your IAM Identity Center credentials
4. You are now in Grafana

> **Tip:** Bookmark the Grafana URL. You will use it frequently to monitor training jobs.

---

## Setting Up the Prometheus Data Source

If the data source is not auto-configured when you first open Grafana:

1. In Grafana, go to **Configuration** > **Data Sources** > **Add data source**
2. Select **Prometheus**
3. Set the URL to the `PrometheusEndpoint` from your stack Outputs
4. Under **Authentication**, select **SigV4 auth** and choose the correct AWS region
5. Click **Save & Test**

The test should succeed with a green checkmark.

---

## Pre-Built Dashboards

The stack deploys five pre-built dashboards. Find them in Grafana under **Dashboards** in the left sidebar.

### Cluster Overview

**File:** `modules/observability/dashboards/cluster-overview.json`

Shows a high-level view of cluster health:
- Total nodes and their status (up/down)
- CPU utilization across all nodes
- Memory utilization across all nodes
- Disk usage on the root volume and `/fsx`
- Network traffic (bytes in/out)

**When to use:** Start here when you first open Grafana to get a quick sense of cluster health.

### GPU Utilization (GPU Stacks)

**File:** `modules/observability/dashboards/gpu-utilization.json`

Detailed GPU metrics from the DCGM Exporter:
- GPU utilization percentage (per GPU, per node)
- GPU memory used vs. available
- GPU temperature
- GPU power consumption
- GPU clock speed
- PCIe throughput

**When to use:** During training to ensure GPUs are fully utilized. Idle GPUs mean wasted money.

### NeuronCore Utilization (Trainium Stacks)

**File:** `modules/observability/dashboards/neuron-utilization.json`

Detailed Neuron metrics from the Neuron Monitor:
- NeuronCore utilization percentage
- Neuron memory usage
- Neuron compiler activity
- Device errors

**When to use:** Same as GPU utilization -- monitor during training to ensure NeuronCores are busy.

### EFA Performance

**File:** `modules/observability/dashboards/efa-performance.json`

Network metrics for EFA (Elastic Fabric Adapter):
- EFA bytes sent/received per node
- RDMA read/write operations
- EFA error counts
- Latency percentiles

**When to use:** If you suspect network issues are affecting training performance, or to verify that EFA is being used (not falling back to TCP).

### Training Jobs

**File:** `modules/observability/dashboards/training-jobs.json`

Job-level metrics:
- Active jobs and their resource consumption
- Job queue depth (Slurm stacks)
- GPU/NeuronCore allocation per job
- Job duration trends

**When to use:** To understand how your jobs are using cluster resources and identify scheduling bottlenecks.

---

## Pre-Configured Alert Rules

The stack creates Prometheus alert rules that fire when something needs attention. You can view active alerts in Grafana under **Alerting** > **Alert rules**.

### GPU Cluster Alerts

| Alert | Condition | Severity | What to Do |
|-------|-----------|----------|------------|
| **GPUUnderutilized** | Average GPU utilization < 10% for 30 min | Warning | Check if training jobs are running. If not, consider deleting the cluster to save costs. |
| **GPUMemoryHigh** | GPU memory usage > 95% for 10 min | Warning | Reduce batch size or enable gradient checkpointing to lower memory usage. |
| **GPUTemperatureHigh** | GPU temperature > 85C for 5 min | Critical | Usually indicates a cooling issue. HyperPod should auto-replace the node. |
| **NodeDown** | Node unreachable for 5 min | Critical | HyperPod auto-recovery should replace the node. Check cluster node status. |
| **EFAErrors** | EFA RDMA errors detected | Warning | Check network configuration. See [Networking Troubleshooting](troubleshooting/networking-issues.md). |
| **DiskUsageHigh** | Disk usage > 90% for 10 min | Warning | Clean up old checkpoints, logs, or temporary files on `/fsx` or the root volume. |

### Trainium Cluster Alerts

Trainium stacks have similar alerts adapted for Neuron metrics (NeuronCore utilization instead of GPU utilization, Neuron memory instead of GPU memory, etc.).

---

## Useful Prometheus Queries

You can run these queries directly in Grafana using the **Explore** view (compass icon in the left sidebar). Select the Prometheus data source, then enter a query.

### GPU Metrics (PromQL)

```promql
# Average GPU utilization across all GPUs on all nodes
avg(DCGM_FI_DEV_GPU_UTIL)

# GPU utilization per node
avg by (instance) (DCGM_FI_DEV_GPU_UTIL)

# Total GPU memory used (in GB) across the cluster
sum(DCGM_FI_DEV_FB_USED) / 1024

# GPU memory utilization as a percentage
(DCGM_FI_DEV_FB_USED / (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE)) * 100

# GPU power consumption per GPU
DCGM_FI_DEV_POWER_USAGE

# GPU temperature
DCGM_FI_DEV_GPU_TEMP
```

### Node Metrics (PromQL)

```promql
# CPU utilization per node
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# Memory utilization per node
(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100

# Disk usage on /fsx
(1 - node_filesystem_avail_bytes{mountpoint="/fsx"} / node_filesystem_size_bytes{mountpoint="/fsx"}) * 100

# Network bytes received per second per node
rate(node_network_receive_bytes_total{device="eth0"}[5m])
```

### EFA Metrics (PromQL)

```promql
# EFA bytes transmitted per second
rate(efa_tx_bytes_total[5m])

# EFA bytes received per second
rate(efa_rx_bytes_total[5m])

# Total EFA throughput across all nodes
sum(rate(efa_tx_bytes_total[5m])) + sum(rate(efa_rx_bytes_total[5m]))

# EFA RDMA read errors (should be 0)
rate(efa_rdma_read_errors_total[5m])
```

### Slurm Metrics (PromQL, Slurm Stacks Only)

```promql
# Number of running jobs
slurm_jobs_running

# Number of pending jobs
slurm_jobs_pending

# Node states
slurm_nodes_state
```

### NeuronCore Metrics (PromQL, Trainium Stacks Only)

```promql
# Average NeuronCore utilization
avg(neuron_runtime_vcore_usage)

# Neuron memory usage
neuron_runtime_memory_used_bytes
```

---

## Setting Up Alert Notifications

By default, alerts are visible in Grafana but do not send notifications. To receive alerts via email, Slack, or other channels:

### Step 1: Open Alert Contact Points

In Grafana, go to **Alerting** > **Contact points** > **Add contact point**.

### Step 2: Configure a Channel

**For Slack:**
1. Choose **Slack** as the type
2. Enter your Slack webhook URL
3. Test the notification
4. Save

**For Email:**
1. Choose **Email** as the type
2. Enter the email addresses
3. Test the notification
4. Save

**For PagerDuty:**
1. Choose **PagerDuty** as the type
2. Enter your PagerDuty integration key
3. Test the notification
4. Save

### Step 3: Assign the Channel to Alerts

Go to **Alerting** > **Notification policies** and configure which alerts route to which contact point. For example, route `severity=critical` alerts to PagerDuty and `severity=warning` alerts to Slack.

---

## Adding Custom Dashboards

You can create your own dashboards in Grafana:

1. In Grafana, choose **Dashboards** > **New** > **New Dashboard**
2. Add panels using the Prometheus data source
3. Use the PromQL queries above as starting points
4. Save the dashboard

> **Warning:** Custom dashboards are stored in the Grafana workspace. If you delete the CloudFormation stack, the Grafana workspace and all custom dashboards are deleted. Export important dashboards as JSON before deleting the stack.

To export a dashboard: open the dashboard > click the gear icon (settings) > choose **JSON Model** > copy the JSON.

---

## Prometheus Data Retention and Costs

Amazon Managed Prometheus retains metrics for **150 days** by default. There is no configuration needed.

Pricing is based on:
- **Ingestion:** ~$0.03 per 10,000 metric samples ingested
- **Storage:** ~$0.03 per GB-month
- **Queries:** ~$0.01 per 10,000 query samples processed

For a typical small cluster (2 nodes), expect Prometheus costs of $50-100/month. For large clusters (32 nodes), expect $200-500/month.

See the [AMP pricing page](https://aws.amazon.com/prometheus/pricing/) for current rates.

---

## Next Steps

- [Run benchmarks](07-benchmarking.md) and monitor results in the EFA Performance dashboard
- Learn about [cost management](09-cost-management.md) -- monitoring dashboards help you spot idle resources
