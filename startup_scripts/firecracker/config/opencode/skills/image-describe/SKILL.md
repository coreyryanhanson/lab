---
name: image-describe
description: Generate image descriptions using OpenCode AI vision for alt text, artistic analysis, or technical documentation
license: MIT
---

## What I do

I provide instructions for using the `image-describe` tool to generate text descriptions of images via OpenCode AI's vision model.

## When to use me

- Adding alt text to images in content files, pages, or components
- Generating descriptions for portfolio, gallery, or recipe images
- Creating image metadata for accessibility compliance
- Batch-processing images in a directory that need descriptions

## How the tool works
Call `image-describe` with:

| Argument | Required | Options | Default | Description |
|----------|----------|---------|---------|-------------|
| `filePath` | Yes | Any image path | — | Absolute or relative path to the image |
| `model` | No | Any OpenCode-compatible model | `qwen3-6-27b` | OpenCode AI model to use |
| `length` | No | `short`, `medium`, `detailed` | `short` | Output length |
| `style` | No | `alt-text`, `artistic`, `technical` | `alt-text` | Description focus |

## Usage patterns

### Single image alt text
Use `length: short` and `style: alt-text` for accessibility-focused one-sentence descriptions:
```
image-describe({ filePath: "src/assets/art/dove1.jpg", length: "short", style: "alt-text" })
```

### Portfolio/gallery descriptions
Use `length: medium` or `detailed` with `style: artistic` for richer descriptions:
```
image-describe({ filePath: "src/assets/art/royalicingpaint1.jpg", length: "medium", style: "artistic" })
```
### Technical documentation
Use `style: technical` for objective, precise descriptions:
```
image-describe({ filePath: "src/assets/art/dove1.jpg", style: "technical", length: "medium" })
```

## Batch processing
When multiple images in a directory need descriptions:
1. Use `glob` to find all image files in the target directory
2. Call `image-describe` for each image
3. Write descriptions to `.md` files alongside each image, or update the relevant content files

## Requirements
- `VENICE_API_KEY` must be set as an environment variable
- If the key is not found, the tool returns an error message — inform the user to set it

## Configuration
- Default model is defined in `utils/vision-api.ts` as `DEFAULT_MODEL`
- API URL defaults to `https://api.venice.ai/api/v1/chat/completions` but can be overridden via `VENICE_API_URL` environment variable
- Shared configuration between `image-describe` and `image-transcribe` lives in `utils/vision-api.ts`

## Tips
- Default to `short` + `alt-text` for web accessibility
- Use `medium` + `artistic` for portfolio and gallery pages
- Use `detailed` + `technical` only when precise documentation is needed
- The tool handles path resolution automatically (relative to worktree)
