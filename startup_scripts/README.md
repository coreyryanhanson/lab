# Startup Scripts

Scripts to expedite the starting of certain command line only programs that may or may not require additional services for full functionality.

## Directories

- **firecracker/** — OverlayFS-based Firecracker microVM manager with jailer isolation. Includes:
  - Core scripts: `init_base.sh`, `create_overlay.sh`, `start.sh`, `cleanup.sh`, `extract.sh`, `inject.sh`
  - `config/pi/` — Pi Coding Agent configuration (models, auth, settings) and in-tree extensions (opencode-zen, venice-ai); browser + search via the `pi-lean-dimension` Pi package
  - `config/opencode/` — OpenCode configuration with vision tools (image-describe, image-transcribe, search) and skills
  - `config/searxng/` — SearXNG service configuration (systemd unit + settings)
  - `config/chroot-scripts/` — Build-time chroot scripts (nvm + Node.js + OpenCode installer)
  - `rescue.md` — Troubleshooting guide for `init_base.sh` crash recovery
- **open-webui/** — Open WebUI + SearXNG via podman-compose
