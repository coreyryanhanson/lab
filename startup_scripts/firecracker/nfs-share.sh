#!/bin/bash
# ============================================================
# nfs-share.sh — On-demand NFS server for the Firecracker VM
# ============================================================
# Serves two exports to the VM over NFSv4 (single port 2049,
# opened via HOST_SERVICE_PORTS in config.sh):
#
#   - $RO_EXPORT  read-only  (media library / transcriptions)
#   - $RW_EXPORT  read-write (scratch space for scrape downloads)
#
# nfsd is started/stopped on demand because the media typically
# lives on an external volume that is not always mounted.
#
# Usage:
#   sudo ./nfs-share.sh setup    # one-time host config (idempotent)
#   sudo ./nfs-share.sh start    # apply exports + start nfsd
#   sudo ./nfs-share.sh stop     # stop nfsd (closes port 2049)
#   ./nfs-share.sh status        # service state + active exports
#
# See nfs.md for the full guide.
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

# --- Export configuration (edit to match your layout) ---
# Read-only export: prefer a data subdirectory over a repo root —
# an export exposes EVERYTHING under the path, including .git/
RO_EXPORT="/root/bob/dharmabob_rag"
# Optional: source dir to bind-mount onto RO_EXPORT at start time (and
# unbind at stop). Use this when the export target is a hotplug volume
# mounted at a session-scoped path (e.g. /run/media/...) — do NOT put the
# bind in fstab: at boot the volume usually isn't there yet. The bind
# gives NFS a clean, shallow, stable export path.
RO_BIND_SRC=""
# Read-write scratch: keep OUTSIDE the ro export and outside the repo
RW_EXPORT="/srv/rag-scrape"
# Unprivileged host user all NFS requests are squashed to. The VM's
# root can claim any UID over AUTH_SYS NFS; all_squash neutralizes that.
SQUASH_USER="rag-scraper"
SQUASH_UID="1005"
# Client subnet as seen by the HOST. VM traffic leaves the netns
# MASQUERADEd, so the source is the veth subnet, NOT 172.16.0.2.
CLIENT_SUBNET="${VETH_SUBNET}"

NFS_UNIT="nfs-server"   # Debian trixie unit name; alias for nfs-kernel-server

fail() { echo "ERROR: $1" >&2; exit 1; }

# NFS export needs POSIX filehandles — exFAT/NTFS/FAT historically can't
# provide them, and none honor chown. Kernels >= 6.2 CAN export exfat
# read-only (no ownership semantics), so the ro export only warns for
# that case; everything else is a hard failure.
require_exportable_fs() {
    local DIR="$1" MODE="${2:-rw}" FSTYPE
    FSTYPE=$(findmnt -no FSTYPE --target "$DIR" 2>/dev/null || true)
    case "$FSTYPE" in
        exfat|ntfs3)
            if [[ "$MODE" == ro ]]; then
                echo "WARNING: $DIR is on $FSTYPE. Read-only export works on kernels >= 6.2"
                echo "         (no ownership semantics — fine with all_squash + world-readable perms)."
            else
                fail "$DIR is on $FSTYPE, which cannot serve the rw export (no chown, no POSIX ownership). Use an ext4 target for $RW_EXPORT."
            fi
            ;;
        vfat|fuseblk|ntfs)
            fail "$DIR is on a $FSTYPE filesystem, which cannot be NFS-exported.
       Either reformat the volume as ext4, or create an ext4 loopback image on it and export the loop mount (see nfs.md)."
            ;;
    esac
}

require_installed() {
    command -v exportfs >/dev/null 2>&1 || fail "nfs-kernel-server not installed. Run: sudo apt install nfs-kernel-server"
    [[ -f /etc/exports ]] || fail "/etc/exports missing. Run: sudo ./nfs-share.sh setup"
}

cmd_setup() {
    # /etc/exports is owned by the nfs-kernel-server package; refuse to
    # half-configure a host that doesn't have it installed yet.
    command -v exportfs >/dev/null 2>&1 || fail "nfs-kernel-server is not installed — run: sudo apt install nfs-kernel-server, then re-run setup"

    # Dedicated unprivileged user for squashing. If the uid is taken by
    # a different account, the exports would squash to the wrong user — fail loudly.
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

    # Scratch dir owned by the squash user
    sudo mkdir -p "$RW_EXPORT"
    require_exportable_fs "$RW_EXPORT" rw
    sudo chown "$SQUASH_USER:$SQUASH_USER" "$RW_EXPORT"

    # NFSv4-only: single port 2049, no rpcbind/mountd ports needed.
    if grep -q 'nfs-share.sh managed' /etc/nfs.conf 2>/dev/null; then
        :  # already configured by a previous run
    elif grep -q '^\[nfsd\]' /etc/nfs.conf 2>/dev/null; then
        echo "NOTE: /etc/nfs.conf already has an [nfsd] section."
        echo "      Make sure it contains: vers3=n"
    else
        echo "Appending NFSv4-only block to /etc/nfs.conf..."
        sudo tee -a /etc/nfs.conf > /dev/null << EOF

# --- nfs-share.sh managed block (do not edit below this line) ---
[nfsd]
  vers3=n
  vers4=y
EOF
    fi

    # Export entries (idempotent append)
    local RO_OPTS RO_LINE RW_LINE
    RO_OPTS="ro,no_subtree_check,all_squash,anonuid=${SQUASH_UID},anongid=${SQUASH_UID}"
    RW_OPTS="rw,no_subtree_check,all_squash,anonuid=${SQUASH_UID},anongid=${SQUASH_UID}"
    RO_LINE="${RO_EXPORT} ${CLIENT_SUBNET}(${RO_OPTS})"
    RW_LINE="${RW_EXPORT} ${CLIENT_SUBNET}(${RW_OPTS})"
    for LINE in "$RO_LINE" "$RW_LINE"; do
        local PATH_CHECK
        PATH_CHECK="${LINE%% *}"
        if ! grep -qE "^${PATH_CHECK//\//\\/]}\s" /etc/exports; then
            echo "Adding export line for ${PATH_CHECK} to /etc/exports..."
            echo "$LINE" | sudo tee -a /etc/exports > /dev/null
        fi
    done

    echo "One-time setup complete. Start sharing with: sudo ./nfs-share.sh start"
}

cmd_start() {
    require_installed
    if [[ -n "$RO_BIND_SRC" ]]; then
        [[ -d "$RO_BIND_SRC" ]] || fail "Media volume not mounted at $RO_BIND_SRC — plug in / mount the external volume first."
        [[ "$RO_BIND_SRC" != "$RO_EXPORT" ]] || fail "RO_BIND_SRC and RO_EXPORT must differ."
        # Rebind if the existing mount points at a stale superblock
        # (volume was unplugged without stop and remounted fresh).
        if mountpoint -q "$RO_EXPORT" && [[ "$(stat -c %d "$RO_EXPORT")" != "$(stat -c %d "$RO_BIND_SRC")" ]]; then
            sudo umount "$RO_EXPORT"
        fi
        mountpoint -q "$RO_EXPORT" || sudo mount --bind "$RO_BIND_SRC" "$RO_EXPORT"
    fi
    [[ -d "$RO_EXPORT" ]] || fail "Read-only export path $RO_EXPORT does not exist — mount the external media volume first."
    require_exportable_fs "$RO_EXPORT" ro
    require_exportable_fs "$RW_EXPORT" rw
    sudo systemctl start "$NFS_UNIT"
    sudo exportfs -ra
    # nfsd may take a moment to open the listener
    for _ in $(seq 1 20); do
        ss -tln | grep -q ':2049 ' && break
        sleep 0.5
    done
    ss -tln | grep -q ':2049 ' || fail "nfsd is not listening on 2049 — check: journalctl -u ${NFS_UNIT}"

    echo "NFS sharing is up."
    echo "Active exports:"
    sudo exportfs -v
    echo ""
    echo "In the VM:"
    echo "  mount -t nfs4 ${VETH_HOST_IP}:${RO_EXPORT} /mnt/library"
    echo "  mount -t nfs4 ${VETH_HOST_IP}:${RW_EXPORT} /mnt/scrape"
}

cmd_stop() {
    # No require_installed: stopping an unconfigured host should just be a no-op attempt
    sudo systemctl stop "$NFS_UNIT"
    if [[ -n "$RO_BIND_SRC" ]] && mountpoint -q "$RO_EXPORT"; then
        sudo umount "$RO_EXPORT"
    fi
    echo "NFS sharing stopped (port 2049 closed)."
}

cmd_status() {
    if systemctl is-active --quiet "$NFS_UNIT" 2>/dev/null; then
        echo "nfsd: RUNNING"
        echo "Active exports:"
        sudo exportfs -v
    else
        echo "nfsd: stopped"
    fi
}

case "${1:-}" in
    setup)  cmd_setup ;;
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    status) cmd_status ;;
    *)
        echo "Usage: sudo ./nfs-share.sh {setup|start|stop|status}"
        echo "  setup   one-time host configuration (user, dirs, /etc/exports, NFSv4-only)"
        echo "  start   apply exports and start nfsd (media volume must be mounted)"
        echo "  stop    stop nfsd (closes port 2049)"
        echo "  status  show service state and active exports"
        exit 1
        ;;
esac
