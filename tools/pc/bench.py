"""Manga Viewer PC benchmark: how fast does this computer colorize a page?

Runs the colorizer model with ONNX Runtime on every execution provider it can
start (DirectML on each graphics adapter, CPU), at several input sizes, and
writes a table plus preview images. Send bench_result.txt back.

  python bench.py --model colorizer_fp16.onnx [--samples samples] [--out result]
"""

import argparse
import glob
import json
import math
import os
import platform
import statistics
import subprocess
import sys
import time

import numpy as np
from PIL import Image

try:
    import onnxruntime as ort
except Exception as e:  # pragma: no cover
    print("onnxruntime is not available:", e)
    sys.exit(2)

SIZES = [448, 576, 704, 768]  # widths; height = round(w * 1.4444 / 32) * 32


def height_for(w):
    return int(round(w * 1.4444 / 32)) * 32


def sh(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=20, shell=True).stdout
    except Exception:
        return ""


def system_info():
    info = {"os": platform.platform(), "python": platform.python_version(),
            "onnxruntime": ort.__version__, "providers": ort.get_available_providers(),
            "cpu_count": os.cpu_count()}
    if os.name == "nt":
        ps = lambda q: [l.strip() for l in sh(f'powershell -NoProfile -Command "{q}"').splitlines() if l.strip()]
        info["cpu"] = ps("(Get-CimInstance Win32_Processor).Name")
        info["gpus"] = ps("(Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name + ' / ' + [math]::Round($_.AdapterRAM/1MB) + ' MB' })")
        info["ram_gb"] = ps("[math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB,1)")
    else:
        info["cpu"] = [platform.processor() or platform.machine()]
    return info


def make_session(model, provider, device_id, w, h, threads=0):
    so = ort.SessionOptions()
    so.add_free_dimension_override_by_name("h", h)
    so.add_free_dimension_override_by_name("w", w)
    if provider == "DmlExecutionProvider":
        # DirectML wants sequential execution and no memory pattern.
        so.enable_mem_pattern = False
        so.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
        providers = [(provider, {"device_id": device_id})]
    else:
        if threads:
            so.intra_op_num_threads = threads
        providers = [provider]
    sess = ort.InferenceSession(model, so, providers=providers)
    if provider not in sess.get_providers()[:1]:
        raise RuntimeError(f"{provider} not active (got {sess.get_providers()})")
    return sess


def page_input(w, h):
    x = np.zeros((1, 5, h, w), np.float32)
    x[:, 0] = 1.0
    x[:, 0, h // 6: h * 4 // 5, w // 6: w * 5 // 6] = 0.6
    rng = np.random.default_rng(0)
    x[:, 0, rng.integers(0, h, h * 6), rng.integers(0, w, h * 6)] = 0.0
    return x


def time_runs(sess, x, runs):
    first_t = time.perf_counter()
    out = sess.run(None, {"input": x})[0]
    first = time.perf_counter() - first_t
    times = []
    for _ in range(runs):
        t = time.perf_counter()
        sess.run(None, {"input": x})
        times.append(time.perf_counter() - t)
    return first, times, out


def colorize_page(sess, gray_img, w, h):
    """The app's pipeline: letterbox into the model input, predict, merge the
    prediction's chroma with the page's own luminance."""
    s = min(w / gray_img.width, h / gray_img.height)
    pw, ph = max(1, round(gray_img.width * s)), max(1, round(gray_img.height * s))
    canvas = Image.new("L", (w, h), 255)
    canvas.paste(gray_img.resize((pw, ph), Image.BILINEAR), (0, 0))
    x = np.zeros((1, 5, h, w), np.float32)
    x[0, 0] = np.asarray(canvas, np.float32) / 255
    y = sess.run(None, {"input": x})[0][0].transpose(1, 2, 0)[:ph, :pw].clip(0, 1) * 255
    cb = 128 - 0.168736 * y[..., 0] - 0.331264 * y[..., 1] + 0.5 * y[..., 2]
    cr = 128 + 0.5 * y[..., 0] - 0.418688 * y[..., 1] - 0.081312 * y[..., 2]
    W, H = gray_img.size
    cb = np.asarray(Image.fromarray(cb.astype(np.float32)).resize((W, H), Image.BILINEAR))
    cr = np.asarray(Image.fromarray(cr.astype(np.float32)).resize((W, H), Image.BILINEAR))
    lum = np.asarray(gray_img, np.float32)
    out = np.stack([lum + 1.402 * (cr - 128),
                    lum - 0.344136 * (cb - 128) - 0.714136 * (cr - 128),
                    lum + 1.772 * (cb - 128)], -1)
    return Image.fromarray(out.clip(0, 255).astype(np.uint8))


def screentone(gray_img, period=4.0):
    g = np.asarray(gray_img, np.float32) / 255
    yy, xx = np.mgrid[: g.shape[0], : g.shape[1]].astype(np.float32)
    u, v = (xx + yy) / math.sqrt(2), (xx - yy) / math.sqrt(2)
    cell = (np.cos(2 * math.pi * u / period) + np.cos(2 * math.pi * v / period) + 2) / 4
    return Image.fromarray(np.where(cell < g, 255, 0).astype(np.uint8))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True, nargs="+", help="one or more .onnx files (e.g. fp32 and fp16)")
    ap.add_argument("--samples")
    ap.add_argument("--out", default="result")
    ap.add_argument("--runs", type=int, default=4)
    ap.add_argument("--sizes", default=",".join(map(str, SIZES)))
    ap.add_argument("--max-devices", type=int, default=4)
    args = ap.parse_args()
    # Windows shells do not expand wildcards.
    args.model = [f for a in args.model for f in (sorted(glob.glob(a)) or [a])]
    os.makedirs(args.out, exist_ok=True)
    sizes = [int(s) for s in args.sizes.split(",")]
    lines = []

    def say(s=""):
        print(s, flush=True)
        lines.append(s)

    info = system_info()
    say("== Manga Viewer PC benchmark ==")
    for k, v in info.items():
        say(f"{k}: {v}")
    models = {os.path.basename(m).replace("colorizer_", "").replace(".onnx", ""): m for m in args.model}
    for tag, m in models.items():
        say(f"model {tag}: {os.path.basename(m)} ({os.path.getsize(m) / 1e6:.0f} MB)")
    say()
    first_model = next(iter(models.values()))

    # Which (provider, device) pairs start at all?
    targets = []
    avail = ort.get_available_providers()
    if "DmlExecutionProvider" in avail:
        for d in range(args.max_devices):
            try:
                make_session(first_model, "DmlExecutionProvider", d, 448, 640)
                targets.append(("DmlExecutionProvider", d, f"DirectML adapter {d}"))
            except Exception as e:
                say(f"DirectML adapter {d}: not usable ({str(e).splitlines()[0][:120]})")
                if d == 0:
                    break
    else:
        say("DirectML: not available in this onnxruntime build")
    targets.append(("CPUExecutionProvider", 0, f"CPU ({info.get('cpu_count')} threads)"))

    results = []
    reference = {}
    say(f"{'engine':<34}{'size':>10}{'load s':>9}{'1st run s':>11}{'median s':>10}{'min s':>8}   note")
    for tag, model_path in models.items():
      for provider, dev, label0 in targets:
        label = f"{label0} {tag}"
        for w in sizes:
            h = height_for(w)
            row = {"engine": label, "width": w, "height": h, "model": tag, "model_path": model_path,
                   "provider": provider, "device": dev}
            try:
                t = time.perf_counter()
                sess = make_session(model_path, provider, dev, w, h)
                row["load_s"] = time.perf_counter() - t
                x = page_input(w, h)
                first, times, out = time_runs(sess, x, args.runs)
                row.update(first_s=first, median_s=statistics.median(times), min_s=min(times))
                if w == 448 and provider == "CPUExecutionProvider":
                    reference[tag] = out
                elif w == 448 and tag in reference:
                    row["diff_vs_cpu"] = float(np.abs(out - reference[tag]).mean())
                note = f"diff vs CPU {row['diff_vs_cpu']:.5f}" if "diff_vs_cpu" in row else ""
                say(f"{label:<34}{f'{w}x{h}':>10}{row['load_s']:>9.1f}{first:>11.2f}"
                    f"{row['median_s']:>10.2f}{row['min_s']:>8.2f}   {note}")
                del sess
            except Exception as e:
                row["error"] = str(e).splitlines()[0][:200]
                say(f"{label:<34}{f'{w}x{h}':>10}   failed: {row['error']}")
            results.append(row)

    ok = [r for r in results if "median_s" in r]
    say()
    if ok:
        fastest = min(ok, key=lambda r: r["median_s"] * (448 * 640) / (r["width"] * r["height"]))
        say(f"fastest engine: {fastest['engine']}")
        for w in sizes:
            best = [r for r in ok if r["width"] == w]
            if best:
                b = min(best, key=lambda r: r["median_s"])
                say(f"  {w}x{height_for(w)}: {b['median_s']:.2f} s per page on {b['engine']}")
        usable = [r for r in ok if r["median_s"] <= 3.0]
        if usable:
            top = max(usable, key=lambda r: r["width"])
            say(f"largest size within 3 s per page: {top['width']}x{top['height']} on {top['engine']}")

    # Quality preview: the same page colorized at each size, plus a screentoned copy.
    if args.samples and ok:
        best_engine = min(ok, key=lambda r: r["median_s"])
        t = (best_engine["provider"], best_engine["device"])
        model_for_preview = best_engine["model_path"]
        files = sorted(f for f in os.listdir(args.samples) if f.lower().endswith((".png", ".jpg")))[:3]
        sess_by_w = {}
        rows = []
        for name in files:
            orig = Image.open(os.path.join(args.samples, name)).convert("RGB")
            orig.thumbnail((640, 640))
            gray = orig.convert("L")
            toned = screentone(gray.resize((gray.width * 2, gray.height * 2), Image.BICUBIC)).resize(gray.size, Image.BILINEAR)
            panels = [toned.convert("RGB")]
            for w in sizes:
                if w not in sess_by_w:
                    sess_by_w[w] = make_session(model_for_preview, t[0], t[1], w, height_for(w))
                panels.append(colorize_page(sess_by_w[w], toned, w, height_for(w)))
            panels.append(orig)
            row = Image.new("RGB", (orig.width * len(panels), orig.height))
            for i, p in enumerate(panels):
                row.paste(p, (i * orig.width, 0))
            rows.append(row)
        sheet = Image.new("RGB", (max(r.width for r in rows), sum(r.height for r in rows)), "white")
        y = 0
        for r in rows:
            sheet.paste(r, (0, y))
            y += r.height
        sheet.save(os.path.join(args.out, "quality_by_size.png"))
        say(f"quality preview: columns = screentoned page, " + ", ".join(f"{w}px" for w in sizes) + ", original")

    with open(os.path.join(args.out, "bench_result.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    with open(os.path.join(args.out, "bench_result.json"), "w", encoding="utf-8") as f:
        json.dump({"system": info, "results": results}, f, indent=2, default=str)
    say(f"\nSaved to {os.path.abspath(args.out)}")


if __name__ == "__main__":
    main()
