"""Builds assets/models/colorizer.tflite from manga-colorization-v2.

Model: https://github.com/qweasdd/manga-colorization-v2 (generator weights
from the project's README). Automatic mode: the color-hint channels are zero.

Pipeline: PyTorch -> ONNX -> onnx2tf (NHWC, float16 weights) -> TFLite,
then the TFLite output is checked against PyTorch on the same input.

TFLite contract used by the app (lib/colorizer.dart):
  input : [1, H, W, 1] float32, gray 0..1 (page letterboxed, padded white)
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


class AutoColorizer(nn.Module):
    """Generator forward without the training-only decoder branch, with the
    four hint channels fixed to zero (fully automatic colorization)."""

    def __init__(self, generator):
        super().__init__()
        self.g = generator

    def forward(self, gray):  # [1, 1, H, W] in 0..1
        g = self.g
        hint = torch.zeros_like(gray).repeat(1, 4, 1, 1)
        x0 = g.to0(torch.cat([gray, hint], 1))
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
    torch.onnx.export(model, torch.rand(1, 1, H, W), onnx_path, opset_version=17,
                      input_names=["gray"], output_names=["rgb"], dynamo=False)
    subprocess.run(["onnx2tf", "-i", onnx_path, "-o", os.path.join(work, "tf"), "-b", "1"],
                   check=True)
    fp16 = glob.glob(os.path.join(work, "tf", "*_float16.tflite"))[0]
    shutil.copy(fp16, out_path)
    return out_path


def run_tflite(path, x_nhwc, threads=4):
    import tensorflow as tf

    it = tf.lite.Interpreter(model_path=path, num_threads=threads)
    it.allocate_tensors()
    inp, out = it.get_input_details()[0], it.get_output_details()[0]
    assert list(inp["shape"]) == [1, H, W, 1], inp["shape"]
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
    x = np.ones((1, 1, H, W), np.float32)
    x[:, :, 100:700, 80:500] = 0.6
    x[:, :, rng.integers(0, H, 4000), rng.integers(0, W, 4000)] = 0.0
    with torch.no_grad():
        ref = model(torch.from_numpy(x)).numpy().transpose(0, 2, 3, 1)
    lite, ms = run_tflite(args.out, x.transpose(0, 2, 3, 1))
    err = np.abs(lite - ref)
    print(f"tflite vs torch: mean {err.mean():.5f} max {err.max():.4f} "
          f"(output range {ref.min():.3f}..{ref.max():.3f}), {ms:.0f} ms, "
          f"{os.path.getsize(args.out) / 1e6:.1f} MB")
    assert err.mean() < 0.01, "converted model does not match PyTorch"
    print("wrote", args.out)


if __name__ == "__main__":
    main()
