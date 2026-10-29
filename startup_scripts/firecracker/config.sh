#!/bin/bash
# ============================================================
# Shared Configuration for Firecracker VM
# ============================================================
# Sourced by every other script, so its variables are read elsewhere;
# the linter cannot see that and flags them all as unused.
# shellcheck disable=SC2034
# Network namespace and interfaces
NETNS="fc-vm1"
VETH_HOST="fc-veth0"
VETH_NS="fc-veth1"
VETH_HOST_IP="192.168.100.1"
VETH_NS_IP="192.168.100.2"
TAP_DEV="fc-tap0"
TAP_IP="172.16.0.1"
VM_IP="172.16.0.2"
VM_ROUTE_MASK="/32"
MASK="/30"
FC_MAC="06:00:AC:10:00:02"
# Host services accessible from VM
# 8001 llama.cpp | 6806 SiYuan | 2049 NFSv4 (rw scratch) | 2022 rclone sftp (ro library)
HOST_SERVICE_PORTS="8001 12315 6806 2049 2022"
# Port nfs-share.sh serves the read-only library on (rclone sftp). Must stay
# listed in HOST_SERVICE_PORTS or the VM firewall blocks it.
RO_PORT="2022"
# VM resources
VM_VCPUS=8
VM_MEM_MIB=16384
# Guest network config (passed via kernel boot args)
GUEST_IP="${VM_IP}"
GUEST_GW="${TAP_IP}"
GUEST_MASK="${MASK#*/}"  # Strip the leading / to get just the number (30)
# VM identification
VM_ID="vm1"
# Jailer UID/GID
JAILER_UID=1000
JAILER_GID=1000
# DNS configuration
PRIMARY_DNS="8.8.8.8"
SECONDARY_DNS="8.8.4.4"
# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FC_VERSION="v1.17.0"
RELEASE_DIR="release-${FC_VERSION}-x86_64"
JAILER_BIN="jailer-${FC_VERSION}-x86_64"
FC_BIN="firecracker-${FC_VERSION}-x86_64"
KERNEL="${SCRIPT_DIR}/images/vmlinux-6.1.188"
BASE_ROOTFS="${SCRIPT_DIR}/base/rootfs.ext4"
OVERLAY_DIR="${SCRIPT_DIR}/overlays"
KEY_DIR="${SCRIPT_DIR}/keys"
# Default SSH key (base image key)
SSH_KEY="${KEY_DIR}/debian-trixie.id_rsa"
# Computed values
VETH_SUBNET=$(echo ${VETH_NS_IP} | awk -F. '{print $1"."$2"."$3".0/24"}')
JAILER="${SCRIPT_DIR}/${RELEASE_DIR}/${JAILER_BIN}"
FC_BINARY="${SCRIPT_DIR}/${RELEASE_DIR}/${FC_BIN}"
FC_BINARY_NAME="${FC_BIN}"
CHROOT_DIR="/srv/jailer/${FC_BINARY_NAME}/${VM_ID}/root"
IP_FORWARD_STATE="/tmp/firecracker-${VM_ID}.ip_forward"
HOST_IFACE_STATE="/tmp/firecracker-${VM_ID}.iface"

# Shared helpers: single copies of logic every overlay script needs.
list_overlays() {
    local list
    list=$(ls -1 "${OVERLAY_DIR}/" 2>/dev/null | grep '\.ext4$' | sed 's/\.ext4$//')
    echo "${list:-  (none)}"
}

# Repair an overlay ext4 with a dirty journal (VM did not unmount cleanly).
# Set AUTO_REPAIR=true to skip the interactive prompt (extract.sh -y, inject.sh).
check_and_repair() {
    local img="$1"

    local fs_state
    fs_state=$(sudo dumpe2fs -h "$img" 2>/dev/null | grep "Filesystem state" | head -1 || true)

    if echo "$fs_state" | grep -q "not clean"; then
        echo "Overlay has a dirty journal (VM did not unmount cleanly)."
        if [ "$AUTO_REPAIR" = true ]; then
            echo "Auto-repairing with e2fsck..."
        else
            echo "To extract files, the journal must be replayed."
            echo ""
            echo "Options:"
            echo "  1. Re-run with -y to auto-repair"
            echo "  2. Manual repair: sudo e2fsck -y $img"
            echo ""
            read -p "Run e2fsck now? [y/N] " response
            if [[ ! "$response" =~ ^[Yy]$ ]]; then
                echo "Aborted."
                return 1
            fi
        fi

        echo "Running e2fsck -p (automatic repair)..."
        local rc=0
        sudo e2fsck -p "$img" || rc=$?
        # 0=clean, 1=errors corrected, 2=corrected (reboot suggested) are all success
        if [ "$rc" -ge 4 ]; then
            echo "WARNING: e2fsck could not fully repair (rc=$rc), trying full check..."
            rc=0
            sudo e2fsck -y "$img" || rc=$?
            if [ "$rc" -ge 4 ]; then
                echo "ERROR: Filesystem could not be repaired (rc=$rc)."
                return 1
            fi
        fi
        echo "Filesystem repaired."
    else
        echo "Filesystem is clean."
    fi
    return 0
}
