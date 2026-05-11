#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

OVERLAY_NAME="${1:-}"

if [ -z "$OVERLAY_NAME" ]; then
    echo "Usage: $0 <overlay_name>"
    echo ""
    echo "Available overlays:"
    ls -1 "${OVERLAY_DIR}/" 2>/dev/null | grep '\.ext4$' | sed 's/\.ext4$//' || echo "  (none)"
    echo ""
    echo "Create a new overlay with: ./create_overlay.sh <name>"
    exit 1
fi

OVERLAY_PATH="${OVERLAY_DIR}/${OVERLAY_NAME}.ext4"

if [ ! -f "$OVERLAY_PATH" ]; then
    echo "ERROR: Overlay $OVERLAY_NAME not found at $OVERLAY_PATH"
    echo "Create it first with: ./create_overlay.sh $OVERLAY_NAME"
    exit 1
fi

echo "Starting VM with overlay: $OVERLAY_NAME"

# Detect default host interface
HOST_IFACE=$(ip -j route list default | jq -r '.[0].dev' 2>/dev/null || echo "")
if [ -z "$HOST_IFACE" ]; then
    echo "ERROR: Could not detect default network interface"
    exit 1
fi

# ============================================================
# Safety checks
# ============================================================
for f in "$JAILER" "$FC_BINARY" "$KERNEL"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: Not found: $f"
        exit 1
    fi
done

if [ ! -f "$BASE_ROOTFS" ]; then
    echo "ERROR: Base rootfs not found: $BASE_ROOTFS"
    echo "Run ./init_base.sh first"
    exit 1
fi

# ============================================================
# Verify overlay compatibility
# ============================================================
CHECKSUM_PATH="${OVERLAY_DIR}/${OVERLAY_NAME}.base_checksum"
CURRENT_BASE_CHECKSUM=$(md5sum "$BASE_ROOTFS" | cut -d' ' -f1)

if [ -f "$CHECKSUM_PATH" ]; then
    EXPECTED_CHECKSUM=$(cat "$CHECKSUM_PATH")
    if [ "$CURRENT_BASE_CHECKSUM" != "$EXPECTED_CHECKSUM" ]; then
        echo "==============================================="
        echo "ERROR: Base rootfs checksum mismatch!"
        echo "==============================================="
        echo ""
        echo "The overlay '$OVERLAY_NAME' was created with a different"
        echo "base rootfs than the current one. Booting with a mismatched"
        echo "base can cause filesystem corruption or phantom files."
        echo ""
        echo "  Overlay expects:  $EXPECTED_CHECKSUM"
        echo "  Current base:     $CURRENT_BASE_CHECKSUM"
        echo ""
        echo "Choices:"
        echo "  1. Recreate the overlay (destroys overlay contents):"
        echo "     sudo rm $OVERLAY_PATH $CHECKSUM_PATH"
        echo "     ./create_overlay.sh $OVERLAY_NAME"
        echo ""
        echo "  2. Update the checksum to match the new base (at your own risk):"
        echo "     echo $CURRENT_BASE_CHECKSUM > $CHECKSUM_PATH"
        exit 1
    else
        echo "Overlay checksum verified: $OVERLAY_NAME matches current base"
    fi
else
    echo "WARNING: No checksum file found for overlay $OVERLAY_NAME"
    echo "This overlay was created before checksum tracking was added."
    echo "Proceeding anyway, but consider recreating it."
    echo ""
    echo "$CURRENT_BASE_CHECKSUM" > "$CHECKSUM_PATH"
fi

# ============================================================
# Check for running VM
# ============================================================
if sudo ip netns list 2>/dev/null | grep -q "^$NETNS"; then
    echo "ERROR: Network namespace $NETNS already exists."
    echo "This likely means a VM is already running."
    echo "Run ./cleanup.sh first to stop it."
    exit 1
fi

# ============================================================
# Clean up any previous run
# ============================================================
echo "Cleaning up previous resources..."
"${SCRIPT_DIR}/cleanup.sh" > /dev/null 2>&1 || true

# ============================================================
# Boot args (always with overlay)
# ============================================================
KERNEL_BOOT_ARGS="console=ttyS0 reboot=k panic=1 net.ifnames=0 biosdevname=0 overlay_root=vdb init=/sbin/overlay-init dns=${PRIMARY_DNS},${SECONDARY_DNS} vm_ip=${GUEST_IP} vm_gw=${GUEST_GW} vm_mask=${GUEST_MASK}"

# ============================================================
# Error cleanup trap
# ============================================================
cleanup_on_error() {
    echo ""
    echo "Error occurred, cleaning up..."
    sudo umount "${CHROOT_DIR}/overlay.ext4" 2>/dev/null || true
    sudo umount "${CHROOT_DIR}/rootfs.ext4" 2>/dev/null || true
    sudo umount "${CHROOT_DIR}" 2>/dev/null || true
    sudo rm -rf "/srv/jailer/${FC_BINARY_NAME}/${VM_ID}"
    "${SCRIPT_DIR}/cleanup.sh" > /dev/null 2>&1 || true
    exit 1
}

trap cleanup_on_error ERR

# ============================================================
# Prepare jailer chroot with bind mounts
# ============================================================
echo "Preparing jailer chroot..."

sudo mkdir -p "$CHROOT_DIR"

# Make chroot a private mount to isolate bind mounts
# This prevents mount events from propagating to/from the host
sudo mount --bind "$CHROOT_DIR" "$CHROOT_DIR"
sudo mount --make-private "$CHROOT_DIR"

# Copy kernel
sudo install -m 644 "$KERNEL" "${CHROOT_DIR}/vmlinux"
sudo chown ${JAILER_UID}:${JAILER_GID} "${CHROOT_DIR}/vmlinux"

# Bind mount base rootfs read-only
echo "  Binding base rootfs (read-only)..."
sudo touch "${CHROOT_DIR}/rootfs.ext4"
sudo mount --bind "$BASE_ROOTFS" "${CHROOT_DIR}/rootfs.ext4"
sudo mount -o remount,ro,bind "${CHROOT_DIR}/rootfs.ext4"

# Bind mount overlay read-write
echo "  Binding overlay: $OVERLAY_NAME (read-write)..."
sudo chown ${JAILER_UID}:${JAILER_GID} "$OVERLAY_PATH"
sudo touch "${CHROOT_DIR}/overlay.ext4"
sudo mount --bind "$OVERLAY_PATH" "${CHROOT_DIR}/overlay.ext4"

# ============================================================
# Generate jailer config
# ============================================================
echo "Generating jailer config..."

JAILER_CONFIG="${CHROOT_DIR}/config.json"

sudo tee "$JAILER_CONFIG" > /dev/null << EOF
{
  "boot-source": {
    "kernel_image_path": "/vmlinux",
    "boot_args": "${KERNEL_BOOT_ARGS}"
  },
  "drives": [
    {
      "drive_id": "rootfs",
      "path_on_host": "/rootfs.ext4",
      "is_root_device": true,
      "is_read_only": true
    },
    {
      "drive_id": "overlay",
      "path_on_host": "/overlay.ext4",
      "is_root_device": false,
      "is_read_only": false
    }
  ],
  "network-interfaces": [
    {
      "iface_id": "net1",
      "guest_mac": "${FC_MAC}",
      "host_dev_name": "${TAP_DEV}"
    }
  ],
  "machine-config": {
    "vcpu_count": ${VM_VCPUS},
    "mem_size_mib": ${VM_MEM_MIB}
  }
}
EOF

sudo chown ${JAILER_UID}:${JAILER_GID} "$JAILER_CONFIG"

# ============================================================
# Set up networking
# ============================================================
echo "Setting up network..."

sudo ip netns add $NETNS
sudo ip link add $VETH_HOST type veth peer name $VETH_NS
sudo ip link set $VETH_NS netns $NETNS
sudo ip addr add ${VETH_HOST_IP}/24 dev $VETH_HOST
sudo ip link set $VETH_HOST up
sudo ip netns exec $NETNS ip addr add ${VETH_NS_IP}/24 dev $VETH_NS
sudo ip netns exec $NETNS ip link set $VETH_NS up
sudo ip netns exec $NETNS ip link set lo up
sudo ip netns exec $NETNS ip tuntap add dev $TAP_DEV mode tap
sudo ip netns exec $NETNS ip addr add ${TAP_IP}${MASK} dev $TAP_DEV
sudo ip netns exec $NETNS ip link set $TAP_DEV up
sudo ip netns exec $NETNS ip route add default via ${VETH_HOST_IP}
sudo ip netns exec $NETNS sysctl -w net.ipv4.ip_forward=1 > /dev/null
sudo ip netns exec $NETNS iptables -t nat -A POSTROUTING -s ${VM_IP}${VM_ROUTE_MASK} -o $VETH_NS -j MASQUERADE
sudo ip netns exec $NETNS iptables -A FORWARD -i $TAP_DEV -o $VETH_NS -j ACCEPT
sudo ip netns exec $NETNS iptables -A FORWARD -i $VETH_NS -o $TAP_DEV -j ACCEPT
sudo ip route add ${VM_IP}${VM_ROUTE_MASK} via ${VETH_NS_IP}
sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null
sudo iptables -A FORWARD -i $VETH_HOST -o $HOST_IFACE -j ACCEPT
sudo iptables -A FORWARD -i $HOST_IFACE -o $VETH_HOST -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -t nat -A POSTROUTING -s ${VETH_SUBNET} -o $HOST_IFACE -j MASQUERADE

# ============================================================
# Firewall: Allow VM to reach host services (local LLM, etc.)
# ============================================================
echo "Configuring firewall for VM access..."

# Allow VM subnet to reach specific host ports
for PORT in $HOST_SERVICE_PORTS; do
    sudo firewall-cmd --zone=public --add-rich-rule="rule family=\"ipv4\" source address=\"${VETH_SUBNET}\" port port=\"${PORT}\" protocol=\"tcp\" accept" 2>/dev/null || true
done

# Disable rp_filter on veth to prevent kernel from dropping VM->host packets
sudo sysctl -w net.ipv4.conf.fc-veth0.rp_filter=0 > /dev/null 2>&1 || true

# ============================================================
# Start Firecracker with jailer
# ============================================================
echo "Starting Firecracker VM..."

sudo $JAILER \
  --id $VM_ID \
  --exec-file $FC_BINARY \
  --uid $JAILER_UID \
  --gid $JAILER_GID \
  --netns /var/run/netns/$NETNS \
  --daemonize \
  -- --config-file /config.json \
  >> "${SCRIPT_DIR}/firecracker-${VM_ID}.log" 2>&1

# ============================================================
# Wait for VM
# ============================================================
echo "Waiting for VM to be ready..."
MAX_WAIT=30
for i in $(seq 1 $MAX_WAIT); do
    if ssh -i ${SSH_KEY} -o ConnectTimeout=1 -o StrictHostKeyChecking=no root@${VM_IP} true 2>/dev/null; then
        echo "VM is ready!"
        break
    fi
    if [ $i -eq $MAX_WAIT ]; then
        echo "ERROR: VM did not become reachable within ${MAX_WAIT}s"
        echo "Check logs: ${SCRIPT_DIR}/firecracker-${VM_ID}.log"
        cleanup_on_error
    fi
    sleep 1
done

# Remove error trap since we succeeded
trap - ERR

echo ""
echo "Overlay:       $OVERLAY_NAME"
echo "Base rootfs:   bind-mounted read-only"
echo "Overlay:       bind-mounted read-write"
echo "Changes persist in: overlays/${OVERLAY_NAME}.ext4"
echo ""
echo "SSH into the VM with:"
echo "  ssh -i ${SSH_KEY} root@${VM_IP}"
