import { Type } from "@earendil-works/pi-ai";
import { defineTool, type ExtensionAPI } from "@earendil-works/pi-coding-agent";

interface SearXNGResult {
  title: string;
  url: string;
  content: string;
  engine: string;
}

interface SearXNGResponse {
  results: SearXNGResult[];
  answers: string[];
  suggestions: string[];
}

const webSearchTool = defineTool({
  name: "web-search",
  label: "Web Search",
  description:
    "Search the web using the local SearXNG instance. Use for finding current information, research, news, and fact-checking.",
  parameters: Type.Object({
    query: Type.String({ description: "The search query" }),
    count: Type.Optional(
      Type.Number({ description: "Number of results to return (default: 5)" }),
    ),
  }),

  async execute(_toolCallId, params, _signal, _onUpdate, _ctx) {
    const { query, count = 5 } = params;
    const url = `http://127.0.0.1:8888/search?format=json&q=${encodeURIComponent(query)}&language=en`;

    const response = await fetch(url);
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

    const data: SearXNGResponse = await response.json();
    const results = (data.results || []).slice(0, count);

    if (results.length === 0) {
      return {
        content: [{ type: "text", text: `No web search results found for "${query}".` }],
        details: { results: [] },
      };
    }

    let output = "";
    for (const [i, r] of results.entries()) {
      output += `${i + 1}. ${r.title}\n`;
      output += `   ${r.url}\n`;
      output += `   ${(r.content || "").replace(/\s+/g, " ").trim().slice(0, 300)}\n`;
      output += `   [${r.engine}]\n\n`;
    }

    if (data.suggestions?.length) {
      output += `Suggestions: ${data.suggestions.slice(0, 3).join(", ")}`;
    }

    return {
      content: [{ type: "text", text: output.trim() }],
      details: { resultCount: results.length },
    };
  },
});

export default function (pi: ExtensionAPI) {
  pi.registerTool(webSearchTool);
}
