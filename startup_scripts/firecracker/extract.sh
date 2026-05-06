#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

usage() {
    echo "Usage: $0 <overlay_name> <vm_path> [host_destination]"
    echo ""
    echo "Extract files from a Firecracker overlay (VM must be stopped)."
    echo "Only copies overlay-layer files — base rootfs is ignored."
    echo ""
    echo "Arguments:"
    echo "  overlay_name        Name of the overlay"
    echo "  vm_path             Absolute path inside the VM (e.g., /root/output.csv)"
    echo "  host_destination    Where to copy on host (default: ./extracted-<name>/)"
    echo ""
    echo "Options:"
    echo "  -l, --list          List changed files instead of extracting"
    echo "  -y, --yes           Automatically repair filesystem if dirty"
    echo ""
    echo "Examples:"
    echo "  $0 my-project /root/output.csv"
    echo "  $0 my-project /root/scraped-data/"
    echo "  $0 my-project /root/results/ ~/backups/results/"
    echo "  $0 my-project --list"
    echo "  $0 my-project --list -y    (auto-repair if dirty)"
    echo ""
    echo "Available overlays:"
    ls -1 "${OVERLAY_DIR}/" 2>/dev/null | grep '\.ext4$' | sed 's/\.ext4$//' || echo "  (none)"
    exit 1
}

OVERLAY_NAME=""
VM_PATH=""
DEST_DIR=""
MODE="extract"
AUTO_REPAIR=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -l|--list)
            MODE="list"
            shift
            ;;
        -y|--yes)
            AUTO_REPAIR=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            if [ -z "$OVERLAY_NAME" ]; then
                OVERLAY_NAME="$1"
            elif [ -z "$VM_PATH" ]; then
                VM_PATH="$1"
            elif [ -z "$DEST_DIR" ]; then
                DEST_DIR="$1"
            else
                echo "Error: Unknown argument: $1"
                usage
            fi
            shift
            ;;
    esac
done

OVERLAY_PATH="${OVERLAY_DIR}/${OVERLAY_NAME}.ext4"

if [ ! -f "$OVERLAY_PATH" ]; then
    echo "ERROR: Overlay '$OVERLAY_NAME' not found"
    echo "Create it with: ./create_overlay.sh $OVERLAY_NAME"
    exit 1
fi

# ============================================================
# Helper: Check and repair ext4 filesystem
# ============================================================
check_and_repair() {
    local img="$1"

    local fs_state
    fs_state=$(sudo dumpe2fs -h "$img" 2>/dev/null | grep "Filesystem state" | head -1 || true)

    if echo "$fs_state" | grep -q "not clean"; then
        echo "Overlay has a dirty journal (VM did not unmount cleanly)."
        echo ""

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
        sudo e2fsck -p "$img" || {
            echo "WARNING: e2fsck returned errors, trying full check..."
            sudo e2fsck -y "$img"
        }
        echo "Filesystem repaired."
    else
        echo "Filesystem is clean."
    fi
    return 0
}

# ============================================================
# Helper: Mount overlay safely (read-write for journal, then read-only)
# ============================================================
mount_overlay() {
    local img="$1"
    local mount_point="$2"

    # Mount read-write to replay journal
    sudo mount -o loop "$img" "$mount_point"

    # Immediately remount read-only
    sudo mount -o remount,ro "$mount_point"
}

# ============================================================
# List mode
# ============================================================
if [ "$MODE" = "list" ]; then
    echo "Overlay: $OVERLAY_NAME"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    check_and_repair "$OVERLAY_PATH" || exit 1

    MOUNT_POINT=$(mktemp -d /tmp/fc-extract-XXXXXX)

    cleanup() {
        sudo umount "$MOUNT_POINT" 2>/dev/null || true
        sudo rmdir "$MOUNT_POINT" 2>/dev/null || true
    }
    trap cleanup EXIT

    mount_overlay "$OVERLAY_PATH" "$MOUNT_POINT"

    UPPER_DIR="$MOUNT_POINT/root"

    if ! sudo test -d "$UPPER_DIR"; then
        echo "ERROR: Overlay upper directory not found at /root/"
        echo "This overlay may not have been used with overlay-init."
        exit 1
    fi

    echo "Changed files:"
    echo "──────────────"
    sudo find "$UPPER_DIR" -mindepth 1 \( -type f -o -type l \) -printf '%P\n' | sort
    echo ""

    echo "Changed directories:"
    echo "─────────────────────"
    sudo find "$UPPER_DIR" -mindepth 1 -type d -printf '%P\n' | sort
    echo ""

    WHITEOUT_COUNT=$(sudo find "$UPPER_DIR" -name '.wh.*' 2>/dev/null | wc -l)
    if [ "$WHITEOUT_COUNT" -gt 0 ]; then
        echo "Deleted from base (whiteout files):"
        echo "─────────────────────────────────────"
        sudo find "$UPPER_DIR" -name '.wh.*' -printf '%P\n' | sort
    fi

    exit 0
fi

# ============================================================
# Extract mode
# ============================================================

if [ -z "$VM_PATH" ]; then
    echo "ERROR: VM path is required"
    echo ""
    usage
fi

# Default destination
if [ -z "$DEST_DIR" ]; then
    DEST_DIR="${SCRIPT_DIR}/extracted-${OVERLAY_NAME}"
fi

# VM path must be absolute
if [[ ! "$VM_PATH" =~ ^/ ]]; then
    echo "ERROR: VM path must be absolute (start with /)"
    echo "Example: /root/output.csv"
    exit 1
fi

# Safety check
if mountpoint -q "/srv/jailer/${FC_BINARY_NAME}/${VM_ID}/root" 2>/dev/null; then
    echo "ERROR: Overlay is mounted by a running VM."
    echo "Stop the VM first: sudo ./cleanup.sh"
    exit 1
fi

echo "Extracting: $VM_PATH"
echo "From overlay: $OVERLAY_NAME"
echo "To: $DEST_DIR"
echo ""

check_and_repair "$OVERLAY_PATH" || exit 1

MOUNT_POINT=$(mktemp -d /tmp/fc-extract-XXXXXX)

cleanup() {
    sudo umount "$MOUNT_POINT" 2>/dev/null || true
    sudo rmdir "$MOUNT_POINT" 2>/dev/null || true
}
trap cleanup EXIT

mount_overlay "$OVERLAY_PATH" "$MOUNT_POINT"

# Overlay upper directory is at /root/ inside the ext4
UPPER_DIR="$MOUNT_POINT/root"

if ! sudo test -d "$UPPER_DIR"; then
    echo "ERROR: Overlay upper directory not found"
    echo "This overlay may not have been used with overlay-init."
    exit 1
fi

# Map VM path to overlay path
SOURCE_PATH="${UPPER_DIR}${VM_PATH}"

if ! sudo test -e "$SOURCE_PATH"; then
    echo "ERROR: '$VM_PATH' not found in overlay layer"
    echo ""
    echo "This means the file either:"
    echo "  1. Was never created/modified in this overlay"
    echo "  2. Exists only in the base rootfs (not the overlay)"
    echo ""
    echo "Contents of parent directory in overlay:"
    echo "──────────────────────────────────────"
    sudo ls -la "$(dirname "$SOURCE_PATH")" 2>/dev/null || echo "(parent does not exist)"
    exit 1
fi

# Create destination
mkdir -p "$DEST_DIR"

# Copy the file or directory
sudo cp -a "$SOURCE_PATH" "$DEST_DIR/"

# Fix ownership
CURRENT_USER=$(id -u)
CURRENT_GROUP=$(id -g)
sudo chown -R ${CURRENT_USER}:${CURRENT_GROUP} "$DEST_DIR"

# Show result
echo ""
echo "Done!"
echo ""

# Check the destination (owned by current user, no permission issues)
EXTRACTED_NAME=$(basename "$VM_PATH")
if [ -d "${DEST_DIR}/${EXTRACTED_NAME}" ]; then
    echo "Extracted directory: ${EXTRACTED_NAME}/"
    FILE_COUNT=$(find "$DEST_DIR" -type f | wc -l)
    find "$DEST_DIR" -type f | head -20 | sed "s|^${DEST_DIR}|."
    if [ "$FILE_COUNT" -gt 20 ]; then
        echo "... and $((FILE_COUNT - 20)) more files"
    fi
else
    echo "Extracted file: ${EXTRACTED_NAME}"
    ls -la "$DEST_DIR/"
fi
