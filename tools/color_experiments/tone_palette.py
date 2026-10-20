import sys, numpy as np, cv2
from PIL import Image
D='/tmp/claude-0/exp/data/'; O='/tmp/claude-0/exp/out/'

def luma(a): return (0.299*a[...,0]+0.587*a[...,1]+0.114*a[...,2])
def cbcr(a):
    r,g,b=a[...,0],a[...,1],a[...,2]
    return (-0.168736*r-0.331264*g+0.5*b, 0.5*r-0.418688*g-0.081312*b)

def palette(cover, k=12):
    """Colors of the cover: (gray, cb, cr, share), saturated ones only."""
    a=np.asarray(Image.fromarray(cover).resize((cover.shape[1]//3,cover.shape[0]//3),Image.BILINEAR)).astype(np.float32)
    y=luma(a); cb,cr=cbcr(a); ch=np.hypot(cb,cr)
    m=(y>45)&(ch>10)               # not ink, not paper/gray
    pts=np.stack([cb[m],cr[m],y[m]*0.35],1).astype(np.float32)
    if len(pts)<200: return []
    crit=(cv2.TERM_CRITERIA_EPS+cv2.TERM_CRITERIA_MAX_ITER,30,0.5)
    _,lab,cen=cv2.kmeans(pts,k,None,crit,3,cv2.KMEANS_PP_CENTERS)
    out=[]
    for i in range(k):
        sel=lab[:,0]==i
        if sel.sum()<len(pts)*0.02: continue
        out.append((float(y[m][sel].mean()),float(cb[m][sel].mean()),float(cr[m][sel].mean()),float(sel.mean())))
    return out

def regions(gray, min_frac=0.0004):
    line=(gray<115).astype(np.uint8)
    n,lab,stats,_=cv2.connectedComponentsWithStats(1-line,connectivity=4)
    return n,lab,stats

def colorize(gray_rgb, pal, strength=1.0):
    a=gray_rgb.astype(np.float32); y=luma(a); H,W=y.shape
    n,lab,stats=regions(y)
    cb=np.zeros_like(y); cr=np.zeros_like(y)
    area=H*W
    for i in range(1,n):
        ar=stats[i,cv2.CC_STAT_AREA]
        if ar<area*0.0004: continue
        m=lab==i
        g=float(y[m].mean())
        if g>236: continue                 # white: left alone
        best=None;bs=-1e9
        for (pg,pcb,pcr,sh) in pal:
            s=-abs(pg-g)/30.0+0.6*np.log(sh+1e-3)
            if s>bs: bs=s;best=(pcb,pcr)
        if best is None: continue
        cb[m]=best[0]*strength; cr[m]=best[1]*strength
    k=np.clip((y-60)/80,0,1)[...,None]       # ink stays gray
    R=y+1.402*cr*k[...,0]; G=y-0.344136*cb*k[...,0]-0.714136*cr*k[...,0]; B=y+1.772*cb*k[...,0]
    return np.stack([R,G,B],-1).clip(0,255).astype(np.uint8)

def delta(a,b):
    ya,yb=luma(a.astype(np.float32)),luma(b.astype(np.float32))
    ca=np.stack(cbcr(a.astype(np.float32)),-1); cb_=np.stack(cbcr(b.astype(np.float32)),-1)
    return float(np.sqrt(((ca-cb_)**2).sum(-1)).mean())

if __name__=='__main__':
    for name in ['naruto','onepiece','anyong']:
        real=np.asarray(Image.open(D+f'cover_{name}.png').convert('RGB'))
        g=luma(real.astype(np.float32)); gray=np.stack([g,g,g],-1)
        pal=palette(real)
        out=colorize(gray,pal)
        Image.fromarray(out).save(O+f'self_{name}.png')
        base=np.stack([g,g,g],-1)
        print(name,'palette',len(pal),'chroma err gray-only %.1f  palette-regions %.1f'%(delta(base,real),delta(out,real)))
