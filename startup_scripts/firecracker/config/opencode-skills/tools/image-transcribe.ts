import { tool } from "@opencode-ai/plugin";
import { OPENCODE_API_URL, DEFAULT_MODEL, getApiKey, imageToBase64, resolveFilePath } from "../utils/vision-api.ts";

async function transcribeText(base64Image, apiKey, model) {
  const response = await fetch(OPENCODE_API_URL, {
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
              text:
                "Transcribe all visible text from this image exactly as it appears. " +
                "Preserve the original formatting, line breaks, and structure. " +
                "Output only the transcribed text with no introduction or commentary.",
            },
            {
              type: "image_url",
              image_url: { url: base64Image },
            },
          ],
        },
      ],
      temperature: 0.3,
      opencode_parameters: { disable_thinking: true },
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
    "Transcribe all visible text from an image using a vision LLM. Use this when the user wants to extract or read text from an image file (screenshot, photo, scan, receipt, document, handwriting, whiteboard, code snippet).",
  args: {
    filePath: tool.schema.string().describe("Absolute path to the image file to transcribe"),
    model: tool.schema.string().optional().describe(`OpenCode AI model to use (default: ${DEFAULT_MODEL})`),
  },
  async execute(args, context) {
    const apiKey = getApiKey();
    if (!apiKey) {
      return "Error: OpenCode API key not found. Set OPENCODE_API_KEY env var or place key in ~/.secrets/opencode-api-key.";
    }

    const { filePath, model = DEFAULT_MODEL } = args;

    try {
      const resolvedPath = resolveFilePath(filePath, context.worktree);
      const base64 = imageToBase64(resolvedPath);
      const text = await transcribeText(base64, apiKey, model);
      return text;
    } catch (err) {
      return `Error transcribing image: ${err.message}`;
    }
  },
});
