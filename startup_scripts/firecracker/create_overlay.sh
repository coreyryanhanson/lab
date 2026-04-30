#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

OVERLAY_NAME="${1:-}"
if [ -z "$OVERLAY_NAME" ]; then
    echo "Usage: $0 <overlay_name>"
    echo ""
    echo "Creates a new overlay image for a project."
    echo "The overlay will be a thin writable layer on top of the base rootfs."
    echo ""
    echo "Existing overlays:"
    ls -1 "${OVERLAY_DIR}/" 2>/dev/null | sed 's/\.ext4$//' || echo "  (none)"
    exit 1
fi

OVERLAY_PATH="${OVERLAY_DIR}/${OVERLAY_NAME}.ext4"
CHECKSUM_PATH="${OVERLAY_DIR}/${OVERLAY_NAME}.base_checksum"

if [ -f "$OVERLAY_PATH" ]; then
    echo "ERROR: Overlay $OVERLAY_NAME already exists at $OVERLAY_PATH"
    echo "Delete it first if you want to recreate it."
    exit 1
fi

echo "Creating overlay: $OVERLAY_NAME"
echo "  Path: $OVERLAY_PATH"

mkdir -p "$OVERLAY_DIR"

# Create a sparse 8G file (only uses space as written)
truncate -s 8G "$OVERLAY_PATH"

# Format as ext4
sudo mkfs.ext4 -F "$OVERLAY_PATH" > /dev/null 2>&1

# Pre-create overlay directories needed by overlay-init
sudo mkdir -p /tmp/overlay-mount
sudo mount -o loop "$OVERLAY_PATH" /tmp/overlay-mount
sudo mkdir -p /tmp/overlay-mount/root
sudo mkdir -p /tmp/overlay-mount/work
sudo umount /tmp/overlay-mount
sudo rmdir /tmp/overlay-mount

# Set ownership so jailer user can write to the overlay
sudo chown ${JAILER_UID}:${JAILER_GID} "$OVERLAY_PATH"

# Record the base rootfs checksum this overlay was created against
BASE_CHECKSUM=$(md5sum "$BASE_ROOTFS" | cut -d' ' -f1)
echo "$BASE_CHECKSUM" > "$CHECKSUM_PATH"

echo ""
echo "Overlay created successfully!"
echo "  Base checksum: $BASE_CHECKSUM"
echo "  Owner: ${JAILER_UID}:${JAILER_GID} (jailer user)"
echo ""
echo "Note: Overlay files are owned by the jailer user."
echo "Use 'sudo rm' to delete overlays."
echo ""
echo "To install packages in this overlay:"
echo "  1. Start VM: ./start.sh $OVERLAY_NAME"
echo "  2. SSH in:   ssh -i ${SSH_KEY} root@${VM_IP}"
echo "  3. Install packages (they'll be written to the overlay)"
echo "  4. Reboot or poweroff to save changes"
echo ""
echo "Or use bake_overlay.sh to automate package installation."
