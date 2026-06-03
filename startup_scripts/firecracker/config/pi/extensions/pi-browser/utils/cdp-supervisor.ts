/**
 * CDP Supervisor — handles JavaScript dialogs and browser events.
 *
 * Automatically dismisses alert/confirm/prompt dialogs and logs them
 * for the user to see. Also handles page crash and unresponsive events.
 *
 * Works with both Playwright (Chromium) and stealth (Firefox) backends.
 */

import type { Page, BrowserContext } from "playwright";

export interface DialogEvent {
  type: "alert" | "confirm" | "prompt" | "beforeunload";
  message: string;
  /** Default value for prompt dialogs */
  defaultValue?: string;
  /** How the dialog was handled */
  handledAs: "accepted" | "dismissed";
  timestamp: number;
}

/** Dialogs logged per task, for reporting to user */
const _dialogLog = new Map<string, DialogEvent[]>();

/** Get logged dialogs for a task */
export function getDialogLog(taskId: string): DialogEvent[] {
  return _dialogLog.get(taskId) ?? [];
}

/** Clear dialog log for a task */
export function clearDialogLog(taskId: string): void {
  _dialogLog.delete(taskId);
}

/**
 * Install dialog handlers on a Playwright page.
 * Automatically accepts all dialogs (alert, confirm, prompt) and logs them.
 */
export function installDialogHandlers(taskId: string, page: Page): void {
  const log: DialogEvent[] = [];
  _dialogLog.set(taskId, log);

  page.on("dialog", async (dialog) => {
    const entry: DialogEvent = {
      type: dialog.type() as DialogEvent["type"],
      message: dialog.message(),
      defaultValue: dialog.defaultValue(),
      handledAs: "accepted",
      timestamp: Date.now(),
    };

    // Auto-accept all dialogs
    try {
      await dialog.accept();
    } catch {
      // Dialog may have already been handled
      entry.handledAs = "dismissed";
    }

    log.push(entry);
  });

  // Handle page crashes
  page.on("crash", () => {
    log.push({
      type: "alert",
      message: "⚠ Page crashed",
      handledAs: "dismissed",
      timestamp: Date.now(),
    });
  });
}

/**
 * Install dialog handlers on a BrowserContext (for contexts where we
 * want to catch dialogs on any page in the context).
 */
export function installContextDialogHandlers(taskId: string, context: BrowserContext): void {
  context.on("page", (page) => {
    installDialogHandlers(taskId, page);
  });
}

/**
 * Format dialog log entries for display to the user.
 */
export function formatDialogLog(taskId: string): string {
  const log = getDialogLog(taskId);
  if (log.length === 0) return "";

  return log
    .map((d, i) => {
      const prefix = d.type === "alert" ? "📢" : d.type === "confirm" ? "❓" : "💬";
      return `${prefix} [${d.type}] ${d.message} (auto-${d.handledAs})`;
    })
    .join("\n");
}
