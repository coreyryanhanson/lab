---
name: image-transcribe
description: Transcribe text from images using OpenCode AI vision models via the dedicated image-transcribe tool. Use when the user mentions transcribing, extracting, or reading text from an image file (screenshot, photo, scan, receipt, document, handwriting, whiteboard, code snippet).
license: MIT
---

## What I do

I provide instructions for using the `image-transcribe` tool to extract all visible text from images via OpenCode AI's vision model.

## Tool: image-transcribe

Defined at `.opencode/tools/image-transcribe.ts`. Accepts:

| Argument | Required | Type | Default | Description |
|----------|----------|------|---------|-------------|
| `filePath` | Yes | string | — | Absolute path to the image file |
| `model` | No | string | `DEFAULT_MODEL` | OpenCode AI model to use |

## Usage

### Basic transcription
```
image-transcribe({ filePath: "src/assets/screenshots/code.png" })
```

### With a different model
```
image-transcribe({ filePath: "src/assets/scans/letter.jpg", model: "qwen3-6-27b" })
```
## Requirements

- API key is read from `~/.secrets/opencode-api-key` or `OPENCODE_API_KEY` env var (same as `image-describe`)
- Auto-discovered from `.opencode/tools/` — no registration needed
