#!/bin/bash
# ============================================================
# Shared Configuration for Firecracker VM
# ============================================================
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
HOST_SERVICE_PORTS="8001"
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
RELEASE_DIR="release-v1.15.1-x86_64"
JAILER_BIN="jailer-v1.15.1-x86_64"
FC_BIN="firecracker-v1.15.1-x86_64"
KERNEL="${SCRIPT_DIR}/images/vmlinux-6.1.155"
BASE_ROOTFS="${SCRIPT_DIR}/base/rootfs.ext4"
OVERLAY_DIR="${SCRIPT_DIR}/overlays"
KEY_DIR="${SCRIPT_DIR}/keys"
# Default SSH key (base image key)
SSH_KEY="${KEY_DIR}/debian-trixie.id_rsa"
# Computed values
VETH_SUBNET=$(echo ${VETH_NS_IP} | awk -F. '{print $1"."$2"."$3".0/24"}')
JAILER="${SCRIPT_DIR}/${RELEASE_DIR}/${JAILER_BIN}"
FC_BINARY="${SCRIPT_DIR}/${RELEASE_DIR}/${FC_BIN}"
FC_BINARY_NAME="firecracker-v1.15.1-x86_64"
CHROOT_DIR="/srv/jailer/${FC_BINARY_NAME}/${VM_ID}/root"
