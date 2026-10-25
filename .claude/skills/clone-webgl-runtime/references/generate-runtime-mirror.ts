import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { ensureDir, readJSON, writeBytes, writeJSON, writeText } from "../util/fsx.js";
import {
  isRuntimeText,
  rewriteRuntimeText,
  type RuntimeMirrorManifest,
  type RuntimeResource,
} from "../capture/runtimeMirror.js";

export type RuntimeMirrorMaterialization = {
  enabled: boolean;
  copied: number;
  totalBytes: number;
};

export function injectRuntimeRoute(html: string, entryUrl: string): string {
  const url = new URL(entryUrl);
  const route = `${url.pathname}${url.search}${url.hash}` || "/";
  const bootstrap = `<script>history.replaceState(null,"",${JSON.stringify(route)});</script>`;
  if (/<head(?:\s[^>]*)?>/i.test(html)) {
    return html.replace(/<head(\s[^>]*)?>/i, (match) => `${match}${bootstrap}`);
  }
  return `${bootstrap}${html}`;
}

function targetForResource(resource: RuntimeResource, manifest: RuntimeMirrorManifest, publicDir: string): string {
  if (resource.localPath === manifest.entryPath) {
    return join(publicDir, "__ditto_runtime", "index.html");
  }
  return join(publicDir, ...resource.localPath.split("/"));
}

export function materializeRuntimeMirror(sourceDir: string, appDir: string): RuntimeMirrorMaterialization {
  const mirrorDir = join(sourceDir, "runtime-mirror");
  const manifestPath = join(mirrorDir, "manifest.json");
  if (!existsSync(manifestPath)) return { enabled: false, copied: 0, totalBytes: 0 };
  const manifest = readJSON<RuntimeMirrorManifest>(manifestPath);
  if (!manifest.probe.enabled || !manifest.resources.length) {
    return { enabled: false, copied: 0, totalBytes: 0 };
  }

  const publicDir = join(appDir, "public");
  ensureDir(publicDir);
  let copied = 0;
  for (const resource of [...manifest.resources].sort((a, b) => a.localPath.localeCompare(b.localPath))) {
    const sourcePath = join(mirrorDir, "files", ...resource.localPath.split("/"));
    if (!existsSync(sourcePath)) continue;
    let bytes = readFileSync(sourcePath);
    if (isRuntimeText(resource.contentType, resource.localPath)) {
      let text = rewriteRuntimeText(bytes.toString("utf8"), manifest);
      if (resource.localPath === manifest.entryPath) {
        text = injectRuntimeRoute(text, manifest.entryUrl);
      }
      bytes = Buffer.from(text, "utf8");
    }
    writeBytes(targetForResource(resource, manifest, publicDir), bytes);
    copied++;
  }

  writeJSON(join(publicDir, "__ditto_runtime", "manifest.json"), manifest);
  writeText(join(appDir, "src", "app", "page.tsx"), `export default function Page() {
  return (
    <iframe
      id="ditto-runtime"
      title="Interactive site replica"
      src="/__ditto_runtime/index.html"
      allow="autoplay; fullscreen; picture-in-picture"
      allowFullScreen
      style={{
        position: "fixed",
        inset: 0,
        width: "100vw",
        height: "100vh",
        border: 0,
        display: "block",
        background: "#000",
      }}
    />
  );
}
`);
  return { enabled: true, copied, totalBytes: manifest.totalBytes };
}

