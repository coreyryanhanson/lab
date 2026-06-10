#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/.env"

# Substitute SearXNG host/port from .env into systemd service template
sed -i "s/SEARXNG_HOST_PLACEHOLDER/${SEARXNG_HOST}/g" "${SCRIPT_DIR}/config/searxng/searxng.service"
sed -i "s/SEARXNG_PORT_PLACEHOLDER/${SEARXNG_PORT}/g" "${SCRIPT_DIR}/config/searxng/searxng.service"

ARCH="$(uname -m)"
ROOTFS_DIR="${SCRIPT_DIR}/base/debian-trixie-rootfs"
ROOTFS_IMG="${SCRIPT_DIR}/base/rootfs.ext4"
KERNEL_DEST="${SCRIPT_DIR}/images/vmlinux-6.1.155"

# Cleanup trap: unmount virtual filesystems on script exit or error
# Placed here so ROOTFS_DIR is already defined (avoid unmounting host /proc)
cleanup_mounts() {
	local rc=$?
	if [ -n "${ROOTFS_DIR}" ]; then
		sudo umount "${ROOTFS_DIR}/proc" "${ROOTFS_DIR}/sys" "${ROOTFS_DIR}/dev" 2>/dev/null || true
	fi
	exit $rc
}
trap cleanup_mounts EXIT

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
	latest_kernel_key=$(curl "http://spec.ccfc.min.s3.amazonaws.com/?prefix=firecracker-ci/$CI_VERSION/$ARCH/vmlinux-&list-type=2" |
		grep -oP "(?<=<Key>)(firecracker-ci/$CI_VERSION/$ARCH/vmlinux-[0-9]+\.[0-9]+\.[0-9]{1,3})(?=</Key>)" |
		sort -V | tail -1)

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

# Mount virtual filesystems for chroot operations
sudo mkdir -p "$ROOTFS_DIR/proc" "$ROOTFS_DIR/sys" "$ROOTFS_DIR/dev"
sudo mount -t proc proc "$ROOTFS_DIR/proc"
sudo mount -t sysfs sysfs "$ROOTFS_DIR/sys"
sudo mount -t devtmpfs devtmpfs "$ROOTFS_DIR/dev"

sudo chroot "$ROOTFS_DIR" /bin/bash -c '
    # Set root password
    echo "root:root" | chpasswd

    # Set hostname
    echo "firecracker" > /etc/hostname
    echo "127.0.1.1 firecracker" >> /etc/hosts

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
        gnupg \
        locales \
        libgtk-3-0

    # Generate locale
    sed -i "s/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/" /etc/locale.gen
    locale-gen
    echo "LANG=en_US.UTF-8" > /etc/default/locale

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

# Copy and run the nvm/Node.js install script inside the chroot
sudo cp "${SCRIPT_DIR}/config/chroot-scripts/install-nvm-node.sh" "${ROOTFS_DIR}/tmp/"
sudo chroot "$ROOTFS_DIR" /bin/bash /tmp/install-nvm-node.sh
sudo rm -f "${ROOTFS_DIR}/tmp/install-nvm-node.sh"

# ============================================================
# Add overlay-init script
# ============================================================
echo "Adding overlay-init script..."

sudo tee "$ROOTFS_DIR/sbin/overlay-init" >/dev/null <<'OVERLAY_INIT'
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

sudo tee "$ROOTFS_DIR/usr/local/bin/fcnet-setup.sh" >/dev/null <<'NETSCRIPT'
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

sudo tee "$ROOTFS_DIR/etc/systemd/system/fcnet-setup.service" >/dev/null <<'SERVICE'
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
# Install OpenCode configuration (config + tools + utils + skills)
# ============================================================
echo "Setting up OpenCode config..."

# Copy full opencode config into chroot
sudo cp -a "${SCRIPT_DIR}/config/opencode" "$ROOTFS_DIR/tmp/opencode-config"

# Run the canonical install script (handles tools, utils, skills)
sudo chroot "$ROOTFS_DIR" /bin/bash -c '
    bash /tmp/opencode-config/install_skills.sh
    cp /tmp/opencode-config/config.json /root/.config/opencode/config.json
    cp /tmp/opencode-config/package.json /root/.config/opencode/package.json 2>/dev/null || true
'

# Install npm dependencies for tools (e.g. @opencode-ai/plugin)
sudo chroot "$ROOTFS_DIR" /bin/bash -c '
    export NVM_DIR="/root/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    cd /root/.config/opencode && [ -f package.json ] && npm install 2>/dev/null || true
'

# Clean up temp copy
sudo rm -rf "$ROOTFS_DIR/tmp/opencode-config"
sudo chmod 700 "$ROOTFS_DIR/root/.config"
echo "  OpenCode config, tools, utils, and skills installed"

# ============================================================
# Install Pi Coding Agent
# ============================================================
echo "Installing Pi Coding Agent..."

sudo chroot "$ROOTFS_DIR" /bin/bash -c '
    export NVM_DIR="/root/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    npm install -g --ignore-scripts @earendil-works/pi-coding-agent
    echo "  Pi agent installed: $(pi --version 2>/dev/null || true)"

    # Install Pi packages (subagents, tools, skills)
    pi install npm:pi-subagents
    pi install npm:@juicesharp/rpiv-ask-user-question
    pi install npm:@juicesharp/rpiv-todo
    pi install npm:pi-llama-cpp
    echo "  Pi packages installed: pi-subagents, rpiv-ask-user-question, rpiv-todo, pi-llama-cpp"
'

# ============================================================
# Install Pi configuration (auth, settings, models, extensions)
# ============================================================
echo "Setting up Pi config..."

sudo cp -a "${SCRIPT_DIR}/config/pi" "$ROOTFS_DIR/tmp/pi-config"

sudo chroot "$ROOTFS_DIR" /bin/bash -c '
    PI_DIR="$HOME/.pi/agent"
    mkdir -p "$PI_DIR/extensions"

    [ -f /tmp/pi-config/auth.json ]     && cp /tmp/pi-config/auth.json "$PI_DIR/"
    [ -f /tmp/pi-config/settings.json ] && cp /tmp/pi-config/settings.json "$PI_DIR/"
    [ -f /tmp/pi-config/models.json ]   && cp /tmp/pi-config/models.json "$PI_DIR/"
    [ -d /tmp/pi-config/extensions ]    && cp -r /tmp/pi-config/extensions/* "$PI_DIR/extensions/"
'

sudo rm -rf "$ROOTFS_DIR/tmp/pi-config"
echo "  Pi config, auth, models, and extensions installed"

# ============================================================
# Install SearXNG (metasearch engine for agent web search)
# ============================================================
echo "Installing SearXNG..."

sudo mkdir -p "$ROOTFS_DIR/etc/searxng"
sudo cp "${SCRIPT_DIR}/config/searxng/settings.yml" "$ROOTFS_DIR/etc/searxng/"
sudo cp "${SCRIPT_DIR}/config/searxng/searxng.service" "$ROOTFS_DIR/etc/systemd/system/"

sudo chroot "$ROOTFS_DIR" /bin/bash -c '
    # Create searxng system user
    useradd --system --shell /bin/bash --home-dir /usr/local/searxng searxng

    # Clone SearXNG source
    git clone --depth 1 https://github.com/searxng/searxng.git /usr/local/searxng/searxng-src

    # Create Python venv with uv and install SearXNG + Granian
    uv venv /usr/local/searxng/searx-pyenv
    # Build deps must be installed before editable install (searx/__init__.py imports msgspec at setup time)
    VIRTUAL_ENV=/usr/local/searxng/searx-pyenv /usr/local/bin/uv pip install setuptools wheel msgspec pyyaml typing-extensions pybind11
    VIRTUAL_ENV=/usr/local/searxng/searx-pyenv /usr/local/bin/uv pip install -e /usr/local/searxng/searxng-src --no-build-isolation
    VIRTUAL_ENV=/usr/local/searxng/searx-pyenv /usr/local/bin/uv pip install granian

    # Generate a random secret key
    SEARXNG_SECRET=$(openssl rand -hex 32)
    sed -i "s/ultrasecretkey/$SEARXNG_SECRET/g" /etc/searxng/settings.yml

    # Fix permissions
    chown -R searxng:searxng /usr/local/searxng /etc/searxng

    # Enable service
    systemctl enable searxng
'

echo "  SearXNG installed (listening on http://127.0.0.1:8888)"

# ============================================================
# Playwright + Invisible Playwright
# ============================================================
echo "Installing Playwright + Invisible Playwright..."

sudo chroot "$ROOTFS_DIR" /bin/bash -c '
    # Install Xvfb — needed by invisible_playwright headless mode
    apt-get install -y xvfb

    # Node.js Playwright (Chromium only) — installed as a local dep of the pi-browser extension
    export NVM_DIR="/root/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    EXT_DIR="$HOME/.pi/agent/extensions/pi-browser"
    if [ -f "$EXT_DIR/package.json" ]; then
        npm install --prefix "$EXT_DIR" 2>/dev/null || true
    fi
    # Install Chromium browser binary using the locally-installed playwright
    if [ -f "$EXT_DIR/node_modules/.bin/playwright" ]; then
        "$EXT_DIR/node_modules/.bin/playwright" install --with-deps chromium 2>/dev/null || true
        ln -sf "$EXT_DIR/node_modules/.bin/playwright" /usr/local/bin/playwright
    fi
'

echo "  Playwright + Chromium installed"

# Copy offline deps into chroot filesystem before installing invisible_playwright
OFFLINE_DEPS="${SCRIPT_DIR}/offline-deps"
if [ -d "$OFFLINE_DEPS" ]; then
	sudo cp -a "$OFFLINE_DEPS/invisible_playwright" "$ROOTFS_DIR/tmp/invisible_playwright_src"
	if [ -f "$OFFLINE_DEPS/firefox-7-patched.tar.gz" ]; then
		sudo cp "$OFFLINE_DEPS/firefox-7-patched.tar.gz" "$ROOTFS_DIR/tmp/"
	fi
fi

sudo chroot "$ROOTFS_DIR" /bin/bash -c '
    # Python invisible_playwright (patched Firefox for stealth)
    uv venv /opt/ipw-pyenv

    # Install from local source copy (offline-deps, no git clone needed)
    if [ -d /tmp/invisible_playwright_src ]; then
        cp -a /tmp/invisible_playwright_src /opt/invisible_playwright_src
        VIRTUAL_ENV=/opt/ipw-pyenv \
        /usr/local/bin/uv pip install -e /opt/invisible_playwright_src

        # Extract cached Firefox binary instead of fetching from GitHub Releases
        if [ -f /tmp/firefox-7-patched.tar.gz ]; then
            mkdir -p /root/.cache/invisible-playwright
            tar xzf /tmp/firefox-7-patched.tar.gz -C /root/.cache/invisible-playwright/
        else
            echo "WARNING: firefox-7-patched.tar.gz not found — stealth Firefox binary will be missing"
        fi

        # CLI symlink for discoverability
        ln -sf /opt/ipw-pyenv/bin/invisible_playwright /usr/local/bin/invisible_playwright
    else
        echo "NOTE: offline invisible_playwright source not found — skipping stealth Firefox installation"
        echo "  The pi-browser extension will still work with Node.js Playwright/Chromium"
        echo "  but stealth mode (Firefox) will not be available."
    fi
'

echo "  Invisible Playwright installed"

# ============================================================
# Inject environment variables into VM
# ============================================================
echo "Injecting environment variables into VM..."

# Write all non-comment lines from .env as exports into a profile script
sed -n '/^[A-Z_]/s/^/export /p' "${SCRIPT_DIR}/.env" |
	sudo tee "$ROOTFS_DIR/etc/profile.d/99-vm-env.sh" >/dev/null
sudo chmod 644 "$ROOTFS_DIR/etc/profile.d/99-vm-env.sh"
echo "  Environment variables written to /etc/profile.d/99-vm-env.sh"

# Configure git inside the VM
sudo chroot "$ROOTFS_DIR" /bin/bash -c '
    git config --global user.name "'"${GIT_NAME}"'"
    git config --global user.email "'"${GIT_EMAIL}"'"
    echo "  Git configured: '"${GIT_NAME}"' <'"${GIT_EMAIL}"'>"
'

# Unmount virtual filesystems before creating image
sudo umount "$ROOTFS_DIR/proc" "$ROOTFS_DIR/sys" "$ROOTFS_DIR/dev" 2>/dev/null || true

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
