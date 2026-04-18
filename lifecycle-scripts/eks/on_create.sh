#!/bin/bash

# =============================================================================
# HyperPod Lifecycle Script: EKS
# =============================================================================
# Minimal lifecycle script for EKS-orchestrated HyperPod clusters.
# EKS handles most node configuration (device plugins, networking) via
# managed add-ons, so this script only handles FSx mounting and basic setup.
#
# NOTE: Do NOT use "set -e" here. HyperPod treats any non-zero exit as a
# fatal provisioning failure.
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
RESOURCE_CONFIG="/opt/ml/config/resource_config.json"
FSX_DNS=""
FSX_MOUNT=""

if [[ -f "$PROVISIONING_PARAMS" ]]; then
    FSX_DNS=$(jq -r '.fsx_dns_name // empty' "$PROVISIONING_PARAMS" 2>/dev/null || true)
    FSX_MOUNT=$(jq -r '.fsx_mountname // empty' "$PROVISIONING_PARAMS" 2>/dev/null || true)
fi

# Auto-discover FSx if not in provisioning params
if [[ -z "$FSX_DNS" || "$FSX_DNS" == *"PLACEHOLDER"* ]]; then
    log "Auto-discovering FSx..."
    CLUSTER_PREFIX=$(jq -r '.ClusterConfig.ClusterName // empty' "$RESOURCE_CONFIG" 2>/dev/null || true)
    CLUSTER_PREFIX="${CLUSTER_PREFIX%%-slurm}"
    CLUSTER_PREFIX="${CLUSTER_PREFIX%%-eks}"

    if [[ -n "$CLUSTER_PREFIX" ]]; then
        IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)
        REGION=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || \
                 curl -s http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || true)
        if [[ -n "$REGION" ]]; then
            FSX_INFO=$(aws fsx describe-file-systems \
                --query "FileSystems[?Tags[?Key=='Name' && contains(Value, '${CLUSTER_PREFIX}')]].{DNS:DNSName,Mount:LustreConfiguration.MountName}" \
                --output json --region "$REGION" 2>/dev/null || true)
            if [[ -n "$FSX_INFO" ]]; then
                FSX_DNS=$(echo "$FSX_INFO" | jq -r '.[0].DNS // empty' 2>/dev/null || true)
                FSX_MOUNT=$(echo "$FSX_INFO" | jq -r '.[0].Mount // empty' 2>/dev/null || true)
                [[ -n "$FSX_DNS" ]] && log "Auto-discovered FSx: DNS=$FSX_DNS, Mount=$FSX_MOUNT"
            fi
        fi
    fi
fi

if [[ -n "$FSX_DNS" && -n "$FSX_MOUNT" && "$FSX_DNS" != *"PLACEHOLDER"* ]]; then
    log "--- Setting up FSx Lustre ---"
    MOUNT_POINT="/fsx"
    mkdir -p "$MOUNT_POINT"

    if ! lsmod | grep -q lustre 2>/dev/null; then
        apt-get update -qq 2>/dev/null || true
        apt-get install -y -qq lustre-client-modules-aws 2>/dev/null || \
        apt-get install -y -qq "lustre-client-modules-$(uname -r)" 2>/dev/null || \
        log "WARNING: Could not install Lustre client"
    fi

    if ! mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        if mount -t lustre -o relatime,flock "${FSX_DNS}@tcp:/${FSX_MOUNT}" "$MOUNT_POINT"; then
            echo "${FSX_DNS}@tcp:/${FSX_MOUNT} $MOUNT_POINT lustre defaults,relatime,flock,_netdev,x-systemd.automount,x-systemd.requires=network.target 0 0" >> /etc/fstab
            log "FSx Lustre mounted at $MOUNT_POINT"
        else
            log "WARNING: Failed to mount FSx Lustre — continuing without shared storage"
        fi
    fi
else
    log "FSx Lustre not configured — skipping mount"
fi

# -------------------------------------------------------------------------
# Verify accelerator devices
# -------------------------------------------------------------------------
log "--- Verifying accelerator devices ---"
if command -v nvidia-smi &>/dev/null; then
    GPU_COUNT=$(nvidia-smi --query-gpu=count --format=csv,noheader 2>/dev/null | head -1 || echo "0")
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

exit 0
