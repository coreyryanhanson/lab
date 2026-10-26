#!/bin/bash
# ============================================================
# nfs-share.sh — On-demand file sharing for the Firecracker VM
# ============================================================
# Two paths, two mechanisms, each with server-side enforcement:
#
#   - Read-only media library: `rclone serve sftp --read-only`,
#     bound to the veth IP on port 2022. Any filesystem works
#     (exFAT hotplug volume included); all write ops are rejected
#     by the server. The guest sees the served path as SFTP '/'.
#
#   - Read-write scratch: NFSv4 export on port 2049 (all_squash).
#     Requires a POSIX filesystem (ext4) for ownership semantics.
#
# Ports are opened via HOST_SERVICE_PORTS in config.sh (2049 2022).
# The host's sshd (port 22) is NOT exposed to the VM.
#
# Run `start` AFTER `start.sh` — rclone binds to the veth IP, which
# only exists while the VM networking is up.
#
# Usage:
#   sudo ./nfs-share.sh setup    # one-time host config (idempotent)
#   sudo ./nfs-share.sh start    # start rclone + nfsd
#   sudo ./nfs-share.sh stop     # stop both (closes 2022 + 2049)
#   ./nfs-share.sh status
#   ./nfs-share.sh vm            # print the VM-side mount commands
#
# See nfs.md for the full guide.
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

# Host-specific values (media path, service user, squash uid) live in .env —
# see .env.example. Nothing in this file names a particular host or user.
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    source "${SCRIPT_DIR}/.env"
fi

fail() { echo "ERROR: $1" >&2; exit 1; }

# --- Read-only side (rclone serve sftp) ---
# Host path of the media library; served as the SFTP root. Any fs works.
RO_PATH="${NFS_RO_PATH:-}"
# RO_PORT comes from config.sh (must stay in HOST_SERVICE_PORTS there).
RO_USER="rag-reader"          # SFTP username (auth is key-only, no system account)
# Host account the rclone service runs as — it must be able to read the
# media files (udisks mounts them owned by this user).
SERVE_USER="${NFS_SERVE_USER:-}"
# Keypair lives under keys/ (gitignored); pubkey copied where the service
# can read it (/root is not readable by the service user). Renamed away
# from SSH_KEY to avoid shadowing config.sh's VM-login key.
RO_KEYPAIR="${SCRIPT_DIR}/keys/rclone_sftp_ed25519"
AUTHKEYS_FILE="/etc/rclone-vm-share/authorized_keys"
RO_UNIT="rclone-ro"

# --- Read-write scratch side (NFSv4) ---
RW_EXPORT="/srv/rag-scrape"
# Unprivileged host user all NFS requests are squashed to. The VM's
# root can claim any UID over AUTH_SYS NFS; all_squash neutralizes that.
SQUASH_USER="rag-scraper"
SQUASH_UID="${NFS_SQUASH_UID:-}"
# Client subnet as seen by the HOST. VM traffic leaves the netns
# MASQUERADEd, so the source is the veth subnet, NOT 172.16.0.2.
CLIENT_SUBNET="${VETH_SUBNET}"

NFS_UNIT="nfs-server"

# Ports this script serves must be firewalled open via config.sh; nothing
# else links them, and a mismatch fails silently at the guest.
for _PORT in "$RO_PORT" 2049; do
    [[ " $HOST_SERVICE_PORTS " == *" $_PORT "* ]] || fail "port ${_PORT} is missing from HOST_SERVICE_PORTS in config.sh — the VM firewall will block it"
done
unset _PORT

# NFS rw export needs POSIX filehandles and chown — exFAT/NTFS/FAT can't
# provide either. (The ro side doesn't use NFS, so it has no fs limits.)
require_rw_exportable_fs() {
    local DIR="$1" FSTYPE
    FSTYPE=$(findmnt -no FSTYPE --target "$DIR" 2>/dev/null || true)
    case "$FSTYPE" in
        exfat|ntfs|ntfs3|vfat|fuseblk)
            fail "$DIR is on a $FSTYPE filesystem, which cannot serve the rw NFS export (no chown, no POSIX ownership). Use an ext4 path for RW_EXPORT."
            ;;
    esac
}

# Host-specific sharing values are required by setup and start only; stop,
# status and vm are informative and work without them.
require_share_config() {
    [[ -n "$RO_PATH" ]] || fail "NFS_RO_PATH not set — add it to .env (see .env.example)"
    [[ -n "$SERVE_USER" ]] || fail "NFS_SERVE_USER not set — add it to .env (see .env.example)"
    [[ -n "$SQUASH_UID" ]] || fail "NFS_SQUASH_UID not set — add it to .env (see .env.example)"
}

require_installed() {
    command -v exportfs >/dev/null 2>&1 || fail "nfs-kernel-server not installed. Run: sudo apt install nfs-kernel-server"
    command -v rclone >/dev/null 2>&1 || fail "rclone not installed. Run: sudo apt install rclone"
    [[ -f /etc/exports ]] || fail "/etc/exports missing. Run: sudo ./nfs-share.sh setup"
    [[ -f "/etc/systemd/system/${RO_UNIT}.service" ]] || fail "rclone service unit missing. Run: sudo ./nfs-share.sh setup"
}

wait_for_port() {
    local PORT="$1"
    for _ in $(seq 1 20); do
        ss -tln | grep -q ":${PORT} " && return 0
        sleep 0.5
    done
    return 1
}

cmd_setup() {
    require_share_config
    # --- NFS rw scratch ---
    command -v exportfs >/dev/null 2>&1 || fail "nfs-kernel-server not installed — run: sudo apt install nfs-kernel-server, then re-run setup"
    command -v rclone >/dev/null 2>&1 || fail "rclone not installed — run: sudo apt install rclone, then re-run setup"
    id "$SERVE_USER" >/dev/null 2>&1 || fail "SERVE_USER '$SERVE_USER' does not exist — set it to the account owning the media files"

    # Dedicated unprivileged user for squashing. If the uid is taken by
    # a different account, exports would squash to the wrong user — fail loudly.
    if id -u "$SQUASH_UID" >/dev/null 2>&1 && [[ "$(id -un "$SQUASH_UID")" != "$SQUASH_USER" ]]; then
        fail "uid $SQUASH_UID is already taken by '$(id -un "$SQUASH_UID")' — pick a different SQUASH_UID"
    fi
    if id "$SQUASH_USER" >/dev/null 2>&1; then
        [[ "$(id -u "$SQUASH_USER")" == "$SQUASH_UID" ]] || fail "user $SQUASH_USER exists with uid $(id -u "$SQUASH_USER"), not SQUASH_UID $SQUASH_UID — reconcile the config"
        echo "User $SQUASH_USER already exists."
    else
        echo "Creating user $SQUASH_USER (uid $SQUASH_UID, no login)..."
        sudo useradd -u "$SQUASH_UID" -M -s /usr/sbin/nologin "$SQUASH_USER"
    fi

    sudo mkdir -p "$RW_EXPORT"
    require_rw_exportable_fs "$RW_EXPORT"
    sudo chown "$SQUASH_USER:$SQUASH_USER" "$RW_EXPORT"

    # NFSv4-only: single port 2049, no rpcbind/mountd ports needed.
    if grep -q 'nfs-share.sh managed' /etc/nfs.conf 2>/dev/null; then
        :  # already configured by a previous run
    elif grep -q '^\[nfsd\]' /etc/nfs.conf 2>/dev/null; then
        if ! grep -qE '^[[:space:]]*vers3[[:space:]]*=[[:space:]]*n' /etc/nfs.conf; then
            fail "/etc/nfs.conf already has an [nfsd] section without 'vers3=n'.
  Add 'vers3=n' under [nfsd] (and remove any 'vers3=y') — the export is NFSv4-only:
  without it rpcbind (111) and mountd (20048) listen and the firewall blocks the share."
        fi
        echo "/etc/nfs.conf already has [nfsd] with vers3=n."
    else
        echo "Appending NFSv4-only block to /etc/nfs.conf..."
        sudo tee -a /etc/nfs.conf > /dev/null << EOF

# --- nfs-share.sh managed block (do not edit below this line) ---
[nfsd]
  vers3=n
  vers4=y
EOF
    fi

    local RW_LINE
    RW_LINE="${RW_EXPORT} ${CLIENT_SUBNET}(rw,no_subtree_check,all_squash,anonuid=${SQUASH_UID},anongid=${SQUASH_UID})"
    if ! grep -qE "^${RW_EXPORT//\//\\/}\s" /etc/exports; then
        echo "Adding export line for ${RW_EXPORT} to /etc/exports..."
        echo "$RW_LINE" | sudo tee -a /etc/exports > /dev/null
    fi

    # --- rclone read-only library ---
    if [[ ! -f "$RO_KEYPAIR" ]]; then
        if [[ -f "$BASE_ROOTFS" ]]; then
            fail "no keypair at $RO_KEYPAIR, but a base image already exists.
  The guest bakes in the private key at build time, so a freshly generated one would not match.
  Options: rebuild the base, or generate the key and inject it into each overlay:
    ssh-keygen -t ed25519 -N '' -f $RO_KEYPAIR -C rag-reader-vm
    ./inject.sh <overlay_name> $RO_KEYPAIR /root/.ssh/rclone_sftp_ed25519"
        fi
        echo "Generating keypair: $RO_KEYPAIR"
        ssh-keygen -t ed25519 -N "" -f "$RO_KEYPAIR" -C "rag-reader-vm" -q
    fi
    # Public keys are not secrets; readable location so the service can load it
    sudo install -d -m 755 /etc/rclone-vm-share
    sudo install -m 644 "${RO_KEYPAIR}.pub" "$AUTHKEYS_FILE"

    echo "Writing systemd unit ${RO_UNIT}.service..."
    sudo tee "/etc/systemd/system/${RO_UNIT}.service" > /dev/null << EOF
# Managed by nfs-share.sh — regenerate with: sudo ./nfs-share.sh setup
[Unit]
Description=Read-only SFTP for Firecracker VM (rclone serve sftp)
After=network.target

[Service]
User=${SERVE_USER}
ExecStart=/usr/bin/rclone serve sftp --read-only --addr ${VETH_HOST_IP}:${RO_PORT} --user ${RO_USER} --authorized-keys ${AUTHKEYS_FILE} ${RO_PATH}
Restart=on-failure
RestartSec=2
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload

    # Clean up artifacts from the older sshd-based design, if present
    if [[ -f /etc/ssh/sshd_config.d/rag-reader.conf ]]; then
        echo "Removing legacy sshd drop-in (ro side now uses rclone)..."
        sudo rm /etc/ssh/sshd_config.d/rag-reader.conf
        systemctl is-active --quiet ssh 2>/dev/null && sudo systemctl reload ssh || true
    fi

    echo "One-time setup complete. Start sharing with: sudo ./nfs-share.sh start"
}

cmd_start() {
    require_share_config
    require_installed
    [[ -d "$RO_PATH" ]] || fail "Media volume not mounted at $RO_PATH — plug in / mount it first."
    # A failed start must not abort under set -e — wait_for_port reports it
    # with the journalctl hint below.
    sudo systemctl start "$RO_UNIT" || true
    wait_for_port "$RO_PORT" || fail "rclone not listening on $RO_PORT — check: journalctl -u ${RO_UNIT}"

    sudo systemctl start "$NFS_UNIT" || true
    sudo exportfs -ra
    wait_for_port 2049 || fail "nfsd not listening on 2049 — check: journalctl -u ${NFS_UNIT}"
    sudo exportfs -v 2>/dev/null | grep -qF "$RW_EXPORT" \
        || fail "RW export $RW_EXPORT is not active — run: sudo ./nfs-share.sh setup"

    echo "Sharing is up."
    echo "Active NFS exports:"
    sudo exportfs -v
    "$SCRIPT_DIR/nfs-share.sh" vm
}

cmd_stop() {
    # No require_installed: stopping an unconfigured host should be a no-op attempt
    sudo systemctl stop "$RO_UNIT" 2>/dev/null || true
    sudo systemctl stop "$NFS_UNIT" 2>/dev/null || true
    echo "Sharing stopped (ports 2022 and 2049 closed)."
}

cmd_status() {
    systemctl is-active --quiet "$RO_UNIT" 2>/dev/null && echo "rclone ro: RUNNING (port ${RO_PORT})" || echo "rclone ro: stopped"
    systemctl is-active --quiet "$NFS_UNIT" 2>/dev/null && { echo "nfsd: RUNNING (rw scratch)"; echo "Active exports:"; sudo exportfs -v; } || echo "nfsd: stopped"
}

cmd_vm() {
    echo "In the VM (both clients and the key are preinstalled in the base image):"
    echo "  sshfs -p ${RO_PORT} -o ro,reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,kernel_cache,cache=yes,entry_timeout=120,attr_timeout=120,compression=no,IdentityFile=/root/.ssh/rclone_sftp_ed25519,StrictHostKeyChecking=no ${RO_USER}@${VETH_HOST_IP}:/ /mnt/library"
    echo "  mount -t nfs4 ${VETH_HOST_IP}:${RW_EXPORT} /mnt/scrape"
    echo ""
    echo "The served path (${RO_PATH}) appears as / inside the sshfs mount."
}

case "${1:-}" in
    setup)  cmd_setup ;;
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    status) cmd_status ;;
    vm)     cmd_vm ;;
    *)
        echo "Usage: sudo ./nfs-share.sh {setup|start|stop|status|vm}"
        echo "  setup   one-time host configuration (users, keys, systemd unit, /etc/exports, NFSv4-only)"
        echo "  start   start rclone (ro) + nfsd (rw); run AFTER start.sh (needs the veth IP up)"
        echo "  stop    stop both (closes ports 2022 and 2049)"
        echo "  status  show service state and active exports"
        echo "  vm      print the VM-side mount commands"
        exit 1
        ;;
esac
