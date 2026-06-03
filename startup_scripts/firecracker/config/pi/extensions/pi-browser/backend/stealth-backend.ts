/**
 * Level 3: Invisible Playwright Stealth Backend
 *
 * Spawns a Python subprocess running the invisible_playwright bridge.
 * Communicates via JSON-RPC over stdin/stdout (line-delimited JSON).
 *
 * Uses Playwright's sync API (Firefox) with stealth patches for
 * anti-detection: patched fingerprint, Bezier mouse trajectories,
 * reCAPTCHA seeding, etc.
 */

import { spawn, type ChildProcess } from "node:child_process";
import { createInterface, type Interface } from "node:readline";
import { parseSnapshot } from "../utils/accessibility-tree";
import { sessionManager } from "../utils/session-manager";

// ─── Types ────────────────────────────────────────────────────────────

export interface StealthNavigateResult {
  success: boolean;
  url: string;
  title: string;
  snapshot: string;
  elementCount: number;
  backend: "stealth";
  error?: string;
}

export interface StealthSnapshotResult {
  success: boolean;
  snapshot: string;
  elementCount: number;
  error?: string;
}

export interface StealthInteractionResult {
  success: boolean;
  error?: string;
  newUrl?: string;
  newTitle?: string;
}

export interface StealthScreenshotResult {
  success: boolean;
  dataUri: string;
  error?: string;
}

// ─── Bridge Process ───────────────────────────────────────────────────

interface JsonRpcRequest {
  id: number;
  method: string;
  params?: Record<string, unknown>;
}

interface JsonRpcResponse {
  id: number;
  result?: unknown;
  error?: string;
}

const BRIDGE_PATH = __dirname + "/stealth_bridge.py";

let _process: ChildProcess | null = null;
let _readline: Interface | null = null;
let _requestId = 0;
let _pending = new Map<number, { resolve: (r: JsonRpcResponse) => void; reject: (e: Error) => void }>();
let _initialized = false;

async function call(method: string, params?: Record<string, unknown>): Promise<JsonRpcResponse> {
  ensureProcess();

  const id = ++_requestId;
  const msg: JsonRpcRequest = { id, method, params };

  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      _pending.delete(id);
      reject(new Error(`RPC call "${method}" timed out after 60s`));
    }, 60_000);

    _pending.set(id, {
      resolve: (r) => { clearTimeout(timeout); resolve(r); },
      reject: (e) => { clearTimeout(timeout); reject(e); },
    });

    _process!.stdin!.write(JSON.stringify(msg) + "\n");
  });
}

function ensureProcess(): void {
  if (_process && _process.exitCode === null) return;

  _process = spawn(BRIDGE_PATH, [], {
    stdio: ["pipe", "pipe", "pipe"],
    env: { ...process.env, PYTHONUNBUFFERED: "1" },
  });

  _readline = createInterface({ input: _process.stdout! });

  _readline.on("line", (line: string) => {
    try {
      const resp: JsonRpcResponse = JSON.parse(line.trim());
      if (resp.id === 0 && resp.result && (resp.result as any)?.ready) {
        // Startup ack
        return;
      }
      const pending = _pending.get(resp.id);
      if (pending) {
        _pending.delete(resp.id);
        if (resp.error) {
          pending.resolve(resp); // Resolve with error (not reject) — caller checks
        } else {
          pending.resolve(resp);
        }
      }
    } catch {
      // Ignore malformed lines
    }
  });

  _process.on("exit", (code) => {
    // Reject all pending
    for (const [id, p] of _pending) {
      p.reject(new Error(`Bridge process exited with code ${code}`));
      _pending.delete(id);
    }
    _process = null;
    _readline = null;
    _initialized = false;
  });
}

async function init(session: { taskId: string }): Promise<void> {
  if (_initialized) return;
  ensureProcess();
  const resp = await call("init", { seed: generateSeedFromTaskId(session.taskId) });
  if (resp.error) throw new Error(`Bridge init failed: ${resp.error}`);
  _initialized = true;
}

async function shutdown(): Promise<void> {
  if (!_process) return;
  try {
    await call("shutdown");
  } catch { /* ok */ }
  _process?.kill();
  _process = null;
  _readline = null;
  _initialized = false;
}

function generateSeedFromTaskId(taskId: string): number {
  let hash = 0;
  for (let i = 0; i < taskId.length; i++) {
    hash = ((hash << 5) - hash) + taskId.charCodeAt(i);
    hash |= 0; // Convert to 32bit integer
  }
  return Math.abs(hash) & 0x7fffffff;
}

// ─── Element Cache ─────────────────────────────────────────────────────

/** Cache of @e refs → { role, name, level } for interaction lookup */
const _elementCaches = new Map<string, Map<string, { role: string; name: string; level?: number }>>();

function getElementCache(taskId: string) {
  let cache = _elementCaches.get(taskId);
  if (!cache) {
    cache = new Map();
    _elementCaches.set(taskId, cache);
  }
  return cache;
}

function cacheSnapshot(taskId: string, snap: string): { text: string; count: number } {
  const parsed = parseSnapshot(snap);
  const cache = getElementCache(taskId);
  cache.clear();
  for (const [ref, node] of parsed.elements) {
    let level: number | undefined;
    for (const prop of node.props) {
      if (prop.startsWith("level=")) level = parseInt(prop.slice(6), 10);
    }
    cache.set(ref, { role: node.role, name: node.name, level });
  }
  return { text: parsed.text, count: parsed.count };
}

function lookupRef(taskId: string, ref: string): { role: string; name: string; level?: number } | null {
  const key = ref.startsWith("@") ? ref.slice(1) : ref;
  return getElementCache(taskId).get(key) ?? null;
}

// ─── A11y helpers ─────────────────────────────────────────────────────

function parseAriaSnapshot(snap: string): { text: string; count: number } {
  const parsed = parseSnapshot(snap);
  return { text: parsed.text, count: parsed.count };
}

// ─── API ──────────────────────────────────────────────────────────────

export async function navigate(
  url: string,
  taskId: string,
  timeoutMs: number = 30_000,
): Promise<StealthNavigateResult> {
  try {
    await init({ taskId });

    const navResp = await call("navigate", {
      url,
      timeout: timeoutMs,
      waitUntil: "networkidle",
    });
    if (navResp.error) {
      return {
        success: false, url, title: "", snapshot: "", elementCount: 0,
        backend: "stealth", error: navResp.error,
      };
    }

    const navResult = navResp.result as { url: string; title: string; statusCode: number };

    // Take accessibility snapshot and cache elements
    const snapResp = await call("snapshot");
    const snapRaw = (snapResp.result as { snapshot: string })?.snapshot || "";
    const { text: snapshotText, count: elementCount } = cacheSnapshot(taskId, snapRaw);

    sessionManager.updateSession(taskId, {
      currentUrl: navResult.url,
      currentTitle: navResult.title,
      level: "stealth",
    });

    return {
      success: true,
      url: navResult.url,
      title: navResult.title,
      snapshot: snapshotText,
      elementCount,
      backend: "stealth",
    };
  } catch (err: unknown) {
    return {
      success: false, url, title: "", snapshot: "", elementCount: 0,
      backend: "stealth",
      error: err instanceof Error ? err.message : String(err),
    };
  }
}

export async function snapshot(taskId: string): Promise<StealthSnapshotResult> {
  try {
    const resp = await call("snapshot");
    if (resp.error) return { success: false, snapshot: "", elementCount: 0, error: resp.error };

    const snapRaw = (resp.result as { snapshot: string })?.snapshot || "";
    const { text, count } = cacheSnapshot(taskId, snapRaw);
    return { success: true, snapshot: text, elementCount: count };
  } catch (err: unknown) {
    return { success: false, snapshot: "", elementCount: 0, error: err instanceof Error ? err.message : String(err) };
  }
}

export async function click(
  taskId: string,
  ref: string,
): Promise<StealthInteractionResult> {
  const node = lookupRef(taskId, ref);
  if (!node) {
    return { success: false, error: `Element ${ref} not found in cache. Refresh with browser-snapshot first.` };
  }

  try {
    const params: Record<string, unknown> = { role: node.role, name: node.name };
    if (node.level !== undefined) params.level = node.level;

    const resp = await call("click", params);
    if (resp.error) return { success: false, error: resp.error };

    const r = resp.result as { url?: string; title?: string };
    sessionManager.updateSession(taskId, { currentUrl: r.url, currentTitle: r.title });
    return { success: true, newUrl: r.url, newTitle: r.title };
  } catch (err: unknown) {
    return { success: false, error: err instanceof Error ? err.message : String(err) };
  }
}

export async function type(
  taskId: string,
  ref: string,
  text: string,
): Promise<StealthInteractionResult> {
  const node = lookupRef(taskId, ref);
  if (!node) {
    return { success: false, error: `Element ${ref} not found in cache. Refresh with browser-snapshot first.` };
  }

  try {
    const params: Record<string, unknown> = { role: node.role, name: node.name, text };
    if (node.level !== undefined) params.level = node.level;

    const resp = await call("type", params);
    if (resp.error) return { success: false, error: resp.error };
    return { success: true };
  } catch (err: unknown) {
    return { success: false, error: err instanceof Error ? err.message : String(err) };
  }
}

export async function scroll(taskId: string, direction: "up" | "down"): Promise<StealthInteractionResult> {
  try {
    const resp = await call("scroll", { direction });
    if (resp.error) return { success: false, error: resp.error };
    return { success: true };
  } catch (err: unknown) {
    return { success: false, error: err instanceof Error ? err.message : String(err) };
  }
}

export async function screenshot(taskId: string): Promise<StealthScreenshotResult> {
  try {
    const resp = await call("screenshot");
    if (resp.error) return { success: false, dataUri: "", error: resp.error };

    return { success: true, dataUri: (resp.result as { dataUri: string }).dataUri };
  } catch (err: unknown) {
    return { success: false, dataUri: "", error: err instanceof Error ? err.message : String(err) };
  }
}

export async function goBack(taskId: string): Promise<StealthInteractionResult> {
  try {
    const resp = await call("goBack");
    if (resp.error) return { success: false, error: resp.error };
    const r = resp.result as { url?: string; title?: string };
    return { success: true, newUrl: r.url, newTitle: r.title };
  } catch (err: unknown) {
    return { success: false, error: err instanceof Error ? err.message : String(err) };
  }
}

export async function press(taskId: string, key: string): Promise<StealthInteractionResult> {
  try {
    const resp = await call("press", { key });
    if (resp.error) return { success: false, error: resp.error };
    return { success: true };
  } catch (err: unknown) {
    return { success: false, error: err instanceof Error ? err.message : String(err) };
  }
}

export async function evaluate(taskId: string, expression: string): Promise<{ success: boolean; result?: unknown; error?: string }> {
  try {
    const resp = await call("evaluate", { expression });
    if (resp.error) return { success: false, error: resp.error };
    return { success: true, result: (resp.result as { result?: unknown }).result };
  } catch (err: unknown) {
    return { success: false, error: err instanceof Error ? err.message : String(err) };
  }
}

export async function cleanup(taskId: string): Promise<void> {
  _elementCaches.delete(taskId);
}

export async function cleanupAll(): Promise<void> {
  await shutdown();
}
