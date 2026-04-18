#!/bin/bash

# =============================================================================
# HyperPod Lifecycle Script: Slurm + GPU
# =============================================================================
# This script runs on every node during HyperPod cluster creation.
# It detects whether the node is a controller (head) or worker (compute),
# then sets up the appropriate services.
#
# NOTE: Do NOT use "set -e" here. HyperPod treats any non-zero exit as a
# fatal provisioning failure. Individual commands may fail non-critically
# (e.g., optional package installs), so we handle errors explicitly.
# =============================================================================

LOG_FILE="/var/log/hyperpod/on_create.log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log "=========================================="
log "HyperPod Lifecycle Script Starting"
log "Orchestrator: Slurm | Compute: GPU"
log "=========================================="

# Give systemd-resolved (DNS) time to stabilize after HyperPod agent reboot
log "Waiting 30s for DNS to stabilize..."
sleep 30

# -------------------------------------------------------------------------
# Detect node type from HyperPod resource config
# -------------------------------------------------------------------------
RESOURCE_CONFIG="/opt/ml/config/resource_config.json"
if [[ ! -f "$RESOURCE_CONFIG" ]]; then
    log "ERROR: Resource config not found at $RESOURCE_CONFIG"
    exit 1
fi

# Ensure jq is available
if ! command -v jq &>/dev/null; then
    log "jq not found, installing..."
    apt-get update -qq && apt-get install -y -qq jq || {
        log "ERROR: Failed to install jq"
        exit 1
    }
fi

# Helper: get instance metadata (supports both IMDSv1 and IMDSv2)
get_metadata() {
    local path="$1"
    # Try IMDSv2 first (requires token)
    local token
    token=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)
    if [[ -n "$token" ]]; then
        curl -s -H "X-aws-ec2-metadata-token: $token" \
            "http://169.254.169.254/latest/meta-data/$path" 2>/dev/null || true
    else
        # Fall back to IMDSv1
        curl -s "http://169.254.169.254/latest/meta-data/$path" 2>/dev/null || true
    fi
}

# Detect instance group name — try multiple config formats
INSTANCE_GROUP_NAME=$(jq -r '.InstanceGroupName // empty' "$RESOURCE_CONFIG" 2>/dev/null || true)

# If not at top level, find it by matching this instance's ID against InstanceGroups
if [[ -z "$INSTANCE_GROUP_NAME" ]]; then
    INSTANCE_ID=$(get_metadata "instance-id")
    log "Instance ID from metadata: ${INSTANCE_ID:-not available}"
    if [[ -n "$INSTANCE_ID" ]]; then
        INSTANCE_GROUP_NAME=$(jq -r --arg id "$INSTANCE_ID" '
            .InstanceGroups[]? |
            select(.Instances[]?.InstanceId == $id) |
            .Name // empty
        ' "$RESOURCE_CONFIG" 2>/dev/null || true)
    fi
fi

# Fallback: check instance type from metadata
if [[ -z "$INSTANCE_GROUP_NAME" ]]; then
    CURRENT_TYPE=$(get_metadata "instance-type")
    log "Could not detect instance group, instance type: ${CURRENT_TYPE:-not available}"
    if echo "$CURRENT_TYPE" | grep -qi "m5"; then
        INSTANCE_GROUP_NAME="controller-group"
    else
        INSTANCE_GROUP_NAME="worker-group"
    fi
fi

# Final fallback: check ClusterConfig for Slurm controller hint
if [[ -z "$INSTANCE_GROUP_NAME" ]]; then
    CLUSTER_TYPE=$(jq -r '.ClusterConfig.ClusterType // empty' "$RESOURCE_CONFIG" 2>/dev/null || true)
    PRIMARY_IP=$(jq -r '.ClusterConfig.SlurmConfig.PrimaryControllerIp // empty' "$RESOURCE_CONFIG" 2>/dev/null || true)
    # On the controller node, PrimaryControllerIp is empty
    if [[ "$CLUSTER_TYPE" == "Slurm" && -z "$PRIMARY_IP" ]]; then
        log "Detected as controller (PrimaryControllerIp is empty)"
        INSTANCE_GROUP_NAME="controller-group"
    else
        INSTANCE_GROUP_NAME="worker-group"
    fi
fi

log "Instance group: $INSTANCE_GROUP_NAME"

# Determine if this is the controller or a worker
if echo "$INSTANCE_GROUP_NAME" | grep -qi "controller"; then
    NODE_TYPE="controller"
else
    NODE_TYPE="worker"
fi
log "Node type: $NODE_TYPE"

# -------------------------------------------------------------------------
# Mount FSx Lustre shared filesystem (optional — skipped if not configured)
# -------------------------------------------------------------------------
log "--- Setting up FSx Lustre ---"
PROVISIONING_PARAMS="/opt/ml/config/provisioning_parameters.json"
FSX_DNS=""
FSX_MOUNT=""

if [[ -f "$PROVISIONING_PARAMS" ]]; then
    FSX_DNS=$(jq -r '.fsx_dns_name // empty' "$PROVISIONING_PARAMS" 2>/dev/null || true)
    FSX_MOUNT=$(jq -r '.fsx_mountname // empty' "$PROVISIONING_PARAMS" 2>/dev/null || true)
fi

# Skip FSx if values are empty or still have placeholders
if [[ -n "$FSX_DNS" && -n "$FSX_MOUNT" && "$FSX_DNS" != *"PLACEHOLDER"* ]]; then
    MOUNT_POINT="/fsx"
    mkdir -p "$MOUNT_POINT"

    # Install Lustre client if not present
    if ! lsmod | grep -q lustre 2>/dev/null; then
        log "Installing Lustre client..."
        apt-get update -qq 2>/dev/null || true
        apt-get install -y -qq lustre-client-modules-aws 2>/dev/null || \
        apt-get install -y -qq "lustre-client-modules-$(uname -r)" 2>/dev/null || \
        log "WARNING: Could not install Lustre client — may already be built into kernel"
    fi

    # Mount FSx Lustre
    if ! mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        log "Mounting FSx Lustre: ${FSX_DNS}@tcp:/${FSX_MOUNT} -> $MOUNT_POINT"
        if mount -t lustre -o relatime,flock "${FSX_DNS}@tcp:/${FSX_MOUNT}" "$MOUNT_POINT"; then
            echo "${FSX_DNS}@tcp:/${FSX_MOUNT} $MOUNT_POINT lustre defaults,relatime,flock,_netdev,x-systemd.automount,x-systemd.requires=network.target 0 0" >> /etc/fstab
            log "FSx Lustre mounted at $MOUNT_POINT"
        else
            log "WARNING: Failed to mount FSx Lustre — continuing without shared storage"
        fi
    else
        log "FSx Lustre already mounted at $MOUNT_POINT"
    fi
else
    log "FSx Lustre not configured — skipping mount"
fi

# -------------------------------------------------------------------------
# Verify GPU devices
# -------------------------------------------------------------------------
log "--- Verifying GPU devices ---"
if command -v nvidia-smi &>/dev/null; then
    GPU_COUNT=$(nvidia-smi --query-gpu=count --format=csv,noheader 2>/dev/null | head -1 || echo "0")
    log "Found $GPU_COUNT GPU(s)"
    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | while read -r line; do
        log "  GPU: $line"
    done
else
    log "WARNING: nvidia-smi not found — GPU drivers may not be installed"
fi

# -------------------------------------------------------------------------
# Verify EFA devices
# -------------------------------------------------------------------------
log "--- Verifying EFA devices ---"
if command -v fi_info &>/dev/null; then
    EFA_COUNT=$(fi_info -p efa 2>/dev/null | grep -c "provider: efa" || echo "0")
    log "Found $EFA_COUNT EFA interface(s)"
else
    log "INFO: fi_info not found — EFA may not be available on this instance type"
fi

# -------------------------------------------------------------------------
# Configure SSH between nodes
# -------------------------------------------------------------------------
log "--- Configuring SSH ---"

SSH_DIR="/root/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Generate inter-node SSH key if not present
if [[ ! -f "$SSH_DIR/id_rsa" ]]; then
    ssh-keygen -t rsa -b 4096 -f "$SSH_DIR/id_rsa" -N "" -q
    cat "$SSH_DIR/id_rsa.pub" >> "$SSH_DIR/authorized_keys"
    chmod 600 "$SSH_DIR/authorized_keys"
fi

# If user provided their SSH public key (stored in SSM by CloudFormation),
# add it to authorized_keys so they can SSH directly to cluster nodes
CLUSTER_NAME=$(jq -r '.ClusterConfig.ClusterName // .ClusterName // empty' "$RESOURCE_CONFIG" 2>/dev/null || true)
log "Cluster name for SSM lookup: ${CLUSTER_NAME:-not found}"
USER_SSH_KEY="none"

if [[ -n "$CLUSTER_NAME" ]]; then
    USER_SSH_KEY=$(aws ssm get-parameter \
        --name "/hyperpod/${CLUSTER_NAME}/ssh-public-key" \
        --query "Parameter.Value" --output text 2>/dev/null || echo "none")
fi

if [[ -z "$USER_SSH_KEY" || "$USER_SSH_KEY" == "none" ]]; then
    # Fallback: try provisioning_parameters.json
    if [[ -f "$PROVISIONING_PARAMS" ]]; then
        USER_SSH_KEY=$(jq -r '.ssh_public_key // "none"' "$PROVISIONING_PARAMS" 2>/dev/null || echo "none")
    fi
fi

if [[ -n "$USER_SSH_KEY" && "$USER_SSH_KEY" != "none" && "$USER_SSH_KEY" != "" ]]; then
    log "Adding user-provided SSH public key to authorized_keys"
    echo "$USER_SSH_KEY" >> "$SSH_DIR/authorized_keys"

    # Also add to ubuntu user if it exists (default HyperPod user)
    if id ubuntu &>/dev/null; then
        UBUNTU_SSH="/home/ubuntu/.ssh"
        mkdir -p "$UBUNTU_SSH"
        echo "$USER_SSH_KEY" >> "$UBUNTU_SSH/authorized_keys"
        chmod 700 "$UBUNTU_SSH"
        chmod 600 "$UBUNTU_SSH/authorized_keys"
        chown -R ubuntu:ubuntu "$UBUNTU_SSH"
        log "SSH key also added for ubuntu user"
    fi
else
    log "No user SSH key provided — use SSM Session Manager to access nodes"
fi

# Configure SSH to skip host key checking within cluster
cat > "$SSH_DIR/config" << 'SSHCONFIG'
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
SSHCONFIG
chmod 600 "$SSH_DIR/config"
log "SSH configured"

# -------------------------------------------------------------------------
# Start Slurm services
# -------------------------------------------------------------------------
log "--- Starting Slurm services ---"

# Ensure MUNGE is running (required for Slurm authentication)
log "Verifying MUNGE authentication daemon..."
if systemctl is-active munge &>/dev/null; then
    log "MUNGE is running"
else
    log "Starting MUNGE..."
    systemctl enable munge 2>/dev/null || true
    systemctl start munge 2>/dev/null || log "WARNING: Could not start MUNGE"
fi

# Get controller IPs from resource_config.json for configless Slurm
CONTROLLER_IPS=$(jq -r '
    .InstanceGroups[]? |
    select(.Name | test("controller"; "i")) |
    [.Instances[]?.CustomerIpAddress] | join(",")
' "$RESOURCE_CONFIG" 2>/dev/null || true)
log "Controller IPs: ${CONTROLLER_IPS:-not found}"

if [[ "$NODE_TYPE" == "controller" ]]; then
    # Wait for slurm.conf to be provisioned by HyperPod
    SLURM_CONF="/opt/slurm/etc/slurm.conf"
    log "Waiting for $SLURM_CONF to be provisioned by HyperPod..."
    for i in $(seq 1 120); do
        if [[ -f "$SLURM_CONF" ]]; then
            log "slurm.conf found after ${i}s"
            break
        fi
        sleep 1
    done

    if [[ ! -f "$SLURM_CONF" ]]; then
        log "WARNING: slurm.conf not found after 120s"
    fi

    log "Starting Slurm controller daemon (slurmctld)..."
    systemctl enable slurmctld 2>/dev/null || true
    systemctl start slurmctld 2>/dev/null || log "WARNING: Could not start slurmctld"

    # Prevent slurmd from running on controller
    if [[ -f /etc/systemd/system/slurmd.service ]]; then
        mv /etc/systemd/system/slurmd.service /etc/systemd/system/slurmd_DISABLED.service 2>/dev/null || true
        log "Disabled slurmd on controller node"
    fi

    # Wait for controller to be ready
    for i in $(seq 1 30); do
        if scontrol ping &>/dev/null; then
            log "Slurm controller is ready"
            break
        fi
        sleep 2
    done
else
    log "Starting Slurm compute daemon (slurmd)..."

    # Workers use --conf-server to fetch config from the controller (configless mode)
    if [[ -n "$CONTROLLER_IPS" ]]; then
        log "Configuring slurmd with --conf-server $CONTROLLER_IPS"
        SLURMD_SERVICE="/etc/systemd/system/slurmd.service"
        if [[ -f "$SLURMD_SERVICE" ]]; then
            if grep -q '\$SLURMD_OPTIONS' "$SLURMD_SERVICE"; then
                # Service file has $SLURMD_OPTIONS placeholder — use envsubst
                log "Injecting --conf-server via envsubst into slurmd.service"
                SLURMD_OPTIONS="--conf-server $CONTROLLER_IPS" envsubst < "$SLURMD_SERVICE" > /tmp/slurmd.service
                mv /tmp/slurmd.service "$SLURMD_SERVICE"
            else
                # No placeholder — inject --conf-server directly into ExecStart
                log "No \$SLURMD_OPTIONS placeholder found, modifying ExecStart directly"
                sed -i "s|ExecStart=.*slurmd.*|& --conf-server $CONTROLLER_IPS|" "$SLURMD_SERVICE"
            fi
            systemctl daemon-reload
        fi
    fi

    systemctl enable slurmd 2>/dev/null || true
    systemctl start slurmd 2>/dev/null || log "WARNING: Could not start slurmd"

    # Verify slurmd is running and connected
    sleep 5
    if systemctl is-active slurmd &>/dev/null; then
        log "slurmd is running"
        # Log the actual ExecStart line for debugging
        grep ExecStart /etc/systemd/system/slurmd.service 2>/dev/null | while read -r line; do
            log "  slurmd config: $line"
        done
    else
        log "ERROR: slurmd failed to start"
        journalctl -u slurmd --no-pager -n 10 2>/dev/null | while read -r line; do
            log "  slurmd log: $line"
        done
    fi

    # Prevent slurmctld from running on compute nodes
    if [[ -f /etc/systemd/system/slurmctld.service ]]; then
        mv /etc/systemd/system/slurmctld.service /etc/systemd/system/slurmctld_DISABLED.service 2>/dev/null || true
        log "Disabled slurmctld on compute node"
    fi
fi

# -------------------------------------------------------------------------
# Set NCCL environment variables for optimal GPU communication
# -------------------------------------------------------------------------
log "--- Configuring NCCL environment ---"
# Note: Do NOT set NCCL_ALGO, NCCL_PROTO, or NCCL_TREE_THRESHOLD —
# per AWS docs these degrade performance. Let NCCL auto-tune.
cat >> /etc/environment << 'NCCL_ENV'
NCCL_DEBUG=WARN
NCCL_BUFFSIZE=8388608
NCCL_P2P_NET_CHUNKSIZE=524288
NCCL_SOCKET_IFNAME=^docker,lo,veth
FI_PROVIDER=efa
FI_EFA_USE_DEVICE_RDMA=1
FI_EFA_FORK_SAFE=1
NCCL_ENV

# -------------------------------------------------------------------------
# Install NCCL test sbatch script on controller
# -------------------------------------------------------------------------
if [[ "$NODE_TYPE" == "controller" ]]; then
    log "--- Installing NCCL test scripts ---"

    # Find the pre-built NCCL test binary path
    NCCL_BINARY=""
    for p in /usr/local/cuda-13.0/efa/test-cuda-13.0/all_reduce_perf \
             /usr/local/cuda-12.9/efa/test-cuda-12.9/all_reduce_perf \
             /opt/nccl-tests/build/all_reduce_perf; do
        if [[ -x "$p" ]]; then
            NCCL_BINARY="$p"
            break
        fi
    done

    NCCL_LIB_DIR=$(echo "$NCCL_BINARY" | grep -o '/usr/local/cuda-[0-9.]*' || echo "/usr/local/cuda")

    cat > /opt/slurm/bin/run-nccl-test << NCCL_SCRIPT
#!/bin/bash
#SBATCH --job-name=nccl-test
#SBATCH --exclusive
#SBATCH --output=/tmp/nccl-test_%j.out
#SBATCH --error=/tmp/nccl-test_%j.err

NODES=\${1:-2}
GPUS=\${2:-\$(nvidia-smi -L 2>/dev/null | wc -l || echo 1)}
[[ "\$GPUS" -eq 0 ]] && GPUS=1
TOTAL=\$((NODES * GPUS))
BINARY="${NCCL_BINARY:-/opt/nccl-tests/build/all_reduce_perf}"
LIB="${NCCL_LIB_DIR}/lib"

echo "NCCL Test: \$NODES nodes, \$GPUS GPUs/node, \$TOTAL total"
echo "Binary: \$BINARY"

/opt/amazon/openmpi/bin/mpirun --allow-run-as-root \\
    -np \$TOTAL -N \$GPUS --bind-to none \\
    -x FI_PROVIDER=efa -x FI_EFA_FORK_SAFE=1 \\
    -x LD_LIBRARY_PATH=\$LIB:/opt/amazon/efa/lib:/opt/amazon/openmpi/lib:/opt/amazon/ofi-nccl/lib:/usr/local/lib:/usr/lib \\
    -x NCCL_DEBUG=INFO -x NCCL_BUFFSIZE=8388608 -x NCCL_P2P_NET_CHUNKSIZE=524288 \\
    -x NCCL_SOCKET_IFNAME=^docker,lo,veth \\
    --mca pml ^ucx --mca btl tcp,self --mca btl_tcp_if_exclude lo,docker0,veth_def_agent \\
    \$BINARY -b 8 -e 16G -f 2 -g 1 -c 1 -n 100
NCCL_SCRIPT
    chmod +x /opt/slurm/bin/run-nccl-test

    # Ensure /opt/slurm/bin is in PATH for all users
    if ! grep -q '/opt/slurm/bin' /etc/environment 2>/dev/null; then
        sed -i 's|^PATH="|PATH="/opt/slurm/bin:|' /etc/environment 2>/dev/null || \
        echo 'PATH="/opt/slurm/bin:$PATH"' >> /etc/environment
    fi

    if [[ -n "$NCCL_BINARY" ]]; then
        log "NCCL test ready: run-nccl-test [nodes] [gpus-per-node]"
        log "  Example: run-nccl-test 2 1"
        log "  Or: sbatch -N 2 run-nccl-test"
    else
        log "WARNING: NCCL test binary not found on this AMI"
    fi
fi

log "=========================================="
log "HyperPod Lifecycle Script Complete"
log "Node type: $NODE_TYPE"
log "=========================================="

exit 0
