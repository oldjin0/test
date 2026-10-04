"""Runs colorizer.tflite on sample images with the same pre/post-processing as
lib/colorizer.dart and writes a side-by-side preview (gray | colorized | original).

With --denoiser, each sample is also screentoned (printed-manga halftone
dots) and colorized with and without the denoiser first:
  screentoned | colorized | denoised + colorized | original

Usage: python preview.py MODEL OUT_PNG IMAGE [IMAGE ...] [--denoiser DENOISER]
"""

import argparse
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


def run(it, x):
    it.set_tensor(it.get_input_details()[0]["index"], x)
    t = time.perf_counter()
    it.invoke()
    return it.get_tensor(it.get_output_details()[0]["index"]), (time.perf_counter() - t) * 1000


def screentone(gray_img, period=4.0):
    """Halftone dots at 45 degrees, like printed manga: each gray becomes
    black dots on white whose size follows the darkness."""
    g = np.asarray(gray_img, np.float32) / 255
    yy, xx = np.mgrid[: g.shape[0], : g.shape[1]].astype(np.float32)
    u, v = (xx + yy) / np.sqrt(2), (xx - yy) / np.sqrt(2)
    cell = (np.cos(2 * np.pi * u / period) + np.cos(2 * np.pi * v / period) + 2) / 4  # 0..1
    return Image.fromarray(np.where(cell < g, 255, 0).astype(np.uint8))


def colorize(it, gray_img, denoiser=None):
    """gray_img: PIL 'L' image. Returns colorized PIL RGB at the same size.

    The page is letterboxed into the model input (padded white at the
    right/bottom), as lib/colorizer.dart does."""
    _, h, w, in_c = it.get_input_details()[0]["shape"]
    out_c = it.get_output_details()[0]["shape"][3]
    s = min(w / gray_img.width, h / gray_img.height)
    pw, ph = max(1, round(gray_img.width * s)), max(1, round(gray_img.height * s))
    canvas = Image.new("L", (w, h), 255)
    canvas.paste(gray_img.resize((pw, ph), Image.BILINEAR), (0, 0))
    small = np.asarray(canvas, np.float32)
    x = (small / 255.0 if out_c == 3 else srgb_to_l(small) / 100.0).astype(np.float32)
    x = x[None, :, :, None]
    ms = 0.0
    if denoiser is not None:
        x, ms = run(denoiser, x)
    if in_c > 1:  # gray + empty hint channels
        x = np.concatenate([x, np.zeros(x.shape[:3] + (in_c - 1,), np.float32)], -1)
    y, ms2 = run(it, x)
    ms += ms2
    y = y[0]
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


def interpreter(path):
    it = tf.lite.Interpreter(model_path=path, num_threads=4)
    it.allocate_tensors()
    return it


def saturation(im):
    return np.asarray(im.convert("HSV"), np.float32)[..., 1].mean()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model")
    ap.add_argument("out_png")
    ap.add_argument("images", nargs="+")
    ap.add_argument("--denoiser")
    args = ap.parse_args()
    it = interpreter(args.model)
    dn = interpreter(args.denoiser) if args.denoiser else None
    rows = []
    for p in args.images:
        orig = Image.open(p).convert("RGB")
        orig.thumbnail((640, 640))
        gray = orig.convert("L")
        if dn is None:
            col, ms = colorize(it, gray)
            print(f"{p}: {orig.size} inference {ms:.0f} ms, mean saturation {saturation(col):.1f}/255")
            panels = [gray.convert("RGB"), col, orig]
        else:
            # Print-like page: screentone at 2x, then shrunk as a page would be.
            big = gray.resize((gray.width * 2, gray.height * 2), Image.BICUBIC)
            toned = screentone(big).resize(gray.size, Image.BILINEAR)
            plain, ms = colorize(it, toned)
            clean, ms_dn = colorize(it, toned, dn)
            print(f"::notice::{p.split('/')[-1]}: screentoned; colorize {ms:.0f} ms sat {saturation(plain):.1f}, "
                  f"denoise+colorize {ms_dn:.0f} ms sat {saturation(clean):.1f}")
            panels = [toned.convert("RGB"), plain, clean, orig]
        row = Image.new("RGB", (orig.width * len(panels), orig.height))
        for i, im in enumerate(panels):
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
