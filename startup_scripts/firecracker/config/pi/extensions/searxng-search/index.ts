import { defineTool, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type, StringEnum } from "@earendil-works/pi-ai";
import { Text } from "@earendil-works/pi-tui";

interface SearXNGResult {
  title: string;
  url: string;
  content: string;
  engine: string;
  score?: number;
}

interface SearXNGResponse {
  results: SearXNGResult[];
  answers: string[];
  suggestions: string[];
}

const DEFAULT_SEARXNG_URL = process.env.SEARXNG_URL || "http://127.0.0.1:8888";

// Module-level reachability state (updated on session start and manual checks)
let searxngServerWasReachable: boolean | null = null;
const SEARXNG_HTML_URL = `${DEFAULT_SEARXNG_URL}`;

/**
 * Startup probe — check if the SearXNG HTTP server responds.
 * Probes the root `/` endpoint which just returns the HTML search page,
 * avoiding the full aggregation pipeline. Very fast (~ms) when up.
 */
async function checkSearXNGServerReachable(signal?: AbortSignal): Promise<boolean> {
  try {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 1000); // 1s — just need the HTML page

    let res: Response;
    try {
      res = await fetch(SEARXNG_HTML_URL, {
        signal: (signal ?? controller.signal) as AbortSignal,
      });
    } finally {
      clearTimeout(timeoutId);
    }

    return res.ok && res.status === 200;
  } catch {
    return false;
  }
}

/**
 * Full-pipeline probe — verifies the search API actually works end-to-end.
 * Used by `/searxng-status` to detect partial outages (server up but
 * aggregation/search pipeline broken). Longer timeout because it triggers
 * upstream engine fetching.
 */
async function checkSearXNGSearchReachable(signal?: AbortSignal): Promise<boolean> {
  const url = `${SEARXNG_HTML_URL}/search?q=ping&format=json`;
  try {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 5000); // 5s — need room for aggregation

    let res: Response;
    try {
      res = await fetch(url, {
        signal: (signal ?? controller.signal) as AbortSignal,
        headers: { Accept: "application/json" },
      });
    } finally {
      clearTimeout(timeoutId);
    }

    if (!res.ok || res.status !== 200) return false;

    // Don't read/pause the body — just verify we get a valid JSON response
    const text = await res.text();
    if (!text) return false;
    try {
      JSON.parse(text); // validate it's actually JSON
      return true;
    } catch {
      return false; // not valid JSON, pipeline is broken
    }
  } catch {
    return false;
  }
}

/**
 * Inject a system-prompt-style message telling the LLM that SearXNG is unavailable.
 * This prevents the agent from repeatedly calling web-search when it's down.
 */
function injectUnavailabilityNotice(pi: ExtensionAPI): void {
  pi.sendMessage(
    {
      customType: "searxng-health",
      content:
        `The SearXNG search instance at \`${DEFAULT_SEARXNG_URL}\` is currently unreachable. ` +
        `Web search will not return results. Ask the user to verify their SEARXNG_URL configuration or check that the SearXNG service is running.`,
      display: false,
    },
    { deliverAs: "nextTurn" },
  );
}

/**
 * Set a status bar widget showing SearXNG connectivity.
 */
function updateStatus(ctx: { ui: { setStatus: (key: string, label: string) => void } }, reachable: boolean): void {
  const icon = reachable ? "🟢" : "🔴";
  const label = reachable ? "SearXNG connected" : "SearXNG unreachable";
  ctx.ui.setStatus("searxng", `${icon} ${label}`);
}

function buildSearchUrl(
  query: string,
  options: {
    count: number;
    language: string;
    safesearch: string;
    time_range: string;
    category: string;
    engines: string;
  },
): string {
  const params = new URLSearchParams({
    format: "json",
    q: query,
  });

  params.set("limit", String(options.count));

  if (options.language) params.set("language", options.language);
  if (options.safesearch) params.set("safesearch", options.safesearch);
  if (options.time_range) params.set("time_range", options.time_range);
  if (options.category) params.set("categories", options.category);
  if (options.engines) params.set("engines", options.engines);

  return `${DEFAULT_SEARXNG_URL}/search?${params.toString()}`;
}

const webSearchTool = defineTool({
  name: "web-search",
  label: "Web Search",
  description:
    "Search the web using the local SearXNG instance. Use for finding current information, research, news, and fact-checking.",
  promptSnippet:
    "Search the web via a local SearXNG instance — use for up-to-date facts, verification, or research.",
  promptGuidelines:
    'Use when you need recent/current information not already known. Increase `count` for broad research; keep it small for quick lookups. Filter by time_range="day" for breaking news, category="news" for journalism. Set language to match the query (e.g. "de" for German, "es" for Spanish).',
  parameters: Type.Object({
    query: Type.String({ description: "The search query" }),
    count: Type.Optional(
      Type.Number({
        description:
          "Number of results to return (default: 5). Max is 100.",
        minimum: 1,
        maximum: 100,
      }),
    ),
    timeout: Type.Optional(
      Type.Number({
        description:
          "Request timeout in seconds (default: 15, max configurable: 30)",
        minimum: 1,
        maximum: 30,
      }),
    ),
    language: Type.Optional(
      Type.String({
        description:
          'Language code for results (e.g. "en", "de", "es"). Empty string or omit for any language.',
      }),
    ),
    safesearch: Type.Optional(
      StringEnum(["0", "1", "2"], { description: 'Filtering: off=0, moderate=1, strict=2' }),
    ),
    time_range: Type.Optional(
      StringEnum(["day", "week", "month", "year"], { description: 'Recency filter: day, week, month, or year' }),
    ),
    category: Type.Optional(
      StringEnum(["general", "news", "science", "images", "videos", "files", "it", "social media"], { description: 'Result category (e.g. news, science, images)' }),
    ),
    engines: Type.Optional(
      Type.String({
        description:
          'Comma-separated upstream search engines (e.g. "google,bing")',
      }),
    ),
  }),

  async execute(_toolCallId, params, _signal, _onUpdate, _ctx) {
    const {
      query,
      count = 5,
      timeout: userTimeout,
      language = "",
      safesearch = "0",
      time_range = "",
      category = "",
      engines = "",
    } = params;

    // Clamp and resolve timeout
    const timeoutSeconds = Math.min(
      Math.max(userTimeout ?? 15, 1),
      30,
    );

    // Build URL with all SearXNG parameters
    const url = buildSearchUrl(query, {
      count,
      language,
      safesearch,
      time_range,
      category,
      engines,
    });

    // AbortController for timeout support
    const controller = new AbortController();
    let timedOut = false;
    if (_signal) {
      _signal.addEventListener("abort", () => controller.abort(), { once: true });
    }
    if (_signal?.aborted) {
      return {
        content: [{ type: "text", text: "Web search cancelled." }],
        details: { cancelled: true },
      };
    }
    const timeoutId = setTimeout(
      () => {
        timedOut = true;
        controller.abort();
      },
      timeoutSeconds * 1000,
    );

    // Short-circuit if startup health check already found SearXNG unreachable
    if (searxngServerWasReachable === false) {
      clearTimeout(timeoutId);
      return {
        content: [{ type: "text", text: `Web search skipped — SearXNG at \`${DEFAULT_SEARXNG_URL}\` was unreachable during startup. Run \`/searxng-status\` to re-check or ensure the service is running.` }],
        details: { error: true, connectionError: true },
      };
    }

    try {
      // Layer 1: Connection-level error handling
      let response;
      try {
        response = await fetch(url, { signal: controller.signal, headers: { Accept: "application/json" } });
      } catch (connectionErr) {
        clearTimeout(timeoutId);
        if (
          connectionErr instanceof DOMException &&
          connectionErr.name === "AbortError"
        ) {
          if (timedOut) {
            return {
              content: [
                {
                  type: "text",
                  text: `Web search timed out after ${timeoutSeconds}s. The SearXNG instance at \`${DEFAULT_SEARXNG_URL}\` may be slow or unresponsive.`,
                },
              ],
              details: { error: true, timedOut: true, timeout: timeoutSeconds },
            };
          }
          return {
            content: [
              {
                type: "text",
                text: `Web search was cancelled.`,
              },
            ],
            details: { cancelled: true },
          };
        }
        return {
          content: [
            {
              type: "text",
              text: `Web search connection failed: ${connectionErr instanceof Error ? connectionErr.message : String(connectionErr)}`,
            },
          ],
          details: { error: true, connectionError: true },
        };
      }

      clearTimeout(timeoutId);

      // Layer 2: HTTP error handling
      if (!response.ok) {
        return {
          content: [
            {
              type: "text",
              text: `SearXNG error: HTTP ${response.status} ${response.statusText}`,
            },
          ],
          details: { error: true, status: response.status },
        };
      }

      // Layer 3: JSON parse error handling
      let data: SearXNGResponse;
      try {
        const text = await response.text();
        data = text ? (JSON.parse(text) as SearXNGResponse) : { results: [], answers: [], suggestions: [] };
      } catch (parseErr) {
        return {
          content: [
            {
              type: "text",
              text: `Web search returned unexpected response format. SearXNG may be misconfigured. Error: ${parseErr instanceof Error ? parseErr.message : String(parseErr)}`,
            },
          ],
          details: { error: true, parseError: true },
        };
      }

      // Deduplicate results by URL
      const seenUrls = new Set<string>();
      const uniqueResults = (
        data.results || []
      ).filter((r) => {
        if (seenUrls.has(r.url)) return false;
        seenUrls.add(r.url);
        return true;
      });

      // Sort by relevance score (descending), treating missing scores as 0
      const sortedResults = uniqueResults.sort(
        (a, b) => (b.score ?? 0) - (a.score ?? 0),
      );

      // Slice to requested count
      const results = sortedResults.slice(0, Math.min(count, 100));

      if (results.length === 0) {
        return {
          content: [
            { type: "text", text: `No web search results found for "${query}".` },
          ],
          details: { results: [] },
        };
      }

      // Adaptive output formatting based on result count
      const maxSnippetLen = count <= 3 ? 300 : 150;
      let output = "";
      for (const [i, r] of results.entries()) {
        output += `${i + 1}. ${r.title}\n`;
        output += `   ${r.url}\n`;
        const snippet = (r.content || "")
          .replace(/\s+/g, " ")
          .trim()
          .slice(0, maxSnippetLen);
        if (snippet) {
          output += `   ${snippet}\n`;
        }
        if (count > 1 && r.engine) {
          output += `   [${r.engine}]`;
        }
        if (Number.isFinite(r.score)) {
          output += ` | score: ${r.score.toFixed(2)}`;
        }
        output += "\n\n";
      }

      // Suggestions section
      if (data.suggestions?.length) {
        const suggestionCount = Math.min(data.suggestions.length, 3);
        output += `Suggestions: ${data.suggestions.slice(0, suggestionCount).join(", ")}`;
      }

      return {
        content: [{ type: "text", text: output.trim() }],
        details: {
          resultCount: results.length,
          query,
          timeout: timeoutSeconds,
          results: results.map((r) => ({
            title: r.title,
            url: r.url,
            engine: r.engine,
            score: r.score,
          })),
        },
      };
    } catch (unexpectedErr) {
      clearTimeout(timeoutId);
      return {
        content: [
          {
            type: "text",
            text: `An unexpected error occurred during web search: ${unexpectedErr instanceof Error ? unexpectedErr.message : String(unexpectedErr)}`,
          },
        ],
        details: { error: true, unexpectedError: true },
      };
    }
  },

  renderCall(args, theme, _context) {
    const parts: string[] = [theme.fg("toolTitle", theme.bold("web-search "))];
    parts.push(theme.fg("accent", `"${args.query}"`));
    if (args.count) parts.push(theme.fg("dim", `count=${args.count}`));
    if (args.category) parts.push(theme.fg("dim", `cat:${args.category}`));
    if (args.time_range) parts.push(theme.fg("dim", `time:${args.time_range}`));
    return new Text(parts.join(" "), 0, 0);
  },

  renderResult(result, { expanded, isPartial }, theme, _context) {
    if (isPartial) {
      return new Text(theme.fg("warning", "Searching…"), 0, 0);
    }

    const details = result.details as Record<string, unknown> | undefined;

    if (details?.cancelled) {
      return new Text(theme.fg("warning", "Cancelled"), 0, 0);
    }
    if (details?.timedOut) {
      return new Text(theme.fg("error", `Timed out (${details.timeout ?? "?"}s)`), 0, 0);
    }
    if (details?.connectionError) {
      return new Text(theme.fg("error", "Connection failed"), 0, 0);
    }
    if (details?.parseError) {
      return new Text(theme.fg("error", "Bad response"), 0, 0);
    }
    if (details?.status) {
      return new Text(theme.fg("error", `HTTP ${details.status}`), 0, 0);
    }

    const results = details?.results as Array<{ title: string; url: string; engine?: string; score?: number }> | undefined;
    const resultCount = details?.resultCount as number | undefined;
    const query = details?.query as string | undefined;

    if (!results || results.length === 0) {
      const msg = query ? `No results for "${query}"` : "No results";
      return new Text(theme.fg("dim", msg), 0, 0);
    }

    let text = theme.fg("muted", `🔍 ${resultCount ?? results.length} result(s) for `) +
      theme.fg("accent", `"${query ?? "?"}"`);

    const display = expanded ? results : results.slice(0, 5);

    for (const r of display) {
      const score = typeof r.score === "number" ? ` ${theme.fg("dim", `⭐ ${r.score.toFixed(2)}`)}` : "";
      text += `\n${theme.fg("toolTitle", r.title)}${score}`;
      text += `\n${theme.fg("dim", r.url)}`;
    }

    if (!expanded && results.length > 5) {
      text += `\n${theme.fg("muted", `… ${results.length - 5} more (expand)`)}`;
    }

    return new Text(text, 0, 0);
  },
});

export default function (pi: ExtensionAPI) {
  pi.registerTool(webSearchTool);

  // --- Startup health check (lightweight HTML probe) ------------------
  pi.on("session_start", async (_event, ctx) => {
    const reachable = await checkSearXNGServerReachable(ctx.signal ?? undefined);
    searxngServerWasReachable = reachable;
    updateStatus(ctx, reachable);

    if (!reachable) {
      ctx.ui.notify(
        `⚠ SearXNG at \`${DEFAULT_SEARXNG_URL}\` is unreachable. Web search will be unavailable.`,
        "warning",
      );
      injectUnavailabilityNotice(pi);
    } else {
      ctx.ui.notify("🔍 SearXNG instance is available", "info");
    }
  });

  // --- Cleanup on session end ------------------------------------------
  pi.on("session_shutdown", async (_event, ctx) => {
    searxngServerWasReachable = null;
    try {
      ctx?.ui?.setStatus?.("searxng", "");
    } catch {
      // ctx.ui may not be available during shutdown — that's fine
    }
  });

  // --- Manual status check command ------------------------------------
  pi.registerCommand("searxng-status", {
    description: "Test the full SearXNG search pipeline (aggregation + JSON)",
    handler: async (_args, ctx) => {
      const reachable = await checkSearXNGSearchReachable(ctx.signal ?? undefined);

      if (reachable) {
        searxngServerWasReachable = true;
        ctx.ui.notify("✅ SearXNG search pipeline is working", "info");
      } else {
        // Distinguish between server down vs pipeline broken
        const serverUp = await checkSearXNGServerReachable(ctx.signal ?? undefined);
        if (!serverUp) {
          ctx.ui.notify(
            `❌ SearXNG at \`${DEFAULT_SEARXNG_URL}\` is not responding`,
            "error",
          );
        } else {
          ctx.ui.notify(
            `⚠️ SearXNG server is up but search pipeline may be broken (aggregation failed). Try /searxng-status again after waiting.`,
            "warning",
          );
        }
      }

      return undefined;
    },
  });
}
