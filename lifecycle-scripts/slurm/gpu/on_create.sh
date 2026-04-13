#!/bin/bash
set -euo pipefail

# =============================================================================
# HyperPod Lifecycle Script: Slurm + GPU
# =============================================================================
# This script runs on every node during HyperPod cluster creation.
# It detects whether the node is a controller (head) or worker (compute),
# then sets up the appropriate services.
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

# -------------------------------------------------------------------------
# Detect node type from HyperPod resource config
# -------------------------------------------------------------------------
RESOURCE_CONFIG="/opt/ml/config/resource_config.json"
if [[ ! -f "$RESOURCE_CONFIG" ]]; then
    log "ERROR: Resource config not found at $RESOURCE_CONFIG"
    exit 1
fi

INSTANCE_GROUP_NAME=$(jq -r '.InstanceGroupName' "$RESOURCE_CONFIG")
log "Instance group: $INSTANCE_GROUP_NAME"

# Determine if this is the controller or a worker
if echo "$INSTANCE_GROUP_NAME" | grep -qi "controller"; then
    NODE_TYPE="controller"
else
    NODE_TYPE="worker"
fi
log "Node type: $NODE_TYPE"

# -------------------------------------------------------------------------
# Mount FSx Lustre shared filesystem
# -------------------------------------------------------------------------
log "--- Setting up FSx Lustre ---"
PROVISIONING_PARAMS="/opt/ml/config/provisioning_parameters.json"
if [[ -f "$PROVISIONING_PARAMS" ]]; then
    FSX_DNS=$(jq -r '.fsx_dns_name // empty' "$PROVISIONING_PARAMS")
    FSX_MOUNT=$(jq -r '.fsx_mountname // empty' "$PROVISIONING_PARAMS")

    if [[ -n "$FSX_DNS" && -n "$FSX_MOUNT" ]]; then
        MOUNT_POINT="/fsx"
        mkdir -p "$MOUNT_POINT"

        # Install Lustre client if not present
        if ! dpkg -l | grep -q lustre-client-modules; then
            log "Installing Lustre client..."
            apt-get update -qq
            apt-get install -y -qq lustre-client-modules-aws 2>/dev/null || \
            apt-get install -y -qq lustre-client-modules-$(uname -r) 2>/dev/null || \
            log "WARNING: Could not install Lustre client — may already be built into kernel"
        fi

        # Mount FSx Lustre
        if ! mountpoint -q "$MOUNT_POINT"; then
            log "Mounting FSx Lustre: $FSX_DNS@tcp:/$FSX_MOUNT -> $MOUNT_POINT"
            mount -t lustre -o relatime,flock "${FSX_DNS}@tcp:/${FSX_MOUNT}" "$MOUNT_POINT"
            echo "${FSX_DNS}@tcp:/${FSX_MOUNT} $MOUNT_POINT lustre defaults,relatime,flock,_netdev,x-systemd.automount,x-systemd.requires=network.target 0 0" >> /etc/fstab
            log "FSx Lustre mounted at $MOUNT_POINT"
        else
            log "FSx Lustre already mounted at $MOUNT_POINT"
        fi
    else
        log "WARNING: FSx DNS or mount name not found in provisioning parameters"
    fi
else
    log "WARNING: Provisioning parameters not found at $PROVISIONING_PARAMS"
fi

# -------------------------------------------------------------------------
# Verify GPU devices
# -------------------------------------------------------------------------
log "--- Verifying GPU devices ---"
if command -v nvidia-smi &>/dev/null; then
    GPU_COUNT=$(nvidia-smi --query-gpu=count --format=csv,noheader | head -1)
    log "Found $GPU_COUNT GPU(s)"
    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | while read -r line; do
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
    log "WARNING: fi_info not found — EFA may not be installed"
fi

# -------------------------------------------------------------------------
# Install container runtime tools (Enroot + Pyxis)
# -------------------------------------------------------------------------
log "--- Setting up container runtime ---"
if ! command -v enroot &>/dev/null; then
    log "Installing Enroot and Pyxis for container-based training..."
    # Enroot allows running containers without Docker in Slurm
    apt-get update -qq
    apt-get install -y -qq curl jq squashfuse
    ENROOT_VERSION="3.5.0"
    ARCH=$(dpkg --print-architecture)
    curl -fsSL -o /tmp/enroot.deb \
        "https://github.com/NVIDIA/enroot/releases/download/v${ENROOT_VERSION}/enroot_${ENROOT_VERSION}-1_${ARCH}.deb" 2>/dev/null || \
        log "WARNING: Could not download Enroot — container support may be limited"
    if [[ -f /tmp/enroot.deb ]]; then
        dpkg -i /tmp/enroot.deb 2>/dev/null || apt-get install -f -y -qq
        rm -f /tmp/enroot.deb
        log "Enroot installed"
    fi
else
    log "Enroot already installed"
fi

# -------------------------------------------------------------------------
# Configure SSH between nodes
# -------------------------------------------------------------------------
log "--- Configuring SSH ---"
SSH_DIR="/root/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Generate SSH key if not present
if [[ ! -f "$SSH_DIR/id_rsa" ]]; then
    ssh-keygen -t rsa -b 4096 -f "$SSH_DIR/id_rsa" -N "" -q
    cat "$SSH_DIR/id_rsa.pub" >> "$SSH_DIR/authorized_keys"
    chmod 600 "$SSH_DIR/authorized_keys"
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
if [[ "$NODE_TYPE" == "controller" ]]; then
    log "Starting Slurm controller daemon (slurmctld)..."
    systemctl enable slurmctld 2>/dev/null || true
    systemctl start slurmctld 2>/dev/null || log "WARNING: Could not start slurmctld"

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
    systemctl enable slurmd 2>/dev/null || true
    systemctl start slurmd 2>/dev/null || log "WARNING: Could not start slurmd"
fi

# -------------------------------------------------------------------------
# Set NCCL environment variables for optimal GPU communication
# -------------------------------------------------------------------------
log "--- Configuring NCCL environment ---"
cat >> /etc/environment << 'NCCL_ENV'
NCCL_PROTO=simple
NCCL_ALGO=ring,tree
NCCL_DEBUG=WARN
FI_PROVIDER=efa
FI_EFA_USE_DEVICE_RDMA=1
NCCL_ENV

log "=========================================="
log "HyperPod Lifecycle Script Complete"
log "Node type: $NODE_TYPE"
log "=========================================="
