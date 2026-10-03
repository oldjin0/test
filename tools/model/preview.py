"""Runs colorizer.tflite on sample images with the same pre/post-processing as
lib/colorizer.dart and writes a side-by-side preview (gray | colorized | original).

Usage: python preview.py MODEL OUT_PNG IMAGE [IMAGE ...]
"""

import sys
import time

import numpy as np
import tensorflow as tf
from PIL import Image


def srgb_to_l(v):
    """8-bit sRGB gray -> CIE L* (0..100)."""
    c = v / 255.0
    lin = np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
    d = 6 / 29
    f = np.where(lin > d ** 3, np.cbrt(lin), lin / (3 * d * d) + 4 / 29)
    return 116 * f - 16


def lab_to_rgb(L, a, b):
    d = 6 / 29
    fy = (L + 16) / 116
    fx, fz = fy + a / 500, fy - b / 200

    def finv(t):
        return np.where(t > d, t ** 3, 3 * d * d * (t - 4 / 29))

    X, Y, Z = 0.95047 * finv(fx), finv(fy), 1.08883 * finv(fz)
    r = 3.2404542 * X - 1.5371385 * Y - 0.4985314 * Z
    g = -0.9692660 * X + 1.8760108 * Y + 0.0415560 * Z
    bb = 0.0556434 * X - 0.2040259 * Y + 1.0572252 * Z
    rgb = np.stack([r, g, bb], -1).clip(0, 1)
    rgb = np.where(rgb <= 0.0031308, 12.92 * rgb, 1.055 * rgb ** (1 / 2.4) - 0.055)
    return (rgb * 255).clip(0, 255)


def colorize(it, gray_img):
    """gray_img: PIL 'L' image. Returns colorized PIL RGB at the same size.

    The page is letterboxed into the model input (padded white at the
    right/bottom), as lib/colorizer.dart does."""
    _, h, w, _ = it.get_input_details()[0]["shape"]
    out_c = it.get_output_details()[0]["shape"][3]
    s = min(w / gray_img.width, h / gray_img.height)
    pw, ph = max(1, round(gray_img.width * s)), max(1, round(gray_img.height * s))
    canvas = Image.new("L", (w, h), 255)
    canvas.paste(gray_img.resize((pw, ph), Image.BILINEAR), (0, 0))
    small = np.asarray(canvas, np.float32)
    x = (small / 255.0 if out_c == 3 else srgb_to_l(small) / 100.0).astype(np.float32)
    it.set_tensor(it.get_input_details()[0]["index"], x[None, :, :, None])
    t = time.perf_counter()
    it.invoke()
    ms = (time.perf_counter() - t) * 1000
    y = it.get_tensor(it.get_output_details()[0]["index"])[0]
    k = y.shape[1] / w  # output scale (ECCV16 predicts at 1/4 size)
    y = y[: max(1, round(ph * k)), : max(1, round(pw * k))]
    if out_c == 3:
        rgb = y.clip(0, 1) * 255
    else:
        low_gray = np.asarray(gray_img.resize((y.shape[1], y.shape[0]), Image.BILINEAR), np.float32)
        rgb = lab_to_rgb(srgb_to_l(low_gray), y[..., 0], y[..., 1])
    cb = 128 - 0.168736 * rgb[..., 0] - 0.331264 * rgb[..., 1] + 0.5 * rgb[..., 2]
    cr = 128 + 0.5 * rgb[..., 0] - 0.418688 * rgb[..., 1] - 0.081312 * rgb[..., 2]
    W, H = gray_img.size
    cb = np.asarray(Image.fromarray(cb.astype(np.float32)).resize((W, H), Image.BILINEAR))
    cr = np.asarray(Image.fromarray(cr.astype(np.float32)).resize((W, H), Image.BILINEAR))
    y = np.asarray(gray_img, np.float32)
    out = np.stack([y + 1.402 * (cr - 128),
                    y - 0.344136 * (cb - 128) - 0.714136 * (cr - 128),
                    y + 1.772 * (cb - 128)], -1)
    return Image.fromarray(out.clip(0, 255).astype(np.uint8)), ms


def main():
    model, out_png, *paths = sys.argv[1:]
    it = tf.lite.Interpreter(model_path=model, num_threads=4)
    it.allocate_tensors()
    rows = []
    for p in paths:
        orig = Image.open(p).convert("RGB")
        orig.thumbnail((640, 640))
        gray = orig.convert("L")
        col, ms = colorize(it, gray)
        sat = np.asarray(col.convert("HSV"), np.float32)[..., 1].mean()
        print(f"{p}: {orig.size} inference {ms:.0f} ms, mean saturation {sat:.1f}/255")
        row = Image.new("RGB", (orig.width * 3, orig.height))
        for i, im in enumerate([gray.convert("RGB"), col, orig]):
            row.paste(im, (i * orig.width, 0))
        rows.append(row)
    W = max(r.width for r in rows)
    sheet = Image.new("RGB", (W, sum(r.height for r in rows)), "white")
    y = 0
    for r in rows:
        sheet.paste(r, (0, y))
        y += r.height
    sheet.save(out_png)
    print("wrote", out_png)


if __name__ == "__main__":
    main()
