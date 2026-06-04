# AGENTS.md — Lab

Collection of shell scripts and reference notes. The main project is the Firecracker microVM manager under `startup_scripts/firecracker/`. Licensed under GPL-3.0 (see `LICENSE`).

## Repo layout

- `startup_scripts/firecracker/` — OverlayFS-based Firecracker VM manager (primary focus)
- `startup_scripts/firecracker/config/` — Guest VM configuration (Pi Coding Agent, OpenCode, SearXNG, chroot scripts)
- `startup_scripts/open-webui/` — Open WebUI + SearXNG via podman-compose
- `bash/common_commands/` — Reference markdown files for ffmpeg, pdftk, podman, ssh, etc.

No tests, no linter, no typechecker, no CI. No `package.json` at repo root.

## Firecracker workflow (ordered)

All commands run from `startup_scripts/firecracker/`. Most require `sudo`.

1. `sudo ./init_base.sh` — Build base Debian Trixie rootfs. **Requires `.env` file** (copy from `.env.example`). Downloads kernel + runs debootstrap. Outputs `base/rootfs.ext4`, `images/vmlinux-*`, `keys/debian-trixie.id_rsa`.
2. `./create_overlay.sh <name>` — Create 8G sparse ext4 overlay. Creates `overlays/<name>.ext4` + checksum.
3. `sudo ./start.sh <name>` — Start VM. Sets up netns, iptables, firewall, jailer chroot, bind-mounts base+overlay, waits for SSH.
4. `ssh -i keys/debian-trixie.id_rsa root@172.16.0.2` — Connect to running VM.
5. `sudo ./cleanup.sh` — Kill VM, remove netns, iptables rules, unmount bind mounts, delete chroot.

## Key gotchas

- `init_base.sh` sources `.env` directly — script silently succeeds but `.env` must exist with all vars (even empty).
- `init_base.sh` can leave virtual filesystems mounted if it crashes mid-build — see `rescue.md` for manual recovery steps and the cleanup trap fix.
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

## Guest VM configuration (`config/`)

### `config/pi/` — Pi Coding Agent

- `auth.json` — API key config (references `$VENICE_API_KEY`)
- `models.json` — Provider/model definitions (currently local-llama pointing to host llama.cpp)
- `settings.json` — Default provider, model, thinking level

#### `config/pi/extensions/` — Pi extensions (loaded into guest VM)

- **pi-browser** — Full browser automation (10 tools: navigate, snapshot, click, type, scroll, screenshot, get-images, back, press, console). Three backends: HTTP fetch (static), Playwright Chromium (JS), stealth Firefox (bot-protected). Status bar integration + `/browser-status` command.
- **opencode-zen** — Registers 4 free Zen models (deepseek-v4-flash-free, mimo-v2.5-free, nemotron-3-super-free, big-pickle) as a custom provider. No API key needed.
- **searxng-search** — Web search via local SearXNG instance. Supports query, count, language, safesearch, time_range, category, engines filters. Startup health check + `/searxng-status` command.
- **venice-ai** — Dynamically fetches and registers all Venice AI private text models as a provider. Requires `VENICE_API_KEY`.

### `config/opencode/` — OpenCode

- `config.json` — OpenCode configuration
- `package.json` — Plugin dependency
- `install_skills.sh` — Installer script that copies tools, utils, and skills to `~/.config/opencode/`
- `tools/` — 3 TypeScript tools:
  - `image-describe.ts` — Vision LLM image description
  - `image-transcribe.ts` — Vision LLM image transcription
  - `search.ts` — SearXNG web search tool
- `utils/` — Shared utilities:
  - `vision-api.ts` — Venice AI vision API helper (base64 encoding, file resolution, API key management)
- `skills/` — 2 vision skills:
  - `image-describe/SKILL.md` — Image description (alt-text, artistic, technical styles)
  - `image-transcribe/SKILL.md` — Image text transcription

### `config/searxng/` — SearXNG service

- `searxng.service` — systemd unit file (granian WSGI server)
- `settings.yml` — Instance settings (JSON format enabled, port 8888)

### `config/chroot-scripts/` — Base image build scripts

- `install-nvm-node.sh` — Installs nvm, Node.js LTS, OpenCode, and creates `/etc/profile.d/nvm.sh`. Run during `init_base.sh` debootstrap.

## Guest software (pre-installed in base image)

Python 3 + pip + uv, Node.js via nvm (LTS), OpenCode (`opencode-ai@latest` with vision tools and skills), Pi Coding Agent (`@earendil-works/pi-coding-agent` with pi-browser, opencode-zen, searxng-search, and venice-ai extensions).
