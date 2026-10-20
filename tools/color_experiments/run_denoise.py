import sys, numpy as np, onnxruntime as ort
inp, out, h, w = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
x = np.fromfile(inp, dtype=np.float32).reshape(1, 1, h, w)
s = ort.InferenceSession('/tmp/onnx_out/denoiser.onnx', providers=['CPUExecutionProvider'])
s.run(None, {'input': x})[0].astype(np.float32).tofile(out)
