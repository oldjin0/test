"""Builds assets/models/denoiser.tflite from the FFDNet weights that
manga-colorization-v2 runs before colorizing (MangaColorizator.set_image,
apply_denoise=True, sigma 25): it removes screentone dots and JPEG noise so
the colorizer sees clean shading.

FFDNet's custom input/output layers are rewritten with pixel_unshuffle /
pixel_shuffle (same channel order), so the graph converts to plain TFLite
ops, and the result is checked against the project's own FFDNet.

TFLite contract used by the app (lib/colorizer.dart):
  input : [1, H, W, 1] float32, gray 0..1 (the colorizer's letterboxed input)
  output: [1, H, W, 1] float32, denoised gray 0..1

Usage:
  PYTHONPATH=/path/to/manga-colorization-v2 python convert_denoiser.py \
      --weights net_rgb.pth --width 448 --out ../../assets/models/denoiser.tflite
  PYTHONPATH=/path/to/manga-colorization-v2 python convert_denoiser.py --random --check-only
"""

import argparse
import glob
import os
import shutil
import subprocess
import tempfile
import time
import zipfile

import numpy as np
import torch
import torch.nn.functional as F
from torch import nn

SIGMA = 25 / 255  # the project's default denoise strength


class GrayDenoiser(nn.Module):
    """FFDNet (RGB weights) on a gray page: gray -> RGB -> denoise -> channel 0,
    as the project feeds a gray page and keeps channel 0 for the colorizer."""

    def __init__(self, ffdnet):
        super().__init__()
        self.dncnn = ffdnet.intermediate_dncnn

    def forward(self, gray):  # [1, 1, H, W], H and W even
        x = gray.repeat(1, 3, 1, 1)
        down = F.pixel_unshuffle(x, 2)  # [1, 12, H/2, W/2], channel = c*4 + (dy*2+dx)
        noise = torch.ones_like(down[:, :3]) * SIGMA  # the noise map comes first
        pred = F.pixel_shuffle(self.dncnn(torch.cat([noise, down], 1)), 2)
        return torch.clamp(x - pred, 0.0, 1.0)[:, 0:1]


def load_ffdnet(weights):
    from denoising.models import FFDNet  # from the cloned project
    from denoising.utils import remove_dataparallel_wrapper

    net = FFDNet(num_input_channels=3)
    if weights:
        path = weights
        if zipfile.is_zipfile(weights):
            names = zipfile.ZipFile(weights).namelist()
            # A torch checkpoint is itself a zip (with data.pkl); otherwise it
            # is an archive of checkpoints: take the RGB one.
            if not any(n.endswith("data.pkl") for n in names):
                member = next(n for n in names if n.endswith("net_rgb.pth"))
                path = zipfile.ZipFile(weights).extract(member, tempfile.mkdtemp())
        state = torch.load(path, map_location="cpu")
        if any(k.startswith("module.") for k in state):
            state = remove_dataparallel_wrapper(state)
        net.load_state_dict(state)
    else:
        torch.manual_seed(0)
        for m in net.modules():
            if isinstance(m, nn.Conv2d):
                nn.init.kaiming_normal_(m.weight, nonlinearity="relu")
            if isinstance(m, nn.BatchNorm2d):
                m.running_mean.uniform_(-0.1, 0.1)
                m.running_var.uniform_(0.5, 1.5)
    return net.eval()


def reference(net, gray):
    """The project's own path: FFDNet.forward with its custom layers."""
    x = gray.repeat(1, 3, 1, 1)
    with torch.no_grad():
        noise = net(x, torch.FloatTensor([SIGMA]))
    return torch.clamp(x - noise, 0.0, 1.0)[:, 0:1]


def to_tflite(model, h, w, out_path):
    work = tempfile.mkdtemp()
    onnx_path = os.path.join(work, "denoiser.onnx")
    torch.onnx.export(model, torch.rand(1, 1, h, w), onnx_path, opset_version=17,
                      input_names=["gray"], output_names=["clean"], dynamo=False)
    subprocess.run(["onnx2tf", "-i", onnx_path, "-o", os.path.join(work, "tf"), "-b", "1", "-n"],
                   check=True)
    shutil.copy(glob.glob(os.path.join(work, "tf", "*_float16.tflite"))[0], out_path)


def run_tflite(path, x_nhwc):
    import tensorflow as tf

    it = tf.lite.Interpreter(model_path=path, num_threads=4)
    it.allocate_tensors()
    inp, out = it.get_input_details()[0], it.get_output_details()[0]
    assert list(inp["shape"]) == list(x_nhwc.shape), inp["shape"]
    it.set_tensor(inp["index"], x_nhwc)
    t = time.perf_counter()
    it.invoke()
    return it.get_tensor(out["index"]), (time.perf_counter() - t) * 1000


def test_page(h, w):
    """Line art with a halftone-dot (screentone) area and a little noise."""
    rng = np.random.default_rng(1)
    x = np.ones((h, w), np.float32)
    yy, xx = np.mgrid[:h, :w]
    tone = (np.sin(xx * 1.9) * np.sin(yy * 1.9) > 0.2).astype(np.float32)
    x[h // 5: h // 2, w // 6: w * 5 // 6] = 1 - 0.8 * tone[h // 5: h // 2, w // 6: w * 5 // 6]
    x[h * 3 // 5: h * 4 // 5, w // 4: w // 2] = 0.55
    x[rng.integers(0, h, 3000), rng.integers(0, w, 3000)] = 0.0
    x += rng.normal(0, 0.03, x.shape).astype(np.float32)
    return np.clip(x, 0, 1)[None, None]


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--weights")
    g.add_argument("--random", action="store_true")
    ap.add_argument("--out", default="denoiser.tflite")
    ap.add_argument("--width", type=int, default=448)
    ap.add_argument("--check-only", action="store_true", help="skip TFLite conversion")
    args = ap.parse_args()
    w = args.width
    h = int(round(w * 1.4444 / 32)) * 32  # same input as the colorizer

    net = load_ffdnet(args.weights)
    model = GrayDenoiser(net).eval()
    x = torch.from_numpy(test_page(h, w))
    with torch.no_grad():
        mine = model(x)
    ref = reference(net, x)
    err = (mine - ref).abs().max().item()
    change = (ref - x).abs().max().item()  # how much the denoiser alters the page
    print(f"::notice::rewritten graph vs project FFDNet: max diff {err:.2e} (denoiser changes up to {change:.3f})")
    assert change > 0.01 and err < 1e-3 * change, "rewritten FFDNet does not match the project's"
    if args.check_only:
        return

    to_tflite(model, h, w, args.out)
    lite, ms = run_tflite(args.out, x.numpy().transpose(0, 2, 3, 1))
    diff = np.abs(lite - ref.numpy().transpose(0, 2, 3, 1))
    tone = slice(h // 5, h // 2), slice(w // 6, w * 5 // 6)
    before = x.numpy()[0, 0][tone].std()
    after = lite[0, :, :, 0][tone].std()
    print(f"::notice::denoiser tflite vs torch: mean {diff.mean():.5f} max {diff.max():.4f}, {ms:.0f} ms, "
          f"{os.path.getsize(args.out) / 1e6:.1f} MB; screentone std {before:.3f} -> {after:.3f}")
    assert diff.mean() < 0.01, "converted denoiser does not match PyTorch"
    print("wrote", args.out)


if __name__ == "__main__":
    main()
