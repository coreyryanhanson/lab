#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
[ -f "${SCRIPT_DIR}/.env" ] || { echo "Missing ${SCRIPT_DIR}/.env — run: cp .env.example .env"; exit 1; }
source "${SCRIPT_DIR}/.env"

# Refuse to rebuild while a VM is running: the truncate/mkfs below would replace
# the rootfs image firecracker holds open, corrupting the live guest.
if mountpoint -q "${CHROOT_DIR}" 2>/dev/null || ip netns list 2>/dev/null | grep -q "^${NETNS}"; then
	echo "ERROR: A VM appears to be running (netns ${NETNS} or jailer chroot mounted)."
	echo "Stop it first: sudo ./cleanup.sh"
	exit 1
fi

# Render the SearXNG unit into the build dir (gitignored); the tracked template keeps its placeholders
[ -n "${SEARXNG_HOST:-}" ] && [ -n "${SEARXNG_PORT:-}" ] || { echo "Set SEARXNG_HOST and SEARXNG_PORT in ${SCRIPT_DIR}/.env"; exit 1; }
mkdir -p "${SCRIPT_DIR}/base"
sed -e "s/SEARXNG_HOST_PLACEHOLDER/${SEARXNG_HOST}/g" -e "s/SEARXNG_PORT_PLACEHOLDER/${SEARXNG_PORT}/g" \
    "${SCRIPT_DIR}/config/searxng/searxng.service" > "${SCRIPT_DIR}/base/searxng.service"

ROOTFS_DIR="${SCRIPT_DIR}/base/debian-trixie-rootfs"
ROOTFS_IMG="${SCRIPT_DIR}/base/rootfs.ext4"
KERNEL_VERSION="6.1.188"
KERNEL_DEST="${SCRIPT_DIR}/images/vmlinux-${KERNEL_VERSION}"
# Pinned Firecracker CI kernel. Since the 2025/2026 upstream config refresh
# these prebuilt kernels include FUSE and the NFS v4 client, so no local
# kernel build is needed. The config is verified against the binary below.
KERNEL_URL="https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/20261007-f23a2136011e-0/x86_64/vmlinux-${KERNEL_VERSION}"

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
# Download prebuilt guest kernel (FUSE for sshfs and the NFS
# v4 client for the rw scratch share are both required; older
# prebuilt CI kernels lacked them)
# ============================================================
if [ ! -f "$KERNEL_DEST" ]; then
	echo "Downloading prebuilt Firecracker CI kernel ${KERNEL_VERSION}..."
	mkdir -p "$(dirname "$KERNEL_DEST")"
	# Download to a temp file and move into place, so a failed/partial
	# download never leaves a corrupt kernel that later runs would trust.
	curl -fsSL "$KERNEL_URL" -o "${KERNEL_DEST}.tmp"
	mv "${KERNEL_DEST}.tmp" "$KERNEL_DEST"
else
	echo "Prebuilt kernel already exists at $KERNEL_DEST"
fi

# Verify the config embedded in the binary (CONFIG_IKCONFIG=y) on every
# run: fail the build loudly if a future repoint loses FUSE or NFSv4,
# and never trust a kernel left behind by an earlier failed verification.
python3 - "$KERNEL_DEST" <<'PYEOF'
import gzip, sys

data = open(sys.argv[1], "rb").read()
i = data.find(b"IKCFG_ST")
if i == -1:
    sys.exit("kernel has no embedded config (IKCFG_ST missing)")
end = data.find(b"IKCFG_ED", i)
if end == -1:
    sys.exit("kernel embedded config is truncated (IKCFG_ED missing)")
config = gzip.decompress(data[i + len(b"IKCFG_ST"):end]).decode("utf-8", "replace")
required = ("CONFIG_FUSE_FS=y", "CONFIG_NFS_V4=y")
missing = [k for k in required if k not in config]
if missing:
    sys.exit("prebuilt kernel lacks required options: " + ", ".join(missing))
print("Kernel config OK:", ", ".join(required))
PYEOF

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

# A crashed run can leave these mounted (SIGKILL skips the EXIT trap);
# stacking a second mount would let the chown -R below recurse into the host
critical_mounts_left_behind() {
	for p in proc sys dev; do
		mountpoint -q "$ROOTFS_DIR/$p" && return 0
	done
	return 1
}

if critical_mounts_left_behind; then
	echo "ERROR: $ROOTFS_DIR/{proc,sys,dev} still mounted from a previous run."
	echo "Clean them up first (see rescue.md)."
	exit 1
fi

# Mount virtual filesystems for chroot operations
sudo mkdir -p "$ROOTFS_DIR/proc" "$ROOTFS_DIR/sys" "$ROOTFS_DIR/dev"
sudo mount -t proc proc "$ROOTFS_DIR/proc"
sudo mount -t sysfs sysfs "$ROOTFS_DIR/sys"
sudo mount -t devtmpfs devtmpfs "$ROOTFS_DIR/dev"

sudo chroot "$ROOTFS_DIR" /bin/bash -c '
    set -eo pipefail

    # Set root password
    echo "root:root" | chpasswd

    # Set hostname
    echo "firecracker" > /etc/hostname
    grep -q "127.0.1.1 firecracker" /etc/hosts || echo "127.0.1.1 firecracker" >> /etc/hosts

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
        libgtk-3-0 \
        nfs-common \
        sshfs

    # Generate locale
    sed -i "s/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/" /etc/locale.gen
    locale-gen
    echo "LANG=en_US.UTF-8" > /etc/default/locale

    systemctl enable ssh

    # Install herdr (terminal multiplexer); pipefail makes a failed
    # download fatal instead of piping an empty script into sh
    curl -fsSL https://herdr.dev/install.sh | sh

    # Set herdr as default terminal (guarded so re-runs do not append twice)
    if ! grep -q "Auto-start herdr as the default terminal" /root/.bashrc; then
        cat >> /root/.bashrc << HERDR_PROFILE

# Auto-start herdr as the default terminal
case "\$HERDR_ENV" in
  1) ;; # already inside a herdr pane, do nothing
  *) [ -t 0 ] && exec "\$HOME/.local/bin/herdr" ;;
esac
HERDR_PROFILE
    fi

    # Allow root login
    sed -i "s/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/" /etc/ssh/sshd_config
'

# ============================================================
# Install Python 3 + uv
# ============================================================
echo "Installing Python and uv..."

sudo chroot "$ROOTFS_DIR" /bin/bash -c '
    set -eo pipefail

    apt-get install -y python3 python3-pip python3-venv

    # Install uv
    curl -LsSf https://astral.sh/uv/install.sh | sh
    mv /root/.local/bin/uv /usr/local/bin/
    mv /root/.local/bin/uvx /usr/local/bin/ 2>/dev/null || true
'

# ============================================================
# Install nvm + Node.js
# ============================================================
echo "Installing nvm and Node.js..."

# Copy and run the nvm/Node.js install script inside the chroot
sudo cp "${SCRIPT_DIR}/config/chroot-scripts/install-nvm-node.sh" "${ROOTFS_DIR}/tmp/"
sudo chroot "$ROOTFS_DIR" /bin/bash /tmp/install-nvm-node.sh
sudo rm -f "${ROOTFS_DIR}/tmp/install-nvm-node.sh"

# ============================================================
# Add overlay-init script
# ============================================================
echo "Adding overlay-init script..."

sudo install -m 755 "${SCRIPT_DIR}/config/guest/overlay-init" "$ROOTFS_DIR/sbin/overlay-init"

# ============================================================
# Create mount points for overlay-init (CRITICAL)
# ============================================================
echo "Creating overlay mount points..."

sudo mkdir -p "$ROOTFS_DIR/overlay/root"
sudo mkdir -p "$ROOTFS_DIR/overlay/work"
sudo mkdir -p "$ROOTFS_DIR/rom"
sudo mkdir -p "$ROOTFS_DIR/mnt/library" "$ROOTFS_DIR/mnt/scrape"

# ============================================================
# Configure networking
# ============================================================
echo "Configuring network auto-setup..."

sudo install -m 755 "${SCRIPT_DIR}/config/guest/fcnet-setup.sh" "$ROOTFS_DIR/usr/local/bin/fcnet-setup.sh"

echo "Configuring fcnet-setup service..."

sudo install -m 644 "${SCRIPT_DIR}/config/guest/fcnet-setup.service" "$ROOTFS_DIR/etc/systemd/system/fcnet-setup.service"

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

# Bake the rclone SFTP private key into the base image so the VM can mount
# the read-only library without any key-copy step (the pubkey side is
# installed to the host by nfs-share.sh setup)
if [ ! -f "${KEY_DIR}/rclone_sftp_ed25519" ]; then
	echo "Generating rclone SFTP key..."
	ssh-keygen -t ed25519 -N "" -f "${KEY_DIR}/rclone_sftp_ed25519" -C "rag-reader-vm" -q
fi
sudo cp "${KEY_DIR}/rclone_sftp_ed25519" "$ROOTFS_DIR/root/.ssh/rclone_sftp_ed25519"
sudo chmod 600 "$ROOTFS_DIR/root/.ssh/rclone_sftp_ed25519"

# ============================================================
# Install Pi Coding Agent
# ============================================================
echo "Installing Pi Coding Agent..."

sudo chroot "$ROOTFS_DIR" /bin/bash -c '
    set -e

    export NVM_DIR="/root/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    npm install -g --ignore-scripts @earendil-works/pi-coding-agent
    echo "  Pi agent installed: $(pi --version 2>/dev/null || true)"

    # Install Pi packages (subagents, tools, skills)
    pi install npm:pi-subagents
    pi install npm:@juicesharp/rpiv-ask-user-question
    pi install npm:@juicesharp/rpiv-todo
    pi install npm:pi-lean-dimension
    pi install npm:pi-agents-init
    pi install npm:pi-file-injector
    pi install npm:pi-prompt-template-model
    pi install npm:pi-lens
    pi install npm:pi-intercom
    pi install npm:pi-tbox
    pi install npm:gnubrain
    pi install git:github.com/DietrichGebert/ponytail
    echo "  Pi packages installed: pi-subagents, rpiv-ask-user-question, rpiv-todo, pi-lean-dimension, pi-agents-init, pi-file-injector, pi-prompt-template-model, pi-lens, pi-intercom, pi-tbox, gnubrain, ponytail"
'

# ============================================================
# Install Pi configuration (auth, settings, models, extensions)
# ============================================================
echo "Setting up Pi config..."

sudo rm -rf "$ROOTFS_DIR/tmp/pi-config"
sudo cp -a "${SCRIPT_DIR}/config/pi" "$ROOTFS_DIR/tmp/pi-config"

sudo chroot "$ROOTFS_DIR" /bin/bash -c '
    set -e

    PI_DIR="$HOME/.pi/agent"
    mkdir -p "$PI_DIR/extensions"
    mkdir -p "$PI_DIR/prompts"

    [ -f /tmp/pi-config/auth.json ]     && cp /tmp/pi-config/auth.json "$PI_DIR/"
    [ -f /tmp/pi-config/settings.json ] && cp /tmp/pi-config/settings.json "$PI_DIR/"
    [ -f /tmp/pi-config/models.json ]   && cp /tmp/pi-config/models.json "$PI_DIR/"
    [ -d /tmp/pi-config/extensions ]    && cp -r /tmp/pi-config/extensions/* "$PI_DIR/extensions/"
    [ -d /tmp/pi-config/prompts ]       && cp -r /tmp/pi-config/prompts/* "$PI_DIR/prompts/"
'

sudo rm -rf "$ROOTFS_DIR/tmp/pi-config"
echo "  Pi config, auth, models, extensions, and prompts installed"

# ============================================================
# Install SearXNG (metasearch engine for agent web search)
# ============================================================
echo "Installing SearXNG..."

sudo mkdir -p "$ROOTFS_DIR/etc/searxng"
sudo cp "${SCRIPT_DIR}/config/searxng/settings.yml" "$ROOTFS_DIR/etc/searxng/"
sudo cp "${SCRIPT_DIR}/base/searxng.service" "$ROOTFS_DIR/etc/systemd/system/"

sudo chroot "$ROOTFS_DIR" /bin/bash -c '
    set -e

    # Create searxng system user (guard for re-runs after a partial build)
    id searxng >/dev/null 2>&1 || useradd --system --shell /bin/bash --home-dir /usr/local/searxng searxng

    # Clone SearXNG source (guard for re-runs after a partial build)
    [ -d /usr/local/searxng/searxng-src/.git ] || git clone --depth 1 https://github.com/searxng/searxng.git /usr/local/searxng/searxng-src

    # Create Python venv with uv and install SearXNG + Granian
    /usr/local/bin/uv venv /usr/local/searxng/searx-pyenv
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
# Playwright browser binaries (for pi-lean-portal)
# ============================================================
echo "Installing Playwright browser binaries..."

# pi-lean-dimension (installed above) pulls in pi-lean-portal, which depends on
# the `playwright` npm package. Playwright does NOT download browser binaries
# during npm install, so install them explicitly here.
sudo chroot "$ROOTFS_DIR" /bin/bash -c '
    set -e

    export NVM_DIR="/root/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    npx --yes playwright install --with-deps chromium firefox
'

echo "  Playwright Chromium + Firefox installed"

# ============================================================
# Inject environment variables into VM
# ============================================================
echo "Injecting environment variables into VM..."

# Write all non-comment lines from .env as exports into a profile script
sed -n '/^[A-Z_]/s/^/export /p' "${SCRIPT_DIR}/.env" |
	sudo tee "$ROOTFS_DIR/etc/profile.d/99-vm-env.sh" >/dev/null
sudo chmod 644 "$ROOTFS_DIR/etc/profile.d/99-vm-env.sh"
echo "  Environment variables written to /etc/profile.d/99-vm-env.sh"

# /etc/profile.d only loads for login shells, so interactive non-login shells
# (herdr panes, nested bash) would miss the env. Root's .bashrc covers those.
grep -q '99-vm-env.sh' "$ROOTFS_DIR/root/.bashrc" 2>/dev/null ||
	sudo tee -a "$ROOTFS_DIR/root/.bashrc" >/dev/null << 'BASHRCEOF'

# VM environment variables (API keys, model config)
source /etc/profile.d/99-vm-env.sh
BASHRCEOF

# Configure git inside the VM
sudo chroot "$ROOTFS_DIR" /bin/bash -c '
    set -e

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

if critical_mounts_left_behind; then
	echo "ERROR: $ROOTFS_DIR/{proc,sys,dev} still mounted; refusing to chown through a live mount."
	exit 1
fi
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
