# Guest VM Configuration

Configuration files and extensions injected into the Firecracker VM during the
base image build (`init_base.sh`) and at runtime. These define the software
environment inside the guest — Pi Coding Agent extensions, OpenCode tools and
skills, the SearXNG service, and chroot build scripts.

## Directory Structure

```
config/
├── opencode/
│   ├── config.json              # OpenCode configuration template
│   ├── package.json             # Plugin dependency (@opencode-ai/plugin)
│   ├── install_skills.sh        # Installer: copies tools/utils/skills to ~/.config/opencode/
│   ├── skills/
│   │   ├── image-describe/SKILL.md   # Image description skill
│   │   └── image-transcribe/SKILL.md # Image text transcription skill
│   ├── tools/
│   │   ├── image-describe.ts    # Vision LLM image description tool
│   │   ├── image-transcribe.ts  # Vision LLM image transcription tool
│   │   └── search.ts           # SearXNG web search tool (OpenCode plugin)
│   └── utils/
│       └── vision-api.ts        # Venice AI vision API helper
├── pi/
│   ├── auth.json                # API key config ($VENICE_API_KEY)
│   ├── models.json             # Provider/model definitions
│   ├── settings.json           # Default provider, model, thinking level
│   └── extensions/
│       ├── pi-browser/         # Browser automation extension (10 tools, 3 backends)
│       ├── opencode-zen/       # Free Zen models provider extension
│       ├── searxng-search/     # SearXNG web search extension
│       └── venice-ai/          # Venice AI models provider extension
├── searxng/
│   ├── searxng.service         # systemd unit file (granian WSGI)
│   └── settings.yml            # SearXNG instance settings
└── chroot-scripts/
    └── install-nvm-node.sh     # nvm + Node.js + OpenCode installer for chroot
```

## Pi Coding Agent Extensions

The Pi Coding Agent supports extensions that add tools, providers, and
capabilities. Four extensions are included in `pi/extensions/`.

### pi-browser — Browser Automation

Full browser automation extension providing 10 tools for web interaction:

| Tool | Description |
|------|-------------|
| `browser-navigate` | Navigate to a URL |
| `browser-snapshot` | Capture accessibility tree snapshot |
| `browser-click` | Click an element |
| `browser-type` | Type text into an input field |
| `browser-scroll` | Scroll the page |
| `browser-screenshot` | Capture a screenshot |
| `browser-get-images` | Get all images on the page |
| `browser-back` | Navigate back |
| `browser-press` | Press a keyboard key |
| `browser-console` | Execute JavaScript in the console |

Three browser backends are available, selected automatically or manually:

- **HTTP fetch** — For static pages. Fast, no browser process needed.
- **Playwright Chromium** — For JavaScript-heavy pages. Full rendering support.
- **Stealth Firefox** — For bot-protected sites. Uses a Python bridge with
  anti-detection measures.

Includes a status bar widget and `/browser-status` command for monitoring the
current browser state.

**Key files:**
- `index.ts` — Entry point and tool registration
- `package.json` — Dependencies and metadata
- `backend/` — Backend implementations (fetch, playwright, stealth, router)
- `utils/` — Utilities (accessibility-tree, bot-detection, cdp-supervisor,
  session-manager, url-safety)
- `stealth_bridge.py` — Python bridge for stealth Firefox mode

### opencode-zen — Free Zen Models Provider

Registers 4 free models from OpenCode Zen as a custom Pi provider. No API key
required — uses the `"public"` key automatically.

| Model | Context Window |
|-------|---------------|
| `deepseek-v4-flash-free` | Up to 1M tokens |
| `mimo-v2.5-free` | Up to 1M tokens |
| `nemotron-3-super-free` | Up to 1M tokens |
| `big-pickle` | Up to 1M tokens |

These models are useful for tasks that don't require a paid API or when
`VENICE_API_KEY` is not configured.

### searxng-search — Web Search via SearXNG

Web search tool for Pi using the local SearXNG instance. Supports rich query
parameters:

| Parameter | Description | Values |
|-----------|-------------|--------|
| `query` | Search query string | Any text |
| `count` | Number of results (1–100) | Default: 10 |
| `language` | Result language | ISO 639-1 code |
| `safesearch` | Filter level | 0 (off), 1 (moderate), 2 (strict) |
| `time_range` | Time filter | `day`, `week`, `month`, `year` |
| `category` | Search category | `general`, `news`, `science`, `images`, `videos`, `files`, `it`, `social media` |
| `engines` | Specific engines | Comma-separated engine names |

Includes a startup health check and `/searxng-status` command. Gracefully
degrades when SearXNG is unreachable — returns an error message instead of
crashing.

### venice-ai — Venice AI Models Provider

Dynamically fetches and registers all Venice AI private text models as a Pi
provider. Requires `VENICE_API_KEY` to be set in `pi/auth.json`.

At startup, the extension fetches the model list from
`https://api.venice.ai/api/v1/models?type=text` and registers each available
model. Supports:

- **Vision models** — For image understanding tasks
- **Reasoning models** — For complex reasoning and analysis
- **Thinking levels** — Configurable reasoning depth per model

## OpenCode Vision Tools

OpenCode tools and skills for image understanding via the Venice AI vision API.
Located in `opencode/`.

### Tools

Three tools are available:

- **image-describe.ts** — Generate image descriptions via Venice AI vision API.
  Configurable length (`short`, `medium`, `detailed`) and style (`alt-text`,
  `artistic`, `technical`). Default model: `qwen3-6-27b`. Requires
  `VENICE_API_KEY`.

- **image-transcribe.ts** — Extract text from images via Venice AI vision API.
  Same model and API key requirements as image-describe.

- **search.ts** — Simple SearXNG search tool for the OpenCode plugin system.
  Queries `http://127.0.0.1:8888/search?format=json` and returns structured
  results.

### Utilities

- **vision-api.ts** — Shared utility module providing base64 image encoding,
  file path resolution, API key management (`VENICE_API_KEY`), and Venice API
  URL configuration. Used by both image-describe and image-transcribe.

### Skills

Skills provide instructions for when and how to use the vision tools:

- **image-describe/SKILL.md** — Instructions for image description. Covers
  when to use each style: `alt-text` (accessibility), `artistic` (creative
  writing), `technical` (diagrams, charts, documentation).

- **image-transcribe/SKILL.md** — Instructions for image transcription. Covers
  when to use text extraction (OCR, screenshots, documents, code from images).

### install_skills.sh

Installer script that copies vision tools, utilities, and skill definitions to
the OpenCode configuration directory:

- `tools/*.ts` → `~/.config/opencode/tools/`
- `utils/*.ts` → `~/.config/opencode/utils/`
- `skills/*/SKILL.md` → `~/.config/opencode/skills/<name>/SKILL.md`

Run after OpenCode is installed to enable vision capabilities.

## SearXNG Service

A local SearXNG meta-search engine is configured to run as a systemd service,
providing web search capabilities to both Pi and OpenCode tools.

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

The SearXNG service is expected to be running on the host. Both the
`searxng-search` Pi extension and the `search.ts` OpenCode tool connect to
`http://127.0.0.1:8888` for search queries.

## Chroot Build Scripts

Scripts in `chroot-scripts/` are executed during the `init_base.sh`
debootstrap phase to install software inside the chroot before the rootfs
image is finalized.

### install-nvm-node.sh

Installs Node.js and OpenCode inside the debootstrap chroot:

1. Installs nvm v0.40.1
2. Installs Node.js LTS and sets it as the default alias
3. Installs OpenCode globally (`opencode-ai@latest`)
4. Creates `/etc/profile.d/nvm.sh` with dynamic `NODE_PATH` so all users
   have access to nvm-managed Node.js

This script is called automatically by `init_base.sh` — do not run it
directly.
