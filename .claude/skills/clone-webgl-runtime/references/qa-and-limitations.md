# QA and limitations

## Required evidence

Collect:

- source and local screenshots at identical viewport sizes and states;
- production build output;
- missing-asset count;
- local HTTP failures;
- page and console errors;
- runtime engine and canvas dimensions;
- primary interaction results;
- a final P0/P1/P2 issue list.

Put source and implementation screenshots side by side before judging fidelity. A screenshot alone is not QA.

## Expected differences

Continuously running physics, particles, randomized layouts, video frames, and real-time lighting can differ between captures taken at different milliseconds. Grade stable layout, camera, lighting, texture, typography, and behavior separately from frame timing.

## External dependencies

A frontend mirror cannot make these independent:

- authentication and private sessions;
- payments;
- private or stateful APIs;
- databases;
- third-party maps, video, analytics, or embeds;
- server-side mutations;
- protected media and DRM.

Preserve required public integrations only when allowed, and label them as external. Never claim an offline clone when core behavior still depends on a remote service.

## Editability

Runtime mirroring maximizes fidelity by replaying captured frontend logic. It does not turn minified production JavaScript into maintainable source code.

- Copy, colors, and assets may be replaceable.
- Minified Three.js scene and scroll logic are difficult to maintain.
- A freely editable commercial product normally requires a clean-room rebuild with owned assets.

Always tell the user whether the result is a runtime mirror or an independently authored implementation.

