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
# Helper: get instance metadata (supports IMDSv2)
# -------------------------------------------------------------------------
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

AWS_REGION=$(get_metadata "placement/region")
log "Region: ${AWS_REGION:-unknown}"

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

# Auto-discover FSx if not in provisioning params
if [[ -z "$FSX_DNS" || "$FSX_DNS" == *"PLACEHOLDER"* ]]; then
    log "Provisioning params missing FSx info — auto-discovering..."
    CLUSTER_PREFIX=$(jq -r '.ClusterConfig.ClusterName // empty' "$RESOURCE_CONFIG" 2>/dev/null || true)
    CLUSTER_PREFIX="${CLUSTER_PREFIX%%-slurm}"
    CLUSTER_PREFIX="${CLUSTER_PREFIX%%-eks}"

    if [[ -n "$CLUSTER_PREFIX" && -n "$AWS_REGION" ]]; then
        FSX_INFO=$(aws fsx describe-file-systems \
            --query "FileSystems[?Tags[?Key=='Name' && contains(Value, '${CLUSTER_PREFIX}')]].{DNS:DNSName,Mount:LustreConfiguration.MountName}" \
            --output json --region "$AWS_REGION" 2>/dev/null || true)

        if [[ -n "$FSX_INFO" ]]; then
            FSX_DNS=$(echo "$FSX_INFO" | jq -r '.[0].DNS // empty' 2>/dev/null || true)
            FSX_MOUNT=$(echo "$FSX_INFO" | jq -r '.[0].Mount // empty' 2>/dev/null || true)
            if [[ -n "$FSX_DNS" ]]; then
                log "Auto-discovered FSx: DNS=$FSX_DNS, Mount=$FSX_MOUNT"
            fi
        fi
    fi
fi

FSX_MOUNTED=false
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
            FSX_MOUNTED=true
        else
            log "WARNING: Failed to mount FSx Lustre — continuing without shared storage"
        fi
    else
        log "FSx Lustre already mounted at $MOUNT_POINT"
        FSX_MOUNTED=true
    fi
else
    log "FSx Lustre not configured — skipping mount"
fi

# -------------------------------------------------------------------------
# Verify Neuron devices and detect core count
# -------------------------------------------------------------------------
log "--- Verifying Neuron devices ---"
NEURON_CORES=0
if command -v neuron-ls &>/dev/null; then
    NEURON_DEVICE_COUNT=$(neuron-ls --json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
    NEURON_CORES=$(neuron-ls 2>/dev/null | awk '/^\| [0-9]+/ {total += $4} END {print total}' || echo "0")
    log "Found $NEURON_DEVICE_COUNT Neuron device(s), $NEURON_CORES NeuronCore(s)"
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
    log "INFO: fi_info not found — EFA may not be available on this instance type"
fi

# -------------------------------------------------------------------------
# Configure Neuron environment (auto-detect instance type)
# -------------------------------------------------------------------------
log "--- Configuring Neuron environment ---"

# Detect Neuron target based on core count
if [[ "$NEURON_CORES" -ge 64 ]]; then
    NEURON_TARGET="trn2"
    NEURON_RT_NUM_CORES_VAL=64
    NEURON_RT_VISIBLE_CORES_VAL="0-63"
elif [[ "$NEURON_CORES" -ge 32 ]]; then
    NEURON_TARGET="trn1"
    NEURON_RT_NUM_CORES_VAL=32
    NEURON_RT_VISIBLE_CORES_VAL="0-31"
elif [[ "$NEURON_CORES" -ge 4 ]]; then
    NEURON_TARGET="trn2"
    NEURON_RT_NUM_CORES_VAL=4
    NEURON_RT_VISIBLE_CORES_VAL="0-3"
else
    NEURON_TARGET="trn1"
    NEURON_RT_NUM_CORES_VAL=32
    NEURON_RT_VISIBLE_CORES_VAL="0-31"
fi
log "Neuron target: $NEURON_TARGET, cores: $NEURON_RT_NUM_CORES_VAL"

cat >> /etc/environment << EOF
NEURON_RT_NUM_CORES=$NEURON_RT_NUM_CORES_VAL
NEURON_RT_VISIBLE_CORES=$NEURON_RT_VISIBLE_CORES_VAL
NEURON_CC_FLAGS=--target=$NEURON_TARGET
NEURON_FUSE_SOFTMAX=1
NEURON_RT_ASYNC_EXEC_MAX_INFLIGHT_REQUESTS=5
NEURON_RT_STOCHASTIC_ROUNDING_EN=1
OMP_NUM_THREADS=1
MALLOC_ARENA_MAX=70
FI_PROVIDER=efa
FI_EFA_USE_DEVICE_RDMA=1
EOF
log "Neuron environment configured"

# -------------------------------------------------------------------------
# Configure SSH for inter-node communication
# -------------------------------------------------------------------------
log "--- Configuring SSH ---"

CLUSTER_NAME=$(jq -r '.ClusterConfig.ClusterName // .ClusterName // empty' "$RESOURCE_CONFIG" 2>/dev/null || true)
SSH_DIR="/root/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [[ "$FSX_MOUNTED" == true ]]; then
    FSX_SSH_DIR="/fsx/.ssh-cluster"
    mkdir -p "$FSX_SSH_DIR" 2>/dev/null || true
    if [[ ! -f "$FSX_SSH_DIR/id_rsa" ]]; then
        ssh-keygen -t rsa -b 4096 -f "$FSX_SSH_DIR/id_rsa" -N "" -q 2>/dev/null || true
        cat "$FSX_SSH_DIR/id_rsa.pub" >> "$FSX_SSH_DIR/authorized_keys" 2>/dev/null || true
        chmod 600 "$FSX_SSH_DIR/authorized_keys" "$FSX_SSH_DIR/id_rsa" 2>/dev/null || true
        log "Generated shared SSH keypair on FSx"
    fi
    cp "$FSX_SSH_DIR/id_rsa" "$FSX_SSH_DIR/id_rsa.pub" "$FSX_SSH_DIR/authorized_keys" "$SSH_DIR/" 2>/dev/null || true
    chmod 600 "$SSH_DIR/id_rsa" "$SSH_DIR/authorized_keys"
    log "Copied shared SSH keys from FSx"
else
    if [[ ! -f "$SSH_DIR/id_rsa" ]]; then
        ssh-keygen -t rsa -b 4096 -f "$SSH_DIR/id_rsa" -N "" -q
        cat "$SSH_DIR/id_rsa.pub" >> "$SSH_DIR/authorized_keys"
        chmod 600 "$SSH_DIR/authorized_keys"
        log "Generated local SSH keypair"
    fi
fi

USER_SSH_KEY="none"
if [[ -n "$CLUSTER_NAME" ]]; then
    USER_SSH_KEY=$(aws ssm get-parameter \
        --name "/hyperpod/${CLUSTER_NAME}/ssh-public-key" \
        --query "Parameter.Value" --output text 2>/dev/null || echo "none")
fi
if [[ -n "$USER_SSH_KEY" && "$USER_SSH_KEY" != "none" && "$USER_SSH_KEY" != "" ]]; then
    log "Adding user-provided SSH public key"
    echo "$USER_SSH_KEY" >> "$SSH_DIR/authorized_keys"
    if id ubuntu &>/dev/null; then
        UBUNTU_SSH="/home/ubuntu/.ssh"
        mkdir -p "$UBUNTU_SSH" && chmod 700 "$UBUNTU_SSH"
        touch "$UBUNTU_SSH/authorized_keys" && chmod 600 "$UBUNTU_SSH/authorized_keys"
        echo "$USER_SSH_KEY" >> "$UBUNTU_SSH/authorized_keys"
        chown -R ubuntu:ubuntu "$UBUNTU_SSH"
    fi
fi

SLURM_CONF_PATH="/opt/slurm/etc/slurm.conf"
cat > /etc/ssh/ssh_config.d/hyperpod-cluster.conf << SSHCONF
Host 127.0.0.1 localhost $(hostname)
    StrictHostKeyChecking no
    HostbasedAuthentication no
    CheckHostIP no
    UserKnownHostsFile /dev/null

Match host * exec "grep '^NodeName=%h ' $SLURM_CONF_PATH &> /dev/null"
    StrictHostKeyChecking no
    HostbasedAuthentication no
    CheckHostIP no
    UserKnownHostsFile /dev/null
SSHCONF

cat > "$SSH_DIR/config" << 'SSHCONFIG'
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
SSHCONFIG
chmod 600 "$SSH_DIR/config"

# Set library paths globally
cat >> /etc/environment << 'LIB_PATHS'
LD_LIBRARY_PATH=/usr/local/cuda/lib64:/opt/amazon/openmpi/lib:/opt/amazon/efa/lib:/opt/amazon/ofi-nccl/lib:/usr/local/lib:/usr/lib
LIB_PATHS
cat > /etc/profile.d/hyperpod-libs.sh << 'PROFILE'
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:/opt/amazon/openmpi/lib:/opt/amazon/efa/lib:/opt/amazon/ofi-nccl/lib:/usr/local/lib:/usr/lib:${LD_LIBRARY_PATH:-}
export PATH=/opt/slurm/bin:/opt/amazon/openmpi/bin:$PATH
PROFILE
chmod 644 /etc/profile.d/hyperpod-libs.sh
log "SSH and library paths configured"

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

    # Distribute SSH keys to workers via Slurm (if no FSx)
    if [[ "$FSX_MOUNTED" != true ]]; then
        log "Distributing controller SSH key to workers via Slurm..."
        CONTROLLER_PUBKEY=$(cat "$SSH_DIR/id_rsa.pub")

        # Auto-detect the worker partition name
        WORKER_PARTITION=$(sinfo -h -o "%P" 2>/dev/null | grep -v "^dev" | head -1 | tr -d '*' || echo "")
        log "Worker partition: ${WORKER_PARTITION:-not found}"

        for i in $(seq 1 60); do
            WORKER_COUNT=$(sinfo -N -h ${WORKER_PARTITION:+-p $WORKER_PARTITION} -t idle,alloc,mix 2>/dev/null | wc -l || echo "0")
            [[ "$WORKER_COUNT" -gt 0 ]] && break
            sleep 5
        done
        if [[ "$WORKER_COUNT" -gt 0 ]]; then
            srun -N "$WORKER_COUNT" ${WORKER_PARTITION:+-p $WORKER_PARTITION} bash -c "
                mkdir -p /root/.ssh && chmod 700 /root/.ssh
                echo '$CONTROLLER_PUBKEY' >> /root/.ssh/authorized_keys
                chmod 600 /root/.ssh/authorized_keys
            " 2>/dev/null && log "SSH key distributed to $WORKER_COUNT worker(s)" \
                          || log "WARNING: Failed to distribute SSH keys"

            # Collect worker public keys back to controller
            srun -N "$WORKER_COUNT" ${WORKER_PARTITION:+-p $WORKER_PARTITION} bash -c "cat /root/.ssh/id_rsa.pub" 2>/dev/null | while read -r key; do
                if [[ -n "$key" ]]; then
                    echo "$key" >> "$SSH_DIR/authorized_keys"
                fi
            done
            log "Worker SSH keys collected"
        fi
    fi
else
    log "Starting slurmd..."

    if [[ -n "$CONTROLLER_IPS" ]]; then
        log "Configuring slurmd with --conf-server $CONTROLLER_IPS"
        SLURMD_SERVICE="/etc/systemd/system/slurmd.service"
        if [[ -f "$SLURMD_SERVICE" ]]; then
            if grep -q '\$SLURMD_OPTIONS' "$SLURMD_SERVICE"; then
                log "Injecting --conf-server via envsubst"
                SLURMD_OPTIONS="--conf-server $CONTROLLER_IPS" envsubst < "$SLURMD_SERVICE" > /tmp/slurmd.service
                mv /tmp/slurmd.service "$SLURMD_SERVICE"
            else
                log "Modifying ExecStart directly"
                sed -i "s|ExecStart=.*slurmd.*|& --conf-server $CONTROLLER_IPS|" "$SLURMD_SERVICE"
            fi
            systemctl daemon-reload
        fi
    fi

    systemctl enable slurmd 2>/dev/null || true
    systemctl start slurmd 2>/dev/null || log "WARNING: Could not start slurmd"

    sleep 5
    if systemctl is-active slurmd &>/dev/null; then
        log "slurmd is running"
    else
        log "ERROR: slurmd failed to start"
        journalctl -u slurmd --no-pager -n 10 2>/dev/null | while read -r line; do
            log "  $line"
        done
    fi

    if [[ -f /etc/systemd/system/slurmctld.service ]]; then
        mv /etc/systemd/system/slurmctld.service /etc/systemd/system/slurmctld_DISABLED.service 2>/dev/null || true
        log "Disabled slurmctld on worker"
    fi
fi

log "=========================================="
log "HyperPod Lifecycle Script Complete"
log "Node type: $NODE_TYPE"
log "=========================================="

exit 0
