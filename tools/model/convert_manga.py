"""Builds assets/models/colorizer.tflite from manga-colorization-v2.

Model: https://github.com/qweasdd/manga-colorization-v2 (generator weights
from the project's README). The four color-hint channels are model inputs:
all zero colorizes automatically; a hint paints a color under a mask.

Pipeline: PyTorch -> ONNX -> onnx2tf (NHWC, float16 weights) -> TFLite,
then the TFLite output is checked against PyTorch on the same input.

TFLite contract used by the app (lib/colorizer.dart):
  input : [1, H, W, 5] float32: gray 0..1 (page letterboxed, padded white),
          then hint r*m, g*m, b*m (color in -1..1) and the hint mask m (0/1)
  output: [1, H, W, 3] float32, RGB 0..1

Usage:
  PYTHONPATH=/path/to/manga-colorization-v2 python convert_manga.py \
      --weights generator.zip --out ../../assets/models/colorizer.tflite
  PYTHONPATH=/path/to/reference python convert_manga.py --random   # self-test
"""

import argparse
import glob
import os
import shutil
import subprocess
import tempfile
import time

import numpy as np
import torch
from torch import nn

# Portrait page shape; both sides divisible by 32 as the network requires.
# Width 576 is the project's default inference size; see --width.
H, W = 832, 576


IN_CH = 5


class AutoColorizer(nn.Module):
    """Generator forward without the training-only decoder branch. Input is
    gray + hint channels, as MangaColorizator.colorize() concatenates them."""

    def __init__(self, generator):
        super().__init__()
        self.g = generator

    def forward(self, x):  # [1, 5, H, W]
        g = self.g
        gray = x[:, 0:1]
        x0 = g.to0(x)
        aux = g.to3(g.to2(g.to1(x0)))
        x1, x2, x3, x4 = g.encoder(gray)
        out = g.tunnel4(torch.cat([x4, aux], 1))
        x = g.tunnel3(torch.cat([out, x3], 1))
        x = g.tunnel2(torch.cat([x, x2, x1], 1))
        x = torch.tanh(g.exit(torch.cat([x, x0], 1)))
        return x * 0.5 + 0.5


def load_generator(weights):
    from networks.models import Colorizer  # from the cloned project

    c = Colorizer()
    if weights:
        state = torch.load(weights, map_location="cpu")
        c.generator.load_state_dict(state)
    else:
        torch.manual_seed(0)
        for m in c.modules():
            if isinstance(m, nn.BatchNorm2d):
                m.running_mean.uniform_(-0.2, 0.2)
                m.running_var.uniform_(0.5, 1.5)
    return c.generator.eval()


def to_tflite(model, out_path):
    work = tempfile.mkdtemp()
    onnx_path = os.path.join(work, "colorizer.onnx")
    torch.onnx.export(model, torch.rand(1, IN_CH, H, W), onnx_path, opset_version=17,
                      input_names=["gray_hint"], output_names=["rgb"], dynamo=False)
    subprocess.run(["onnx2tf", "-i", onnx_path, "-o", os.path.join(work, "tf"), "-b", "1", "-n"],
                   check=True)
    fp16 = glob.glob(os.path.join(work, "tf", "*_float16.tflite"))[0]
    shutil.copy(fp16, out_path)
    return out_path


def run_tflite(path, x_nhwc, threads=4):
    import tensorflow as tf

    it = tf.lite.Interpreter(model_path=path, num_threads=threads)
    it.allocate_tensors()
    inp, out = it.get_input_details()[0], it.get_output_details()[0]
    assert list(inp["shape"]) == [1, H, W, IN_CH], inp["shape"]
    assert list(out["shape"]) == [1, H, W, 3], out["shape"]
    it.set_tensor(inp["index"], x_nhwc)
    t = time.perf_counter()
    it.invoke()
    return it.get_tensor(out["index"]), (time.perf_counter() - t) * 1000


def main():
    global H, W
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--weights")
    g.add_argument("--random", action="store_true")
    ap.add_argument("--out", default="colorizer.tflite")
    ap.add_argument("--width", type=int, default=576, help="multiple of 32; height = width * 1.44")
    args = ap.parse_args()
    W = args.width
    H = int(round(W * 1.4444 / 32)) * 32

    model = AutoColorizer(load_generator(args.weights)).eval()
    to_tflite(model, args.out)

    # A page-like input: white paper with dark strokes and gray areas.
    rng = np.random.default_rng(0)
    x = np.zeros((1, IN_CH, H, W), np.float32)
    x[:, 0] = 1.0
    x[:, 0, 100:700, 80:500] = 0.6
    x[:, 0, rng.integers(0, H, 4000), rng.integers(0, W, 4000)] = 0.0
    with torch.no_grad():
        ref = model(torch.from_numpy(x)).numpy().transpose(0, 2, 3, 1)
    lite, ms = run_tflite(args.out, x.transpose(0, 2, 3, 1))
    err = np.abs(lite - ref)
    print(f"tflite vs torch: mean {err.mean():.5f} max {err.max():.4f} "
          f"(output range {ref.min():.3f}..{ref.max():.3f}), {ms:.0f} ms, "
          f"{os.path.getsize(args.out) / 1e6:.1f} MB")
    assert err.mean() < 0.01, "converted model does not match PyTorch"

    # A red hint (as lib/colorizer.dart paints it: discs of color under a
    # mask) has to make that region redder in the converted model too.
    hinted = x.copy()
    yy, xx = np.mgrid[:H, :W]
    disc = ((yy - 300) ** 2 + (xx - 220) ** 2) < 12 ** 2
    hinted[0, 1][disc], hinted[0, 2][disc], hinted[0, 3][disc] = 1.0, -1.0, -1.0
    hinted[0, 4][disc] = 1.0
    red, _ = run_tflite(args.out, hinted.transpose(0, 2, 3, 1))
    region = (slice(250, 350), slice(170, 270))

    def redness(img):
        r = img[0][region]
        return float((r[..., 0] - (r[..., 1] + r[..., 2]) / 2).mean())

    # How strongly hints steer this model is measured by probe_hints.py; here
    # the converted graph only has to react to them the same way PyTorch does.
    with torch.no_grad():
        red_ref = model(torch.from_numpy(hinted)).numpy().transpose(0, 2, 3, 1)
    print(f"::notice::redness around a red hint: {redness(lite):.3f} -> {redness(red):.3f} "
          f"(torch {redness(red_ref):.3f})")
    assert abs(redness(red) - redness(red_ref)) < 0.01, "hint input converted wrongly"
    print("wrote", args.out)


if __name__ == "__main__":
    main()
