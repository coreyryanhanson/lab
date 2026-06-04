/**
 * Level 1: HTTP Fetch Backend
 *
 * Uses plain fetch() with configurable User-Agent, HTML parsing via
 * node-html-parser, and Markdown conversion via turndown.
 * No JavaScript execution — fastest path for static content.
 */

import TurndownService from "turndown";
import { parse as parseHtml } from "node-html-parser";

export interface FetchNavigateResult {
  success: boolean;
  url: string;
  title: string;
  content: string;        // Markdown
  needsJavaScript: boolean; // true if page appears to be a JS shell
  backend: "fetch";
  statusCode?: number;
  error?: string;
}

const DEFAULT_USER_AGENT =
  "Mozilla/5.0 (compatible; PiBrowser/1.0; +https://pi.ai)";

const turndown = new TurndownService({
  headingStyle: "atx",
  codeBlockStyle: "fenced",
  emDelimiter: "*",
});

/**
 * Detect whether a page is a JS-only shell (empty <div id="root">,
 * mostly <noscript> content, etc.)
 */
function detectNeedsJavaScript(root: ReturnType<typeof parseHtml>): boolean {
  // Check for common JS-app shell patterns
  const rootDiv = root.querySelector("#root, #__next, #app, #__nuxt");
  if (rootDiv) {
    const text = rootDiv.textContent?.trim() || "";
    // If the root div has little or no text content, JS likely hasn't rendered
    if (text.length < 100) return true;
  }

  // Check if most content is in <noscript> tags
  const noscripts = root.querySelectorAll("noscript");
  if (noscripts.length > 0) {
    const bodyText = root.textContent?.trim() || "";
    const noscriptText = noscripts.map((n) => n.textContent?.trim() || "").join("");
    if (noscriptText.length > 0 && noscriptText.length > bodyText.length * 0.5) {
      return true;
    }
  }

  // Check for SPA meta tags
  const metaApp = root.querySelector('meta[name="application-name"]');
  if (metaApp?.getAttribute("content")?.toLowerCase().includes("react")) {
    return true;
  }

  return false;
}

function extractTitle(root: ReturnType<typeof parseHtml>): string {
  const titleTag = root.querySelector("title");
  return titleTag?.textContent?.trim() || "";
}

export async function navigate(
  url: string,
  timeoutMs: number = 30_000,
  signal?: AbortSignal,
): Promise<FetchNavigateResult> {
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), timeoutMs);

  // Wire up external signal
  if (signal) {
    signal.addEventListener("abort", () => controller.abort(), { once: true });
  }

  try {
    const response = await fetch(url, {
      signal: controller.signal,
      headers: {
        "User-Agent": DEFAULT_USER_AGENT,
        Accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.5",
      },
      redirect: "follow",
    });

    clearTimeout(timeoutId);

    if (!response.ok) {
      return {
        success: false,
        url,
        title: "",
        content: `HTTP ${response.status} ${response.statusText}`,
        needsJavaScript: false,
        backend: "fetch",
        statusCode: response.status,
        error: `HTTP ${response.status}`,
      };
    }

    const html = await response.text();
    if (!html) {
      return {
        success: false,
        url,
        title: "",
        content: "Empty response body",
        needsJavaScript: false,
        backend: "fetch",
        error: "Empty body",
      };
    }

    const root = parseHtml(html);
    const title = extractTitle(root);
    const needsJavaScript = detectNeedsJavaScript(root);

    // Remove script, style, noscript tags for cleaner markdown.
    // SVGs are kept as text placeholders based on aria-label or title.
    root.querySelectorAll("script, style, noscript").forEach((el) => el.remove());
    // Convert SVGs to descriptive placeholders instead of stripping
    root.querySelectorAll("svg").forEach((el) => {
      const ariaLabel = el.getAttribute("aria-label") || el.getAttribute("title") || "";
      const role = el.getAttribute("role") || "";
      const img = el.querySelector("image") || el.querySelector("img");
      const alt = img?.getAttribute("aria-label") || img?.getAttribute("alt") || "";
      const label = ariaLabel || alt || role || "";
      if (label) {
        el.replaceWith(`[SVG: ${label.trim()}]`);
      } else {
        // Check for text content inside SVG (e.g., chart labels)
        const textEls = el.querySelectorAll("text");
        const texts = textEls.map((t) => t.textContent?.trim()).filter(Boolean);
        if (texts.length > 0) {
          el.replaceWith(`[SVG with text: ${texts.join("; ").slice(0, 120)}]`);
        } else {
          el.replaceWith(`[SVG graphic]`);
        }
      }
    });

    const markdown = turndown.turndown(root.innerHTML || root.textContent || "");

    return {
      success: true,
      url: response.url, // final URL after redirects
      title,
      content: markdown.trim(),
      needsJavaScript,
      backend: "fetch",
      statusCode: response.status,
    };
  } catch (err: unknown) {
    clearTimeout(timeoutId);
    if (err instanceof DOMException && err.name === "AbortError") {
      return {
        success: false,
        url,
        title: "",
        content: "Request timed out or was cancelled",
        needsJavaScript: false,
        backend: "fetch",
        error: "timeout",
      };
    }
    return {
      success: false,
      url,
      title: "",
      content: `Fetch error: ${err instanceof Error ? err.message : String(err)}`,
      needsJavaScript: false,
      backend: "fetch",
      error: err instanceof Error ? err.message : String(err),
    };
  }
}
