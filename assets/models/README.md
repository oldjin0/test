Both models are generated in CI (`.github/workflows/build-model.yml`) from
manga-colorization-v2, https://github.com/qweasdd/manga-colorization-v2,
and checked against the project's PyTorch code. Weights are float16 and
run on the XNNPACK CPU delegate.

`colorizer.tflite` (`tools/model/convert_manga.py`), NHWC float32:
- input:  [1, 640, 448, 5]  gray 0..1, then hint r*m, g*m, b*m (-1..1) and mask m
- output: [1, 640, 448, 3]  RGB 0..1

`denoiser.tflite` (`tools/model/convert_denoiser.py`), the project's FFDNet
(sigma 25) that cleans screentone before colorizing:
- input:  [1, 640, 448, 1]  gray 0..1
- output: [1, 640, 448, 1]  gray 0..1

Without the colorizer the app falls back to a tone-correction filter;
without the denoiser it colorizes the page as is.
