# venice-ai — Pi Extension for Venice.ai

A [pi](https://github.com/earendil-works/pi-coding-agent) extension that provides access to [Venice.ai](https://venice.ai) models through the OpenAI-compatible completions API.

## Why Venice-Only?

This extension deliberately includes **only models that meet Venice's `private` privacy tier**. That means your prompts and completions are never stored, logged, or used for training by Venice or the underlying model provider.

Models that don't meet this bar are excluded. In practice, this filters out:

- **Closed-weight models from tech giants** (e.g. OpenAI, Anthropic) that are hostile to the AI commons — their weights are proprietary, their data practices are opaque, and they contribute nothing back to the open-source ecosystem.
- **Grok models** — despite having a Zero Data Retention (ZDR) agreement with Venice that technically qualifies them as `private`, Grok does not release its weights. Privacy through a legal contract with a for-profit entity is not the same as privacy through open weights and verifiable infrastructure. Grok is filtered out with a separate check.

We believe the AI commons requires models that are both **open-weight** and **private by design**. If a model can't meet both bars, it doesn't belong here.

## Providers

The extension registers two pi providers:

| Provider | Status | Description |
|----------|--------|-------------|
| `venice` | ✅ Active | OpenAI-compatible private models |
| `venice-e2ee` | ⏳ Coming soon | End-to-end encrypted models (secp256k1 key exchange + TEE attestation + AES-256-GCM) |

### Available Models

Models are fetched live from the Venice API at startup. Only models meeting these criteria are included:

- **Type**: `text` (chat completion models)
- **Privacy**: `private` (Venice's highest tier — no data retention)
- **Not offline**: hosted models only (no local/downloadable models)
- **Not Grok**: excluded per the policy above

Each model's capabilities (reasoning, vision, function calling, etc.) are auto-detected from the Venice API response and mapped to pi's model config.

### E2EE Models

Venice offers a subset of models with **end-to-end encryption** — your prompts are encrypted client-side before they ever leave your machine, and only decrypted inside a verified TEE (Trusted Execution Environment) on Venice's infrastructure.

These models are detected by `supportsE2EE: true` in Venice's model spec. The `venice-e2ee` provider is **registered but not yet active** — implementing the E2EE stream handler (secp256k1 key exchange, TEE attestation verification, AES-256-GCM encrypt/decrypt) is still in progress.

## Setup

### 1. Get a Venice API Key

Sign up at [venice.ai](https://venice.ai) and generate an API key from your account settings.

### 2. Set the environment variable

```bash
export VENICE_API_KEY="your-api-key-here"
```

Pi will automatically pick up `$VENICE_API_KEY` as configured by the extension.

### 3. Select a Venice model

Use pi's model picker or set your default model to a Venice model ID (e.g. `venice/qwen3-6-27b`).

## `/debugvenice` Command

The extension provides a `/debugvenice` slash command for troubleshooting Venice API interactions. It captures request/response data using pi's event system — it **only observes events and never modifies the streaming pipeline**, so it's safe to use during normal operation (including tool calling).

### Usage

| Command | What it does |
|---------|-------------|
| `/debugvenice` | Toggle debug logging on/off |
| `/debugvenice status` | Show whether debug is on and the log directory |
| `/debugvenice open` | Show the current debug log directory path |
| `/debugvenice latest` | Show the path to the most recent request payload |

### Captured Data

When debug mode is active, data is written to `/tmp/venice-debug/<timestamp-session>/`:

| File | Contents |
|------|----------|
| `request-payload-001.json` | Full HTTP request body sent to Venice |
| `response-headers-001.json` | HTTP status code + response headers |
| `message-summary.json` | Final message state: stopReason, errorMessage, usage, content block types |
| `events.ndjson` | Timestamped event stream (all debug events in chronological order) |

### Debugging Tips

1. **Check `request-payload-*.json`** — Look at the `reasoning_effort` value. Valid values for Venice are `"none"`, `"low"`, `"medium"`, `"high"`. Anything else means the request will be rejected.

2. **Check `response-headers-*.json`** — If the HTTP status isn't `200`, or if `Content-Type` is `application/json` instead of `text/event-stream`, Venice rejected the request before streaming started.

3. **Check `message-summary.json`** — `stopReason: "error"` with an `errorMessage` tells you exactly what went wrong. `stopReason: "stop"` means the response completed normally.

4. **Check `events.ndjson`** — Full chronological trace for correlating events across the request lifecycle.

### Quick Reference

```bash
# List all debug sessions
ls -lt /tmp/venice-debug/

# View the most recent request payload
cat $(ls -td /tmp/venice-debug/*/ | head -1)/request-payload-001.json | jq .

# View response headers for the latest request
cat $(ls -td /tmp/venice-debug/*/ | head -1)/response-headers-001.json | jq .

# View the message summary
cat $(ls -td /tmp/venice-debug/*/ | head -1)/message-summary.json | jq .

# Find all error responses across sessions
find /tmp/venice-debug/ -name "response-headers-*.json" -exec grep -l '"status": [^2]' {} \;
```

## Compatibility Notes

### Developer Role

Some Venice models (currently `qwen3-6-27b`) do not support the OpenAI `developer` role. Venice returns a non-standard SSE error chunk for these models when `developer` is used, which causes pi to throw "Stream ended without finish_reason". The extension sets `supportsDeveloperRole: false` for known affected models, which tells pi to send `system` instead.

### Reasoning Effort

Venice accepts `reasoning_effort` values of `"none"`, `"low"`, `"medium"`, and `"high"`. Pi's thinking levels map as follows:

| Pi Level | Venice Value |
|----------|-------------|
| `off` | `none` |
| `minimal` | `none` |
| `low` | `low` |
| `medium` | `medium` |
| `high` | `high` |
| `xhigh` | `high` |

`"minimal"` and `"xhigh"` are not valid Venice values and are mapped to the nearest valid level.
