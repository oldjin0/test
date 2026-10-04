"""Exports manga-colorization-v2 to ONNX for the PC version (ONNX Runtime with
DirectML / CPU) and checks it against the PyTorch model.

  input : [1, 5, H, W] float32 NCHW: gray 0..1, hint r*m, g*m, b*m (-1..1), mask m
  output: [1, 3, H, W] float32 RGB 0..1
  H and W are dynamic (multiples of 32); ONNX Runtime can pin them per session
  (free dimension overrides), which DirectML prefers.

With --denoiser-weights also writes denoiser.onnx (FFDNet, sigma 25):
  input : [1, 1, H, W] gray 0..1    output: [1, 1, H, W] denoised gray 0..1

Writes colorizer_fp32.onnx and, when the half-precision conversion matches,
colorizer_fp16.onnx (inputs/outputs stay float32).

Usage:
  PYTHONPATH=/path/to/manga-colorization-v2 python export_onnx.py \
      --weights generator.zip --out-dir out
  PYTHONPATH=/path/to/reference python export_onnx.py --random --out-dir out   # self-test
"""

import argparse
import json
import os
import sys

import numpy as np
import torch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "model"))
import convert_manga as cm  # noqa: E402  (AutoColorizer, load_generator)


def page_like(h, w, seed=0):
    """Gray page with a hint disc, as the app feeds the model."""
    rng = np.random.default_rng(seed)
    x = np.zeros((1, 5, h, w), np.float32)
    x[:, 0] = 1.0
    x[:, 0, h // 6: h * 4 // 5, w // 6: w * 5 // 6] = 0.6
    x[:, 0, rng.integers(0, h, h * 6), rng.integers(0, w, h * 6)] = 0.0
    yy, xx = np.mgrid[:h, :w]
    disc = (yy - h // 2) ** 2 + (xx - w // 2) ** 2 < (w // 30) ** 2
    x[0, 1][disc], x[0, 2][disc], x[0, 3][disc], x[0, 4][disc] = 1.0, -1.0, -1.0, 1.0
    return x


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--weights")
    g.add_argument("--random", action="store_true")
    ap.add_argument("--out-dir", default="out")
    ap.add_argument("--denoiser-weights", help="FFDNet net_rgb.pth; with --random a random FFDNet is used")
    ap.add_argument("--fp16-tolerance", type=float, default=0.02, help="max mean abs diff to ship fp16")
    args = ap.parse_args()
    os.makedirs(args.out_dir, exist_ok=True)

    import onnx
    import onnxruntime as ort

    model = cm.AutoColorizer(cm.load_generator(args.weights)).eval()
    fp32 = os.path.join(args.out_dir, "colorizer_fp32.onnx")
    torch.onnx.export(
        model, torch.from_numpy(page_like(640, 448)), fp32, opset_version=17,
        input_names=["input"], output_names=["rgb"],
        dynamic_axes={"input": {2: "h", 3: "w"}, "rgb": {2: "h", 3: "w"}}, dynamo=False)
    print("wrote", fp32, f"{os.path.getsize(fp32) / 1e6:.1f} MB")

    report = {"fp32": {"mb": round(os.path.getsize(fp32) / 1e6, 1)}}

    def parity(path, label, sizes=((640, 448), (832, 576))):
        sess = ort.InferenceSession(path, providers=["CPUExecutionProvider"])
        out = {}
        for h, w in sizes:
            x = page_like(h, w, seed=h)
            with torch.no_grad():
                ref = model(torch.from_numpy(x)).numpy()
            got = sess.run(None, {"input": x})[0]
            assert got.shape == ref.shape, (got.shape, ref.shape)
            d = np.abs(got - ref)
            out[f"{w}x{h}"] = {"mean": float(d.mean()), "max": float(d.max())}
            print(f"{label} {w}x{h}: mean diff {d.mean():.6f} max {d.max():.5f}")
        return out

    report["fp32"]["parity"] = parity(fp32, "fp32 vs torch")
    assert all(v["mean"] < 0.002 for v in report["fp32"]["parity"].values()), "ONNX does not match PyTorch"

    # Half precision: smaller files and faster on GPUs; kept only if it matches.
    try:
        from onnxconverter_common import float16

        m16 = float16.convert_float_to_float16(onnx.load(fp32), keep_io_types=True)
        fp16 = os.path.join(args.out_dir, "colorizer_fp16.onnx")
        onnx.save(m16, fp16)
        report["fp16"] = {"mb": round(os.path.getsize(fp16) / 1e6, 1)}
        report["fp16"]["parity"] = parity(fp16, "fp16 vs torch")
        worst = max(v["mean"] for v in report["fp16"]["parity"].values())
        if worst > args.fp16_tolerance:
            print(f"fp16 differs too much ({worst:.4f}): not shipped")
            os.remove(fp16)
            report["fp16"]["shipped"] = False
        else:
            report["fp16"]["shipped"] = True
    except Exception as e:  # the fp32 model is the baseline
        print("fp16 conversion failed:", e)
        report["fp16"] = {"error": str(e), "shipped": False}

    if args.denoiser_weights or args.random:
        import convert_denoiser as cd  # tools/model

        net = cd.load_ffdnet(args.denoiser_weights)
        dn = cd.GrayDenoiser(net).eval()
        path = os.path.join(args.out_dir, "denoiser.onnx")
        dummy = torch.rand(1, 1, 640, 448)
        torch.onnx.export(
            dn, dummy, path, opset_version=17, input_names=["input"], output_names=["clean"],
            dynamic_axes={"input": {2: "h", 3: "w"}, "clean": {2: "h", 3: "w"}}, dynamo=False)
        sess = ort.InferenceSession(path, providers=["CPUExecutionProvider"])
        res = {}
        for h, w in ((640, 448), (832, 576)):
            x = torch.from_numpy(cd.test_page(h, w))
            with torch.no_grad():
                ref = dn(x).numpy()
            got = sess.run(None, {"input": x.numpy()})[0]
            d = np.abs(got - ref)
            res[f"{w}x{h}"] = {"mean": float(d.mean()), "max": float(d.max())}
            print(f"denoiser onnx vs torch {w}x{h}: mean diff {d.mean():.7f} max {d.max():.6f}")
            assert d.mean() < 1e-4, "denoiser ONNX does not match PyTorch"
        report["denoiser"] = {"mb": round(os.path.getsize(path) / 1e6, 1), "parity": res}

    with open(os.path.join(args.out_dir, "export_report.json"), "w") as f:
        json.dump(report, f, indent=2)


if __name__ == "__main__":
    main()
