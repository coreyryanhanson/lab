import { tool } from "@opencode-ai/plugin";
import { VENICE_API_URL, DEFAULT_MODEL, getApiKey, imageToBase64, resolveFilePath, isVeniceUrl } from "../utils/vision-api.ts";

const LENGTH_CONFIG = {
  short: { maxTokens: 100, prompt: "in one concise sentence suitable for alt text" },
  medium: { maxTokens: 250, prompt: "in 2-3 sentences with moderate detail" },
  detailed: { maxTokens: 500, prompt: "in a detailed paragraph covering all notable visual elements" },
};

const STYLE_PROMPTS = {
  "alt-text": "Focus on the main subject, key visual details, and any text visible. Do not include phrases like 'the image shows' or 'a photo of'.",
  artistic: "Focus on composition, color palette, mood, and artistic style. Describe the emotional impact and creative elements.",
  technical: "Focus on specific objects, materials, techniques, and precise visual details. Use objective, descriptive language.",
};

async function generateDescription(base64Image, apiKey, model, length, style) {
  const config = LENGTH_CONFIG[length];
  const stylePrompt = STYLE_PROMPTS[style];

  const response = await fetch(VENICE_API_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model,
      messages: [
        {
          role: "user",
          content: [
            {
              type: "text",
              text: `Describe this image ${config.prompt}. ${stylePrompt}`,
            },
            {
              type: "image_url",
              image_url: { url: base64Image },
            },
          ],
        },
      ],
      max_tokens: config.maxTokens,
      temperature: 0.3,
      ...(isVeniceUrl() ? { venice_parameters: { disable_thinking: true } } : {}),
    }),
  });

  if (!response.ok) {
    const errorBody = await response.text();
    throw new Error(`OpenCode API error ${response.status}: ${errorBody}`);
  }

  const data = await response.json();
  const message = data.choices[0].message;
  return (message.reasoning_content || message.content || "").trim();
}

export default tool({
  description:
    "Generate a text description of an image using a vision LLM. Supports configurable length (short/medium/detailed) and style (alt-text/artistic/technical). Requires VENICE_API_KEY environment variable.",
  args: {
    filePath: tool.schema.string().describe("Absolute path to the image file to describe"),
    model: tool.schema.string().optional().describe(`OpenCode AI model to use (default: ${DEFAULT_MODEL})`),
    length: tool.schema.enum(["short", "medium", "detailed"]).optional().describe("Description length: short (1 sentence, alt-text), medium (2-3 sentences), detailed (paragraph)"),
    style: tool.schema.enum(["alt-text", "artistic", "technical"]).optional().describe("Description style: alt-text (accessibility-focused), artistic (mood and composition), technical (precise and objective)"),
  },
  async execute(args, context) {
    const apiKey = getApiKey();
    if (!apiKey) {
      return "Error: Venice API key not found. Set VENICE_API_KEY environment variable.";
    }

    const { filePath, model = DEFAULT_MODEL, length = "short", style = "alt-text" } = args;

    try {
      const resolvedPath = resolveFilePath(filePath, context.worktree);
      const base64 = imageToBase64(resolvedPath);
      const description = await generateDescription(base64, apiKey, model, length, style);
      return description;
    } catch (err) {
      return `Error generating description: ${err.message}`;
    }
  },
});
