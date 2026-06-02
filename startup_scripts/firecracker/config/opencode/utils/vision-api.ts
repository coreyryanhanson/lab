import fs from "fs";
import path from "path";

export const DEFAULT_MODEL = "qwen3-6-27b";
export const VENICE_API_URL = process.env.VENICE_API_URL || "https://api.venice.ai/api/v1/chat/completions";

export function isVeniceUrl(): boolean {
  return VENICE_API_URL.includes("venice.ai");
}

export function getApiKey(): string | null {
  return process.env.VENICE_API_KEY || null;
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
