Place the colorization model here as `colorizer.tflite`.

Expected format (NHWC, float32):
- input:  [1, H, W, 1 or 3]  grayscale luminance in 0..1 (H, W taken from the model, 512 recommended)
- output: [1, H, W, 3]       RGB in 0..1, or [1, H, W, 2] Cb/Cr in 0..1

The app works without this file: it falls back to a tone-correction filter.
