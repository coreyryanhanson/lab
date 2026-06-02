# AGENTS.md — Lab

Collection of shell scripts and reference notes. The main project is the Firecracker microVM manager under `startup_scripts/firecracker/`.

## Repo layout

- `startup_scripts/firecracker/` — OverlayFS-based Firecracker VM manager (primary focus)
- `startup_scripts/open-webui/` — Open WebUI + SearXNG via podman-compose
- `bash/common_commands/` — Reference markdown files for ffmpeg, podman, ssh, etc.

No tests, no linter, no typechecker, no CI. No `package.json` at root.

## Firecracker workflow (ordered)

All commands run from `startup_scripts/firecracker/`. Most require `sudo`.

1. `sudo ./init_base.sh` — Build base Debian Trixie rootfs. **Requires `.env` file** (copy from `.env.example`). Downloads kernel + runs debootstrap. Outputs `base/rootfs.ext4`, `images/vmlinux-*`, `keys/debian-trixie.id_rsa`.
2. `./create_overlay.sh <name>` — Create 8G sparse ext4 overlay. Creates `overlays/<name>.ext4` + checksum.
3. `sudo ./start.sh <name>` — Start VM. Sets up netns, iptables, firewall, jailer chroot, bind-mounts base+overlay, waits for SSH.
4. `ssh -i keys/debian-trixie.id_rsa root@172.16.0.2` — Connect to running VM.
5. `sudo ./cleanup.sh` — Kill VM, remove netns, iptables rules, unmount bind mounts, delete chroot.

## Key gotchas

- `init_base.sh` sources `.env` directly — script silently succeeds but `.env` must exist with all vars (even empty).
- Overlay checksum: `start.sh` validates overlay was created against current base. Rebuilding base invalidates existing overlays.
- `extract.sh` / `inject.sh` require VM to be **stopped**.
- `inject.sh` requires the overlay to have been **booted at least once** (overlay-init creates the `root/` and `work/` dirs inside the ext4).
- `cleanup.sh` unmounts in dependency order: overlay first, then rootfs, then chroot dir. Resets overlay ownership to current user.
- Network: guest IP is `172.16.0.2/30`, gateway `172.16.0.1`, host veth `192.168.100.1`. DNS from kernel boot args (`dns=8.8.8.8,8.8.4.4`).
- Host services reachable from VM **must** bind `0.0.0.0` (not `127.0.0.1`). Ports in `HOST_SERVICE_PORTS` in `config.sh`.
- OpenCode in VM connects to host llama.cpp at `http://192.168.100.1:8001/v1` (see `config/opencode/config.json`).
- Firecracker binary: `release-v1.15.1-x86_64/`. Jailer chroot at `/srv/jailer/firecracker-v1.15.1-x86_64/<vm_id>/root/`.
- `.gitignore` excludes `.env`, `keys/`, `secrets/`, plus build artifacts (`base/`, `extracted-*/`, `images/`, `overlays/`, `release*/`).
- Sparse overlay files show 8G apparent but small actual usage. Use `bash show_disk_usage.sh` to see both.

## Guest software (pre-installed in base image)

Python 3 + pip + uv, Node.js via nvm (LTS), OpenCode (`opencode-ai@latest`), Pi Coding Agent (`@earendil-works/pi-coding-agent`).
