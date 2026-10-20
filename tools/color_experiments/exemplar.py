import numpy as np, torch, cv2, sys, time
from PIL import Image
sys.path.insert(0,'/tmp/claude-0/exp')
from tone_palette import luma, cbcr, delta
from transformers import AutoModel
D='/tmp/claude-0/exp/data/'; O='/tmp/claude-0/exp/out/'
import os
P={'small':'/tmp/claude-0/exp/hf/models--facebook--dinov2-small/snapshots/ed25f3a31f01632728cabb09d1542f84ab7b0056',
   'base':'/tmp/claude-0/exp/hf/models--facebook--dinov2-base/snapshots/f9e44c814b77203eaa57a6bdbbd535f21ede1415'}[os.environ.get('DINO','small')]
torch.set_num_threads(4)
net=AutoModel.from_pretrained(P).eval()
MEAN=np.array([0.485,0.456,0.406],np.float32); STD=np.array([0.229,0.224,0.225],np.float32)

def grid(h,w,side=518):
    s=side/max(h,w); nh=max(1,round(h*s/14)); nw=max(1,round(w*s/14)); return nh,nw

@torch.no_grad()
def feats(gray_u8, nh, nw):
    im=cv2.resize(gray_u8,(nw*14,nh*14),interpolation=cv2.INTER_AREA).astype(np.float32)/255
    x=np.stack([im]*3,-1); x=(x-MEAN)/STD
    t=torch.from_numpy(x.transpose(2,0,1)[None])
    h=net(pixel_values=t).last_hidden_state[0,1:]       # tokens
    f=torch.nn.functional.normalize(h,dim=-1)
    return f  # (nh*nw, C)

def ref_bank(color_rgb):
    H,W=color_rgb.shape[:2]; nh,nw=grid(H,W)
    g=luma(color_rgb.astype(np.float32)).clip(0,255).astype(np.uint8)
    f=feats(g,nh,nw)
    small=cv2.resize(color_rgb,(nw*14,nh*14),interpolation=cv2.INTER_AREA).astype(np.float32)
    cb,cr=cbcr(small)
    cb=cb.reshape(nh,14,nw,14).mean((1,3)).reshape(-1); cr=cr.reshape(nh,14,nw,14).mean((1,3)).reshape(-1)
    return f, torch.from_numpy(np.stack([cb,cr],1).astype(np.float32))

def transfer(target_rgb, banks, k=8, temp=0.05):
    H,W=target_rgb.shape[:2]; nh,nw=grid(H,W)
    g=luma(target_rgb.astype(np.float32)).clip(0,255).astype(np.uint8)
    ft=feats(g,nh,nw)
    F=torch.cat([b[0] for b in banks]); C=torch.cat([b[1] for b in banks])
    sim=ft@F.T                                   # tokens x refs
    v,i=sim.topk(k,dim=1)
    w=torch.softmax(v/temp,dim=1)
    ch=(C[i]*w[...,None]).sum(1)                  # tokens x 2
    return ch.reshape(nh,nw,2).numpy(), g

def to_rgb(luma_img, cb, cr):
    y=luma_img
    R=y+1.402*cr; G=y-0.344136*cb-0.714136*cr; B=y+1.772*cb
    return np.stack([R,G,B],-1).clip(0,255).astype(np.uint8)

def upsample_regions(ch, g, mode='region'):
    H,W=g.shape; nh,nw=ch.shape[:2]
    cb=cv2.resize(ch[...,0],(W,H),interpolation=cv2.INTER_CUBIC); cr=cv2.resize(ch[...,1],(W,H),interpolation=cv2.INTER_CUBIC)
    if mode=='bilinear': return cb,cr
    line=(g<115).astype(np.uint8)
    n,lab,stats,_=cv2.connectedComponentsWithStats(1-line,connectivity=4)
    cbo=cb.copy(); cro=cr.copy()
    # region means (vectorised)
    idx=lab.reshape(-1); cnt=np.bincount(idx,minlength=n).astype(np.float64)
    mcb=np.bincount(idx,cb.reshape(-1),minlength=n)/np.maximum(cnt,1); mcr=np.bincount(idx,cr.reshape(-1),minlength=n)/np.maximum(cnt,1)
    big=cnt>=H*W*0.0004
    big[0]=False
    sel=big[lab]
    cbo[sel]=mcb[lab][sel]; cro[sel]=mcr[lab][sel]
    return cbo,cro

def colorize(target_rgb, banks, mode='region', strength=1.0):
    ch,g=transfer(target_rgb,banks)
    H,W=g.shape
    cb,cr=upsample_regions(ch,g,mode)
    y=luma(target_rgb.astype(np.float32))
    k=np.clip((y-60)/80,0,1)
    return to_rgb(y, cb*strength*k, cr*strength*k)

def grayify(rgb):
    y=luma(rgb.astype(np.float32)).clip(0,255).astype(np.uint8); return np.stack([y]*3,-1)

if __name__=='__main__':
    L=lambda n: np.asarray(Image.open(D+n+'.png').convert('RGB'))
    pairs=[('na_group','na_poster'),('na_poster','na_group'),('op_crew','op_event'),('op_event','op_crew')]
    from model_cover import model_color
    from ddcolor_run import ddcolor
    for tgt,ref in pairs:
        T=L(tgt); R=L(ref); G=grayify(T)
        t0=time.time(); bank=ref_bank(R); out_r=colorize(G,[bank],'region'); out_b=colorize(G,[bank],'bilinear'); dt=time.time()-t0
        m=model_color(G); d=ddcolor(G)
        print(f'{tgt:9s} ref={ref:9s} gray {delta(G,T):5.1f} mcv2 {delta(m,T):5.1f} ddcolor {delta(d,T):5.1f} exemplar-bilinear {delta(out_b,T):5.1f} exemplar-region {delta(out_r,T):5.1f}  ({dt:.1f}s)')
        Image.fromarray(out_r).save(O+f'ex_{tgt}_from_{ref}.png'); Image.fromarray(m).save(O+f'mc_{tgt}.png'); Image.fromarray(d).save(O+f'dd_{tgt}.png')
