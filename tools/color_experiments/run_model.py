import sys, numpy as np, onnxruntime as ort
inp, out, h, w = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
x = np.fromfile(inp, dtype=np.float32).reshape(h, w, 5).transpose(2, 0, 1)[None]
s = ort.InferenceSession('/tmp/onnx_out/colorizer_fp32.onnx', providers=['CPUExecutionProvider'])
y = s.run(None, {'input': x.astype(np.float32)})[0][0]  # 3,h,w
y.transpose(1, 2, 0).astype(np.float32).tofile(out)
