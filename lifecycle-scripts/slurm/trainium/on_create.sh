#!/bin/bash
set -euo pipefail

# =============================================================================
# HyperPod Lifecycle Script: Slurm + Trainium
# =============================================================================
# This script runs on every node during HyperPod cluster creation.
# Similar to the GPU variant but configures Neuron SDK instead of NVIDIA tools.
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

# -------------------------------------------------------------------------
# Detect node type
# -------------------------------------------------------------------------
RESOURCE_CONFIG="/opt/ml/config/resource_config.json"
if [[ ! -f "$RESOURCE_CONFIG" ]]; then
    log "ERROR: Resource config not found at $RESOURCE_CONFIG"
    exit 1
fi

INSTANCE_GROUP_NAME=$(jq -r '.InstanceGroupName' "$RESOURCE_CONFIG")
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
if [[ -f "$PROVISIONING_PARAMS" ]]; then
    FSX_DNS=$(jq -r '.fsx_dns_name // empty' "$PROVISIONING_PARAMS")
    FSX_MOUNT=$(jq -r '.fsx_mountname // empty' "$PROVISIONING_PARAMS")

    if [[ -n "$FSX_DNS" && -n "$FSX_MOUNT" ]]; then
        MOUNT_POINT="/fsx"
        mkdir -p "$MOUNT_POINT"

        if ! dpkg -l | grep -q lustre-client-modules; then
            log "Installing Lustre client..."
            apt-get update -qq
            apt-get install -y -qq lustre-client-modules-aws 2>/dev/null || \
            apt-get install -y -qq lustre-client-modules-$(uname -r) 2>/dev/null || \
            log "WARNING: Could not install Lustre client"
        fi

        if ! mountpoint -q "$MOUNT_POINT"; then
            log "Mounting FSx Lustre: $FSX_DNS@tcp:/$FSX_MOUNT -> $MOUNT_POINT"
            mount -t lustre -o relatime,flock "${FSX_DNS}@tcp:/${FSX_MOUNT}" "$MOUNT_POINT"
            echo "${FSX_DNS}@tcp:/${FSX_MOUNT} $MOUNT_POINT lustre defaults,relatime,flock,_netdev,x-systemd.automount,x-systemd.requires=network.target 0 0" >> /etc/fstab
            log "FSx Lustre mounted at $MOUNT_POINT"
        else
            log "FSx Lustre already mounted at $MOUNT_POINT"
        fi
    fi
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
if [[ "$NODE_TYPE" == "controller" ]]; then
    log "Starting Slurm controller daemon (slurmctld)..."
    systemctl enable slurmctld 2>/dev/null || true
    systemctl start slurmctld 2>/dev/null || log "WARNING: Could not start slurmctld"

    for i in $(seq 1 30); do
        if scontrol ping &>/dev/null; then
            log "Slurm controller is ready"
            break
        fi
        sleep 2
    done
else
    log "Starting Slurm compute daemon (slurmd)..."
    systemctl enable slurmd 2>/dev/null || true
    systemctl start slurmd 2>/dev/null || log "WARNING: Could not start slurmd"
fi

log "=========================================="
log "HyperPod Lifecycle Script Complete"
log "Node type: $NODE_TYPE"
log "=========================================="
