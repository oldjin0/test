---
name: clone-webgl-runtime
description: Clone an authorized public WebGL, Three.js, Rive, canvas-heavy, or scroll-driven website into a local runnable app by capturing its browser runtime, localizing public resources, building the generated project, and running multi-viewport visual and interaction QA. Use when a normal DOM or screenshot clone loses 3D scenes, canvas animation, models, textures, WASM, workers, video, or high-fidelity interactions.
---

# Clone WebGL Runtime

Create a local runtime mirror when the source's visual truth lives in JavaScript and canvas rather than ordinary DOM. Preserve the distinction between a runtime mirror and an independently rewritten site.

## Safety and rights

- Work only on public URLs the user is authorized to test.
- Respect robots rules, access controls, and target terms. Never bypass authentication, paywalls, bot protection, or rate limits.
- Treat captured code, design, copy, models, textures, audio, and video as the target owner's material unless an explicit license says otherwise.
- Do not publish or commercialize captured target assets without permission.
- Publish only this Skill, integration code, and synthetic test fixtures; never commit a captured site's runtime directory.

## Workflow

1. Capture and inspect a reference screenshot before changing code.
2. Locate a `ditto.site` checkout. Clone the MIT-licensed upstream project when no checkout exists.
3. Run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts/check-environment.ps1 -DittoRoot "<ditto-root>"
   ```

4. Classify the source:
   - Use the ordinary DOM pipeline for pages whose primary visuals are HTML/CSS.
   - Use runtime mirroring when a visible canvas has a known engine marker or covers most of the viewport while scripts are active.
5. If runtime mirroring is missing from the checkout, read `references/runtime-mirror-architecture.md` and port the reference modules listed there. Integrate by symbol and behavior, not by brittle line-number patches.
6. Install dependencies and Chromium when required:

   ```powershell
   npm ci
   npx playwright install chromium
   ```

7. Run the clone:

   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts/run-clone.ps1 `
     -DittoRoot "<ditto-root>" `
     -Url "https://example.com/" `
     -Output "output/example-runtime" `
     -Viewports "375,768,1280,1920"
   ```

8. Build the generated app with `npm install` and `npm run build`.
9. Serve the static export or development build locally.
10. Run runtime QA from the `ditto.site` repository root so its Playwright dependency resolves:

    ```powershell
    node "<skill-root>/scripts/runtime-qa.mjs" `
      --url=http://127.0.0.1:3100/ `
      --out="<qa-output>" `
      --viewports=375x812,768x1024,1280x800,1920x1080
    ```

11. Put equal-size source and implementation screenshots side by side. Fix visible differences before handoff.
12. Report local resource count, missing assets, build result, viewport results, interaction results, and remaining external dependencies.

## Runtime mirror requirements

- Preserve same-origin root-relative paths so models, textures, workers, and WASM keep working.
- Isolate captured external hosts under a deterministic local directory.
- Exclude analytics and telemetry from replay.
- Bound each resource and total capture bytes.
- Reject partial media bodies; reassemble complete files with validated HTTP ranges.
- Rewrite captured absolute URLs in HTML, CSS, and JavaScript.
- Restore the original route before source scripts execute.
- Use a full-viewport iframe only as a runtime boundary. Say plainly that the result runs captured frontend logic.
- Keep API, authentication, payment, and third-party media dependencies explicit; do not pretend they are local.

## QA gates

Do not call the clone complete unless:

- the production build passes;
- all required visual resources are local and return successful HTTP responses;
- the runtime canvas starts at every requested viewport;
- reference and implementation screenshots were inspected together;
- primary navigation, menus, product selectors, and visible CTAs work;
- page and console errors are either zero or proven identical upstream behavior;
- a QA report records P0, P1, and P2 findings.

Read `references/qa-and-limitations.md` when grading results or explaining what cannot be mirrored exactly.

