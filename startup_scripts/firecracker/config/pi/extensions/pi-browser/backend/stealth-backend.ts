/**
 * Level 3: Invisible Playwright Stealth Backend
 *
 * Spawns a per-task Python subprocess running the invisible_playwright bridge.
 * Communicates via JSON-RPC over stdin/stdout (line-delimited JSON).
 *
 * Uses Playwright's sync API (Firefox) with stealth patches for
 * anti-detection: patched fingerprint, Bezier mouse trajectories,
 * reCAPTCHA seeding, etc.
 *
 * Each task gets its own isolated bridge process and browser page,
 * ensuring session isolation across concurrent browsing sessions.
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
  /** Auto-captured snapshot after interaction */
  snapshot?: string;
  /** Number of elements in the auto-captured snapshot */
  elementCount?: number;
}

export interface StealthScreenshotResult {
  success: boolean;
  dataUri: string;
  error?: string;
}

// ─── JSON-RPC types ──────────────────────────────────────────────────

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

interface PendingCall {
  resolve: (r: JsonRpcResponse) => void;
  reject: (e: Error) => void;
}

const BRIDGE_PATH = __dirname + "/stealth_bridge.py";

// ─── Per-Task Bridge ──────────────────────────────────────────────────

/**
 * Wraps a single Python bridge process for one task.
 * Each task gets its own isolated browser page.
 */
class StealthBridge {
  process: ChildProcess | null = null;
  readline: Interface | null = null;
  requestId = 0;
  pending = new Map<number, PendingCall>();
  initialized = false;

  /**
   * Send a JSON-RPC call to this bridge process.
   * Creates the process on first use.
   */
  async call(method: string, params?: Record<string, unknown>): Promise<JsonRpcResponse> {
    this.ensureProcess();

    const id = ++this.requestId;
    const msg: JsonRpcRequest = { id, method, params };

    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`RPC call "${method}" timed out after 60s`));
      }, 60_000);

      this.pending.set(id, {
        resolve: (r) => { clearTimeout(timeout); resolve(r); },
        reject: (e) => { clearTimeout(timeout); reject(e); },
      });

      this.process!.stdin!.write(JSON.stringify(msg) + "\n");
    });
  }

  private ensureProcess(): void {
    if (this.process && this.process.exitCode === null) return;

    this.process = spawn(BRIDGE_PATH, [], {
      stdio: ["pipe", "pipe", "pipe"],
      env: { ...process.env, PYTHONUNBUFFERED: "1" },
    });

    this.readline = createInterface({ input: this.process.stdout! });

    this.readline.on("line", (line: string) => {
      try {
        const resp: JsonRpcResponse = JSON.parse(line.trim());
        if (resp.id === 0 && resp.result && (resp.result as any)?.ready) {
          // Startup ack
          return;
        }
        const pending = this.pending.get(resp.id);
        if (pending) {
          this.pending.delete(resp.id);
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

    this.process.on("exit", (code) => {
      // Reject all pending
      for (const [id, p] of this.pending) {
        p.reject(new Error(`Bridge process exited with code ${code}`));
        this.pending.delete(id);
      }
      this.process = null;
      this.readline = null;
      this.initialized = false;
    });
  }

  async init(taskId: string): Promise<void> {
    if (this.initialized) return;
    this.ensureProcess();
    const resp = await this.call("init", { seed: generateSeedFromTaskId(taskId) });
    if (resp.error) throw new Error(`Bridge init failed: ${resp.error}`);
    this.initialized = true;
  }

  async shutdown(): Promise<void> {
    if (!this.process) return;
    try {
      await this.call("shutdown");
    } catch { /* ok */ }
    this.process?.kill();
    this.process = null;
    this.readline = null;
    this.initialized = false;
  }
}

// ─── Bridge Registry ─────────────────────────────────────────────────

/** Map of taskId → per-task stealth bridge */
const _bridges = new Map<string, StealthBridge>();

/** Element caches, still per-task (shared across bridge lifecycle) */
const _elementCaches = new Map<string, Map<string, { role: string; name: string; level?: number }>>();

function getBridge(taskId: string): StealthBridge {
  let bridge = _bridges.get(taskId);
  if (!bridge) {
    bridge = new StealthBridge();
    _bridges.set(taskId, bridge);
  }
  return bridge;
}

async function getOrInitBridge(taskId: string): Promise<StealthBridge> {
  const bridge = getBridge(taskId);
  await bridge.init(taskId);
  return bridge;
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

// ─── API ──────────────────────────────────────────────────────────────

export async function navigate(
  url: string,
  taskId: string,
  timeoutMs: number = 30_000,
): Promise<StealthNavigateResult> {
  try {
    const bridge = await getOrInitBridge(taskId);

    const navResp = await bridge.call("navigate", {
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
    const snapResp = await bridge.call("snapshot");
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
    const bridge = getBridge(taskId);

    const resp = await bridge.call("snapshot");
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
    const bridge = getBridge(taskId);
    const params: Record<string, unknown> = { role: node.role, name: node.name };
    if (node.level !== undefined) params.level = node.level;

    const resp = await bridge.call("click", params);
    if (resp.error) return { success: false, error: resp.error };

    const r = resp.result as { url?: string; title?: string };
    sessionManager.updateSession(taskId, { currentUrl: r.url, currentTitle: r.title });

    // Auto-snapshot after click so the model sees updated page state
    const snapResp = await bridge.call("snapshot");
    const snapRaw = (snapResp.result as { snapshot: string })?.snapshot || "";
    const { text: snapshotText, count: elementCount } = cacheSnapshot(taskId, snapRaw);

    return { success: true, newUrl: r.url, newTitle: r.title, snapshot: snapshotText, elementCount };
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
    const bridge = getBridge(taskId);
    const params: Record<string, unknown> = { role: node.role, name: node.name, text };
    if (node.level !== undefined) params.level = node.level;

    const resp = await bridge.call("type", params);
    if (resp.error) return { success: false, error: resp.error };

    // Auto-snapshot after type so the model sees updated page state
    const snapResp = await bridge.call("snapshot");
    const snapRaw = (snapResp.result as { snapshot: string })?.snapshot || "";
    const { text: snapshotText, count: elementCount } = cacheSnapshot(taskId, snapRaw);

    return { success: true, snapshot: snapshotText, elementCount };
  } catch (err: unknown) {
    return { success: false, error: err instanceof Error ? err.message : String(err) };
  }
}

export async function scroll(taskId: string, direction: "up" | "down"): Promise<StealthInteractionResult> {
  try {
    const bridge = getBridge(taskId);
    const resp = await bridge.call("scroll", { direction });
    if (resp.error) return { success: false, error: resp.error };

    // Auto-snapshot after scroll so the model sees updated page state
    const snapResp = await bridge.call("snapshot");
    const snapRaw = (snapResp.result as { snapshot: string })?.snapshot || "";
    const { text: snapshotText, count: elementCount } = cacheSnapshot(taskId, snapRaw);

    return { success: true, snapshot: snapshotText, elementCount };
  } catch (err: unknown) {
    return { success: false, error: err instanceof Error ? err.message : String(err) };
  }
}

export async function screenshot(taskId: string): Promise<StealthScreenshotResult> {
  try {
    const bridge = getBridge(taskId);
    const resp = await bridge.call("screenshot");
    if (resp.error) return { success: false, dataUri: "", error: resp.error };

    return { success: true, dataUri: (resp.result as { dataUri: string }).dataUri };
  } catch (err: unknown) {
    return { success: false, dataUri: "", error: err instanceof Error ? err.message : String(err) };
  }
}

export async function goBack(taskId: string): Promise<StealthInteractionResult> {
  try {
    const bridge = getBridge(taskId);
    const resp = await bridge.call("goBack");
    if (resp.error) return { success: false, error: resp.error };
    const r = resp.result as { url?: string; title?: string };

    // Auto-snapshot after goBack so the model sees the previous page
    const snapResp = await bridge.call("snapshot");
    const snapRaw = (snapResp.result as { snapshot: string })?.snapshot || "";
    const { text: snapshotText, count: elementCount } = cacheSnapshot(taskId, snapRaw);

    return { success: true, newUrl: r.url, newTitle: r.title, snapshot: snapshotText, elementCount };
  } catch (err: unknown) {
    return { success: false, error: err instanceof Error ? err.message : String(err) };
  }
}

export async function press(taskId: string, key: string): Promise<StealthInteractionResult> {
  try {
    const bridge = getBridge(taskId);
    const resp = await bridge.call("press", { key });
    if (resp.error) return { success: false, error: resp.error };

    // Auto-snapshot after press so the model sees updated page state
    const snapResp = await bridge.call("snapshot");
    const snapRaw = (snapResp.result as { snapshot: string })?.snapshot || "";
    const { text: snapshotText, count: elementCount } = cacheSnapshot(taskId, snapRaw);

    return { success: true, snapshot: snapshotText, elementCount };
  } catch (err: unknown) {
    return { success: false, error: err instanceof Error ? err.message : String(err) };
  }
}

export async function evaluate(taskId: string, expression: string): Promise<{ success: boolean; result?: unknown; error?: string }> {
  try {
    const bridge = getBridge(taskId);
    const resp = await bridge.call("evaluate", { expression });
    if (resp.error) return { success: false, error: resp.error };
    return { success: true, result: (resp.result as { result?: unknown }).result };
  } catch (err: unknown) {
    return { success: false, error: err instanceof Error ? err.message : String(err) };
  }
}

export async function cleanup(taskId: string): Promise<void> {
  const bridge = _bridges.get(taskId);
  if (bridge) {
    await bridge.shutdown();
    _bridges.delete(taskId);
  }
  _elementCaches.delete(taskId);
}

export async function cleanupAll(): Promise<void> {
  const promises: Promise<void>[] = [];
  for (const [taskId, bridge] of _bridges) {
    promises.push(bridge.shutdown().catch(() => {}));
    _bridges.delete(taskId);
  }
  await Promise.all(promises);
  _elementCaches.clear();
}
