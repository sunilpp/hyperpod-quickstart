#!/bin/bash

# =============================================================================
# HyperPod Lifecycle Script: Slurm + GPU
# =============================================================================
# This script runs on every node during HyperPod cluster creation.
# It detects whether the node is a controller (head) or worker (compute),
# then sets up the appropriate services.
#
# NOTE: Do NOT use "set -e" here. HyperPod treats any non-zero exit as a
# fatal provisioning failure. Individual commands may fail non-critically,
# so we handle errors explicitly.
#
# Based on: aws-samples/awsome-distributed-training lifecycle scripts
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

# Detect instance group name — try multiple methods
INSTANCE_GROUP_NAME=$(jq -r '.InstanceGroupName // empty' "$RESOURCE_CONFIG" 2>/dev/null || true)

# Method 2: match instance ID against InstanceGroups
if [[ -z "$INSTANCE_GROUP_NAME" ]]; then
    INSTANCE_ID=$(get_metadata "instance-id")
    log "Instance ID: ${INSTANCE_ID:-not available}"
    if [[ -n "$INSTANCE_ID" ]]; then
        INSTANCE_GROUP_NAME=$(jq -r --arg id "$INSTANCE_ID" '
            .InstanceGroups[]? |
            select(.Instances[]?.InstanceId == $id) |
            .Name // empty
        ' "$RESOURCE_CONFIG" 2>/dev/null || true)
    fi
fi

# Method 3: check instance type
if [[ -z "$INSTANCE_GROUP_NAME" ]]; then
    CURRENT_TYPE=$(get_metadata "instance-type")
    log "Instance type: ${CURRENT_TYPE:-not available}"
    if echo "$CURRENT_TYPE" | grep -qi "m5"; then
        INSTANCE_GROUP_NAME="controller-group"
    else
        INSTANCE_GROUP_NAME="worker-group"
    fi
fi

# Method 4: SlurmConfig hint (controller has empty PrimaryControllerIp)
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

# Get cluster name for later use
CLUSTER_NAME=$(jq -r '.ClusterConfig.ClusterName // .ClusterName // empty' "$RESOURCE_CONFIG" 2>/dev/null || true)
log "Cluster name: ${CLUSTER_NAME:-unknown}"

# -------------------------------------------------------------------------
# Mount FSx Lustre shared filesystem
# -------------------------------------------------------------------------
log "--- Setting up FSx Lustre ---"
PROVISIONING_PARAMS="/opt/ml/config/provisioning_parameters.json"
FSX_DNS=""
FSX_MOUNT=""
FSX_MOUNTED=false

# Try provisioning_parameters.json first
if [[ -f "$PROVISIONING_PARAMS" ]]; then
    FSX_DNS=$(jq -r '.fsx_dns_name // empty' "$PROVISIONING_PARAMS" 2>/dev/null || true)
    FSX_MOUNT=$(jq -r '.fsx_mountname // empty' "$PROVISIONING_PARAMS" 2>/dev/null || true)
fi

# Auto-discover FSx if not in provisioning params
if [[ -z "$FSX_DNS" || "$FSX_DNS" == *"PLACEHOLDER"* ]]; then
    log "Auto-discovering FSx..."
    CLUSTER_PREFIX="${CLUSTER_NAME%%-slurm}"
    CLUSTER_PREFIX="${CLUSTER_PREFIX%%-eks}"

    if [[ -n "$CLUSTER_PREFIX" && -n "$AWS_REGION" ]]; then
        FSX_INFO=$(aws fsx describe-file-systems \
            --query "FileSystems[?Tags[?Key=='Name' && contains(Value, '${CLUSTER_PREFIX}')]].{DNS:DNSName,Mount:LustreConfiguration.MountName}" \
            --output json --region "$AWS_REGION" 2>/dev/null || true)

        if [[ -n "$FSX_INFO" ]]; then
            FSX_DNS=$(echo "$FSX_INFO" | jq -r '.[0].DNS // empty' 2>/dev/null || true)
            FSX_MOUNT=$(echo "$FSX_INFO" | jq -r '.[0].Mount // empty' 2>/dev/null || true)
            [[ -n "$FSX_DNS" ]] && log "Auto-discovered FSx: DNS=$FSX_DNS, Mount=$FSX_MOUNT"
        fi
    fi
fi

# Mount if we have valid FSx info
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
            log "WARNING: Failed to mount FSx Lustre"
        fi
    else
        log "FSx Lustre already mounted at $MOUNT_POINT"
        FSX_MOUNTED=true
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
    log "INFO: nvidia-smi not found (expected on controller m5 instance)"
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
# Configure SSH for inter-node communication (MPI/NCCL)
# Based on: awsome-distributed-training ssh-to-compute.sh + gen-keypair-ubuntu.sh
# -------------------------------------------------------------------------
log "--- Configuring SSH ---"

# Setup SSH for root
SSH_DIR="/root/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [[ "$FSX_MOUNTED" == true ]]; then
    # FSx available — use shared key storage (AWS reference pattern)
    FSX_SSH_DIR="/fsx/.ssh-cluster"
    mkdir -p "$FSX_SSH_DIR" 2>/dev/null || true

    if [[ ! -f "$FSX_SSH_DIR/id_rsa" ]]; then
        # First node to run generates the shared keypair
        ssh-keygen -t rsa -b 4096 -f "$FSX_SSH_DIR/id_rsa" -N "" -q 2>/dev/null || true
        cat "$FSX_SSH_DIR/id_rsa.pub" >> "$FSX_SSH_DIR/authorized_keys" 2>/dev/null || true
        chmod 600 "$FSX_SSH_DIR/authorized_keys" 2>/dev/null || true
        chmod 600 "$FSX_SSH_DIR/id_rsa" 2>/dev/null || true
        log "Generated shared SSH keypair on FSx"
    fi

    # Copy shared keys to local SSH directory
    cp "$FSX_SSH_DIR/id_rsa" "$SSH_DIR/id_rsa" 2>/dev/null || true
    cp "$FSX_SSH_DIR/id_rsa.pub" "$SSH_DIR/id_rsa.pub" 2>/dev/null || true
    cp "$FSX_SSH_DIR/authorized_keys" "$SSH_DIR/authorized_keys" 2>/dev/null || true
    chmod 600 "$SSH_DIR/id_rsa" "$SSH_DIR/authorized_keys"
    log "Copied shared SSH keys from FSx"
else
    # No FSx — generate local keypair, distribution happens after Slurm starts
    if [[ ! -f "$SSH_DIR/id_rsa" ]]; then
        ssh-keygen -t rsa -b 4096 -f "$SSH_DIR/id_rsa" -N "" -q
        cat "$SSH_DIR/id_rsa.pub" >> "$SSH_DIR/authorized_keys"
        chmod 600 "$SSH_DIR/authorized_keys"
        log "Generated local SSH keypair (will distribute via Slurm)"
    fi
fi

# Add user-provided SSH public key from SSM
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
        mkdir -p "$UBUNTU_SSH"
        chmod 700 "$UBUNTU_SSH"
        touch "$UBUNTU_SSH/authorized_keys"
        chmod 600 "$UBUNTU_SSH/authorized_keys"
        echo "$USER_SSH_KEY" >> "$UBUNTU_SSH/authorized_keys"
        chown -R ubuntu:ubuntu "$UBUNTU_SSH"
        log "SSH key added for ubuntu user"
    fi
else
    log "No user SSH key — use SSM Session Manager to access nodes"
fi

# Configure SSH to skip host key checking for cluster nodes
# Based on: awsome-distributed-training ssh-to-compute.sh
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

# Also set root's SSH config
cat > "$SSH_DIR/config" << 'SSHCONFIG'
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
SSHCONFIG
chmod 600 "$SSH_DIR/config"
log "SSH configured"

# -------------------------------------------------------------------------
# Set library paths globally (needed for mpirun, srun, and NCCL)
# -------------------------------------------------------------------------
log "--- Setting library paths ---"
cat >> /etc/environment << 'LIB_PATHS'
LD_LIBRARY_PATH=/usr/local/cuda/lib64:/opt/amazon/openmpi/lib:/opt/amazon/efa/lib:/opt/amazon/ofi-nccl/lib:/usr/local/lib:/usr/lib
LIB_PATHS

# Also set for current session and profile
cat > /etc/profile.d/hyperpod-libs.sh << 'PROFILE'
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:/opt/amazon/openmpi/lib:/opt/amazon/efa/lib:/opt/amazon/ofi-nccl/lib:/usr/local/lib:/usr/lib:${LD_LIBRARY_PATH:-}
export PATH=/opt/slurm/bin:/opt/amazon/openmpi/bin:$PATH
PROFILE
chmod 644 /etc/profile.d/hyperpod-libs.sh
log "Library paths configured"

# -------------------------------------------------------------------------
# Start Slurm services
# -------------------------------------------------------------------------
log "--- Starting Slurm services ---"

# Ensure MUNGE is running
log "Verifying MUNGE authentication daemon..."
if systemctl is-active munge &>/dev/null; then
    log "MUNGE is running"
else
    log "Starting MUNGE..."
    systemctl enable munge 2>/dev/null || true
    systemctl start munge 2>/dev/null || log "WARNING: Could not start MUNGE"
fi

# Get controller IPs for configless Slurm
CONTROLLER_IPS=$(jq -r '
    .InstanceGroups[]? |
    select(.Name | test("controller"; "i")) |
    [.Instances[]?.CustomerIpAddress] | join(",")
' "$RESOURCE_CONFIG" 2>/dev/null || true)
log "Controller IPs: ${CONTROLLER_IPS:-not found}"

if [[ "$NODE_TYPE" == "controller" ]]; then
    # Wait for slurm.conf
    log "Waiting for $SLURM_CONF_PATH..."
    for i in $(seq 1 120); do
        if [[ -f "$SLURM_CONF_PATH" ]]; then
            log "slurm.conf found after ${i}s"
            break
        fi
        sleep 1
    done
    [[ ! -f "$SLURM_CONF_PATH" ]] && log "WARNING: slurm.conf not found after 120s"

    log "Starting slurmctld..."
    systemctl enable slurmctld 2>/dev/null || true
    systemctl start slurmctld 2>/dev/null || log "WARNING: Could not start slurmctld"

    # Disable slurmd on controller
    if [[ -f /etc/systemd/system/slurmd.service ]]; then
        mv /etc/systemd/system/slurmd.service /etc/systemd/system/slurmd_DISABLED.service 2>/dev/null || true
        log "Disabled slurmd on controller"
    fi

    # Wait for slurmctld to be ready
    for i in $(seq 1 30); do
        if scontrol ping &>/dev/null; then
            log "Slurm controller is ready"
            break
        fi
        sleep 2
    done

    # ── Distribute SSH keys to workers via Slurm ──────────────────
    if [[ "$FSX_MOUNTED" != true ]]; then
        log "Distributing controller SSH key to workers via Slurm..."
        CONTROLLER_PUBKEY=$(cat "$SSH_DIR/id_rsa.pub")

        # Auto-detect the worker partition name
        WORKER_PARTITION=$(sinfo -h -o "%P" 2>/dev/null | grep -v "^dev" | head -1 | tr -d '*' || echo "")
        log "Worker partition: ${WORKER_PARTITION:-not found}"

        # Wait for at least one worker to register
        for i in $(seq 1 60); do
            WORKER_COUNT=$(sinfo -N -h ${WORKER_PARTITION:+-p $WORKER_PARTITION} -t idle,alloc,mix 2>/dev/null | wc -l || echo "0")
            if [[ "$WORKER_COUNT" -gt 0 ]]; then
                log "Found $WORKER_COUNT worker(s) registered"
                break
            fi
            sleep 5
        done

        if [[ "$WORKER_COUNT" -gt 0 ]]; then
            # Push controller's public key to all workers
            srun -N "$WORKER_COUNT" ${WORKER_PARTITION:+-p $WORKER_PARTITION} bash -c "
                mkdir -p /root/.ssh && chmod 700 /root/.ssh
                echo '$CONTROLLER_PUBKEY' >> /root/.ssh/authorized_keys
                chmod 600 /root/.ssh/authorized_keys
            " 2>/dev/null && log "SSH key distributed to $WORKER_COUNT worker(s)" \
                          || log "WARNING: Failed to distribute SSH keys"

            # Also get each worker's public key and add to controller
            srun -N "$WORKER_COUNT" ${WORKER_PARTITION:+-p $WORKER_PARTITION} bash -c "cat /root/.ssh/id_rsa.pub" 2>/dev/null | while read -r key; do
                if [[ -n "$key" ]]; then
                    echo "$key" >> "$SSH_DIR/authorized_keys"
                fi
            done
            log "Worker SSH keys collected"
        else
            log "WARNING: No workers registered after 5 min — SSH keys not distributed"
        fi
    fi

else
    # ── Worker node ──────────────────────────────────────────────
    log "Starting slurmd..."

    # Configure --conf-server for configless Slurm
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

    # Verify slurmd
    sleep 5
    if systemctl is-active slurmd &>/dev/null; then
        log "slurmd is running"
        grep ExecStart /etc/systemd/system/slurmd.service 2>/dev/null | while read -r line; do
            log "  $line"
        done
    else
        log "ERROR: slurmd failed to start"
        journalctl -u slurmd --no-pager -n 10 2>/dev/null | while read -r line; do
            log "  $line"
        done
    fi

    # Disable slurmctld on worker
    if [[ -f /etc/systemd/system/slurmctld.service ]]; then
        mv /etc/systemd/system/slurmctld.service /etc/systemd/system/slurmctld_DISABLED.service 2>/dev/null || true
        log "Disabled slurmctld on worker"
    fi
fi

# -------------------------------------------------------------------------
# NCCL environment variables (all nodes)
# -------------------------------------------------------------------------
log "--- Configuring NCCL environment ---"
# Do NOT set NCCL_ALGO, NCCL_PROTO, or NCCL_TREE_THRESHOLD — per AWS docs
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
# Install NCCL test script on controller
# -------------------------------------------------------------------------
if [[ "$NODE_TYPE" == "controller" ]]; then
    log "--- Installing NCCL test ---"

    # Find pre-built NCCL test binary
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
NODES=\${1:-2}
GPUS=\${2:-0}

# Auto-detect GPUs if not specified
if [[ "\$GPUS" -eq 0 ]]; then
    GPUS=\$(srun -N 1 -p gpu --quiet bash -c "nvidia-smi -L 2>/dev/null | wc -l" 2>/dev/null || echo 1)
    [[ "\$GPUS" -eq 0 ]] && GPUS=1
fi

TOTAL=\$((NODES * GPUS))
BINARY="${NCCL_BINARY:-/opt/nccl-tests/build/all_reduce_perf}"
LIB="${NCCL_LIB_DIR}/lib"

echo "============================================================"
echo "  NCCL All-Reduce Test"
echo "  Nodes: \$NODES | GPUs/node: \$GPUS | Total: \$TOTAL"
echo "  Binary: \$BINARY"
echo "============================================================"

# Build hostfile from Slurm
HOSTFILE="/tmp/nccl-hosts-\$\$"
sinfo -N -h -p gpu -t idle,alloc,mix -o "%N" | head -"\$NODES" > "\$HOSTFILE"

# Run with mpirun (--oversubscribe to bypass PPR limits)
/opt/amazon/openmpi/bin/mpirun --allow-run-as-root --oversubscribe \\
    -np \$TOTAL -N \$GPUS --hostfile "\$HOSTFILE" --bind-to none \\
    -x FI_PROVIDER=efa -x FI_EFA_FORK_SAFE=1 \\
    -x LD_LIBRARY_PATH=\$LIB:/opt/amazon/efa/lib:/opt/amazon/openmpi/lib:/opt/amazon/ofi-nccl/lib:/usr/local/lib:/usr/lib \\
    -x NCCL_DEBUG=INFO -x NCCL_BUFFSIZE=8388608 -x NCCL_P2P_NET_CHUNKSIZE=524288 \\
    -x NCCL_SOCKET_IFNAME=^docker,lo,veth \\
    --mca pml ^ucx --mca btl tcp,self --mca btl_tcp_if_exclude lo,docker0,veth_def_agent \\
    \$BINARY -b 8 -e 16G -f 2 -g 1 -c 1 -n 100

rm -f "\$HOSTFILE"
NCCL_SCRIPT
    chmod +x /opt/slurm/bin/run-nccl-test

    if [[ -n "$NCCL_BINARY" ]]; then
        log "NCCL test ready: run-nccl-test [nodes] [gpus-per-node]"
    else
        log "WARNING: NCCL test binary not found on this AMI"
    fi
fi

log "=========================================="
log "HyperPod Lifecycle Script Complete"
log "Node type: $NODE_TYPE"
log "=========================================="

exit 0
