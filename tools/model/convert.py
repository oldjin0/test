"""Builds assets/models/colorizer.tflite from the ECCV16 colorization model.

Model: Zhang, Isola, Efros, "Colorful Image Colorization" (ECCV 2016),
weights from https://github.com/richzhang/colorization (BSD-2-Clause).

The PyTorch network is re-built in Keras, the weights are copied over, and
the Keras graph is checked against PyTorch before converting to TFLite.

TFLite contract used by the app (lib/colorizer.dart):
  input : [1, S, S, 1] float32, CIE L* / 100   (0..1)
  output: [1, S/4, S/4, 2] float32, CIE a*, b*  (Lab units)

Usage:
  python convert.py --official --out ../../assets/models/colorizer.tflite  # fp16
  python convert.py --random   # layout self-test with random weights
"""

import argparse
import time

import numpy as np
import tensorflow as tf
import torch
from torch import nn

SIZE = 512


class ECCV16(nn.Module):
    """Same layout and parameter names as colorizers.eccv16.ECCVGenerator."""

    def __init__(self):
        super().__init__()

        def block(chs, strides=(), dil=1, last_stride=1):
            layers = []
            for i, (cin, cout) in enumerate(zip(chs, chs[1:])):
                s = last_stride if i == len(chs) - 2 else 1
                layers += [nn.Conv2d(cin, cout, 3, s, dil, dilation=dil), nn.ReLU(True)]
            return layers + [nn.BatchNorm2d(chs[-1])]

        self.model1 = nn.Sequential(*block([1, 64, 64], last_stride=2))
        self.model2 = nn.Sequential(*block([64, 128, 128], last_stride=2))
        self.model3 = nn.Sequential(*block([128, 256, 256, 256], last_stride=2))
        self.model4 = nn.Sequential(*block([256, 512, 512, 512]))
        self.model5 = nn.Sequential(*block([512, 512, 512, 512], dil=2))
        self.model6 = nn.Sequential(*block([512, 512, 512, 512], dil=2))
        self.model7 = nn.Sequential(*block([512, 512, 512, 512]))
        self.model8 = nn.Sequential(
            nn.ConvTranspose2d(512, 256, 4, 2, 1), nn.ReLU(True),
            nn.Conv2d(256, 256, 3, 1, 1), nn.ReLU(True),
            nn.Conv2d(256, 256, 3, 1, 1), nn.ReLU(True),
            nn.Conv2d(256, 313, 1, 1, 0))
        self.softmax = nn.Softmax(dim=1)
        self.model_out = nn.Conv2d(313, 2, 1, 1, 0, bias=False)


def torch_ab_lowres(model, l100):
    """Reference forward pass without the final x4 upsample.

    l100: [N,1,H,W] tensor, CIE L* in 0..100. Returns ab [N,2,H/4,W/4].
    """
    x = (l100 - 50.0) / 100.0
    for m in [model.model1, model.model2, model.model3, model.model4,
              model.model5, model.model6, model.model7, model.model8]:
        x = m(x)
    return model.model_out(model.softmax(x)) * 110.0


def build_keras(model, size=SIZE):
    """Re-creates the network in Keras (NHWC) with the PyTorch weights."""
    L = tf.keras.layers
    sd = {k: v.detach().cpu().numpy() for k, v in model.state_dict().items()}
    inp = L.Input((size, size, 1), batch_size=1, name="l_norm")
    x = L.Lambda(lambda t: t - 0.5, name="center")(inp)

    def conv(x, name, stride=1, dil=1, relu=True, bias=True):
        w = sd[name + ".weight"]  # [O, I, kh, kw]
        k = w.shape[2]
        pad = dil * (k - 1) // 2
        if pad:
            x = L.ZeroPadding2D(pad)(x)
        layer = L.Conv2D(w.shape[0], k, strides=stride, dilation_rate=dil,
                         padding="valid", use_bias=bias,
                         activation="relu" if relu else None)
        x = layer(x)
        weights = [w.transpose(2, 3, 1, 0)]
        if bias:
            weights.append(sd[name + ".bias"])
        layer.set_weights(weights)
        return x

    def bn(x, name):
        layer = L.BatchNormalization(epsilon=1e-5)
        x = layer(x)
        layer.set_weights([sd[name + ".weight"], sd[name + ".bias"],
                           sd[name + ".running_mean"], sd[name + ".running_var"]])
        return x

    def seq(x, prefix, n_convs, last_stride=1, dil=1):
        for i in range(n_convs):
            s = last_stride if i == n_convs - 1 else 1
            x = conv(x, f"{prefix}.{2 * i}", stride=s, dil=dil)
        return bn(x, f"{prefix}.{2 * n_convs}")

    x = seq(x, "model1", 2, last_stride=2)
    x = seq(x, "model2", 2, last_stride=2)
    x = seq(x, "model3", 3, last_stride=2)
    x = seq(x, "model4", 3)
    x = seq(x, "model5", 3, dil=2)
    x = seq(x, "model6", 3, dil=2)
    x = seq(x, "model7", 3)

    w = sd["model8.0.weight"]  # ConvTranspose: [I, O, kh, kw]
    up = L.Conv2DTranspose(w.shape[1], 4, strides=2, padding="same", activation="relu")
    x = up(x)
    up.set_weights([w.transpose(2, 3, 1, 0), sd["model8.0.bias"]])
    x = conv(x, "model8.2")
    x = conv(x, "model8.4")
    x = conv(x, "model8.6", relu=False)
    x = L.Softmax(axis=-1)(x)
    x = conv(x, "model_out", relu=False, bias=False)
    out = L.Lambda(lambda t: t * 110.0, name="ab")(x)
    return tf.keras.Model(inp, out)


def to_tflite(keras_model, precision="fp16"):
    """fp16: float16 weights, fully handled by the XNNPACK CPU delegate on Android.
    int8: dynamic-range weights; half the size, but its hybrid convolutions are
    not delegated to XNNPACK on Android and ran ~100x slower on device."""
    conv = tf.lite.TFLiteConverter.from_keras_model(keras_model)
    conv.optimizations = [tf.lite.Optimize.DEFAULT]
    if precision == "fp16":
        conv.target_spec.supported_types = [tf.float16]
    return conv.convert()


def run_tflite(blob, x, threads=4):
    it = tf.lite.Interpreter(model_content=blob, num_threads=threads)
    it.allocate_tensors()
    it.set_tensor(it.get_input_details()[0]["index"], x)
    t = time.perf_counter()
    it.invoke()
    ms = (time.perf_counter() - t) * 1000
    return it.get_tensor(it.get_output_details()[0]["index"]), ms


def check_parity(model, keras_model, blob, size=SIZE, seed=0):
    rng = np.random.default_rng(seed)
    l = rng.random((1, size, size, 1), dtype=np.float32)
    with torch.no_grad():
        ref = torch_ab_lowres(model, torch.from_numpy(l.transpose(0, 3, 1, 2) * 100))
    ref = ref.numpy().transpose(0, 2, 3, 1)
    ker = keras_model(l).numpy()
    lite, ms = run_tflite(blob, l)
    d_keras = float(np.abs(ker - ref).max())
    d_lite = float(np.abs(lite - ref).mean())
    print(f"shape ref={ref.shape} keras={ker.shape} tflite={lite.shape}")
    print(f"max|keras-torch|={d_keras:.5f}  mean|tflite-torch|={d_lite:.5f}  "
          f"(ab range {ref.min():.1f}..{ref.max():.1f})  tflite {ms:.0f} ms")
    return d_keras, d_lite


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--official", action="store_true")
    g.add_argument("--random", action="store_true")
    ap.add_argument("--out")
    ap.add_argument("--size", type=int, default=SIZE)
    ap.add_argument("--precision", choices=["fp16", "int8"], default="fp16")
    args = ap.parse_args()

    model = ECCV16().eval()
    if args.official:
        from colorizers import eccv16  # from the cloned official repo
        official = eccv16(pretrained=True).eval()
        model.load_state_dict(official.state_dict())
    else:
        torch.manual_seed(0)
        for m in model.modules():  # non-trivial BN stats to exercise the port
            if isinstance(m, nn.BatchNorm2d):
                m.running_mean.uniform_(-0.5, 0.5)
                m.running_var.uniform_(0.5, 2.0)
                m.weight.data.uniform_(0.5, 1.5)
                m.bias.data.uniform_(-0.2, 0.2)

    keras_model = build_keras(model, args.size)
    blob = to_tflite(keras_model, args.precision)
    d_keras, d_lite = check_parity(model, keras_model, blob, args.size)
    assert d_keras < 1e-2, "Keras port does not match PyTorch"
    assert d_lite < 2.0, "quantized TFLite drifts too far from PyTorch"
    print(f"tflite size {len(blob) / 1e6:.1f} MB")
    if args.out:
        with open(args.out, "wb") as f:
            f.write(blob)
        print("wrote", args.out)


if __name__ == "__main__":
    main()
