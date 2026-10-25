import assert from "node:assert/strict";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { writeBytes, writeJSON } from "../src/util/fsx.js";
import {
  isRuntimeText,
  rewriteRuntimeText,
  runtimeLocalPath,
  runtimeWebPath,
  shouldCaptureRuntimeResource,
  type RuntimeMirrorManifest,
} from "../src/capture/runtimeMirror.js";
import { injectRuntimeRoute, materializeRuntimeMirror } from "../src/generate/runtimeMirror.js";

const SOURCE = "https://example.test/";

test("runtimeLocalPath preserves same-origin layout and isolates external hosts", () => {
  assert.equal(runtimeLocalPath("https://example.test/", SOURCE, "document"), "index.html");
  assert.equal(runtimeLocalPath("https://example.test/models/coaster.buf", SOURCE), "models/coaster.buf");
  assert.match(
    runtimeLocalPath("https://example.test/image.webp?w=640", SOURCE, "image"),
    /^image\.__q_[a-f0-9]{12}\.webp$/,
  );
  assert.equal(
    runtimeLocalPath("https://cdn.example.net/lib/runtime.js", SOURCE, "script"),
    "__ditto_external/cdn.example.net/lib/runtime.js",
  );
});

test("runtime resource policy excludes analytics and non-GET requests", () => {
  assert.equal(shouldCaptureRuntimeResource({
    url: "https://example.test/models/a.buf",
    sourceUrl: SOURCE,
    method: "GET",
    resourceType: "fetch",
  }), true);
  assert.equal(shouldCaptureRuntimeResource({
    url: "https://static.cloudflareinsights.com/beacon.min.js",
    sourceUrl: SOURCE,
    method: "GET",
    resourceType: "script",
  }), false);
  assert.equal(shouldCaptureRuntimeResource({
    url: "https://example.test/api",
    sourceUrl: SOURCE,
    method: "POST",
    resourceType: "fetch",
  }), false);
});

test("rewriteRuntimeText localizes exact source and external URLs", () => {
  const resources = [
    { url: SOURCE, localPath: "index.html", contentType: "text/html", resourceType: "document", bytes: 1 },
    { url: "https://example.test/app.js", localPath: "app.js", contentType: "text/javascript", resourceType: "script", bytes: 1 },
    { url: "https://cdn.example.net/font.woff2", localPath: "__ditto_external/cdn.example.net/font.woff2", contentType: "font/woff2", resourceType: "font", bytes: 1 },
  ];
  const manifest: RuntimeMirrorManifest = {
    version: 1,
    sourceUrl: SOURCE,
    entryUrl: SOURCE,
    entryPath: "index.html",
    totalBytes: 3,
    probe: { enabled: true, reason: "test", canvasCount: 1, maxCanvasCoverage: 1, engine: "three", scriptCount: 1 },
    resources,
  };
  const out = rewriteRuntimeText(
    '<script src="https://example.test/app.js"></script><link href="https://cdn.example.net/font.woff2">',
    manifest,
  );
  assert.match(out, /src="\/app\.js"/);
  assert.match(out, /href="\/__ditto_external\/cdn\.example\.net\/font\.woff2"/);
  assert.equal(runtimeWebPath(resources[0]!, SOURCE), "/__ditto_runtime/index.html");
  assert.equal(isRuntimeText("application/wasm", "engine.wasm"), false);
  assert.match(
    injectRuntimeRoute("<html><head></head></html>", "https://example.test/products?x=1"),
    /replaceState\(null,"","\/products\?x=1"\)/,
  );
});

test("materializeRuntimeMirror emits localized files and the wrapper", () => {
  const root = mkdtempSync(join(tmpdir(), "ditto-runtime-"));
  const sourceDir = join(root, "source");
  const appDir = join(root, "app");
  const resources = [
    { url: SOURCE, localPath: "index.html", contentType: "text/html", resourceType: "document", bytes: 52 },
    { url: "https://example.test/app.js", localPath: "app.js", contentType: "text/javascript", resourceType: "script", bytes: 20 },
  ];
  const manifest: RuntimeMirrorManifest = {
    version: 1,
    sourceUrl: SOURCE,
    entryUrl: SOURCE,
    entryPath: "index.html",
    totalBytes: 72,
    probe: { enabled: true, reason: "test", canvasCount: 1, maxCanvasCoverage: 1, engine: "three", scriptCount: 1 },
    resources,
  };
  writeJSON(join(sourceDir, "runtime-mirror", "manifest.json"), manifest);
  writeBytes(
    join(sourceDir, "runtime-mirror", "files", "index.html"),
    Buffer.from('<!doctype html><script src="https://example.test/app.js"></script>'),
  );
  writeBytes(join(sourceDir, "runtime-mirror", "files", "app.js"), Buffer.from("globalThis.ready=true"));

  const result = materializeRuntimeMirror(sourceDir, appDir);
  assert.deepEqual(result, { enabled: true, copied: 2, totalBytes: 72 });
  assert.match(
    readFileSync(join(appDir, "public", "__ditto_runtime", "index.html"), "utf8"),
    /src="\/app\.js"/,
  );
  assert.match(
    readFileSync(join(appDir, "src", "app", "page.tsx"), "utf8"),
    /ditto-runtime/,
  );
});

