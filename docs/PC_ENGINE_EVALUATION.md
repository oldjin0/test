# PC colorizing engine: what ships, and what was evaluated

## What the PC version runs

manga-colorization-v2 (the phone's model) on ONNX Runtime:

- **DirectML** on any DirectX 12 graphics (integrated or discrete), with an
  automatic fall back to the processor. A guard file turns the graphics path
  off for good if it ever crashed the program, and invalid output (NaN) does
  the same.
- Input size is a setting (448, 576, 704 or 768 wide). 576 is the model
  authors' default and is the PC default; the phone uses 448.
- Half precision (fp16) for graphics, full precision for the processor (the
  benchmark measured fp32 faster on CPUs: 2.4 s vs 3.6 s on a 4-core Linux
  machine, 4.6 s vs 5.7 s on the Windows CI runner, both at 448x640).
- Everything is checked against the PyTorch model in CI: the FP32 ONNX file
  matches it exactly, FP16 differs by 0.00015 on average, and the Dart
  binding matches Python bit for bit on the same model and input.

What could **not** be measured here: DirectML speed. The CI machines have no
graphics adapter ("Specified display adapter handle is invalid"), so every
DirectML number in any document is an estimate until someone runs
`MangaBench.zip` (pre-release `pc-bench-N`) on a real PC.

## Better engines that were looked at

| Engine | Needs | License | Verdict |
|---|---|---|---|
| MangaNinja (CVPR 2025) | a **reference color image** per page; CUDA GPU (6 GB VRAM mentioned); SD1.5 (4 GB) + ControlNet (2.5 GB) + CLIP (0.6 GB) + checkpoint (2 GB), ~10 GB in all; 20-50 diffusion steps | CC BY-NC 4.0 (code and weights) | Not shipped. No ONNX/DirectML path exists; porting a diffusion UNet with custom reference attention is a research task, and nothing says it can run on integrated graphics (steps x UNet cost suggests minutes per page there). Personal, non-commercial use would be allowed. |
| Cobra (2025) | reference images (200+) or color hints; DiT | not verified (weights page not reachable from the build environment) | Not shipped: size, speed and license unverified. |
| MangaDiT (2025) | reference image; FLUX-based; tested on an A100 80 GB | MIT code; weights not confirmed published | Not usable on a normal PC. |

Every newer model found needs a reference picture, which the automatic
"colorize the whole book" workflow does not have. No newer model that colors
fully automatically was found.

## Recommendation

1. Use the shipped engine at 576 or 704 wide on a graphics card. The
   quality-by-size preview (`docs/pc_quality_by_size.png`, made by CI with the
   real weights) shows what a larger input changes.
2. If consistent character colors across pages matter, try MangaNinja once on
   a CUDA machine (the project's demo or a rented GPU) with a book's cover as
   the reference, and judge the result before any porting work. The app's
   per-page color hints already cover single pages.
3. Revisit when an automatic (reference-free) model with an ONNX export
   appears.
