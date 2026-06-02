import { tool } from "@opencode-ai/plugin";

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

export default tool({
  description:
    "Search the web using the local SearXNG instance. Use for finding current information, research, news, and fact-checking.",
  args: {
    query: tool.schema.string().describe("The search query"),
    count: tool.schema.number().optional().describe("Number of results to return (default: 5)"),
  },
  async execute(args) {
    const { query, count = 5 } = args;
    const url = `http://127.0.0.1:8888/search?format=json&q=${encodeURIComponent(query)}&language=en`;

    const response = await fetch(url);
    if (!response.ok) {
      return `SearXNG error: HTTP ${response.status} ${response.statusText}`;
    }

    const data: SearXNGResponse = await response.json();
    const results = (data.results || []).slice(0, count);

    if (results.length === 0) {
      return `No web search results found for "${query}".`;
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

    return output.trim();
  },
});
