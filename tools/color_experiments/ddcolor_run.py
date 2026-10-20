import numpy as np, onnxruntime as ort, cv2, sys, time
from PIL import Image
sys.path.insert(0,'/tmp/claude-0/exp')
from tone_palette import luma, delta
D='/tmp/claude-0/exp/data/'; O='/tmp/claude-0/exp/out/'
so=ort.SessionOptions(); so.log_severity_level=3
sess=ort.InferenceSession('/tmp/claude-0/exp/ddcolor512.onnx',so,providers=['CPUExecutionProvider'])
def ddcolor(rgb):
    img=(rgb.astype(np.float32)/255)
    H,W=img.shape[:2]
    lab=cv2.cvtColor(img,cv2.COLOR_RGB2Lab); L=lab[...,:1]
    small=cv2.resize(img,(512,512))
    l2=cv2.cvtColor(small,cv2.COLOR_RGB2Lab)[...,:1]
    g=np.concatenate([l2,np.zeros_like(l2),np.zeros_like(l2)],-1)
    grgb=cv2.cvtColor(g,cv2.COLOR_LAB2RGB)
    x=grgb.transpose(2,0,1)[None].astype(np.float32)
    ab=sess.run(None,{'input':x})[0][0].transpose(1,2,0)
    ab=cv2.resize(ab,(W,H))
    out=cv2.cvtColor(np.concatenate([L,ab],-1).astype(np.float32),cv2.COLOR_Lab2RGB)
    return (out.clip(0,1)*255).astype(np.uint8)
if __name__=='__main__':
    for name in ['naruto','onepiece','anyong']:
        real=np.asarray(Image.open(D+f'cover_{name}.png').convert('RGB'))
        g=luma(real.astype(np.float32)); gray=np.stack([g,g,g],-1).clip(0,255).astype(np.uint8)
        t=time.time(); m=ddcolor(gray); dt=time.time()-t
        Image.fromarray(m).save(O+f'selfdd_{name}.png')
        print(name,'gray %.1f  ddcolor %.1f  (%.1fs)'%(delta(gray,real),delta(m,real),dt))
