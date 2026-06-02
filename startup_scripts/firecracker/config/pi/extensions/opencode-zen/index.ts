import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/**
 * OpenCode Zen Free Models Provider
 *
 * Registers the 4 free Zen models (deepseek-v4-flash-free, mimo-v2.5-free,
 * nemotron-3-super-free, big-pickle) as a custom provider in pi.
 * No API key required — uses the "public" key for free-tier access.
 *
 * Models: https://opencode.ai/zen (free tier, may log prompts during feedback period)
 * Base URL: https://opencode.ai/zen/v1/chat/completions
 */
export default function (pi: ExtensionAPI) {
  pi.registerProvider("opencode-zen", {
    baseUrl: "https://opencode.ai/zen/v1",
    apiKey: "public",
    api: "openai-completions",
    models: [
      {
        id: "deepseek-v4-flash-free",
        name: "DeepSeek V4 Flash (free)",
        reasoning: false,
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 1_048_576,
        maxTokens: 16_384,
      },
      {
        id: "mimo-v2.5-free",
        name: "Mimo v2.5 (free)",
        reasoning: false,
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 1_048_576,
        maxTokens: 16_384,
      },
      {
        id: "nemotron-3-super-free",
        name: "NVIDIA Nemotron 3 Super (free)",
        reasoning: false,
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 131_072,
        maxTokens: 16_384,
      },
      {
        id: "big-pickle",
        name: "Big Pickle (free)",
        reasoning: false,
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 131_072,
        maxTokens: 16_384,
      },
    ],
  });

  pi.on("session_start", async (_event, ctx) => {
    ctx.ui.notify(
      "OpenCode Zen free models loaded (deepseek-v4-flash-free, mimo-v2.5-free, nemotron-3-super-free, big-pickle). Use /model to select.",
      "info",
    );
  });
}
