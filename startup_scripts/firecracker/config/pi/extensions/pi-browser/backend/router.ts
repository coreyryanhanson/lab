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
  /** Auto-captured snapshot after interaction, when available */
  snapshot?: string;
  /** Number of elements in the auto-captured snapshot */
  elementCount?: number;
}

export interface ScreenshotResult {
  success: boolean;
  dataUri: string;
  error?: string;
}

// ─── Helpers ────────────────────────────────────────────────────────────

/**
 * Try to escalate to stealth backend when bot detection is triggered
 * and the strategy is auto. Returns the stealth result if successful,
 * or null if escalation wasn't applicable or failed.
 */
async function escalateToStealthIfAuto(
  result: { url: string; error?: string; botDetected?: boolean },
  strategy: string,
  taskId: string,
  timeoutMs: number,
): Promise<{ success: boolean; url: string; title: string; content: string; elementCount?: number; backendUsed: BackendLevel; botDetectionWarning: boolean; error?: string } | null> {
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
  }
  return null;
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
      const escalated = await escalateToStealthIfAuto(result, strategy, taskId, timeoutMs);
      if (escalated) return escalated;
      // Stealth failed or not applicable — fall through to return chromium result with warning

      const botWarn = result.botDetected && strategy === "auto";
      const snapshotContent = result.snapshot
        ? compactSnapshot(result.snapshot, result.elementCount)
        : "";
      return {
        success: true, url: result.url, title: result.title,
        content: snapshotContent,
        elementCount: result.elementCount,
        backendUsed: "chromium",
        botDetectionWarning: botWarn,
      };
    }

    // Playwright failed — escalate to Level 3 (stealth) if auto
    const escalated = await escalateToStealthIfAuto(result, strategy, taskId, timeoutMs);
    if (escalated) return escalated;

    // Stealth also failed or not applicable — report original error
    // Re-check: if we had bot detection but escalation failed
    if (result.botDetected && strategy === "auto") {
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
      const snapshotContent = result.snapshot
        ? compactSnapshot(result.snapshot, result.elementCount)
        : "";
      return {
        success: true,
        url: result.url,
        title: result.title,
        content: snapshotContent,
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

export async function snapshot(taskId?: string, full?: boolean): Promise<SnapshotResult> {
  const tid = taskId ?? "default";
  const session = sessionManager.getSession(tid);

  if (!session) {
    return { success: false, snapshot: "", elementCount: 0, error: "No active session — navigate to a page first" };
  }

  let result: SnapshotResult;
  if (session.level === "chromium") {
    result = await playwrightBackend.snapshot(tid);
  } else if (session.level === "stealth") {
    result = await stealthBackend.snapshot(tid);
  } else {
    return { success: false, snapshot: "", elementCount: 0, error: `Snapshot requires an interactive browser (Level 2+). Session is on ${session.level}.` };
  }

  // Apply compact mode if not full
  if (result.success && !full) {
    result.snapshot = compactSnapshot(result.snapshot, result.elementCount);
  }

  return result;
}

/**
 * Truncate a snapshot to a compact view (~2500 chars) that still shows
 * the key structure. Appends a hint to use full=true for the complete tree.
 *
 * For very large snapshots (>8000 chars), preserves the first ~2000 chars
 * of structural content (top of the tree including headings/landmarks)
 * plus a structural summary showing what was cut.
 */
function compactSnapshot(snapshot: string, elementCount: number): string {
  if (snapshot.length <= 2800) return snapshot;

  const limit = 2500;
  const remaining = elementCount > 0 ? elementCount : undefined;

  // For very large pages (>8000 chars), try to preserve the top of the tree
  // which typically contains page structure (banner, navigation, headings).
  if (snapshot.length > 8000) {
    // Keep first ~2000 chars of the tree top (usually page structure)
    const topLimit = 2000;
    let topCut = snapshot.lastIndexOf("\n", topLimit);
    if (topCut < topLimit / 2) topCut = topLimit;

    const topSection = snapshot.slice(0, topCut);
    const bottomHint = remaining
      ? `\n… ${snapshot.length - topCut} more chars, ${remaining} elements total (use full=true for complete tree)`
      : `\n… ${snapshot.length - topCut} more chars (use full=true for complete tree)`;
    return topSection + bottomHint;
  }

  // Moderate-sized pages: cut at a natural breakpoint near the limit
  let cut = snapshot.lastIndexOf("\n", limit);
  if (cut < limit / 2) cut = limit;

  const tail = remaining
    ? `\n… ${snapshot.length - cut} more chars, ${remaining} elements total (use full=true for complete tree)`
    : `\n… ${snapshot.length - cut} more chars (use full=true for complete tree)`;

  return snapshot.slice(0, cut) + tail;
}

/** Apply compact truncation to auto-snapshots in interaction results */
function compactInteractionResult(result: InteractionResult): InteractionResult {
  if (result.success && result.snapshot && result.elementCount !== undefined) {
    result.snapshot = compactSnapshot(result.snapshot, result.elementCount);
  }
  return result;
}

// ─── Click ────────────────────────────────────────────────────────────

export async function click(taskId: string | undefined, ref: string): Promise<InteractionResult> {
  const tid = taskId ?? "default";
  const session = sessionManager.getSession(tid);
  if (!session) return { success: false, error: "No active session" };
  let result: InteractionResult;
  if (session.level === "chromium") result = await playwrightBackend.click(tid, ref);
  else if (session.level === "stealth") result = await stealthBackend.click(tid, ref);
  else return { success: false, error: `Click requires an interactive browser. Session is on ${session.level}.` };
  return compactInteractionResult(result);
}

// ─── Type ─────────────────────────────────────────────────────────────

export async function type(taskId: string | undefined, ref: string, text: string): Promise<InteractionResult> {
  const tid = taskId ?? "default";
  const session = sessionManager.getSession(tid);
  if (!session) return { success: false, error: "No active session" };
  let result: InteractionResult;
  if (session.level === "chromium") result = await playwrightBackend.type(tid, ref, text);
  else if (session.level === "stealth") result = await stealthBackend.type(tid, ref, text);
  else return { success: false, error: `Type requires an interactive browser. Session is on ${session.level}.` };
  return compactInteractionResult(result);
}

// ─── Scroll ───────────────────────────────────────────────────────────

export async function scroll(taskId: string | undefined, direction: "up" | "down"): Promise<InteractionResult> {
  const tid = taskId ?? "default";
  const session = sessionManager.getSession(tid);
  if (!session) return { success: false, error: "No active session" };
  let result: InteractionResult;
  if (session.level === "chromium") result = await playwrightBackend.scroll(tid, direction);
  else if (session.level === "stealth") result = await stealthBackend.scroll(tid, direction);
  else return { success: false, error: `Scroll requires an interactive browser. Session is on ${session.level}.` };
  return compactInteractionResult(result);
}

// ─── Screenshot ───────────────────────────────────────────────────────

export async function screenshot(taskId?: string, fullPage?: boolean): Promise<ScreenshotResult> {
  const tid = taskId ?? "default";
  const session = sessionManager.getSession(tid);
  if (!session) return { success: false, dataUri: "", error: "No active session" };
  if (session.level === "chromium") return playwrightBackend.screenshot(tid, fullPage ?? false);
  if (session.level === "stealth") return stealthBackend.screenshot(tid);
  return { success: false, dataUri: "", error: `Screenshot requires an interactive browser. Session is on ${session.level}.` };
}

// ─── Go Back ──────────────────────────────────────────────────────────

export async function goBack(taskId?: string): Promise<InteractionResult> {
  const tid = taskId ?? "default";
  const session = sessionManager.getSession(tid);
  if (!session) return { success: false, error: "No active session" };
  let result: InteractionResult;
  if (session.level === "chromium") result = await playwrightBackend.goBack(tid);
  else if (session.level === "stealth") result = await stealthBackend.goBack(tid);
  else return { success: false, error: `Back navigation requires an interactive browser. Session is on ${session.level}.` };
  return compactInteractionResult(result);
}

// ─── Press Key ────────────────────────────────────────────────────────

export async function press(taskId: string | undefined, key: string): Promise<InteractionResult> {
  const tid = taskId ?? "default";
  const session = sessionManager.getSession(tid);
  if (!session) return { success: false, error: "No active session" };
  let result: InteractionResult;
  if (session.level === "chromium") result = await playwrightBackend.press(tid, key);
  else if (session.level === "stealth") result = await stealthBackend.press(tid, key);
  else return { success: false, error: `Key press requires an interactive browser. Session is on ${session.level}.` };
  return compactInteractionResult(result);
}

// ─── Images ────────────────────────────────────────────────────────────

export interface GetImagesResult {
  success: boolean;
  images: Array<{ src: string; alt: string; width: number; height: number }>;
  count: number;
  error?: string;
}

export async function getImages(taskId?: string): Promise<GetImagesResult> {
  const tid = taskId ?? "default";
  const session = sessionManager.getSession(tid);
  if (!session) return { success: false, images: [], count: 0, error: "No active session" };
  if (session.level === "chromium") {
    const result = await playwrightBackend.getImages(tid);
    return { success: result.success, images: result.images, count: result.images.length, error: result.error };
  }
  if (session.level === "stealth") {
    const result = await stealthBackend.getImages(tid);
    return { success: result.success, images: result.images, count: result.images.length, error: result.error };
  }
  return { success: false, images: [], count: 0, error: `Images require an interactive browser. Session is on ${session.level}.` };
}

// ─── Console & Eval ──────────────────────────────────────────────────

export async function getConsoleMessages(taskId?: string): Promise<{ success: boolean; messages: Array<{ type: string; text: string }>; error?: string }> {
  const tid = taskId ?? "default";
  const session = sessionManager.getSession(tid);
  if (!session) return { success: false, messages: [], error: "No active session" };
  if (session.level === "chromium") {
    const msgs = await playwrightBackend.getConsoleMessages(tid);
    return { success: true, messages: msgs };
  }
  if (session.level === "stealth") {
    const msgs = await stealthBackend.getConsoleMessages(tid);
    return { success: true, messages: msgs };
  }
  return { success: false, messages: [], error: `Console requires an interactive browser. Session is on ${session.level}.` };
}

export async function evaluate(taskId: string | undefined, expression: string): Promise<{ success: boolean; result?: unknown; error?: string }> {
  const tid = taskId ?? "default";
  const session = sessionManager.getSession(tid);
  if (!session) return { success: false, error: "No active session" };
  if (session.level === "chromium") return playwrightBackend.evaluate(tid, expression);
  if (session.level === "stealth") return stealthBackend.evaluate(tid, expression);
  return { success: false, error: `JS evaluation requires an interactive browser. Session is on ${session.level}.` };
}

export async function clearConsole(taskId?: string): Promise<{ success: boolean }> {
  const tid = taskId ?? "default";
  const session = sessionManager.getSession(tid);
  if (!session) return { success: false };
  if (session.level === "chromium") {
    await playwrightBackend.clearConsole(tid);
    return { success: true };
  }
  if (session.level === "stealth") {
    await stealthBackend.clearConsole(tid);
    return { success: true };
  }
  return { success: false };
}
