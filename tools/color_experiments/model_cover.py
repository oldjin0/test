import numpy as np, onnxruntime as ort, sys
from PIL import Image
sys.path.insert(0,'/tmp/claude-0/exp')
from tone_palette import luma, cbcr, delta
D='/tmp/claude-0/exp/data/'; O='/tmp/claude-0/exp/out/'
col=ort.InferenceSession('/tmp/onnx_out/colorizer_fp32.onnx',providers=['CPUExecutionProvider'])
dn=ort.InferenceSession('/tmp/onnx_out/denoiser.onnx',providers=['CPUExecutionProvider'])
def model_color(rgb):
    H,W=rgb.shape[:2]; y=luma(rgb.astype(np.float32))
    iw,ih=448,640; s=min(iw/W,ih/H); pw,ph=round(W*s),round(H*s)
    small=np.asarray(Image.fromarray(y.clip(0,255).astype(np.uint8)).resize((pw,ph),Image.BILINEAR)).astype(np.float32)/255
    g=np.ones((ih,iw),np.float32); g[:ph,:pw]=small
    g=dn.run(None,{'input':g[None,None]})[0][0,0]
    x=np.zeros((1,5,ih,iw),np.float32); x[0,0]=g
    o=col.run(None,{'input':x})[0][0][:, :ph,:pw]*255
    r,g_,b=o; cb=-0.168736*r-0.331264*g_+0.5*b; cr=0.5*r-0.418688*g_-0.081312*b
    cb=np.asarray(Image.fromarray(cb.astype(np.float32),mode='F').resize((W,H),Image.BILINEAR)); cr=np.asarray(Image.fromarray(cr.astype(np.float32),mode='F').resize((W,H),Image.BILINEAR))
    R=y+1.402*cr; G=y-0.344136*cb-0.714136*cr; B=y+1.772*cb
    return np.stack([R,G,B],-1).clip(0,255).astype(np.uint8)
if __name__=='__main__':
    for name in ['naruto','onepiece','anyong']:
        real=np.asarray(Image.open(D+f'cover_{name}.png').convert('RGB'))
        g=luma(real.astype(np.float32)); gray=np.stack([g,g,g],-1)
        m=model_color(real); Image.fromarray(m).save(O+f'selfmodel_{name}.png')
        print(name,'gray %.1f  model %.1f'%(delta(gray,real),delta(m,real)))
