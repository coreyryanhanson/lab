#!/bin/bash
# Firecracker network auto-configuration
# Reads all settings from kernel boot args:
#   vm_ip=172.16.0.2  vm_gw=172.16.0.1  vm_mask=30  dns=8.8.8.8,8.8.4.4

INTERFACE=""
MAX_WAIT=30
WAITED=0

while [ $WAITED -lt $MAX_WAIT ]; do
    if ip link show eth0 > /dev/null 2>&1; then
        INTERFACE="eth0"
        break
    fi
    INTERFACE=$(ip link show | grep -E 'ens|enp' | grep -v lo | awk -F: '{print $2}' | head -1 | tr -d ' ')
    if [ -n "$INTERFACE" ]; then
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done

if [ -z "$INTERFACE" ]; then
    echo "ERROR: No network interface found after ${MAX_WAIT}s"
    exit 1
fi

# Parse kernel command line
CMDLINE=$(cat /proc/cmdline)

VM_IP=$(echo "$CMDLINE" | tr ' ' '\n' | grep '^vm_ip=' | cut -d= -f2)
VM_GW=$(echo "$CMDLINE" | tr ' ' '\n' | grep '^vm_gw=' | cut -d= -f2)
VM_MASK=$(echo "$CMDLINE" | tr ' ' '\n' | grep '^vm_mask=' | cut -d= -f2)
DNS_ARGS=$(echo "$CMDLINE" | tr ' ' '\n' | grep '^dns=' | cut -d= -f2)

# Fallback defaults (should never be needed if kernel args are set)
VM_IP="${VM_IP:-172.16.0.2}"
VM_GW="${VM_GW:-172.16.0.1}"
VM_MASK="${VM_MASK:-30}"

echo "Configuring interface $INTERFACE..."
ip link set $INTERFACE up
ip addr add ${VM_IP}/${VM_MASK} dev $INTERFACE
ip route add default via ${VM_GW} dev $INTERFACE

# DNS configuration from kernel args (format: dns=8.8.8.8,8.8.4.4)
if [ -n "$DNS_ARGS" ]; then
    echo "$DNS_ARGS" | tr ',' '\n' | while read server; do
        echo "nameserver $server"
    done > /etc/resolv.conf
    echo "DNS configured from kernel args: $DNS_ARGS"
else
    cat > /etc/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF
    echo "DNS configured from defaults"
fi

echo "Network configured: IP=${VM_IP}/${VM_MASK} GW=${VM_GW} on $INTERFACE"
