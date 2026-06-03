import { defineTool, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type, StringEnum } from "@earendil-works/pi-ai";
import { Text } from "@earendil-works/pi-tui";
import * as router from "./backend/router";
import { sessionManager } from "./utils/session-manager";

// ============================================================
// Status bar update helper
// ============================================================
function updateFooterStatus(ctx: { ui: { setStatus: (key: string, label: string) => void } }): void {
  ctx.ui.setStatus("browser", sessionManager.getStatus());
}

// ─── Helper to get taskId from tool call context ────────────
function taskId(ctx: { toolCallId?: string }): string {
  return ctx?.toolCallId ?? "default";
}

// ============================================================
// Tool: browser-navigate
// ============================================================
const browserNavigateTool = defineTool({
  name: "browser-navigate",
  label: "Browse Web",
  description:
    "Navigate a browser to a URL and return the page as an accessibility tree with @e1, @e2 element references. " +
    "Auto-selects the best backend: simple HTTP fetch for static sites, " +
    "Playwright Chromium for JS-heavy pages, or stealth mode (future) for bot-protected sites.",
  promptSnippet:
    "Fetch and read web pages in text form",
  promptGuidelines: [
    "Use browser-navigate when you need to read a web page's content.",
    "The tool converts HTML to Markdown for readability.",
    "If the page seems empty or JS-dependent, try strategy='chromium' when the Playwright backend is available.",
    "Use @e1, @e2 references from the accessibility tree with browser-click and browser-type to interact with page elements.",
  ],
  parameters: Type.Object({
    url: Type.String({ description: "The URL to navigate to" }),
    strategy: Type.Optional(
      StringEnum(["auto", "fetch", "chromium", "stealth"] as const, {
        description:
          'Backend strategy: "auto" (default) tries fetch first, escalates as needed; ' +
          '"fetch" uses plain HTTP; "chromium" uses Playwright; "stealth" uses invisible_playwright (future)',
      }),
    ),
    timeout: Type.Optional(
      Type.Number({
        description: "Timeout in seconds (default: 30, max: 120)",
        minimum: 1, maximum: 120,
      }),
    ),
  }),

  async execute(_toolCallId, params, signal, _onUpdate, ctx) {
    const { url, strategy = "auto", timeout = 30 } = params as {
      url: string; strategy?: string; timeout?: number;
    };
    const tid = taskId(ctx);

    signal?.addEventListener("abort", () => {
      sessionManager.removeSession(tid);
      updateFooterStatus(ctx);
    }, { once: true });

    const result = await router.navigate(url, {
      strategy: strategy as any,
      timeout,
      signal: signal ?? undefined,
      taskId: tid,
    });

    updateFooterStatus(ctx);

    if (!result.success) {
      return {
        content: [{ type: "text", text: `Failed to load page: ${result.error ?? "unknown error"}` }],
        details: { error: true, backendUsed: result.backendUsed, url: result.url },
      };
    }

    const lines = [
      `Title: ${result.title || "(no title)"}`,
      `URL: ${result.url}`,
      `Backend: ${result.backendUsed}`,
      result.elementCount !== undefined ? `Interactive elements: ${result.elementCount}` : "",
      result.botDetectionWarning ? `⚠ Bot detection triggered — may need stealth backend.` : "",
      "",
      result.content,
    ];

    return {
      content: [{ type: "text", text: lines.filter(Boolean).join("\n") }],
      details: {
        title: result.title,
        url: result.url,
        backendUsed: result.backendUsed,
        elementCount: result.elementCount,
        botDetectionWarning: result.botDetectionWarning,
      },
    };
  },

  renderCall(args, theme, _context) {
    const parts: string[] = [theme.fg("toolTitle", theme.bold("browser-navigate "))];
    parts.push(theme.fg("accent", `"${args.url}"`));
    if (args.strategy && args.strategy !== "auto") parts.push(theme.fg("dim", `via ${args.strategy}`));
    return new Text(parts.join(" "), 0, 0);
  },

  renderResult(result, { expanded, isPartial }, theme, _context) {
    if (isPartial) return new Text(theme.fg("warning", "Navigating…"), 0, 0);
    const d = result.details as Record<string, unknown> | undefined;
    if (d?.error) return new Text(theme.fg("error", `Failed: ${(result.content?.[0] as any)?.text ?? "?"}`), 0, 0);

    const title = (d?.title as string) || "(no title)";
    const backend = (d?.backendUsed as string) || "?";
    const url = (d?.url as string) || "";
    const ec = d?.elementCount as number | undefined;
    const botWarn = d?.botDetectionWarning as boolean | undefined;

    let text = theme.fg("accent", theme.bold(`🌐 ${title}`));
    text += `\n${theme.fg("dim", url)}`;
    text += `\n${theme.fg("muted", `via ${backend}`)}`;
    if (ec !== undefined) text += ` · ${ec} elements`;
    if (botWarn) text += ` ${theme.fg("warning", "⚠ bot detection")}`;

    const content = (result.content?.[0] as any)?.text ?? "";
    if (expanded) {
      const preview = content.replace(/\n{3,}/g, "\n\n").slice(0, 500);
      text += `\n\n${theme.fg("dim", preview)}`;
      if (content.length > 500) text += `\n${theme.fg("muted", `… ${content.length - 500} more chars`)}`;
    } else {
      text += `\n${theme.fg("muted", `${content.length} chars (expand)`)}`;
    }
    return new Text(text, 0, 0);
  },
});

// ============================================================
// Tool: browser-snapshot
// ============================================================
const browserSnapshotTool = defineTool({
  name: "browser-snapshot",
  label: "Page Snapshot",
  description:
    "Get the current page's accessibility tree with @e1, @e2 element references. " +
    "Use after browser-navigate to refresh the element list, or after page changes (click, scroll) to see the updated state.",
  parameters: Type.Object({
    taskId: Type.Optional(Type.String({ description: "Session ID (auto-populated)" })),
  }),

  async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
    const tid = (params as any)?.taskId ?? taskId(ctx);
    const result = await router.snapshot(tid);
    updateFooterStatus(ctx);

    if (!result.success) {
      return {
        content: [{ type: "text", text: `Snapshot failed: ${result.error ?? "unknown"}` }],
        details: { error: true },
      };
    }

    return {
      content: [{ type: "text", text: result.snapshot || "(empty page)" }],
      details: { elementCount: result.elementCount },
    };
  },

  renderCall(_args, theme, _context) {
    return new Text(theme.fg("toolTitle", theme.bold("browser-snapshot")), 0, 0);
  },

  renderResult(result, { expanded, isPartial }, theme, _context) {
    if (isPartial) return new Text(theme.fg("warning", "Taking snapshot…"), 0, 0);
    const d = result.details as Record<string, unknown> | undefined;
    if (d?.error) return new Text(theme.fg("error", "Snapshot failed"), 0, 0);
    const ec = (d?.elementCount as number) ?? 0;
    const content = (result.content?.[0] as any)?.text ?? "";
    if (expanded) {
      const preview = content.slice(0, 400);
      let text = theme.fg("accent", `📋 ${ec} elements`);
      text += `\n${theme.fg("dim", preview)}`;
      if (content.length > 400) text += `\n${theme.fg("muted", `… ${content.length - 400} more chars`)}`;
      return new Text(text, 0, 0);
    }
    return new Text(theme.fg("accent", `📋 ${ec} elements (expand)`), 0, 0);
  },
});

// ============================================================
// Tool: browser-click
// ============================================================
const browserClickTool = defineTool({
  name: "browser-click",
  label: "Click Element",
  description:
    "Click an element on the page by its @e reference ID (e.g., @e5). " +
    "Use element references from browser-navigate or browser-snapshot output.",
  parameters: Type.Object({
    ref: Type.String({ description: "Element reference like @e5 (from the accessibility tree)" }),
    taskId: Type.Optional(Type.String({ description: "Session ID (auto-populated)" })),
  }),

  async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
    const { ref, taskId: tid } = params as { ref: string; taskId?: string };
    const result = await router.click(tid ?? taskId(ctx), ref);
    updateFooterStatus(ctx);

    if (!result.success) {
      return {
        content: [{ type: "text", text: `Click failed: ${result.error ?? "unknown"}` }],
        details: { error: true },
      };
    }

    const lines = [`Clicked ${ref}`, result.newUrl ? `URL: ${result.newUrl}` : "", result.newTitle ? `Title: ${result.newTitle}` : ""].filter(Boolean);
    return {
      content: [{ type: "text", text: lines.join("\n") }],
      details: { newUrl: result.newUrl, newTitle: result.newTitle },
    };
  },

  renderCall(args, theme, _context) {
    return new Text(`${theme.fg("toolTitle", theme.bold("browser-click"))} ${theme.fg("accent", args.ref)}`, 0, 0);
  },

  renderResult(result, _options, theme, _context) {
    const d = result.details as Record<string, unknown> | undefined;
    if (d?.error) return new Text(theme.fg("error", `Click failed: ${d.error}`), 0, 0);
    const newUrl = d?.newUrl as string | undefined;
    if (newUrl) return new Text(theme.fg("success", `✅ → ${newUrl}`), 0, 0);
    return new Text(theme.fg("success", "✅ clicked"), 0, 0);
  },
});

// ============================================================
// Tool: browser-type
// ============================================================
const browserTypeTool = defineTool({
  name: "browser-type",
  label: "Type Text",
  description:
    "Type text into an input element identified by its @e reference ID. " +
    "Clears existing content before typing. Use after browser-navigate or browser-snapshot.",
  parameters: Type.Object({
    ref: Type.String({ description: "Element reference like @e5 (must be a textbox, searchbox, or combobox)" }),
    text: Type.String({ description: "Text to type into the element" }),
    taskId: Type.Optional(Type.String({ description: "Session ID (auto-populated)" })),
  }),

  async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
    const { ref, text, taskId: tid } = params as { ref: string; text: string; taskId?: string };
    const result = await router.type(tid ?? taskId(ctx), ref, text);
    updateFooterStatus(ctx);

    if (!result.success) {
      return {
        content: [{ type: "text", text: `Type failed: ${result.error ?? "unknown"}` }],
        details: { error: true },
      };
    }

    return {
      content: [{ type: "text", text: `Typed "${text}" into ${ref}` }],
      details: { typed: true, ref, text },
    };
  },

  renderCall(args, theme, _context) {
    return new Text(`${theme.fg("toolTitle", theme.bold("browser-type"))} ${theme.fg("accent", args.ref)} "${args.text}"`, 0, 0);
  },

  renderResult(result, _options, theme, _context) {
    const d = result.details as Record<string, unknown> | undefined;
    if (d?.error) return new Text(theme.fg("error", `Type failed: ${d.error}`), 0, 0);
    return new Text(theme.fg("success", `📝 typed "${d?.text || "?"}"`), 0, 0);
  },
});

// ============================================================
// Tool: browser-scroll
// ============================================================
const browserScrollTool = defineTool({
  name: "browser-scroll",
  label: "Scroll Page",
  description: "Scroll the page up or down by approximately one viewport height.",
  parameters: Type.Object({
    direction: StringEnum(["up", "down"] as const, { description: "Scroll direction" }),
    taskId: Type.Optional(Type.String({ description: "Session ID (auto-populated)" })),
  }),

  async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
    const { direction, taskId: tid } = params as { direction: "up" | "down"; taskId?: string };
    const result = await router.scroll(tid ?? taskId(ctx), direction);
    updateFooterStatus(ctx);

    if (!result.success) {
      return {
        content: [{ type: "text", text: `Scroll failed: ${result.error ?? "unknown"}` }],
        details: { error: true },
      };
    }

    return {
      content: [{ type: "text", text: `Scrolled ${direction}` }],
      details: { direction },
    };
  },

  renderCall(args, theme, _context) {
    return new Text(`${theme.fg("toolTitle", theme.bold("browser-scroll"))} ${theme.fg("dim", args.direction)}`, 0, 0);
  },

  renderResult(result, _options, theme, _context) {
    const d = result.details as Record<string, unknown> | undefined;
    if (d?.error) return new Text(theme.fg("error", "Scroll failed"), 0, 0);
    return new Text(theme.fg("dim", `↕ ${d?.direction || "?"}`), 0, 0);
  },
});

// ============================================================
// Tool: browser-screenshot
// ============================================================
const browserScreenshotTool = defineTool({
  name: "browser-screenshot",
  label: "Take Screenshot",
  description:
    "Take a screenshot of the current page for visual analysis. " +
    "Returns a data URI that vision-capable models can examine.",
  parameters: Type.Object({
    question: Type.Optional(Type.String({ description: "Optional — if provided and the model has vision, it will answer questions about the screenshot" })),
    taskId: Type.Optional(Type.String({ description: "Session ID (auto-populated)" })),
  }),

  async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
    const { taskId: tid } = params as { taskId?: string };
    const result = await router.screenshot(tid ?? taskId(ctx));

    if (!result.success) {
      return {
        content: [{ type: "text", text: `Screenshot failed: ${result.error ?? "unknown"}` }],
        details: { error: true },
      };
    }

    return {
      content: [
        { type: "text", text: "Screenshot captured:" },
        { type: "image", source: { type: "base64", mediaType: "image/png", data: result.dataUri.replace("data:image/png;base64,", "") } },
      ],
      details: { screenshot: true },
    };
  },

  renderCall(_args, theme, _context) {
    return new Text(theme.fg("toolTitle", theme.bold("browser-screenshot")), 0, 0);
  },

  renderResult(_result, _options, theme, _context) {
    return new Text(theme.fg("accent", "📸 Screenshot captured"), 0, 0);
  },
});

// ============================================================
// Tool: browser-back
// ============================================================
const browserBackTool = defineTool({
  name: "browser-back",
  label: "Go Back",
  description: "Navigate back in browser history.",
  parameters: Type.Object({
    taskId: Type.Optional(Type.String({ description: "Session ID (auto-populated)" })),
  }),

  async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
    const { taskId: tid } = params as { taskId?: string };
    const result = await router.goBack(tid ?? taskId(ctx));
    updateFooterStatus(ctx);

    if (!result.success) {
      return {
        content: [{ type: "text", text: `Go back failed: ${result.error ?? "unknown"}` }],
        details: { error: true },
      };
    }

    return {
      content: [{ type: "text", text: `Went back to: ${result.newUrl || "?"}` }],
      details: { newUrl: result.newUrl, newTitle: result.newTitle },
    };
  },

  renderCall(_args, theme, _context) {
    return new Text(theme.fg("toolTitle", theme.bold("browser-back")), 0, 0);
  },

  renderResult(result, _options, theme, _context) {
    const d = result.details as Record<string, unknown> | undefined;
    if (d?.error) return new Text(theme.fg("error", "Go back failed"), 0, 0);
    return new Text(theme.fg("dim", `← ${(d?.newUrl as string) || ""}`), 0, 0);
  },
});

// ============================================================
// Tool: browser-press
// ============================================================
const browserPressTool = defineTool({
  name: "browser-press",
  label: "Press Key",
  description:
    'Press a keyboard key (e.g., "Enter", "Tab", "Escape", "ArrowDown", "ArrowUp"). ' +
    "Useful for submitting forms, dismissing dialogs, or navigating dropdowns.",
  parameters: Type.Object({
    key: Type.String({ description: "Key to press (e.g., 'Enter', 'Tab', 'Escape', 'ArrowDown', 'ArrowUp')" }),
    taskId: Type.Optional(Type.String({ description: "Session ID (auto-populated)" })),
  }),

  async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
    const { key, taskId: tid } = params as { key: string; taskId?: string };
    const result = await router.press(tid ?? taskId(ctx), key);
    updateFooterStatus(ctx);

    if (!result.success) {
      return {
        content: [{ type: "text", text: `Press failed: ${result.error ?? "unknown"}` }],
        details: { error: true },
      };
    }

    return {
      content: [{ type: "text", text: `Pressed "${key}"` }],
      details: { key },
    };
  },

  renderCall(args, theme, _context) {
    return new Text(`${theme.fg("toolTitle", theme.bold("browser-press"))} ${theme.fg("accent", args.key)}`, 0, 0);
  },

  renderResult(result, _options, theme, _context) {
    const d = result.details as Record<string, unknown> | undefined;
    if (d?.error) return new Text(theme.fg("error", "Press failed"), 0, 0);
    return new Text(theme.fg("dim", `⌨ ${d?.key || ""}`), 0, 0);
  },
});

// ============================================================
// Tool: browser-console
// ============================================================
const browserConsoleTool = defineTool({
  name: "browser-console",
  label: "Browser Console",
  description:
    "Execute JavaScript in the current page context and see the result. " +
    "Useful for inspecting page state, reading hidden content, or debugging.",
  parameters: Type.Object({
    expression: Type.String({ description: "JavaScript expression to evaluate in the page context" }),
    taskId: Type.Optional(Type.String({ description: "Session ID (auto-populated)" })),
  }),

  async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
    const { expression, taskId: tid } = params as { expression: string; taskId?: string };
    const result = await router.evaluate(tid ?? taskId(ctx), expression);

    if (!result.success) {
      return {
        content: [{ type: "text", text: `Evaluation failed: ${result.error ?? "unknown"}` }],
        details: { error: true },
      };
    }

    const formatted = typeof result.result === "string" ? result.result : JSON.stringify(result.result, null, 2);
    return {
      content: [{ type: "text", text: formatted ?? "undefined" }],
      details: { result: result.result },
    };
  },

  renderCall(args, theme, _context) {
    return new Text(`${theme.fg("toolTitle", theme.bold("browser-console"))} ${theme.fg("dim", args.expression.slice(0, 60))}`, 0, 0);
  },

  renderResult(result, _options, theme, _context) {
    const d = result.details as Record<string, unknown> | undefined;
    if (d?.error) return new Text(theme.fg("error", "JS eval failed"), 0, 0);
    return new Text(theme.fg("dim", `JS → ${JSON.stringify(d?.result)?.slice(0, 80) || "ok"}`), 0, 0);
  },
});

// ============================================================
// Command: /browser-status
// ============================================================
const browserStatusCommand = {
  description: "Show browser backend health and active sessions",
  handler: async (_args: string, ctx: any) => {
    const status = sessionManager.getStatus();
    const active = sessionManager.getActiveSessions();
    let msg = `Browser status: ${status}`;
    if (active.length > 0) {
      msg += `\nActive sessions: ${active.length}`;
      for (const s of active) {
        msg += `\n  • [${s.level}] ${s.currentUrl || "(pending)"}`;
        if (s.currentTitle) msg += ` — ${s.currentTitle}`;
      }
    } else {
      // Check playright browser state
      const pw = sessionManager.getPlaywrightBrowser();
      if (pw) {
        msg += `\n${pw.isConnected() ? "🟢" : "🔴"} Playwright browser available`;
      }
    }
    ctx.ui.notify(msg, "info");
  },
};

// ============================================================
// Extension entry point
// ============================================================
export default function (pi: ExtensionAPI) {
  // Register tools
  pi.registerTool(browserNavigateTool);
  pi.registerTool(browserSnapshotTool);
  pi.registerTool(browserClickTool);
  pi.registerTool(browserTypeTool);
  pi.registerTool(browserScrollTool);
  pi.registerTool(browserScreenshotTool);
  pi.registerTool(browserBackTool);
  pi.registerTool(browserPressTool);
  pi.registerTool(browserConsoleTool);

  // Register command
  pi.registerCommand("browser-status", browserStatusCommand);

  // --- Startup --------------------------------------------------
  pi.on("session_start", async (_event, ctx) => {
    ctx.ui.notify("🌐 Browser extension loaded. Try: navigate to a URL or browse interactively.", "info");
    updateFooterStatus(ctx);
  });

  // --- Cleanup --------------------------------------------------
  pi.on("session_shutdown", async (_event, ctx) => {
    await import("./backend/playwright-backend").then(m => m.cleanupAll()).catch(() => {});
    await sessionManager.removeAll();
    try {
      ctx?.ui?.setStatus?.("browser", "");
    } catch {
      // ctx.ui may not be available during shutdown
    }
  });
}
