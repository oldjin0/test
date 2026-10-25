# Runtime mirror architecture

Use this reference when a normal DOM reconstruction flattens or loses the primary canvas experience.

## Detection

Probe after navigation and access-wall checks, before scrolling or reveal stabilization changes the canvas state.

Enable runtime mirroring when either condition is true:

- a visible canvas or related host declares a known engine such as Three.js, WebGL, Rive, or Pixi; or
- the largest visible canvas covers at least 55% of the viewport and the page has active scripts.

Retry the probe briefly because engines often attach markers after initial load.

## Capture

Listen to successful GET responses.

- Preserve all same-origin public responses.
- Preserve external scripts, stylesheets, fonts, images, media, XHR/fetch bodies, workers, and supporting binaries required by the public runtime.
- Reject analytics and telemetry hosts.
- Ignore `data:` and `blob:` URLs.
- Do not store HTTP 206 media fragments as complete files.
- Cap an individual resource at 128 MiB and the total mirror at 768 MiB.

Store same-origin resources at their original root-relative layout. Store external resources under:

```text
__ditto_external/<host>/<path>
```

Hash query strings into deterministic filenames so variant responses do not collide.

For source-owned video observed only as ranges, download validated 2 MiB ranges and concatenate only when every `Content-Range` is contiguous and the final byte count matches.

## Manifest

Write a manifest containing:

- source and entry URLs;
- entry local path;
- runtime probe evidence;
- total bytes;
- every original URL, local path, content type, resource type, and size.

The capture result should include this manifest as an optional runtime-mirror field.

## Text rewriting

For HTML, CSS, JavaScript, JSON, manifests, SVG, XML, and text:

- rewrite exact captured absolute URLs to local web paths;
- rewrite same-origin query-string paths to their hashed local filename;
- rewrite the source origin to `/`;
- remove captured analytics scripts.

Before source scripts run, inject:

```html
<script>history.replaceState(null, "", "/original-route");</script>
```

This lets a client-side router see the original entry route even though the raw runtime document is served from an internal path.

## Materialization

Copy binary and rewritten text files into the generated app's `public` directory.

- Serve the raw source document at `/__ditto_runtime/index.html`.
- Preserve same-origin public files at their original root-relative paths.
- Replace the generated page with a full-viewport iframe pointing at the runtime document.
- Keep the iframe boundary explicit in code and user-facing documentation.

The reference implementation modules are:

- `capture-runtime-mirror.ts`
- `generate-runtime-mirror.ts`
- `runtime-mirror.test.ts`

Port them into the corresponding `compiler/src/capture`, `compiler/src/generate`, and `compiler/test` folders. Then integrate them into the network response listener, capture result, runtime fast path, and generation pipeline.

## Fast path

After dynamic runtime detection:

1. Allow a bounded loader settle window.
2. Capture initial screenshots at required viewports without driving full-page scroll.
3. Wait for pending response bodies with a bounded deadline.
4. Complete missing media through validated ranges.
5. Emit a minimal structural capture only to keep downstream reporting deterministic.
6. Materialize the runtime instead of running the expensive static DOM walker.

This avoids forcing a scroll-driven canvas to its final state and prevents very large animated DOMs from blocking capture.

