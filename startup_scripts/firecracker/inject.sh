#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

usage() {
    echo "Usage: $0 <overlay_name> <host_path> <vm_path>"
    echo ""
    echo "Copy files from host into a Firecracker overlay (VM must be stopped)."
    echo ""
    echo "Arguments:"
    echo "  overlay_name    Name of the overlay"
    echo "  host_path       Source file/directory on the host"
    echo "  vm_path         Destination path inside the VM (must be absolute)"
    echo ""
    echo "Ownership is set to root:root by default. Use -u/-g to change."
    echo ""
    echo "Examples:"
    echo "  $0 my-project ./config.yaml /root/config.yaml"
    echo "  $0 my-project ./scripts/ /root/scripts/"
    echo "  $0 my-project ./data.csv /home/user/data.csv -u 1000 -g 1000"
    echo ""
    echo "Directory behavior:"
    echo "  /root/scripts/   → contents go INTO /root/scripts/"
    echo "  /root/scripts    → same as above (trailing slash optional)"
    echo ""
    echo "Available overlays:"
    ls -1 "${OVERLAY_DIR}/" 2>/dev/null | grep '\.ext4$' | sed 's/\.ext4$//' || echo "  (none)"
    exit 1
}

OVERLAY_NAME=""
HOST_PATH=""
VM_PATH=""
FILE_UID=0
FILE_GID=0

while [[ $# -gt 0 ]]; do
    case $1 in
        -u|--uid)
            FILE_UID="$2"
            shift 2
            ;;
        -g|--gid)
            FILE_GID="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            if [ -z "$OVERLAY_NAME" ]; then
                OVERLAY_NAME="$1"
            elif [ -z "$HOST_PATH" ]; then
                HOST_PATH="$1"
            elif [ -z "$VM_PATH" ]; then
                VM_PATH="$1"
            else
                echo "Error: Unknown argument: $1"
                usage
            fi
            shift
            ;;
    esac
done

if [ -z "$OVERLAY_NAME" ] || [ -z "$HOST_PATH" ] || [ -z "$VM_PATH" ]; then
    usage
fi

OVERLAY_PATH="${OVERLAY_DIR}/${OVERLAY_NAME}.ext4"

if [ ! -f "$OVERLAY_PATH" ]; then
    echo "ERROR: Overlay '$OVERLAY_NAME' not found"
    echo "Create it with: ./create_overlay.sh $OVERLAY_NAME"
    exit 1
fi

if [ ! -e "$HOST_PATH" ]; then
    echo "ERROR: Host path does not exist: $HOST_PATH"
    exit 1
fi

if [[ ! "$VM_PATH" =~ ^/ ]]; then
    echo "ERROR: VM path must be absolute (start with /)"
    echo "Example: /root/config.yaml"
    exit 1
fi

# Normalize: strip trailing slash (except for root /)
VM_PATH="${VM_PATH%/}"
if [ -z "$VM_PATH" ]; then
    VM_PATH="/"
fi

# Safety check
if mountpoint -q "/srv/jailer/${FC_BINARY_NAME}/${VM_ID}/root" 2>/dev/null; then
    echo "ERROR: Overlay is mounted by a running VM."
    echo "Stop the VM before injecting files: sudo ./cleanup.sh"
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
        echo "Auto-repairing with e2fsck..."
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

echo "Injecting into overlay: $OVERLAY_NAME"

# Determine what we're copying for display
if [ -d "$HOST_PATH" ]; then
    SOURCE_TYPE="directory"
else
    SOURCE_TYPE="file"
fi

echo "  Host:  $HOST_PATH ($SOURCE_TYPE)"
echo "  VM:    $VM_PATH"
echo "  Owner: ${FILE_UID}:${FILE_GID}"
echo ""

# Check and repair filesystem if needed
check_and_repair "$OVERLAY_PATH"

MOUNT_POINT=$(mktemp -d /tmp/fc-inject-XXXXXX)

cleanup() {
    sudo umount "$MOUNT_POINT" 2>/dev/null || true
    sudo rmdir "$MOUNT_POINT" 2>/dev/null || true
}
trap cleanup EXIT

# Mount read-write (we need write access for injection)
sudo mount -o loop "$OVERLAY_PATH" "$MOUNT_POINT"

UPPER_DIR="$MOUNT_POINT/root"

if ! sudo test -d "$UPPER_DIR"; then
    echo "ERROR: Overlay upper directory not found"
    echo "Boot the VM once before injecting to initialize the overlay structure."
    exit 1
fi

# Map VM path to overlay path
DEST_PATH="${UPPER_DIR}${VM_PATH}"

# Copy files based on source type
if [ -d "$HOST_PATH" ]; then
    # For directories: copy contents INTO destination
    # This avoids nested directories (e.g., /root/scripts/scripts/)
    echo "Creating directory: $VM_PATH"
    sudo mkdir -p "$DEST_PATH"

    echo "Copying directory contents..."
    sudo cp -a "$HOST_PATH"/. "$DEST_PATH"/
else
    # For files: create parent directory and copy file
    echo "Creating parent directory: $(dirname "$VM_PATH")"
    sudo mkdir -p "$(dirname "$DEST_PATH")"

    echo "Copying file..."
    sudo cp -a "$HOST_PATH" "$DEST_PATH"
fi

# Set ownership
sudo chown -R ${FILE_UID}:${FILE_GID} "$DEST_PATH"

# Sync to ensure data is written before unmounting
sync

echo ""
echo "Done!"
echo ""
echo "Start the VM to see changes: sudo ./start.sh $OVERLAY_NAME"
