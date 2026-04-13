#!/bin/bash
set -euo pipefail

# =============================================================================
# HyperPod Lifecycle Script: EKS
# =============================================================================
# Minimal lifecycle script for EKS-orchestrated HyperPod clusters.
# EKS handles most node configuration (device plugins, networking) via
# managed add-ons, so this script only handles FSx mounting and basic setup.
# =============================================================================

LOG_FILE="/var/log/hyperpod/on_create.log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log "=========================================="
log "HyperPod Lifecycle Script Starting"
log "Orchestrator: EKS"
log "=========================================="

# -------------------------------------------------------------------------
# Mount FSx Lustre (if configured)
# -------------------------------------------------------------------------
PROVISIONING_PARAMS="/opt/ml/config/provisioning_parameters.json"
if [[ -f "$PROVISIONING_PARAMS" ]]; then
    FSX_DNS=$(jq -r '.fsx_dns_name // empty' "$PROVISIONING_PARAMS" 2>/dev/null)
    FSX_MOUNT=$(jq -r '.fsx_mountname // empty' "$PROVISIONING_PARAMS" 2>/dev/null)

    if [[ -n "$FSX_DNS" && -n "$FSX_MOUNT" ]]; then
        log "--- Setting up FSx Lustre ---"
        MOUNT_POINT="/fsx"
        mkdir -p "$MOUNT_POINT"

        if ! dpkg -l | grep -q lustre-client-modules; then
            apt-get update -qq
            apt-get install -y -qq lustre-client-modules-aws 2>/dev/null || \
            apt-get install -y -qq lustre-client-modules-$(uname -r) 2>/dev/null || \
            log "WARNING: Could not install Lustre client"
        fi

        if ! mountpoint -q "$MOUNT_POINT"; then
            mount -t lustre -o relatime,flock "${FSX_DNS}@tcp:/${FSX_MOUNT}" "$MOUNT_POINT"
            echo "${FSX_DNS}@tcp:/${FSX_MOUNT} $MOUNT_POINT lustre defaults,relatime,flock,_netdev,x-systemd.automount,x-systemd.requires=network.target 0 0" >> /etc/fstab
            log "FSx Lustre mounted at $MOUNT_POINT"
        fi
    else
        log "No FSx configuration found — skipping mount"
    fi
else
    log "No provisioning parameters found — skipping FSx mount"
fi

# -------------------------------------------------------------------------
# Verify accelerator devices
# -------------------------------------------------------------------------
log "--- Verifying accelerator devices ---"
if command -v nvidia-smi &>/dev/null; then
    GPU_COUNT=$(nvidia-smi --query-gpu=count --format=csv,noheader | head -1)
    log "Found $GPU_COUNT NVIDIA GPU(s)"
elif command -v neuron-ls &>/dev/null; then
    NEURON_COUNT=$(neuron-ls --json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
    log "Found $NEURON_COUNT Neuron device(s)"
else
    log "No accelerator devices detected"
fi

log "=========================================="
log "HyperPod Lifecycle Script Complete"
log "=========================================="
