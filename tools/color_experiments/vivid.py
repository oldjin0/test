import numpy as np, cv2, sys, time
from PIL import Image
sys.path.insert(0,'/tmp/claude-0/exp')
from tone_palette import luma, cbcr
import ddcolor_run as dd
D='/tmp/claude-0/exp/data/'; O='/tmp/claude-0/exp/out/'

def ab_from_dd(gray_u8, lift):
    """DDColor on the page with its whites lifted, chroma back as (cb,cr) at page size."""
    g=gray_u8.astype(np.float32)
    g2=(g*(1-lift)+0*lift) if False else (g*(1.0-lift))      # lift: how much darker the white becomes (0..)
    rgb=np.stack([g2]*3,-1).clip(0,255).astype(np.uint8)
    out=dd.ddcolor(rgb).astype(np.float32)
    # colors of the lifted image, relative to its own gray
    cb,cr=cbcr(out)
    return np.stack([cb,cr],-1)

def regions(g):
    line=(g<115).astype(np.uint8)
    n,lab,stats,_=cv2.connectedComponentsWithStats(1-line,connectivity=4)
    return n,lab,stats

def vivid(rgb, lift=0.0, gain=1.0, smooth='region', keep_paper=True):
    y=luma(rgb.astype(np.float32)); g=y.clip(0,255).astype(np.uint8); H,W=g.shape
    ch=ab_from_dd(g,lift)*gain
    n,lab,stats=regions(g)
    idx=lab.reshape(-1); cnt=np.bincount(idx,minlength=n).astype(np.float64)
    if smooth=='region':
        out=np.zeros_like(ch)
        for c in range(2):
            m=np.bincount(idx,ch[...,c].reshape(-1),minlength=n)/np.maximum(cnt,1)
            out[...,c]=m[lab]
        big=(cnt>=H*W*0.0004); big[0]=False
        out=out*big[lab][...,None]
        # tiny regions and line art: keep the blurred local chroma instead of nothing
        blur=cv2.GaussianBlur(ch,(0,0),max(3,W/200))
        out=np.where(big[lab][...,None],out,blur)
    else: out=ch
    if keep_paper:
        mean_g=np.bincount(idx,y.reshape(-1),minlength=n)/np.maximum(cnt,1)
        edge=set(np.unique(np.concatenate([lab[0,:],lab[-1,:],lab[:,0],lab[:,-1]])))
        paper=np.zeros(n,bool)
        for r in edge:
            if r>0 and mean_g[r]>230: paper[r]=True
        out=out*(~paper[lab])[...,None]
    k=np.clip((y-60)/80,0,1)
    cb=out[...,0]*k; cr=out[...,1]*k
    R=y+1.402*cr; G=y-0.344136*cb-0.714136*cr; B=y+1.772*cb
    return np.stack([R,G,B],-1).clip(0,255).astype(np.uint8)

if __name__=='__main__':
    L=lambda n: np.asarray(Image.open(D+n+'.png').convert('RGB'))
    for p in ['bw_n1621_R','bw_o11_L']:
        T=L(p)
        for lift in [0.0,0.12,0.25]:
            Image.fromarray(vivid(T,lift=lift,gain=1.6)).save(O+f'vv_{p}_{int(lift*100)}.png')
        print(p,'done')
