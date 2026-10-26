# Guest VM Configuration

Configuration files and extensions injected into the Firecracker VM during the
base image build (`init_base.sh`) and at runtime. These define the software
environment inside the guest — Pi Coding Agent extensions, the SearXNG service,
and chroot build scripts.

## Directory Structure

```text
config/
├── pi/
│   ├── auth.json                # API key config ($VENICE_API_KEY)
│   ├── models.json              # Custom providers (gondola-ai, openrouter, venice)
│   ├── settings.json            # Default provider, model, thinking level, browser/searxng config
│   ├── extensions/
│   │   ├── pi-init-plan/        # Plan-mode extension
│   │   ├── subagent/            # Subagent defaults
│   │   └── venice-ai/           # Venice AI models provider extension
│   └── prompts/                 # Prompt templates
├── searxng/
│   ├── searxng.service          # systemd unit file (granian WSGI)
│   └── settings.yml             # SearXNG instance settings
└── chroot-scripts/
    └── install-nvm-node.sh      # nvm + Node.js installer for chroot
```

## Pi Coding Agent Extensions

The Pi Coding Agent supports extensions that add tools, providers, and
capabilities. Three directories are bundled in-tree under `pi/extensions/`:
`venice-ai` (detailed below), `pi-init-plan` and `subagent` (its defaults).

Browser automation and SearXNG web search are now provided by the
[`pi-lean-dimension`](https://www.npmjs.com/package/pi-lean-dimension) Pi
package (a suite that installs both `pi-lean-portal` for interactive
browsing and `pi-lean-search` for SearXNG search, unified under the `/web`
command). It is installed via `pi install npm:pi-lean-dimension` during the
base image build, with Playwright Chromium + Firefox binaries installed via
`npx playwright install --with-deps chromium firefox`. Its configuration lives
in `settings.json` under the `browser.plugins` and `searxng.url` keys.

### venice-ai — Venice AI Models Provider

Dynamically fetches and registers all Venice AI private text models as a Pi
provider. Requires `VENICE_API_KEY` to be set in `pi/auth.json`.

At startup, the extension fetches the model list from
`https://api.venice.ai/api/v1/models?type=text` and registers each available
model. Supports:

- **Vision models** — For image understanding tasks
- **Reasoning models** — For complex reasoning and analysis
- **Thinking levels** — Configurable reasoning depth per model

### Custom providers (models.json)

`pi/models.json` registers three OpenAI-completions providers — `gondola-ai`,
`openrouter` and `venice` — each referencing an env-var API key (`$GONDOLA_API_KEY`,
`$OPENROUTER_API_KEY1`, `$VENICE_API_KEY`). The env vars are written into the VM
via `/etc/profile.d/99-vm-env.sh` from `.env`, so no secret is committed to the
repo. Individual models are enabled via `enabledModels` in `settings.json`.

## SearXNG Service

A local SearXNG meta-search engine is configured to run as a systemd service,
providing web search capabilities to the Pi search tools.

### Service Configuration

- **searxng.service** — systemd unit file running granian WSGI server with 2
  workers and 2 runtime threads. Runs as the `searxng` user. Binds to
  configurable `SEARXNG_HOST` and `SEARXNG_PORT` environment variables.

### Instance Settings

- **settings.yml** — SearXNG instance configuration:
  - JSON format enabled (required for API tool usage)
  - Port 8888, bind 127.0.0.1 (localhost only)
  - Valkey (Redis) disabled — no caching backend
  - Default search categories and engine configuration

The SearXNG service is installed into the guest by `init_base.sh` and runs
as a guest systemd unit on `127.0.0.1:8888`. The `pi-lean-search` tool (from
the `pi-lean-dimension` Pi package) connects to `http://127.0.0.1:8888` for
search queries.

## Chroot Build Scripts

Scripts in `chroot-scripts/` are executed during the `init_base.sh`
debootstrap phase to install software inside the chroot before the rootfs
image is finalized.

### install-nvm-node.sh

Installs nvm and Node.js inside the debootstrap chroot:

1. Installs nvm v0.40.1
2. Installs Node.js LTS and sets it as the default alias
3. Creates `/etc/profile.d/nvm.sh` with dynamic `NODE_PATH` so all users
   have access to nvm-managed Node.js

This script is called automatically by `init_base.sh` — do not run it
directly.
