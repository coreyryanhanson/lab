# AGENTS.md — Lab

Shell scripts plus copy/paste reference notes. GPL-3.0 (`LICENSE`). No tests,
linter, typechecker, CI or root-level package manifest anywhere: verification
means running the scripts.

## Layout

- `startup_scripts/firecracker/` — OverlayFS Firecracker VM manager. Has its own
  `AGENTS.md`: **read it before touching that directory.** It owns the lifecycle
  order, artifact table, hidden prerequisites and hard constraints; don't infer
  that flow from this file or from `README.md` (both lag behind the scripts).
- `startup_scripts/open-webui/` — `start.sh` brings up SearXNG with
  `podman-compose -f docker-compose.searxng.yaml` (port 7921), runs
  `uvx open-webui@latest serve`, then stops SearXNG when Open WebUI exits. The
  compose file bind-mounts `./searxng`, which is not in the repo.
- `bash/common_commands/` — reference markdown only (ffmpeg, pdftk, podman, ssh),
  indexed by its `README.md`. Nothing executes it.

## Gotchas

- The container scripts (open-webui) cannot run in this dev VM: its overlayfs
  rootfs cannot nest Docker/podman. Treat them as unverifiable here.
- Committed config under `startup_scripts/firecracker/config/` counts as code —
  it is injected into guest images at build time. Secrets belong in `.env`
  (gitignored), referenced from that config as env vars.
