#!/bin/bash

# =============================================================================
# HyperPod Lifecycle Script: Slurm + Trainium
# =============================================================================
# This script runs on every node during HyperPod cluster creation.
# Similar to the GPU variant but configures Neuron SDK instead of NVIDIA tools.
#
# NOTE: Do NOT use "set -e" here. HyperPod treats any non-zero exit as a
# fatal provisioning failure. Individual commands may fail non-critically,
# so we handle errors explicitly.
# =============================================================================

LOG_FILE="/var/log/hyperpod/on_create.log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log "=========================================="
log "HyperPod Lifecycle Script Starting"
log "Orchestrator: Slurm | Compute: Trainium"
log "=========================================="

# Give systemd-resolved (DNS) time to stabilize after HyperPod agent reboot
log "Waiting 30s for DNS to stabilize..."
sleep 30

# -------------------------------------------------------------------------
# Detect node type
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
    local token
    token=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)
    if [[ -n "$token" ]]; then
        curl -s -H "X-aws-ec2-metadata-token: $token" \
            "http://169.254.169.254/latest/meta-data/$path" 2>/dev/null || true
    else
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
    if [[ "$CLUSTER_TYPE" == "Slurm" && -z "$PRIMARY_IP" ]]; then
        log "Detected as controller (PrimaryControllerIp is empty)"
        INSTANCE_GROUP_NAME="controller-group"
    else
        INSTANCE_GROUP_NAME="worker-group"
    fi
fi

log "Instance group: $INSTANCE_GROUP_NAME"

if echo "$INSTANCE_GROUP_NAME" | grep -qi "controller"; then
    NODE_TYPE="controller"
else
    NODE_TYPE="worker"
fi
log "Node type: $NODE_TYPE"

# -------------------------------------------------------------------------
# Mount FSx Lustre
# -------------------------------------------------------------------------
log "--- Setting up FSx Lustre ---"
PROVISIONING_PARAMS="/opt/ml/config/provisioning_parameters.json"
FSX_DNS=""
FSX_MOUNT=""

if [[ -f "$PROVISIONING_PARAMS" ]]; then
    FSX_DNS=$(jq -r '.fsx_dns_name // empty' "$PROVISIONING_PARAMS" 2>/dev/null || true)
    FSX_MOUNT=$(jq -r '.fsx_mountname // empty' "$PROVISIONING_PARAMS" 2>/dev/null || true)
fi

if [[ -n "$FSX_DNS" && -n "$FSX_MOUNT" && "$FSX_DNS" != *"PLACEHOLDER"* ]]; then
    MOUNT_POINT="/fsx"
    mkdir -p "$MOUNT_POINT"

    if ! lsmod | grep -q lustre 2>/dev/null; then
        log "Installing Lustre client..."
        apt-get update -qq 2>/dev/null || true
        apt-get install -y -qq lustre-client-modules-aws 2>/dev/null || \
        apt-get install -y -qq "lustre-client-modules-$(uname -r)" 2>/dev/null || \
        log "WARNING: Could not install Lustre client — may already be built into kernel"
    fi

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
# Verify Neuron devices
# -------------------------------------------------------------------------
log "--- Verifying Neuron devices ---"
if command -v neuron-ls &>/dev/null; then
    NEURON_DEVICE_COUNT=$(neuron-ls --json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
    log "Found $NEURON_DEVICE_COUNT Neuron device(s)"
    neuron-ls 2>/dev/null || log "WARNING: neuron-ls failed"
else
    log "WARNING: neuron-ls not found — Neuron SDK may not be installed"
fi

# -------------------------------------------------------------------------
# Verify EFA devices
# -------------------------------------------------------------------------
log "--- Verifying EFA devices ---"
if command -v fi_info &>/dev/null; then
    EFA_COUNT=$(fi_info -p efa 2>/dev/null | grep -c "provider: efa" || echo "0")
    log "Found $EFA_COUNT EFA interface(s)"
else
    log "WARNING: fi_info not found — EFA may not be installed"
fi

# -------------------------------------------------------------------------
# Configure Neuron environment
# -------------------------------------------------------------------------
log "--- Configuring Neuron environment ---"
cat >> /etc/environment << 'NEURON_ENV'
NEURON_RT_NUM_CORES=32
NEURON_RT_VISIBLE_CORES=0-31
NEURON_CC_FLAGS=--target=trn1
FI_PROVIDER=efa
FI_EFA_USE_DEVICE_RDMA=1
NEURON_ENV

# -------------------------------------------------------------------------
# Set up shared Neuron Python environment on FSx
# -------------------------------------------------------------------------
if [[ "$NODE_TYPE" == "worker" ]] && [[ -d "/fsx" ]]; then
    log "--- Setting up shared Neuron Python environment ---"
    VENV_PATH="/fsx/envs/neuron-env"

    if [[ ! -d "$VENV_PATH" ]]; then
        log "Creating shared Neuron virtual environment at $VENV_PATH"
        python3 -m venv "$VENV_PATH"
        source "$VENV_PATH/bin/activate"

        # Install Neuron SDK packages from the pre-installed versions
        pip install --upgrade pip
        pip install torch-neuronx neuronx-cc neuronx-distributed 2>/dev/null || \
            log "WARNING: Could not install Neuron packages — using pre-installed versions"

        deactivate
        log "Shared Neuron environment created at $VENV_PATH"
    else
        log "Shared Neuron environment already exists at $VENV_PATH"
    fi
fi

# -------------------------------------------------------------------------
# Configure SSH
# -------------------------------------------------------------------------
log "--- Configuring SSH ---"

SSH_DIR="/root/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [[ ! -f "$SSH_DIR/id_rsa" ]]; then
    ssh-keygen -t rsa -b 4096 -f "$SSH_DIR/id_rsa" -N "" -q
    cat "$SSH_DIR/id_rsa.pub" >> "$SSH_DIR/authorized_keys"
    chmod 600 "$SSH_DIR/authorized_keys"
fi

# Add user-provided SSH public key (stored in SSM by CloudFormation)
CLUSTER_NAME=$(jq -r '.ClusterConfig.ClusterName // .ClusterName // empty' "$RESOURCE_CONFIG" 2>/dev/null || true)
log "Cluster name for SSM lookup: ${CLUSTER_NAME:-not found}"
if [[ -n "$CLUSTER_NAME" ]]; then
    USER_SSH_KEY=$(aws ssm get-parameter \
        --name "/hyperpod/${CLUSTER_NAME}/ssh-public-key" \
        --query "Parameter.Value" --output text 2>/dev/null || echo "none")
else
    USER_SSH_KEY=$(jq -r '.ssh_public_key // "none"' "$PROVISIONING_PARAMS" 2>/dev/null || echo "none")
fi

if [[ -n "$USER_SSH_KEY" && "$USER_SSH_KEY" != "none" ]]; then
    log "Adding user-provided SSH public key to authorized_keys"
    echo "$USER_SSH_KEY" >> "$SSH_DIR/authorized_keys"

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

    if [[ -f /etc/systemd/system/slurmd.service ]]; then
        mv /etc/systemd/system/slurmd.service /etc/systemd/system/slurmd_DISABLED.service 2>/dev/null || true
        log "Disabled slurmd on controller node"
    fi

    for i in $(seq 1 30); do
        if scontrol ping &>/dev/null; then
            log "Slurm controller is ready"
            break
        fi
        sleep 2
    done
else
    log "Starting Slurm compute daemon (slurmd)..."

    if [[ -n "$CONTROLLER_IPS" ]]; then
        log "Configuring slurmd with --conf-server $CONTROLLER_IPS"
        SLURMD_SERVICE="/etc/systemd/system/slurmd.service"
        if [[ -f "$SLURMD_SERVICE" ]]; then
            if grep -q '\$SLURMD_OPTIONS' "$SLURMD_SERVICE"; then
                log "Injecting --conf-server via envsubst into slurmd.service"
                SLURMD_OPTIONS="--conf-server $CONTROLLER_IPS" envsubst < "$SLURMD_SERVICE" > /tmp/slurmd.service
                mv /tmp/slurmd.service "$SLURMD_SERVICE"
            else
                log "No \$SLURMD_OPTIONS placeholder found, modifying ExecStart directly"
                sed -i "s|ExecStart=.*slurmd.*|& --conf-server $CONTROLLER_IPS|" "$SLURMD_SERVICE"
            fi
            systemctl daemon-reload
        fi
    fi

    systemctl enable slurmd 2>/dev/null || true
    systemctl start slurmd 2>/dev/null || log "WARNING: Could not start slurmd"

    if [[ -f /etc/systemd/system/slurmctld.service ]]; then
        mv /etc/systemd/system/slurmctld.service /etc/systemd/system/slurmctld_DISABLED.service 2>/dev/null || true
        log "Disabled slurmctld on compute node"
    fi
fi

log "=========================================="
log "HyperPod Lifecycle Script Complete"
log "Node type: $NODE_TYPE"
log "=========================================="

exit 0
