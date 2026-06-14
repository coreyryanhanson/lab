import type {
	ExtensionAPI,
	ProviderModelConfig,
} from "@earendil-works/pi-coding-agent";
import { appendFileSync, mkdirSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

// ---------------------------------------------------------------------------
// Venice API types
// ---------------------------------------------------------------------------

interface VeniceModel {
	id: string;
	created?: number;
	context_length?: number;
	model_spec?: {
		name?: string;
		availableContextTokens?: number;
		maxCompletionTokens?: number;
		beta?: boolean;
		betaModel?: boolean;
		offline?: boolean;
		privacy?: string;
		capabilities?: {
			optimizedForCode?: boolean;
			supportsFunctionCalling?: boolean;
			supportsReasoning?: boolean;
			supportsReasoningEffort?: boolean;
			supportsVision?: boolean;
			supportsMultipleImages?: boolean;
			maxImages?: number;
			supportsResponseSchema?: boolean;
			supportsE2EE?: boolean;
		};
		pricing?: {
			input?: { usd?: number; diem?: number };
			output?: { usd?: number; diem?: number };
			cache_input?: { usd?: number; diem?: number };
			cache_write?: { usd?: number; diem?: number };
		};
	};
	object?: string;
	owned_by?: string;
	type: string;
	traits?: string[];
}

interface VeniceModelsResponse {
	data: VeniceModel[];
	object: string;
	type: string;
}

// ---------------------------------------------------------------------------
// Debug logging
// ---------------------------------------------------------------------------

const DEBUG_DIR = "/tmp/venice-debug";
let debugEnabled = false;
let currentSessionDir: string | null = null;
let requestCounter = 0;

/** Create a timestamped session dir and write an initial marker. */
function initDebugSession(): string {
	const ts = new Date().toISOString().replace(/[:.]/g, "-");
	const dir = join(DEBUG_DIR, ts);
	mkdirSync(dir, { recursive: true });
	writeFileSync(join(dir, ".session"), `started: ${ts}\n`, "utf8");
	return dir;
}

/** Append a line to the session's event log. */
function logEvent(event: string, data: unknown): void {
	if (!currentSessionDir) {
		currentSessionDir = initDebugSession();
	}
	const file = join(currentSessionDir, "events.ndjson");
	appendFileSync(
		file,
		JSON.stringify({ ts: Date.now(), event, data }) + "\n",
		"utf8",
	);
}

/** Write a standalone JSON file in the session dir. */
function logFile(name: string, data: unknown): void {
	if (!currentSessionDir) {
		currentSessionDir = initDebugSession();
	}
	writeFileSync(
		join(currentSessionDir, name),
		JSON.stringify(data, null, 2),
		"utf8",
	);
}

// ---------------------------------------------------------------------------
// Models that do NOT support the OpenAI `developer` role.
//
// Venice returns HTTP 200 with a non-standard SSE error chunk for these models
// when `developer` is used, which pi's stream parser sees as "Stream ended
// without finish_reason". Setting supportsDeveloperRole: false tells pi to
// send `system` instead.
//
// Add model IDs here as you discover them. Models NOT in this set default to
// whatever pi's auto-detection decides (usually `developer` for reasoning models).
// ---------------------------------------------------------------------------
const MODELS_REQUIRING_SYSTEM_ROLE: ReadonlySet<string> = new Set([
	"qwen3-6-27b",
]);

// ---------------------------------------------------------------------------
// Model context window lookup (populated during model fetch).
// Used by before_provider_request to clamp max_tokens.
// ---------------------------------------------------------------------------
const MODEL_METADATA: Map<
	string,
	{ contextWindow: number; maxTokens: number }
> = new Map();

// ---------------------------------------------------------------------------
// Model fetching
// ---------------------------------------------------------------------------

async function fetchVeniceModels(): Promise<{
	openai: ProviderModelConfig[];
	e2ee: ProviderModelConfig[];
}> {
	const response = await fetch("https://api.venice.ai/api/v1/models?type=text");
	if (!response.ok) {
		throw new Error(`Venice models API returned ${response.status}`);
	}

	const data: VeniceModelsResponse = await response.json();
	// Common filters applied to both providers:
	// - text-only models, not offline, private privacy tier, not Grok
	const openaiModels: ProviderModelConfig[] = [];
	const e2eeModels: ProviderModelConfig[] = [];

	for (const m of data.data) {
		if (m.type !== "text") continue;
		if (m.model_spec?.offline) continue;
		if (m.model_spec?.privacy !== "private") continue;
		if (/grok/i.test(m.id)) continue;

		const spec = m.model_spec ?? {};
		const pricing = spec.pricing ?? {};
		const caps = spec.capabilities ?? {};

		const ctxWindow = spec.availableContextTokens ?? m.context_length ?? 32768;
		const maxOut = spec.maxCompletionTokens ?? 4096;

		const config: ProviderModelConfig = {
			id: m.id,
			name: spec.name ?? m.id,
			reasoning: caps.supportsReasoning ?? false,
			// Venice accepts: "none", "low", "medium", "high"
			// Map pi levels to valid Venice reasoning_effort values.
			// "minimal" and "xhigh" are NOT valid — they map to nearest valid.
			thinkingLevelMap: caps.supportsReasoningEffort
				? {
						off: "none",
						minimal: "none",
						low: "low",
						medium: "medium",
						high: "high",
						xhigh: "high",
					}
				: undefined,
			input: caps.supportsVision ? ["text", "image"] : ["text"],
			cost: {
				input: pricing.input?.usd ?? 0,
				output: pricing.output?.usd ?? 0,
				cacheRead: pricing.cache_input?.usd ?? 0,
				cacheWrite: pricing.cache_write?.usd ?? 0,
			},
			contextWindow: ctxWindow,
			maxTokens: maxOut,
			// Models that don't support the `developer` role must be overridden
			// so pi sends `system` instead. Without this, Venice returns an
			// empty SSE stream with a validation error, causing pi to throw
			// "Stream ended without finish_reason".
			...(MODELS_REQUIRING_SYSTEM_ROLE.has(m.id)
				? { compat: { supportsDeveloperRole: false } }
				: {}),
		};

		// Populate model metadata lookup for before_provider_request
		MODEL_METADATA.set(m.id, {
			contextWindow: ctxWindow,
			maxTokens: maxOut,
		});

		if (caps.supportsE2EE) {
			e2eeModels.push(config);
		} else {
			openaiModels.push(config);
		}
	}

	return { openai: openaiModels, e2ee: e2eeModels };
}

// ---------------------------------------------------------------------------
// Token estimation helpers
// ---------------------------------------------------------------------------

/**
 * Estimate the number of input tokens from a chat completion payload.
 *
 * We deliberately overestimate input tokens so max_tokens leaves
 * enough room in the context window. An overestimate is SAFE — it
 * gives the API more room than needed.
 *
 * Heuristics:
 *   1 token ≈ 2 characters  — worst-case dense code/symbols
 *   +8 tokens per message for role/metadata overhead
 *
 * Real-world ratios are 1:3 to 1:5 for mixed text+code, so this
 * overestimates input by 50-150%, which translates to a generous
 * safety buffer for max_tokens.
 */
function estimateInputTokensFromPayload(
	payload: Record<string, unknown>,
): number {
	const messages = payload.messages as
		| Array<{ role: string; content: unknown }>
		| undefined;
	if (!messages || !Array.isArray(messages)) return 0;

	let totalChars = 0;
	for (const msg of messages) {
		if (typeof msg.content === "string") {
			totalChars += msg.content.length;
		} else if (Array.isArray(msg.content)) {
			for (const part of msg.content as Array<Record<string, unknown>>) {
				if (part.type === "text" && typeof part.text === "string") {
					totalChars += part.text.length;
				}
				// Ignore image content blocks — underestimating image token
				// overhead is safe (more room for max_tokens = safer).
			}
		}
		// Per-message overhead: role string, metadata, spacing (~8 tokens)
		totalChars += 16;
	}

	// 1 token per 2 characters: always overestimates since even dense code
	// is at least ~2 chars/token and typical text is 4-5 chars/token.
	return Math.ceil(totalChars / 2);
}

// ---------------------------------------------------------------------------
// Extension entry point
// ---------------------------------------------------------------------------

export default async function (pi: ExtensionAPI) {
	let models: { openai: ProviderModelConfig[]; e2ee: ProviderModelConfig[] };

	try {
		models = await fetchVeniceModels();
	} catch (error) {
		console.warn(
			`[venice-ai] Failed to fetch models: ${error instanceof Error ? error.message : String(error)}`,
		);
		return;
	}

	if (models.openai.length === 0 && models.e2ee.length === 0) {
		console.warn("[venice-ai] No text models returned from Venice API");
		return;
	}

	// Provider for OpenAI-compatible private models
	pi.registerProvider("venice", {
		name: "Venice AI",
		baseUrl: "https://api.venice.ai/api/v1",
		apiKey: "$VENICE_API_KEY",
		api: "openai-completions",
		models: models.openai,
	});

	// Provider for E2EE (end-to-end encrypted) models.
	// Currently disabled: E2EE requires a custom streamSimple handler with
	// secp256k1 key exchange, TEE attestation, and AES-256-GCM message
	// encryption/decryption — not yet implemented.
	// TODO: Implement tee-handler.ts and wire it up to enable these models.
	pi.registerProvider("venice-e2ee", {});

	// -----------------------------------------------------------------------
	// /debugvenice — Toggle debug logging for Venice provider
	// -----------------------------------------------------------------------
	//
	// Uses pi's event system (before_provider_request, after_provider_response,
	// message_end) to capture debug data WITHOUT modifying the streaming
	// pipeline. This is safe — it cannot break tool calling because it only
	// observes events, never replaces the stream handler.
	//
	// Logs go to /tmp/venice-debug/<timestamp-session>/ and include:
	//   request-payload.json  — Full request body sent to Venice
	//   response-headers.json  — HTTP status + response headers
	//   message-summary.json   — Final message state (usage, stopReason, error)
	//   events.ndjson          — Timestamped event stream (all debug events)
	//
	// Usage: /debugvenice          — Toggle on/off
	//        /debugvenice status   — Show current state and log location
	//        /debugvenice open     — Show the debug log directory path
	//        /debugvenice latest   — Show the most recent request payload

	pi.registerCommand("debugvenice", {
		description: "Toggle Venice debug logging (captures request/response data)",
		handler: async (args, ctx) => {
			const sub = (args ?? "").trim().toLowerCase();

			if (sub === "status") {
				if (!debugEnabled) {
					ctx.ui.notify("Venice debug: OFF", "info");
				} else {
					ctx.ui.notify(
						`Venice debug: ON\nSession dir: ${currentSessionDir ?? "(none yet)"}`,
						"info",
					);
				}
				return;
			}

			if (sub === "open") {
				if (!currentSessionDir) {
					ctx.ui.notify("No debug session yet — toggle on first", "warning");
					return;
				}
				ctx.ui.notify(`Debug logs: ${currentSessionDir}`, "info");
				return;
			}

			if (sub === "latest") {
				if (!currentSessionDir) {
					ctx.ui.notify("No debug session yet — toggle on first", "warning");
					return;
				}
				try {
					const files = readdirSync(currentSessionDir)
						.filter(
							(f) => f.startsWith("request-payload-") && f.endsWith(".json"),
						)
						.sort();
					if (files.length === 0) {
						ctx.ui.notify("No request payloads captured yet", "info");
						return;
					}
					const latest = files[files.length - 1]!;
					ctx.ui.notify(
						`Latest payload: ${join(currentSessionDir, latest)}`,
						"info",
					);
				} catch {
					ctx.ui.notify("Could not read debug directory", "error");
				}
				return;
			}

			// Toggle
			debugEnabled = !debugEnabled;
			requestCounter = 0;

			if (debugEnabled) {
				currentSessionDir = initDebugSession();
				ctx.ui.setStatus("venice-debug", "🔍 Venice Debug ON");
				ctx.ui.notify(
					`Venice debug logging ON\nLogs: ${currentSessionDir}`,
					"info",
				);
			} else {
				ctx.ui.setStatus("venice-debug", undefined);
				ctx.ui.notify("Venice debug logging OFF", "info");
			}
		},
	});

	// -----------------------------------------------------------------------
	// before_provider_request — Clamp max_tokens to fit within context window
	//
	// Venice defaults max_tokens to maxCompletionTokens (e.g. 131072) when the
	// client doesn't send it. When input is large, input + max_tokens can exceed
	// the model's contextWindow, causing a 400 error and triggering compaction.
	//
	// This handler estimates input tokens and clamps max_tokens so that
	//   input_tokens + max_tokens <= contextWindow - safety_margin
	//
	// Registered before the debug handler so it runs first in the chain.
	// -----------------------------------------------------------------------

	pi.on("before_provider_request", (event) => {
		const payload = event.payload as Record<string, unknown> | undefined;
		if (!payload || typeof payload !== "object") return;

		const modelId = payload.model as string | undefined;
		if (!modelId) return;

		const meta = MODEL_METADATA.get(modelId);
		if (!meta) return;

		const { contextWindow } = meta;

		// --- Compute safe max_tokens from context window ---
		//
		// Venice's API returns maxCompletionTokens (e.g. 24000 for GLM 5.1)
		// but when pi doesn't send max_tokens, Venice defaults to the model's
		// actual capacity (often 131072), which can overflow the context
		// window. We compute a safe value from the context window alone,
		// ignoring maxCompletionTokens which is often misleading.

		const safetyMargin = 8192;
		const inputTokens = estimateInputTokensFromPayload(payload);
		const inputReserve = Math.max(inputTokens, contextWindow * 0.25);
		const maxFromContext = contextWindow - inputReserve - safetyMargin;
		const minOutput = 16384;
		const safeMax = Math.max(minOutput, maxFromContext);

		// --- Case 1: pi didn't set max_tokens at all ---
		//
		// This is the common case. Pi never sends max_tokens, so Venice
		// defaults to the model's full completion capacity (often 131072),
		// which can overflow. Always set max_tokens explicitly.

		if (!("max_tokens" in payload) && !("max_completion_tokens" in payload)) {
			return { ...payload, max_tokens: safeMax };
		}

		// --- Case 2: pi set max_tokens explicitly ---
		//
		// Only clamp downward if the set value exceeds our safe level.
		// Never increase max_tokens beyond what pi requested.

		const currentMax =
			(payload.max_tokens as number) ??
			(payload.max_completion_tokens as number) ??
			meta.maxTokens;

		if (currentMax <= safeMax) return;

		const updated = {
			...payload,
			max_tokens: safeMax,
		};
		if ("max_completion_tokens" in updated) {
			delete (updated as Record<string, unknown>).max_completion_tokens;
		}
		return updated;
	});

	// -----------------------------------------------------------------------
	// Debug event handlers (only active when debugEnabled is true)
	// -----------------------------------------------------------------------

	pi.on("before_provider_request", (event) => {
		if (!debugEnabled) return;
		// Log all requests when debugging — Venice model IDs (like "qwen3-6-27b")
		// don't contain "venice", so we can't reliably filter by model name.
		// Users can filter by model in the log files.

		requestCounter++;
		const id = String(requestCounter).padStart(3, "0");

		logEvent("before_provider_request", {
			requestId: id,
			model: event.payload?.model,
		});
		logFile(`request-payload-${id}.json`, event.payload);
	});

	pi.on("after_provider_response", (event) => {
		if (!debugEnabled) return;

		logEvent("after_provider_response", {
			status: event.status,
			contentType: event.headers?.["content-type"],
		});
		logFile(`response-headers-${requestCounter}.json`, {
			status: event.status,
			headers: event.headers,
		});
	});

	pi.on("message_end", async (event) => {
		if (!debugEnabled) return;
		const msg = event.message;
		if (msg.role !== "assistant") return;

		// Only log for Venice provider responses.
		// Venice model IDs (e.g. "qwen3-6-27b") don't contain "venice",
		// but msg.provider should be "venice" since that's our provider name.
		if (msg.provider !== "venice") return;

		logEvent("message_end", {
			role: msg.role,
			stopReason: msg.stopReason,
			errorMessage: msg.errorMessage,
			usage: msg.usage,
			contentBlockCount: msg.content?.length,
			contentTypes: msg.content?.map((b: { type: string }) => b.type),
		});

		// Write a summary file for the last completed response
		logFile("message-summary.json", {
			stopReason: msg.stopReason,
			errorMessage: msg.errorMessage,
			usage: msg.usage,
			contentBlocks: msg.content?.map((b: { type: string }) => ({
				type: b.type,
				...(b.type === "text"
					? { length: (b as { text: string }).text?.length }
					: {}),
				...(b.type === "toolCall"
					? {
							name: (b as { name: string }).name,
							id: (b as { id: string }).id,
						}
					: {}),
				...(b.type === "thinking"
					? { length: (b as { thinking: string }).thinking?.length }
					: {}),
			})),
		});
	});

	// Also log turn-level info for context
	pi.on("turn_end", async (event) => {
		if (!debugEnabled) return;

		logEvent("turn_end", {
			turnIndex: event.turnIndex,
		});
	});
}
