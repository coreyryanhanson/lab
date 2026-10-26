#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

# Prefer the interface start.sh recorded: if the default route moved since,
# re-detection would delete the wrong iptables rules and leak the originals.
HOST_IFACE=$(cat "${HOST_IFACE_STATE}" 2>/dev/null || true)
if [ -z "$HOST_IFACE" ]; then
    HOST_IFACE=$(ip -j route list default | jq -r '.[0].dev // empty' 2>/dev/null || echo "")
fi
# Same detection as start.sh: rules were added to the default zone, not always "public"
ZONE="$(firewall-cmd --get-default-zone 2>/dev/null || true)"

echo "Cleaning up Firecracker VM resources..."

# Stop file sharing first: rclone binds the veth IP, which dies below —
# leaving the unit running would restart-loop forever. Safe no-op if not set up.
"${SCRIPT_DIR}/nfs-share.sh" stop

# Kill processes gracefully first. Match the jailed child via its
# --config-file arg: a broad "firecracker.*${VM_ID}" would also SIGKILL
# unrelated processes like editors or tail on firecracker-vm1.log.
sudo pkill -f "firecracker.*--config-file" 2>/dev/null || true
sudo pkill -f "jailer.*--id ${VM_ID}" 2>/dev/null || true
sleep 3

# Force kill if still running
sudo pkill -9 -f "firecracker.*--config-file" 2>/dev/null || true
sudo pkill -9 -f "jailer.*--id ${VM_ID}" 2>/dev/null || true

# Reset terminal state (processes may leave it corrupted)
stty sane 2>/dev/null || true
tput reset 2>/dev/null || true

# Remove firewall rules for VM access
if [ -n "$ZONE" ]; then
    for PORT in $HOST_SERVICE_PORTS; do
        sudo firewall-cmd --zone="$ZONE" --remove-rich-rule="rule family=\"ipv4\" source address=\"${VETH_SUBNET}\" port port=\"${PORT}\" protocol=\"tcp\" accept" 2>/dev/null || true
    done
fi

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
    sudo rm -f "${HOST_IFACE_STATE}"
fi

# Restore the host's forwarding state to its pre-start value
if [ -f "${IP_FORWARD_STATE}" ]; then
    sudo sysctl -w "net.ipv4.ip_forward=$(cat "${IP_FORWARD_STATE}")" > /dev/null
    sudo rm -f "${IP_FORWARD_STATE}"
fi

# Unmount bind mounts before removing directory
# Order matters: unmount children first, then the private parent
sudo umount "${CHROOT_DIR}/overlay.ext4" 2>/dev/null || true
sudo umount "${CHROOT_DIR}/rootfs.ext4" 2>/dev/null || true
sudo umount "${CHROOT_DIR}" 2>/dev/null || true

# rm -rf through a still-live bind mount would delete the overlay's contents
if mountpoint -q "${CHROOT_DIR}/overlay.ext4" || mountpoint -q "${CHROOT_DIR}/rootfs.ext4" || mountpoint -q "${CHROOT_DIR}"; then
    echo "ERROR: ${CHROOT_DIR} is still mounted — firecracker or another process may hold it open."
    echo "Refusing to rm -rf (would delete overlay contents). Fix manually:"
    echo "  sudo pkill -9 -f 'firecracker.*--config-file' && sudo umount -l ${CHROOT_DIR}"
    exit 1
fi

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
