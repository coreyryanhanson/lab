/**
 * Backend Router — auto-escalation logic and backend dispatch.
 *
 * Dispatches to Level 1 (fetch) or Level 2 (Playwright Chromium) based
 * on strategy and auto-detection. Level 3 (stealth) will be added in Phase 3.
 */

import * as fetchBackend from "./fetch-backend";
import * as playwrightBackend from "./playwright-backend";
import { sessionManager, type BackendLevel } from "../utils/session-manager";

// ─── Types ────────────────────────────────────────────────────────────

export interface NavigateOptions {
  strategy?: BackendLevel | "auto";
  timeout?: number;
  signal?: AbortSignal;
  taskId?: string;
}

export interface NavigateResult {
  success: boolean;
  url: string;
  title: string;
  /** Page content — Markdown for fetch, accessibility tree for chromium */
  content: string;
  backendUsed: BackendLevel;
  /** Number of interactive elements (for a11y tree) */
  elementCount?: number;
  botDetectionWarning?: boolean;
  error?: string;
  statusCode?: number;
}

export interface SnapshotResult {
  success: boolean;
  snapshot: string;
  elementCount: number;
  error?: string;
}

export interface InteractionResult {
  success: boolean;
  error?: string;
  newUrl?: string;
  newTitle?: string;
}

export interface ScreenshotResult {
  success: boolean;
  dataUri: string;
  error?: string;
}

// ─── Navigation ───────────────────────────────────────────────────────

export async function navigate(
  url: string,
  options: NavigateOptions = {},
): Promise<NavigateResult> {
  const strategy = options.strategy ?? "auto";
  const timeoutMs = (options.timeout ?? 30) * 1000;
  const taskId = options.taskId ?? "default";

  let normalizedUrl: string;
  try {
    normalizedUrl = new URL(url).href;
  } catch {
    return {
      success: false, url, title: "", content: `Invalid URL: ${url}`,
      backendUsed: "fetch", error: "Invalid URL",
    };
  }

  // --- Level 1: HTTP Fetch ---
  if (strategy === "fetch" || strategy === "auto") {
    sessionManager.createSession(taskId, "fetch");
    const session = sessionManager.getSession(taskId)!;
    session.currentUrl = normalizedUrl;

    const result = await fetchBackend.navigate(normalizedUrl, timeoutMs, options.signal);

    if (result.success && !result.needsJavaScript) {
      session.currentUrl = result.url;
      session.currentTitle = result.title;
      return {
        success: true, url: result.url, title: result.title,
        content: result.content,
        backendUsed: "fetch",
        statusCode: result.statusCode,
      };
    }

    if (result.needsJavaScript && strategy === "auto") {
      // Page needs JS — escalate to Level 2
      sessionManager.updateSession(taskId, { level: "chromium" });
      // Fall through to Playwright
    } else if (result.needsJavaScript) {
      // User explicitly asked for fetch, but page needs JS
      session.currentUrl = result.url;
      session.currentTitle = result.title;
      return {
        success: true, url: result.url, title: result.title,
        content: result.content + "\n\n⚠ This page appears to need JavaScript for full rendering.",
        backendUsed: "fetch", botDetectionWarning: true,
        statusCode: result.statusCode,
      };
    } else {
      // Fetch failed entirely
      await playwrightBackend.cleanup(taskId).catch(() => {});
      sessionManager.removeSession(taskId);
      return {
        success: false, url: result.url, title: result.title,
        content: result.content,
        backendUsed: "fetch", error: result.error,
        statusCode: result.statusCode,
      };
    }
  }

  // --- Level 2: Playwright Chromium ---
  if (strategy === "chromium" || strategy === "auto") {
    sessionManager.createSession(taskId, "chromium");
    const session = sessionManager.getSession(taskId)!;
    session.currentUrl = normalizedUrl;

    const result = await playwrightBackend.navigate(
      normalizedUrl, taskId, timeoutMs, options.signal,
    );

    if (result.success) {
      session.currentUrl = result.url;
      session.currentTitle = result.title;

      const botWarn = result.botDetected && strategy === "auto";

      return {
        success: true, url: result.url, title: result.title,
        content: result.snapshot,
        elementCount: result.elementCount,
        backendUsed: "chromium",
        botDetectionWarning: botWarn,
      };
    }

    // Playwright failed
    if (result.botDetected && strategy === "auto") {
      // Would escalate to Level 3 here (Phase 3)
      session.updateSession(taskId, { level: "stealth" });
      return {
        success: false, url: result.url, title: "",
        content: result.error || "Unknown error",
        backendUsed: "chromium",
        botDetectionWarning: true,
        error: result.error,
      };
    }

    // Non-bot error or explicit strategy
    await playwrightBackend.cleanup(taskId).catch(() => {});
    sessionManager.removeSession(taskId);
    return {
      success: false, url: result.url, title: "",
      content: result.error || "Unknown error",
      backendUsed: "chromium",
      error: result.error,
    };
  }

  // --- Level 3: Stealth (Phase 3) ---
  if (strategy === "stealth") {
    return {
      success: false, url: normalizedUrl, title: "", content: "",
      backendUsed: "stealth",
      error: "Stealth backend not yet implemented (planned for Phase 3)",
    };
  }

  // Fallback
  return {
    success: false, url: normalizedUrl, title: "", content: "Unknown strategy",
    backendUsed: "fetch", error: "Unknown strategy",
  };
}

// ─── Snapshot (current page, Level 2+) ────────────────────────────────

export async function snapshot(taskId?: string): Promise<SnapshotResult> {
  const tid = taskId ?? "default";
  const session = sessionManager.getSession(tid);

  if (!session) {
    return { success: false, snapshot: "", elementCount: 0, error: "No active session — navigate to a page first" };
  }

  if (session.level === "chromium") {
    return playwrightBackend.snapshot(tid);
  }

  if (session.level === "fetch") {
    return { success: false, snapshot: "", elementCount: 0, error: "Snapshot requires an interactive browser (Level 2+). Use strategy='chromium' when navigating." };
  }

  return { success: false, snapshot: "", elementCount: 0, error: `Backend ${session.level} doesn't support snapshots` };
}

// ─── Click ────────────────────────────────────────────────────────────

export async function click(taskId: string | undefined, ref: string): Promise<InteractionResult> {
  const tid = taskId ?? "default";
  const session = sessionManager.getSession(tid);
  if (!session) return { success: false, error: "No active session" };
  if (session.level !== "chromium") return { success: false, error: "Click requires an interactive browser (Level 2+)" };
  return playwrightBackend.click(tid, ref);
}

// ─── Type ─────────────────────────────────────────────────────────────

export async function type(taskId: string | undefined, ref: string, text: string): Promise<InteractionResult> {
  const tid = taskId ?? "default";
  const session = sessionManager.getSession(tid);
  if (!session) return { success: false, error: "No active session" };
  if (session.level !== "chromium") return { success: false, error: "Type requires an interactive browser (Level 2+)" };
  return playwrightBackend.type(tid, ref, text);
}

// ─── Scroll ───────────────────────────────────────────────────────────

export async function scroll(taskId: string | undefined, direction: "up" | "down"): Promise<InteractionResult> {
  const tid = taskId ?? "default";
  const session = sessionManager.getSession(tid);
  if (!session) return { success: false, error: "No active session" };
  if (session.level !== "chromium") return { success: false, error: "Scroll requires an interactive browser (Level 2+)" };
  return playwrightBackend.scroll(tid, direction);
}

// ─── Screenshot ───────────────────────────────────────────────────────

export async function screenshot(taskId?: string): Promise<ScreenshotResult> {
  const tid = taskId ?? "default";
  const session = sessionManager.getSession(tid);
  if (!session) return { success: false, dataUri: "", error: "No active session" };
  if (session.level !== "chromium") return { success: false, dataUri: "", error: "Screenshot requires an interactive browser (Level 2+)" };
  return playwrightBackend.screenshot(tid);
}

// ─── Go Back ──────────────────────────────────────────────────────────

export async function goBack(taskId?: string): Promise<InteractionResult> {
  const tid = taskId ?? "default";
  const session = sessionManager.getSession(tid);
  if (!session) return { success: false, error: "No active session" };
  if (session.level !== "chromium") return { success: false, error: "Back navigation requires an interactive browser (Level 2+)" };
  return playwrightBackend.goBack(tid);
}

// ─── Press Key ────────────────────────────────────────────────────────

export async function press(taskId: string | undefined, key: string): Promise<InteractionResult> {
  const tid = taskId ?? "default";
  const session = sessionManager.getSession(tid);
  if (!session) return { success: false, error: "No active session" };
  if (session.level !== "chromium") return { success: false, error: "Key press requires an interactive browser (Level 2+)" };
  return playwrightBackend.press(tid, key);
}

// ─── Console & Eval ──────────────────────────────────────────────────

export async function evaluate(taskId: string | undefined, expression: string): Promise<{ success: boolean; result?: unknown; error?: string }> {
  const tid = taskId ?? "default";
  const session = sessionManager.getSession(tid);
  if (!session) return { success: false, error: "No active session" };
  if (session.level !== "chromium") return { success: false, error: "JS evaluation requires an interactive browser (Level 2+)" };
  return playwrightBackend.evaluate(tid, expression);
}
