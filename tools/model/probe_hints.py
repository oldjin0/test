"""Measures how much color hints steer manga-colorization-v2 (PyTorch), for
several hint colors, sizes and encodings, on a synthetic page and on sample
images. Prints, per case, how far the colors around the hint moved toward
the hint color (0 = no effect, 1 = fully the hint color).

Usage: PYTHONPATH=/path/to/mcv2 python probe_hints.py --weights generator.zip [IMAGE ...]
"""

import argparse

import numpy as np
import torch
from PIL import Image

import convert_manga as cm

COLORS = {"red": (1.0, 0.1, 0.1), "green": (0.1, 0.8, 0.2), "blue": (0.1, 0.3, 1.0)}


def pages(paths, h, w):
    x = np.ones((h, w), np.float32)
    x[100:700, 80:400] = 0.6
    yield "synthetic", x
    for p in paths:
        im = Image.open(p).convert("L")
        im.thumbnail((w, h))
        canvas = Image.new("L", (w, h), 255)
        canvas.paste(im, (0, 0))
        yield p.split("/")[-1], np.asarray(canvas, np.float32) / 255


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--weights", required=True)
    ap.add_argument("--width", type=int, default=448)
    ap.add_argument("images", nargs="*")
    args = ap.parse_args()
    w = args.width
    h = int(round(w * 1.4444 / 32)) * 32
    model = cm.AutoColorizer(cm.load_generator(args.weights)).eval()

    def run(x):
        with torch.no_grad():
            return model(torch.from_numpy(x)).numpy()[0].transpose(1, 2, 0)

    yy, xx = np.mgrid[:h, :w]
    cy, cx = h // 3, w // 3
    for name, gray in pages(args.images, h, w):
        base_in = np.zeros((1, 5, h, w), np.float32)
        base_in[0, 0] = gray
        base = run(base_in)
        for enc in ("signed", "unit"):
            for r in (4, 12, 30):
                disc = (yy - cy) ** 2 + (xx - cx) ** 2 < r * r
                near = (yy - cy) ** 2 + (xx - cx) ** 2 < (3 * r) ** 2
                row = []
                for cname, c in COLORS.items():
                    x = base_in.copy()
                    for k in range(3):
                        v = c[k] * 2 - 1 if enc == "signed" else c[k]
                        x[0, 1 + k][disc] = v
                    x[0, 4][disc] = 1
                    out = run(x)
                    target = np.array(c, np.float32)
                    d0 = np.linalg.norm(base[near] - target, axis=1).mean()
                    d1 = np.linalg.norm(out[near] - target, axis=1).mean()
                    row.append(f"{cname} {(d0 - d1) / max(d0, 1e-6):+.2f}")
                print(f"{name:>16} {enc:>6} r={r:<3} " + "  ".join(row), flush=True)


if __name__ == "__main__":
    main()
