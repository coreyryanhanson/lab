# Firecracker Development Environment

A set of scripts for managing local Firecracker microVMs with overlay-based
persistence, network namespace isolation, and jailer security.

## Overview

This project provides a complete workflow for creating and running lightweight
virtual machines using [Firecracker](https://firecracker-microvm.github.io/).
The key feature is an **OverlayFS-based layering system** that keeps a base
rootfs read-only while storing all changes in a thin writable overlay. This
allows:

- Instant creation of new VM environments from a shared base image
- Persistent storage across reboots without duplicating the base
- Easy rollback by deleting the overlay
- Isolation between different VM environments

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                      Host                            │
│  ┌────────────────────────────────────────────────┐ │
│  │           Network Namespace (fc-vm1)           │ │
│  │  ┌──────────┐    ┌───────────┐                 │ │
│  │  │  veth_ns  │◄──►│   tap0    │                 │ │
│  │  │192.168.100.2   │ 172.16.0.1│                 │ │
│  │  └──────────┘    └─────┬─────┘                 │ │
│  │                         │                        │ │
│  │  ┌─────────────────────▼─────────────────────┐ │ │
│  │  │           Firecracker VM                   │ │ │
│  │  │                                            │ │ │
│  │  │   ┌─────────────────────────┐              │ │ │
│  │  │   │   OverlayFS (writable)  │              │ │ │
│  │  │   │   /overlay.ext4          │              │ │ │
│  │  │   ├─────────────────────────┤              │ │ │
│  │  │   │   Base rootfs (read-only)│              │ │ │
│  │  │   │   /rootfs.ext4           │              │ │ │
│  │  │   └─────────────────────────┘              │ │ │
│  │  │                                            │ │ │
│  │  │   eth0: 172.16.0.2/30                     │ │ │
│  │  └────────────────────────────────────────────┘ │ │
│  └────────────────────────────────────────────────┘ │
│        │                                             │
│  ┌─────▼──────┐                                      │
│  │  veth_host │                                      │
│  │192.168.100.1│                                      │
│  └────────────┘                                       │
│        │                                              │
│  [Host routing/NAT → Internet]                       │
└──────────────────────────────────────────────────────┘
```

### Overlay System

The VM boots with a custom `overlay-init` script that:

1. Mounts the overlay device (`vdb`) or falls back to tmpfs for ephemeral mode
2. Runs `e2fsck` on the overlay if it wasn't cleanly unmounted
3. Sets up an OverlayFS with the base rootfs as the lower (read-only) layer
4. Pivots the root filesystem to the overlay
5. Hands off to the real init system (systemd)

This means all changes during a session are written to the overlay. If you
install packages, modify configs, or create files, those changes persist in
`overlays/<name>.ext4`. The base image remains pristine.

### Networking

Each VM runs in its own network namespace with:

- A veth pair connecting the namespace to the host
- A tap device inside the namespace for the VM
- NAT and forwarding rules for internet access
- Guest network configuration via kernel boot arguments (no DHCP needed)

The guest receives its IP, gateway, and DNS through kernel command line
parameters, which are parsed by the `fcnet-setup.sh` service inside the VM.

## Prerequisites

- Linux with KVM support (`/dev/kvm` must be accessible)
- Firecracker binary (v1.15.1 or compatible)
- Jailer binary (matching Firecracker version)
- Root/sudo access
- Tools: `ip`, `iptables`, `jq`, `e2fsprogs`, `debootstrap`

### Checking KVM Access

```bash
lsmod | grep kvm
[ -r /dev/kvm ] && [ -w /dev/kvm ] && echo "OK" || echo "FAIL"
```

If access fails, add your user to the `kvm` group:

```bash
sudo usermod -aG kvm $USER
# Log out and back in for group changes to take effect
```

## Directory Structure

```
.
├── base/
│   ├── debian-trixie-rootfs/      # Debootstrap working directory (intermediate)
│   └── rootfs.ext4                # Base rootfs image (read-only)
├── images/
│   └── vmlinux-6.1.155            # Uncompressed kernel binary
├── keys/
│   ├── debian-trixie.id_rsa       # SSH private key (DO NOT COMMIT)
│   └── debian-trixie.id_rsa.pub  # SSH public key
├── release-v1.15.1-x86_64/
│   ├── firecracker-v1.15.1-x86_64
│   ├── jailer-v1.15.1-x86_64
│   └── ...                        # Other Firecracker release files
├── overlays/
│   ├── project-a.ext4             # Writable overlay for project-a
│   ├── project-a.base_checksum    # MD5 of base rootfs when overlay was created
│   └── ...                        # Other overlay images
├── config.sh                      # Shared configuration variables
├── init_base.sh                   # Build the base rootfs image
├── create_overlay.sh               # Create a new overlay
├── start.sh                       # Start a VM with an overlay
└── cleanup.sh                     # Stop VM and clean up resources
```

## Configuration

All settings are centralized in `config.sh`. Key variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `NETNS` | Network namespace name | `fc-vm1` |
| `VM_ID` | Jailer VM identifier | `vm1` |
| `VETH_HOST_IP` | Host-side veth IP | `192.168.100.1` |
| `VETH_NS_IP` | Namespace-side veth IP | `192.168.100.2` |
| `TAP_IP` | Tap device IP (VM gateway) | `172.16.0.1` |
| `VM_IP` | Guest VM IP address | `172.16.0.2` |
| `FC_MAC` | Guest MAC address | `06:00:AC:10:00:02` |
| `JAILER_UID` | User ID for jailer process | `1000` |
| `JAILER_GID` | Group ID for jailer process | `1000` |
| `KERNEL` | Path to kernel binary | `./images/vmlinux-6.1.155` |
| `BASE_ROOTFS` | Path to base rootfs image | `./base/rootfs.ext4` |

## Usage

### 1. Initialize the Base Image

This downloads the kernel and creates the base rootfs with Debian Trixie:

```bash
sudo ./init_base.sh
```

This will:
- Download the Firecracker kernel
- Run `debootstrap` for a minimal Debian Trixie install
- Install SSH, Python 3, Node.js, and common utilities
- Create SSH keys for root login
- Generate the ext4 base image at `base/rootfs.ext4`

**Note:** This step requires internet access and takes several minutes.

### 2. Create an Overlay

Each overlay is a writable layer on top of the base rootfs:

```bash
./create_overlay.sh my-project
```

This creates `overlays/my-project.ext4` (8G sparse file) and records the
base rootfs checksum for compatibility checking.

Overlays are thin — they only consume disk space as data is written. A fresh
overlay is approximately 2-3 MB on disk.

### 3. Start the VM

```bash
sudo ./start.sh my-project
```

This will:
- Verify the overlay checksum matches the current base rootfs
- Set up the network namespace and routing
- Bind-mount the base rootfs (read-only) and overlay (read-write)
- Generate the jailer configuration
- Start Firecracker inside the jailer
- Wait for SSH to become available

Once running, connect via SSH:

```bash
ssh -i keys/debian-trixie.id_rsa root@172.16.0.2
```

### 4. Stop the VM

From inside the VM:

```bash
reboot
# or
poweroff
```

Firecracker treats both as a clean shutdown.

From the host (if VM is unresponsive):

```bash
sudo ./cleanup.sh
```

This forcefully terminates the VM, removes network namespaces, and cleans up
iptables rules.

## Overlay Management

### Creating Overlays

```bash
./create_overlay.sh <name>
```

### Listing Overlays

```bash
ls overlays/*.ext4 | sed 's/overlays\///' | sed 's/\.ext4//'
```

### Installing Packages into an Overlay

The recommended approach is to boot the VM and install interactively:

```bash
# 1. Start VM with the overlay
sudo ./start.sh my-project

# 2. SSH in and install packages
ssh -i keys/debian-trixie.id_rsa root@172.16.0.2
apt-get install -y python3-pip nodejs npm

# 3. Reboot to save changes
reboot
```

All changes are written to the overlay file. The base rootfs remains untouched.

### Deleting an Overlay

```bash
sudo rm overlays/my-project.ext4 overlays/my-project.base_checksum
```

### Base Rootfs Compatibility

Each overlay records the MD5 checksum of the base rootfs it was created
against. If you rebuild the base image (re-run `init_base.sh`), existing
overlays will fail with a checksum mismatch error. You must either:

- Delete and recreate overlays (loses all data in the overlay)
- Manually update the checksum file (risk of filesystem corruption)

## Guest Software

The base rootfs includes:

- **SSH Server** — Root login with key-based authentication
- **Python 3** — With pip and venv support
- **Node.js** — Installed via nvm (LTS version)
- **uv** — Fast Python package manager by Astral
- **Common utilities** — curl, wget, git, build-essential, ca-certificates

### Network Configuration

Guest networking is configured automatically via the `fcnet-setup` systemd
service, which reads `vm_ip`, `vm_gw`, `vm_mask`, and `dns` from the kernel
command line.

To manually configure networking inside the guest:

```bash
ip addr add 172.16.0.2/30 dev eth0
ip link set eth0 up
ip route add default via 172.16.0.1 dev eth0
echo "nameserver 8.8.8.8" > /etc/resolv.conf
```

## Security Considerations

### Jailer Isolation

The VM runs inside a jailer chroot with:

- User/group isolation (UID/GID 1000 by default)
- Network namespace isolation
- Bind-mounted read-only base rootfs
- Private mount propagation

**Recommendation:** For enhanced security, use the seccomp filter included in
the Firecracker release:

```bash
# In start.sh, add to jailer command:
--seccomp-filter /path/to/seccomp-filter-v1.15.1-x86_64.json
```

### Overlay Integrity

The overlay-init script performs filesystem checks on boot:

1. Checks if the overlay was cleanly unmounted
2. Runs `e2fsck -p` for automatic repair if needed
3. Falls back to read-only mode if repair fails
4. Falls back to base rootfs (no overlay) if mount fails entirely

### Known Limitations

- **No resource limits** — VMs can consume unlimited CPU/memory on the host.
  Consider adding cgroup limits via the jailer configuration.
- **UID 1000** — May conflict with regular user accounts. Choose a different
  UID/GID if 1000 is in use on your system.
- **No MMDS** — The microvm metadata service is not configured. Add it if you
  need instance metadata.
- **No snapshot/restore** — Snapshots are not set up in this configuration.

## Troubleshooting

### VM won't start

Check the Firecracker log:

```bash
cat firecracker-vm1.log
```

### SSH connection refused

1. Wait longer — the VM may still be booting
2. Check if the VM process is running: `ps aux | grep firecracker`
3. Verify network namespace setup: `sudo ip netns exec fc-vm1 ip addr`

### Overlay checksum mismatch

This means you rebuilt the base rootfs after creating the overlay:

```bash
# Option 1: Recreate the overlay (loses data)
sudo rm overlays/my-project.ext4 overlays/my-project.base_checksum
./create_overlay.sh my-project

# Option 2: Update the checksum (risky)
md5sum base/rootfs.ext4 | cut -d' ' -f1 > overlays/my-project.base_checksum
```

### e2fsck errors on boot

The overlay-init script handles this automatically. If it fails, the VM will
fall back to booting from the read-only base rootfs. Check the serial console
output for details.

### Network not working in guest

Verify the network namespace:

```bash
sudo ip netns exec fc-vm1 ip addr
sudo ip netns exec fc-vm1 ping -c 3 172.16.0.1
```

If the namespace doesn't exist, the VM isn't running or wasn't started with
`start.sh`.

### Cleanup stuck resources

```bash
sudo ./cleanup.sh
```

If that doesn't work, manually clean up:

```bash
# Kill processes
sudo pkill -9 -f firecracker
sudo pkill -9 -f jailer

# Remove namespace
sudo ip netns del fc-vm1

# Remove veth
sudo ip link del fc-veth0

# Unmount bind mounts
sudo umount /srv/jailer/firecracker-v1.15.1-x86_64/vm1/root/rootfs.ext4
sudo umount /srv/jailer/firecracker-v1.15.1-x86_64/vm1/root/overlay.ext4
sudo umount /srv/jailer/firecracker-v1.15.1-x86_64/vm1/root

# Remove chroot
sudo rm -rf /srv/jailer/firecracker-v1.15.1-x86_64/vm1
```

## File Reference

### config.sh

Central configuration file sourced by all other scripts. Modify this to change
VM settings, paths, and network parameters.

### init_base.sh

Builds the base rootfs image from scratch:
- Downloads Firecracker-compatible kernel
- Runs debootstrap for Debian Trixie
- Installs system packages and utilities
- Configures SSH, networking, and overlay-init
- Generates ext4 image

**Requires:** sudo, debootstrap, internet access
**Output:** `images/vmlinux-*`, `base/rootfs.ext4`, `keys/debian-trixie.id_rsa`

### create_overlay.sh

Creates a new writable overlay on top of the base rootfs:
- Creates an 8G sparse ext4 image
- Pre-creates overlay directories for overlay-init
- Records base rootfs checksum for compatibility checking
- Sets ownership to jailer UID/GID

**Usage:** `./create_overlay.sh <name>`
**Output:** `overlays/<name>.ext4`, `overlays/<name>.base_checksum`

### start.sh

Starts a Firecracker VM with the specified overlay:
- Validates overlay compatibility
- Sets up network namespace with routing/NAT
- Prepares jailer chroot with bind mounts
- Generates jailer configuration
- Starts Firecracker daemon
- Waits for SSH availability

**Usage:** `sudo ./start.sh <overlay_name>`

### cleanup.sh

Stops the VM and cleans up all resources:
- Terminates Firecracker/jailer processes
- Removes network namespace and veth pair
- Cleans iptables rules
- Unmounts bind mounts
- Removes jailer chroot directory
- Resets overlay file ownership

**Usage:** `sudo ./cleanup.sh`
