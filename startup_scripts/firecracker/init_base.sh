#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

ARCH="$(uname -m)"
ROOTFS_DIR="${SCRIPT_DIR}/base/debian-trixie-rootfs"
ROOTFS_IMG="${SCRIPT_DIR}/base/rootfs.ext4"
KERNEL_DEST="${SCRIPT_DIR}/images/vmlinux-6.1.155"

echo "========================================"
echo "Building Firecracker Base Image"
echo "========================================"

# ============================================================
# Download kernel
# ============================================================
if [ ! -f "$KERNEL_DEST" ]; then
    echo "Downloading kernel..."
    release_url="https://github.com/firecracker-microvm/firecracker/releases"
    latest_version=$(basename $(curl -fsSLI -o /dev/null -w %{url_effective} ${release_url}/latest))
    CI_VERSION=${latest_version%.*}
    latest_kernel_key=$(curl "http://spec.ccfc.min.s3.amazonaws.com/?prefix=firecracker-ci/$CI_VERSION/$ARCH/vmlinux-&list-type=2" \
        | grep -oP "(?<=<Key>)(firecracker-ci/$CI_VERSION/$ARCH/vmlinux-[0-9]+\.[0-9]+\.[0-9]{1,3})(?=</Key>)" \
        | sort -V | tail -1)

    wget -O "$KERNEL_DEST" "https://s3.amazonaws.com/spec.ccfc.min/${latest_kernel_key}"
else
    echo "Kernel already exists at $KERNEL_DEST"
fi

# ============================================================
# Create rootfs with debootstrap
# ============================================================
if [ ! -d "$ROOTFS_DIR" ]; then
    echo "Running debootstrap (this takes a few minutes)..."
    sudo apt-get install -y debootstrap
    sudo debootstrap --arch=amd64 trixie "$ROOTFS_DIR" http://deb.debian.org/debian
else
    echo "Rootfs directory exists at $ROOTFS_DIR"
fi

# ============================================================
# Configure base system
# ============================================================
echo "Configuring base system..."

sudo chroot "$ROOTFS_DIR" /bin/bash -c '
    # Set root password
    echo "root:root" | chpasswd

    # Set hostname
    echo "firecracker" > /etc/hostname

    # Configure serial console
    systemctl enable serial-getty@ttyS0.service 2>/dev/null || true

    # Update and install base packages
    apt-get update
    apt-get install -y \
        openssh-server \
        curl \
        wget \
        git \
        build-essential \
        ca-certificates \
        e2fsprogs \
        gnupg

    systemctl enable ssh

    # Allow root login
    sed -i "s/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/" /etc/ssh/sshd_config
'

# ============================================================
# Install Python 3 + uv
# ============================================================
echo "Installing Python and uv..."

sudo chroot "$ROOTFS_DIR" /bin/bash -c '
    apt-get install -y python3 python3-pip python3-venv

    # Install uv
    curl -LsSf https://astral.sh/uv/install.sh | sh
    mv /root/.local/bin/uv /usr/local/bin/
    mv /root/.local/bin/uvx /usr/local/bin/ 2>/dev/null || true
'

# ============================================================
# Install nvm + Node.js + OpenCode
# ============================================================
echo "Installing nvm, Node.js, and OpenCode..."

sudo chroot "$ROOTFS_DIR" /bin/bash -c '
    # Install nvm
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash

    # Install latest LTS Node.js
    export NVM_DIR="/root/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    nvm install --lts

    # Explicitly set default alias (critical for non-interactive shells)
    nvm alias default "$(nvm current)"

    # Install OpenCode globally
    npm install -g opencode-ai@latest

    # Add nvm to profile for all users
    cat >> /etc/profile.d/nvm.sh << "NVMEOF"
export NVM_DIR="/root/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
NVMEOF
'

# ============================================================
# Add overlay-init script
# ============================================================
echo "Adding overlay-init script..."

sudo tee "$ROOTFS_DIR/sbin/overlay-init" > /dev/null << 'OVERLAY_INIT'
#!/bin/sh
# OverlayFS init script for Firecracker
# Requires: /overlay, /rom, /mnt directories in base rootfs
# Requires: overlay_root=vdb (or "ram") in kernel boot args

OVERLAY_DEVICE="${overlay_root}"

# Mount essential filesystems early
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# Wait for devices to settle
sleep 0.5

# Mount the overlay device or use tmpfs
if [ "$OVERLAY_DEVICE" = "ram" ]; then
    echo "Using tmpfs overlay (ephemeral)"
    mount -t tmpfs tmpfs /overlay
else
    echo "Mounting overlay device: /dev/$OVERLAY_DEVICE"

    # Wait for overlay device to appear
    MAX_WAIT=30
    WAITED=0
    while [ $WAITED -lt $MAX_WAIT ]; do
        if [ -b "/dev/$OVERLAY_DEVICE" ]; then
            break
        fi
        sleep 0.5
        WAITED=$((WAITED + 1))
    done

    if [ ! -b "/dev/$OVERLAY_DEVICE" ]; then
        echo "ERROR: Overlay device /dev/$OVERLAY_DEVICE not found after ${MAX_WAIT}s"
        echo "Available block devices:"
        ls -la /dev/vd* /dev/sd* 2>/dev/null || true
        echo "Falling back to read-only base rootfs"
        umount /proc /sys /dev 2>/dev/null || true
        exec /sbin/init
    fi

    # Check if filesystem needs checking (was it cleanly unmounted?)
    # dumpe2fs returns: "Filesystem state: clean" or "not clean"
    FS_STATE=$(dumpe2fs -h "/dev/$OVERLAY_DEVICE" 2>/dev/null | grep "Filesystem state" | head -1)
    NEEDS_FSCK=0

    if [ -z "$FS_STATE" ]; then
        echo "WARNING: Could not read filesystem state, running e2fsck..."
        NEEDS_FSCK=1
    elif echo "$FS_STATE" | grep -q "not clean"; then
        echo "Filesystem was not cleanly unmounted, running e2fsck..."
        NEEDS_FSCK=1
    elif echo "$FS_STATE" | grep -q "with errors"; then
        echo "Filesystem has errors, running e2fsck..."
        NEEDS_FSCK=1
    fi

    # Only run e2fsck if needed
    if [ $NEEDS_FSCK -eq 1 ]; then
        # -p = automatic repair
        # Exit codes: 0=clean, 1=errors corrected, 2=corrected+reboot, 4+=uncorrected
        e2fsck -p "/dev/$OVERLAY_DEVICE"
        E2FSCK_RC=$?

        if [ $E2FSCK_RC -ge 4 ]; then
            echo "WARNING: e2fsck could not fully repair overlay (rc=$E2FSCK_RC)"
            echo "Mounting read-only as precaution"
            MOUNT_OPTIONS="ro"
        elif [ $E2FSCK_RC -eq 2 ]; then
            echo "Filesystem errors corrected, reboot recommended (continuing)"
            MOUNT_OPTIONS="rw"
        elif [ $E2FSCK_RC -eq 1 ]; then
            echo "Filesystem errors corrected"
            MOUNT_OPTIONS="rw"
        else
            echo "Filesystem check passed"
            MOUNT_OPTIONS="rw"
        fi
    else
        echo "Filesystem is clean, skipping e2fsck"
        MOUNT_OPTIONS="rw"
    fi

    # Mount with appropriate options
    # errors=remount-ro protects against runtime corruption
    mount -o ${MOUNT_OPTIONS},errors=remount-ro "/dev/$OVERLAY_DEVICE" /overlay

    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to mount /dev/$OVERLAY_DEVICE"
        echo "Falling back to read-only base rootfs"
        umount /proc /sys /dev 2>/dev/null || true
        exec /sbin/init
    fi

    # Double-check overlay is writable before we set up OverlayFS
    if [ "$MOUNT_OPTIONS" = "ro" ] || ! touch /overlay/.writable_test 2>/dev/null; then
        echo "WARNING: Overlay mounted read-only, cannot create writable overlay"
        rm -f /overlay/.writable_test 2>/dev/null
        echo "Booting from base rootfs only (changes will not persist)"
        # Skip overlay and boot directly from base
        umount /overlay 2>/dev/null || true
        umount /proc /sys /dev 2>/dev/null || true
        exec /sbin/init
    fi
    rm -f /overlay/.writable_test
fi

# Ensure overlay directories exist
mkdir -p /overlay/root /overlay/work

# Set up OverlayFS (lowerdir=/ is the read-only base)
echo "Setting up OverlayFS..."
if ! mount -o noatime,lowerdir=/,upperdir=/overlay/root,workdir=/overlay/work \
    -t overlay overlay /mnt; then
    echo "ERROR: OverlayFS mount failed, falling back to base rootfs"
    umount /overlay 2>/dev/null || true
    umount /proc /sys /dev 2>/dev/null || true
    exec /sbin/init
fi

# Move mounts into new root before pivot
mkdir -p /mnt/overlay /mnt/rom /mnt/proc /mnt/sys /mnt/dev

mount --move /overlay /mnt/overlay
mount --move /proc /mnt/proc
mount --move /sys /mnt/sys
mount --move /dev /mnt/dev

# Pivot to the overlay root
echo "Pivoting to overlay root..."
cd /mnt
pivot_root . rom

# now / is the overlay, /rom is the base rootfs
cd /

# Ensure /etc/mtab is a symlink to /proc/mounts for systemd
ln -sf /proc/mounts /etc/mtab 2>/dev/null || true

# Execute real init system
echo "Starting init from overlay..."
exec /sbin/init
OVERLAY_INIT

sudo chmod +x "$ROOTFS_DIR/sbin/overlay-init"

# ============================================================
# Create mount points for overlay-init (CRITICAL)
# ============================================================
echo "Creating overlay mount points..."

sudo mkdir -p "$ROOTFS_DIR/overlay/root"
sudo mkdir -p "$ROOTFS_DIR/overlay/work"
sudo mkdir -p "$ROOTFS_DIR/rom"
sudo mkdir -p "$ROOTFS_DIR/mnt"

# ============================================================
# Configure networking
# ============================================================
echo "Configuring network auto-setup..."

sudo tee "$ROOTFS_DIR/usr/local/bin/fcnet-setup.sh" > /dev/null << 'NETSCRIPT'
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
NETSCRIPT

sudo chmod +x "$ROOTFS_DIR/usr/local/bin/fcnet-setup.sh"

sudo tee "$ROOTFS_DIR/etc/systemd/system/fcnet-setup.service" > /dev/null << 'SERVICE'
[Unit]
Description=Firecracker Network Setup
After=network.target local-fs.target
Wants=network.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 1
ExecStart=/usr/local/bin/fcnet-setup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE

sudo ln -sf /etc/systemd/system/fcnet-setup.service \
    "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/fcnet-setup.service"

# ============================================================
# Generate SSH keys
# ============================================================
echo "Setting up SSH access..."

if [ ! -f "${KEY_DIR}/debian-trixie.id_rsa" ]; then
    mkdir -p "${KEY_DIR}"
    ssh-keygen -f "${KEY_DIR}/debian-trixie.id_rsa" -N ""
fi

sudo mkdir -p "$ROOTFS_DIR/root/.ssh"
sudo cp "${KEY_DIR}/debian-trixie.id_rsa.pub" "$ROOTFS_DIR/root/.ssh/authorized_keys"
sudo chown -R root:root "$ROOTFS_DIR/root/.ssh"
sudo chmod 700 "$ROOTFS_DIR/root/.ssh"
sudo chmod 600 "$ROOTFS_DIR/root/.ssh/authorized_keys"

# ============================================================
# Install OpenCode configuration
# ============================================================
echo "Setting up OpenCode config..."

# Create directories
sudo mkdir -p "$ROOTFS_DIR/root/.config/opencode"
sudo mkdir -p "$ROOTFS_DIR/root/.secrets"

# Copy config template if it exists
if [ -f "${SCRIPT_DIR}/config/opencode-config.json" ]; then
    sudo cp "${SCRIPT_DIR}/config/opencode-config.json" \
            "$ROOTFS_DIR/root/.config/opencode/config.json"
    echo "  Config installed from local template"
else
    echo "  WARNING: No config/opencode-config.json found"
    echo "  OpenCode will use default settings"
fi

# Copy API key if it exists
if [ -f "${SCRIPT_DIR}/secrets/opencode-api-key" ]; then
    API_KEY=$(cat "${SCRIPT_DIR}/secrets/opencode-api-key" | tr -d '[:space:]')
    echo -n "$API_KEY" | sudo tee "$ROOTFS_DIR/root/.secrets/opencode-api-key" > /dev/null
    sudo chmod 600 "$ROOTFS_DIR/root/.secrets/opencode-api-key"
    sudo chown root:root "$ROOTFS_DIR/root/.secrets/opencode-api-key"
    echo "  API key installed"
else
    echo "  WARNING: No secrets/opencode-api-key found"
    echo "  You will need to set the API key manually after booting"
    echo "  Create: /root/.secrets/opencode-api-key"
fi

# Secure the directories
sudo chmod 700 "$ROOTFS_DIR/root/.secrets"
sudo chmod 700 "$ROOTFS_DIR/root/.config"

# ============================================================
# Create ext4 image
# ============================================================
echo "Creating rootfs image..."

sudo chown -R root:root "$ROOTFS_DIR"
truncate -s 8G "$ROOTFS_IMG"
sudo mkfs.ext4 -d "$ROOTFS_DIR" -F "$ROOTFS_IMG"

# ============================================================
# Verify
# ============================================================
echo ""
echo "Base image created successfully:"
[ -f "$KERNEL_DEST" ] && echo "  Kernel: $KERNEL_DEST" || echo "  ERROR: Kernel missing"
[ -f "$ROOTFS_IMG" ] && echo "  Rootfs: $ROOTFS_IMG" || echo "  ERROR: Rootfs missing"
[ -f "${KEY_DIR}/debian-trixie.id_rsa" ] && echo "  SSH Key: ${KEY_DIR}/debian-trixie.id_rsa" || echo "  ERROR: SSH key missing"
echo ""
echo "Create overlays with: ./create_overlay.sh <name>"
echo "Start VM with:        ./start.sh [overlay_name]"
