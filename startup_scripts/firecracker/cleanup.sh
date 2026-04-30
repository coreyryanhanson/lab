#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

HOST_IFACE=$(ip -j route list default | jq -r '.[0].dev' 2>/dev/null || echo "")

echo "Cleaning up Firecracker VM resources..."

# Kill processes gracefully first
sudo pkill -f "firecracker.*${VM_ID}" 2>/dev/null || true
sudo pkill -f "jailer.*--id ${VM_ID}" 2>/dev/null || true
sleep 3

# Force kill if still running
sudo pkill -9 -f "firecracker.*${VM_ID}" 2>/dev/null || true
sudo pkill -9 -f "jailer.*--id ${VM_ID}" 2>/dev/null || true

# Reset terminal state (processes may leave it corrupted)
stty sane 2>/dev/null || true
tput reset 2>/dev/null || true

# Clean namespace iptables
sudo ip netns exec $NETNS iptables -t nat -D POSTROUTING -s ${VM_IP}${VM_ROUTE_MASK} -o $VETH_NS -j MASQUERADE 2>/dev/null || true
sudo ip netns exec $NETNS iptables -D FORWARD -i $TAP_DEV -o $VETH_NS -j ACCEPT 2>/dev/null || true
sudo ip netns exec $NETNS iptables -D FORWARD -i $VETH_NS -o $TAP_DEV -j ACCEPT 2>/dev/null || true

# Remove namespace
sudo ip netns del $NETNS 2>/dev/null || true
sudo ip link del $VETH_HOST 2>/dev/null || true

# Remove host routes
sudo ip route del ${VM_IP}${VM_ROUTE_MASK} 2>/dev/null || true

# Remove host iptables
if [ -n "$HOST_IFACE" ]; then
    sudo iptables -D FORWARD -i $VETH_HOST -o $HOST_IFACE -j ACCEPT 2>/dev/null || true
    sudo iptables -D FORWARD -i $HOST_IFACE -o $VETH_HOST -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    sudo iptables -t nat -D POSTROUTING -s ${VETH_SUBNET} -o $HOST_IFACE -j MASQUERADE 2>/dev/null || true
fi

# Unmount bind mounts before removing directory
# Order matters: unmount children first, then the private parent
CHROOT_DIR="/srv/jailer/${FC_BINARY_NAME}/${VM_ID}/root"
sudo umount "${CHROOT_DIR}/overlay.ext4" 2>/dev/null || true
sudo umount "${CHROOT_DIR}/rootfs.ext4" 2>/dev/null || true
sudo umount "${CHROOT_DIR}" 2>/dev/null || true

# Remove the chroot directory
sudo rm -rf "/srv/jailer/${FC_BINARY_NAME}/${VM_ID}"

rm -f "${SCRIPT_DIR}/firecracker-${VM_ID}.log"

# Reset overlay ownership back to current user for convenience
CURRENT_USER=$(id -u)
CURRENT_GROUP=$(id -g)
for overlay in "${OVERLAY_DIR}/"*.ext4; do
    if [ -f "$overlay" ]; then
        owner=$(stat -c "%u" "$overlay" 2>/dev/null)
        if [ "$owner" = "$JAILER_UID" ]; then
            sudo chown ${CURRENT_USER}:${CURRENT_GROUP} "$overlay" 2>/dev/null || true
        fi
      fi
done

echo "Done."
echo "Note: Overlay and base rootfs files are preserved."
