import type { Page } from "playwright";
import { sha1_12 } from "../util/canonical.js";

export type RuntimeResource = {
  url: string;
  localPath: string;
  contentType: string | null;
  resourceType: string;
  bytes: number;
};

export type RuntimeProbe = {
  enabled: boolean;
  reason: string;
  canvasCount: number;
  maxCanvasCoverage: number;
  engine: string | null;
  scriptCount: number;
};

export type RuntimeMirrorManifest = {
  version: 1;
  sourceUrl: string;
  entryUrl: string;
  entryPath: string;
  totalBytes: number;
  probe: RuntimeProbe;
  resources: RuntimeResource[];
};

const EXTERNAL_BLOCKLIST = [
  "static.cloudflareinsights.com",
  "www.google-analytics.com",
  "www.googletagmanager.com",
  "connect.facebook.net",
  "analytics.tiktok.com",
];

const EXTERNAL_RESOURCE_TYPES = new Set([
  "script",
  "stylesheet",
  "font",
  "image",
  "media",
  "xhr",
  "fetch",
  "other",
]);

function safeSegment(raw: string): string {
  let decoded = raw;
  try { decoded = decodeURIComponent(raw); } catch { /* keep encoded input */ }
  const clean = decoded
    .replace(/[<>:"/\\|?*\u0000-\u001f]/g, "_")
    .replace(/[. ]+$/g, "")
    .trim();
  if (!clean || clean === "." || clean === "..") return "_";
  return clean;
}

function insertQueryHash(path: string, hash: string): string {
  const slash = path.lastIndexOf("/");
  const dot = path.lastIndexOf(".");
  if (dot > slash) return `${path.slice(0, dot)}.__q_${hash}${path.slice(dot)}`;
  return `${path}.__q_${hash}`;
}

export function runtimeLocalPath(rawUrl: string, sourceUrl: string, resourceType = "other"): string {
  const url = new URL(rawUrl, sourceUrl);
  const source = new URL(sourceUrl);
  const segments = url.pathname.split("/").filter(Boolean).map(safeSegment);
  let path = segments.join("/");
  if (!path || url.pathname.endsWith("/") || resourceType === "document" && !/\.[A-Za-z0-9]{1,12}$/.test(path)) {
    path = path ? `${path}/index.html` : "index.html";
  }
  if (url.search) path = insertQueryHash(path, sha1_12(url.href));
  if (url.origin !== source.origin) {
    path = `__ditto_external/${safeSegment(url.host)}/${path}`;
  }
  return path;
}

export function runtimeWebPath(resource: Pick<RuntimeResource, "url" | "localPath">, sourceUrl: string): string {
  const source = new URL(sourceUrl);
  const url = new URL(resource.url, sourceUrl);
  if (url.origin === source.origin && url.pathname === source.pathname && resource.localPath.endsWith("index.html")) {
    return "/__ditto_runtime/index.html";
  }
  return `/${resource.localPath.replace(/\\/g, "/")}`;
}

export function shouldCaptureRuntimeResource(input: {
  url: string;
  sourceUrl: string;
  method: string;
  resourceType: string;
}): boolean {
  if (input.method.toUpperCase() !== "GET") return false;
  let url: URL;
  let source: URL;
  try {
    url = new URL(input.url);
    source = new URL(input.sourceUrl);
  } catch {
    return false;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") return false;
  if (EXTERNAL_BLOCKLIST.includes(url.hostname.toLowerCase())) return false;
  if (url.origin === source.origin) return true;
  return EXTERNAL_RESOURCE_TYPES.has(input.resourceType);
}

export function isRuntimeText(contentType: string | null, localPath: string): boolean {
  const ct = (contentType ?? "").toLowerCase();
  if (/^(text\/|application\/(javascript|json|manifest\+json|xml|xhtml\+xml))/.test(ct)) return true;
  return /\.(?:html?|css|m?js|cjs|json|webmanifest|svg|xml|txt)$/i.test(localPath);
}

function replaceAllLiteral(text: string, from: string, to: string): string {
  if (!from || from === to || !text.includes(from)) return text;
  return text.split(from).join(to);
}

export function rewriteRuntimeText(text: string, manifest: RuntimeMirrorManifest): string {
  const source = new URL(manifest.sourceUrl);
  const mappings: Array<[string, string]> = [];
  for (const resource of manifest.resources) {
    const url = new URL(resource.url, manifest.sourceUrl);
    const webPath = runtimeWebPath(resource, manifest.sourceUrl);
    mappings.push([url.href, webPath]);
    if (url.origin === source.origin && url.search) {
      mappings.push([`${url.pathname}${url.search}`, webPath]);
    }
  }
  mappings.sort((a, b) => b[0].length - a[0].length || a[0].localeCompare(b[0]));
  let out = text;
  for (const [from, to] of mappings) {
    out = replaceAllLiteral(out, from, to);
    out = replaceAllLiteral(out, from.replaceAll("/", "\\/"), to.replaceAll("/", "\\/"));
  }
  out = replaceAllLiteral(out, `${source.origin}/`, "/");
  out = replaceAllLiteral(out, `${source.origin.replaceAll("/", "\\/")}\\/`, "\\/");
  out = out.replace(/<script\b[^>]*cloudflareinsights\.com[^>]*><\/script>/gi, "");
  return out;
}

export async function probeDynamicRuntime(page: Page): Promise<RuntimeProbe> {
  return page.evaluate(() => {
    const viewportArea = Math.max(1, innerWidth * innerHeight);
    const canvases = Array.from(document.querySelectorAll("canvas"));
    let maxCanvasCoverage = 0;
    let engine: string | null = null;
    for (const canvas of canvases) {
      const rect = canvas.getBoundingClientRect();
      const style = getComputedStyle(canvas);
      const visible = rect.width > 2 && rect.height > 2
        && style.display !== "none" && style.visibility !== "hidden"
        && Number.parseFloat(style.opacity || "1") > 0;
      if (!visible) continue;
      const visibleWidth = Math.max(0, Math.min(rect.right, innerWidth) - Math.max(rect.left, 0));
      const visibleHeight = Math.max(0, Math.min(rect.bottom, innerHeight) - Math.max(rect.top, 0));
      maxCanvasCoverage = Math.max(maxCanvasCoverage, visibleWidth * visibleHeight / viewportArea);
      engine ||= canvas.getAttribute("data-engine");
    }
    const scriptCount = document.scripts.length;
    const hasKnownEngine = !!engine || !!document.querySelector(
      '[data-engine*="three" i],[data-engine*="webgl" i],[data-engine*="rive" i],[data-engine*="pixi" i]',
    );
    const enabled = hasKnownEngine || maxCanvasCoverage >= 0.55 && scriptCount > 0;
    return {
      enabled,
      reason: hasKnownEngine
        ? `canvas engine detected${engine ? `: ${engine}` : ""}`
        : enabled
          ? `script-driven canvas covers ${Math.round(maxCanvasCoverage * 100)}% of the viewport`
          : "no dominant script-driven canvas detected",
      canvasCount: canvases.length,
      maxCanvasCoverage: Math.round(maxCanvasCoverage * 10_000) / 10_000,
      engine,
      scriptCount,
    };
  });
}

