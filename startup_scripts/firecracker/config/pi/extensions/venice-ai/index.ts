import type { ExtensionAPI, ProviderModelConfig } from "@earendil-works/pi-coding-agent";

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

async function fetchVeniceModels(): Promise<ProviderModelConfig[]> {
	const response = await fetch("https://api.venice.ai/api/v1/models?type=text");
	if (!response.ok) {
		throw new Error(`Venice models API returned ${response.status}`);
	}

	const data: VeniceModelsResponse = await response.json();
	const models: ProviderModelConfig[] = [];

	for (const m of data.data) {
		if (m.type !== "text") continue;
		if (m.model_spec?.offline) continue;
		if (m.model_spec?.privacy !== "private") continue;
		if (/grok/i.test(m.id)) continue;

		const spec = m.model_spec ?? {};
		const pricing = spec.pricing ?? {};
		const caps = spec.capabilities ?? {};

		models.push({
			id: m.id,
			name: spec.name ?? m.id,
			reasoning: caps.supportsReasoning ?? false,
			thinkingLevelMap: caps.supportsReasoningEffort
				? { minimal: "minimal", low: "low", medium: "medium", high: "high", xhigh: "xhigh" }
				: undefined,
			input: caps.supportsVision ? ["text", "image"] : ["text"],
			cost: {
				input: pricing.input?.usd ?? 0,
				output: pricing.output?.usd ?? 0,
				cacheRead: pricing.cache_input?.usd ?? 0,
				cacheWrite: pricing.cache_write?.usd ?? 0,
			},
			contextWindow: spec.availableContextTokens ?? m.context_length ?? 32768,
			maxTokens: spec.maxCompletionTokens ?? 4096,
		});
	}

	return models;
}

export default async function (pi: ExtensionAPI) {
	let models: ProviderModelConfig[];

	try {
		models = await fetchVeniceModels();
	} catch (error) {
		console.warn(`[venice-ai] Failed to fetch models: ${error instanceof Error ? error.message : String(error)}`);
		return;
	}

	if (models.length === 0) {
		console.warn("[venice-ai] No text models returned from Venice API");
		return;
	}

	pi.registerProvider("venice", {
		name: "Venice AI",
		baseUrl: "https://api.venice.ai/api/v1",
		apiKey: "$VENICE_API_KEY",
		api: "openai-completions",
		models,
	});
}
