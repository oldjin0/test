import numpy as np, torch, cv2, sys, time
from PIL import Image
sys.path.insert(0,'/tmp/claude-0/exp')
from tone_palette import luma, cbcr, delta
import exemplar as ex
from model_cover import model_color
D='/tmp/claude-0/exp/data/'; O='/tmp/claude-0/exp/out/'

def ref_bank2(color_rgb, side=518):
    """Features of the gray reference; each token's color from its non-line pixels only."""
    H,W=color_rgb.shape[:2]; nh,nw=ex.grid(H,W,side)
    g=luma(color_rgb.astype(np.float32)).clip(0,255).astype(np.uint8)
    f=ex.feats(g,nh,nw)
    small=cv2.resize(color_rgb,(nw*14,nh*14),interpolation=cv2.INTER_AREA).astype(np.float32)
    y=luma(small); cb,cr=cbcr(small)
    w=np.clip((y-70)/50,0,1)                       # ink does not count
    def pool(a): return a.reshape(nh,14,nw,14).sum((1,3)).reshape(-1)
    ws=pool(w); cbm=pool(cb*w)/np.maximum(ws,1e-3); crm=pool(cr*w)/np.maximum(ws,1e-3)
    ink=pool((y<70).astype(np.float32))/196.0
    keep=(ws>196*0.25)                              # mostly ink: not a color reference
    C=torch.from_numpy(np.stack([cbm,crm],1).astype(np.float32))
    keep_t=torch.from_numpy(keep)
    return f[keep_t], C[keep_t]

def token_chroma(target_gray_u8, banks, k=6, temp=0.03, side=518):
    H,W=target_gray_u8.shape; nh,nw=ex.grid(H,W,side)
    ft=ex.feats(target_gray_u8,nh,nw)
    F=torch.cat([b[0] for b in banks]); C=torch.cat([b[1] for b in banks])
    sim=ft@F.T; v,i=sim.topk(k,dim=1); w=torch.softmax(v/temp,dim=1)
    col=C[i]; m=(col*w[...,None]).sum(1)
    var=(((col-m[:,None])**2).sum(-1)*w).sum(1)
    conf=torch.clamp((v[:,0]-0.30)/0.35,0,1)*torch.exp(-var/(2*22.0**2))
    return m.reshape(nh,nw,2).numpy(), conf.reshape(nh,nw).numpy()

def colorize2(target_rgb, banks, base_rgb=None, gain=1.5, cmin=0.25, side=518):
    y=luma(target_rgb.astype(np.float32)); g=y.clip(0,255).astype(np.uint8); H,W=g.shape
    ch,conf=token_chroma(g,banks,side=side)
    up=lambda a: cv2.resize(a,(W,H),interpolation=cv2.INTER_CUBIC)
    Ec=np.stack([up(ch[...,0]),up(ch[...,1])],-1); Cf=cv2.resize(conf,(W,H),interpolation=cv2.INTER_LINEAR)
    line=(g<115).astype(np.uint8)
    n,lab,stats,_=cv2.connectedComponentsWithStats(1-line,connectivity=4)
    idx=lab.reshape(-1); cnt=np.bincount(idx,minlength=n).astype(np.float64)
    wsum=np.bincount(idx,Cf.reshape(-1),minlength=n)
    Er=np.stack([np.bincount(idx,(Ec[...,c]*Cf).reshape(-1),minlength=n)/np.maximum(wsum,1e-6) for c in range(2)],1)
    Cr=wsum/np.maximum(cnt,1)
    big=cnt>=H*W*0.0004; big[0]=False
    if base_rgb is not None:
        bcb,bcr=cbcr(base_rgb.astype(np.float32)); Bc=np.stack([bcb,bcr],-1)
    else: Bc=np.zeros_like(Ec)
    mean_g=np.bincount(idx,y.reshape(-1),minlength=n)/np.maximum(cnt,1)
    edge=set(np.unique(np.concatenate([lab[0,:],lab[-1,:],lab[:,0],lab[:,-1]])))
    paper=np.zeros(n,bool)
    for r in edge:
        if r>0 and mean_g[r]>230: paper[r]=True
    # region confidence: gate then ramp
    # speech bubbles: bright, with many small dark pieces (letters) inside: stay white
    dn,dlab,dst,dcen=cv2.connectedComponentsWithStats(line,connectivity=8)
    holes=np.zeros(n)
    amax=H*W*0.0006
    for j in range(1,dn):
        a=dst[j,cv2.CC_STAT_AREA]
        if a<4 or a>amax: continue
        x,y0,w_,h_=dst[j,0],dst[j,1],dst[j,2],dst[j,3]
        xa,ya,xb,yb=max(0,x-3),max(0,y0-3),min(W,x+w_+3),min(H,y0+h_+3)
        ring=lab[ya:yb,xa:xb][(dlab[ya:yb,xa:xb]!=j)&(line[ya:yb,xa:xb]==0)]
        if ring.size: holes[np.bincount(ring).argmax()]+=1
    bubble=(holes>=8)&(mean_g>215)
    wr=np.clip((Cr-cmin)/(0.6-cmin),0,1)*big*(~paper)*(~bubble)
    paper=paper|bubble
    out=np.zeros((H,W,2),np.float32)
    out=(Er*gain)[lab]*wr[lab][...,None]+Bc*(1-wr[lab][...,None])
    out=out*(~paper[lab])[...,None]
    k=np.clip((y-60)/80,0,1)
    cb=out[...,0]*k; cr=out[...,1]*k
    R=y+1.402*cr; G=y-0.344136*cb-0.714136*cr; B=y+1.772*cb
    return np.stack([R,G,B],-1).clip(0,255).astype(np.uint8)

if __name__=='__main__':
    L=lambda n: np.asarray(Image.open(D+n+'.png').convert('RGB'))
    pairs=[('na_group','na_poster'),('na_poster','na_group'),('op_crew','op_event'),('op_event','op_crew')]
    for tgt,ref in pairs:
        T=L(tgt); R=L(ref); G=ex.grayify(T); bank=ref_bank2(R); base=model_color(G)
        res={}
        for gain in (1.0,1.5,2.0):
            res[gain]=colorize2(G,[bank],base,gain=gain)
        old=ex.colorize(G,[ex.ref_bank(R)],'region')
        print(f'{tgt:9s} gray {delta(G,T):5.1f} mcv2 {delta(base,T):5.1f} old-exemplar {delta(old,T):5.1f} new g1.0 {delta(res[1.0],T):5.1f} g1.5 {delta(res[1.5],T):5.1f} g2.0 {delta(res[2.0],T):5.1f}')
        Image.fromarray(res[1.5]).save(O+f'e2_{tgt}.png')
