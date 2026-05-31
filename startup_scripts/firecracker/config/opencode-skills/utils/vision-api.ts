import fs from "fs";
import path from "path";
import os from "os";

export const DEFAULT_MODEL = "qwen3-6-27b";
export const OPENCODE_API_URL = process.env.OPENCODE_API_URL || "https://api.venice.ai/api/v1/chat/completions";

export function isVeniceUrl(): boolean {
  return OPENCODE_API_URL.includes("venice.ai");
}

export function getApiKey(): string | null {
  if (process.env.OPENCODE_API_KEY) return process.env.OPENCODE_API_KEY;
  const keyFile = path.join(os.homedir(), ".secrets", "opencode-api-key");
  if (fs.existsSync(keyFile)) return fs.readFileSync(keyFile, "utf-8").trim();
  return null;
}

export function imageToBase64(filePath: string): string {
  const data = fs.readFileSync(filePath);
  const ext = path.extname(filePath).toLowerCase();
  const mimeType: Record<string, string> = {
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
    ".webp": "image/webp",
    ".gif": "image/gif",
    ".bmp": "image/bmp",
    ".tiff": "image/tiff",
  }[ext] || "image/jpeg";

  return `data:${mimeType};base64,${data.toString("base64")}`;
}

export function resolveFilePath(filePath: string, worktree: string): string {
  const resolvedPath = path.isAbsolute(filePath)
    ? filePath
    : path.join(worktree, filePath);

  if (!fs.existsSync(resolvedPath)) {
    throw new Error(`Image file not found: ${resolvedPath}`);
  }

  const stat = fs.statSync(resolvedPath);
  if (stat.isDirectory()) {
    throw new Error(`Path is a directory, not a file: ${resolvedPath}`);
  }

  return resolvedPath;
}
