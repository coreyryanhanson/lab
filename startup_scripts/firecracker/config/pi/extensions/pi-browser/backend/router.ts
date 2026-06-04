/**
 * Backend Router — auto-escalation logic and backend dispatch.
 *
 * Dispatches to Level 1 (fetch), Level 2 (Playwright Chromium), or
 * Level 3 (Invisible Playwright stealth Firefox) based on strategy
 * and auto-detection.
 */

import * as fetchBackend from "./fetch-backend";
import * as playwrightBackend from "./playwright-backend";
import * as stealthBackend from "./stealth-backend";
import { sessionManager, type BackendLevel } from "../utils/session-manager";
import { validateUrl } from "../utils/url-safety";

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

  // --- URL Safety Check ---
  const safety = validateUrl(normalizedUrl);
  if (!safety.safe) {
    return {
      success: false, url: normalizedUrl, title: "", content: safety.reason || "URL blocked",
      backendUsed: "fetch", error: `URL blocked: ${safety.reason}`,
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

      // Bot detected on successful load — try stealth escalation
      if (result.botDetected && strategy === "auto") {
        sessionManager.updateSession(taskId, { level: "stealth" });
        const stealthResult = await stealthBackend.navigate(result.url, taskId, timeoutMs);
        if (stealthResult.success) {
          return {
            success: true,
            url: stealthResult.url,
            title: stealthResult.title,
            content: stealthResult.snapshot,
            elementCount: stealthResult.elementCount,
            backendUsed: "stealth",
            botDetectionWarning: true,
          };
        }
        // Stealth failed — fall through to return chromium result with warning
      }

      const botWarn = result.botDetected && strategy === "auto";
      return {
        success: true, url: result.url, title: result.title,
        content: result.snapshot,
        elementCount: result.elementCount,
        backendUsed: "chromium",
        botDetectionWarning: botWarn,
      };
    }

    // Playwright failed — escalate to Level 3 (stealth) if auto
    if (result.botDetected && strategy === "auto") {
      sessionManager.updateSession(taskId, { level: "stealth" });
      const stealthResult = await stealthBackend.navigate(result.url, taskId, timeoutMs);
      if (stealthResult.success) {
        return {
          success: true,
          url: stealthResult.url,
          title: stealthResult.title,
          content: stealthResult.snapshot,
          elementCount: stealthResult.elementCount,
          backendUsed: "stealth",
          botDetectionWarning: true,
        };
      }
      // Stealth also failed — report original error
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

  // --- Level 3: Invisible Playwright Stealth ---
  if (strategy === "stealth") {
    sessionManager.createSession(taskId, "stealth");
    const session = sessionManager.getSession(taskId)!;
    session.currentUrl = normalizedUrl;

    const result = await stealthBackend.navigate(normalizedUrl, taskId, timeoutMs);

    if (result.success) {
      session.currentUrl = result.url;
      session.currentTitle = result.title;
      return {
        success: true,
        url: result.url,
        title: result.title,
        content: result.snapshot,
        elementCount: result.elementCount,
        backendUsed: "stealth",
      };
    }

    await stealthBackend.cleanup(taskId).catch(() => {});
    sessionManager.removeSession(taskId);
    return {
      success: false, url: result.url, title: "", content: result.error || "Unknown error",
      backendUsed: "stealth",
      error: result.error,
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

  if (session.level === "stealth") {
    return stealthBackend.snapshot(tid);
  }

  return { success: false, snapshot: "", elementCount: 0, error: `Snapshot requires an interactive browser (Level 2+). Session is on ${session.level}.` };
}

// ─── Click ────────────────────────────────────────────────────────────

export async function click(taskId: string | undefined, ref: string): Promise<InteractionResult> {
  const tid = taskId ?? "default";
  const session = sessionManager.getSession(tid);
  if (!session) return { success: false, error: "No active session" };
  if (session.level === "chromium") return playwrightBackend.click(tid, ref);
  if (session.level === "stealth") return stealthBackend.click(tid, ref);
  return { success: false, error: `Click requires an interactive browser. Session is on ${session.level}.` };
}

// ─── Type ─────────────────────────────────────────────────────────────

export async function type(taskId: string | undefined, ref: string, text: string): Promise<InteractionResult> {
  const tid = taskId ?? "default";
  const session = sessionManager.getSession(tid);
  if (!session) return { success: false, error: "No active session" };
  if (session.level === "chromium") return playwrightBackend.type(tid, ref, text);
  if (session.level === "stealth") return stealthBackend.type(tid, ref, text);
  return { success: false, error: `Type requires an interactive browser. Session is on ${session.level}.` };
}

// ─── Scroll ───────────────────────────────────────────────────────────

export async function scroll(taskId: string | undefined, direction: "up" | "down"): Promise<InteractionResult> {
  const tid = taskId ?? "default";
  const session = sessionManager.getSession(tid);
  if (!session) return { success: false, error: "No active session" };
  if (session.level === "chromium") return playwrightBackend.scroll(tid, direction);
  if (session.level === "stealth") return stealthBackend.scroll(tid, direction);
  return { success: false, error: `Scroll requires an interactive browser. Session is on ${session.level}.` };
}

// ─── Screenshot ───────────────────────────────────────────────────────

export async function screenshot(taskId?: string): Promise<ScreenshotResult> {
  const tid = taskId ?? "default";
  const session = sessionManager.getSession(tid);
  if (!session) return { success: false, dataUri: "", error: "No active session" };
  if (session.level === "chromium") return playwrightBackend.screenshot(tid);
  if (session.level === "stealth") return stealthBackend.screenshot(tid);
  return { success: false, dataUri: "", error: `Screenshot requires an interactive browser. Session is on ${session.level}.` };
}

// ─── Go Back ──────────────────────────────────────────────────────────

export async function goBack(taskId?: string): Promise<InteractionResult> {
  const tid = taskId ?? "default";
  const session = sessionManager.getSession(tid);
  if (!session) return { success: false, error: "No active session" };
  if (session.level === "chromium") return playwrightBackend.goBack(tid);
  if (session.level === "stealth") return stealthBackend.goBack(tid);
  return { success: false, error: `Back navigation requires an interactive browser. Session is on ${session.level}.` };
}

// ─── Press Key ────────────────────────────────────────────────────────

export async function press(taskId: string | undefined, key: string): Promise<InteractionResult> {
  const tid = taskId ?? "default";
  const session = sessionManager.getSession(tid);
  if (!session) return { success: false, error: "No active session" };
  if (session.level === "chromium") return playwrightBackend.press(tid, key);
  if (session.level === "stealth") return stealthBackend.press(tid, key);
  return { success: false, error: `Key press requires an interactive browser. Session is on ${session.level}.` };
}

// ─── Console & Eval ──────────────────────────────────────────────────

export async function evaluate(taskId: string | undefined, expression: string): Promise<{ success: boolean; result?: unknown; error?: string }> {
  const tid = taskId ?? "default";
  const session = sessionManager.getSession(tid);
  if (!session) return { success: false, error: "No active session" };
  if (session.level === "chromium") return playwrightBackend.evaluate(tid, expression);
  if (session.level === "stealth") return stealthBackend.evaluate(tid, expression);
  return { success: false, error: `JS evaluation requires an interactive browser. Session is on ${session.level}.` };
}
