import numpy as np, torch, cv2, sys, time
from PIL import Image
sys.path.insert(0,'/tmp/claude-0/exp')
from tone_palette import luma, cbcr, delta
import exemplar as ex
from ddcolor_run import ddcolor
from model_cover import model_color
D='/tmp/claude-0/exp/data/'; O='/tmp/claude-0/exp/out/'

def regions_of(g):
    line=(g<115).astype(np.uint8)
    n,lab,stats,_=cv2.connectedComponentsWithStats(1-line,connectivity=4)
    return n,lab,stats,line

def region_mean(ch_hw2, lab, n):
    H,W=lab.shape; idx=lab.reshape(-1); cnt=np.bincount(idx,minlength=n).astype(np.float64)
    out=np.zeros((n,2),np.float64)
    for c in range(2):
        out[:,c]=np.bincount(idx,ch_hw2[...,c].reshape(-1),minlength=n)/np.maximum(cnt,1)
    return out,cnt

def token_conf(target_rgb, banks, k=8, temp=0.05):
    """chroma per token, confidence per token (similarity and agreement)"""
    H,W=target_rgb.shape[:2]; nh,nw=ex.grid(H,W)
    g=luma(target_rgb.astype(np.float32)).clip(0,255).astype(np.uint8)
    ft=ex.feats(g,nh,nw)
    F=torch.cat([b[0] for b in banks]); C=torch.cat([b[1] for b in banks])
    sim=ft@F.T; v,i=sim.topk(k,dim=1); w=torch.softmax(v/temp,dim=1)
    col=C[i]                                         # t,k,2
    m=(col*w[...,None]).sum(1)
    var=((col-m[:,None])**2).sum(-1); var=(var*w).sum(1)          # agreement
    s1=v[:,0]
    conf=torch.clamp((s1-0.35)/0.35,0,1)*torch.exp(-var/(2*18.0**2))
    return m.reshape(nh,nw,2).numpy(), conf.reshape(nh,nw).numpy(), g

def hybrid(target_rgb, banks, use_dd=True, w_max=0.9, boost=1.0, dd_gain=1.0):
    H,W=target_rgb.shape[:2]
    y=luma(target_rgb.astype(np.float32))
    g=y.clip(0,255).astype(np.uint8)
    n,lab,stats,line=regions_of(g)
    # exemplar chroma and confidence, up to full size
    ch,conf,_=token_conf(target_rgb,banks)
    Ec=np.stack([cv2.resize(ch[...,0],(W,H),interpolation=cv2.INTER_CUBIC),cv2.resize(ch[...,1],(W,H),interpolation=cv2.INTER_CUBIC)],-1)
    Cf=cv2.resize(conf,(W,H),interpolation=cv2.INTER_LINEAR)
    # DDColor chroma
    if use_dd:
        dd=ddcolor(np.stack([g]*3,-1)); dcb,dcr=cbcr(dd.astype(np.float32)); Dc=np.stack([dcb,dcr],-1)*dd_gain
    else:
        Dc=np.zeros_like(Ec)
    Er,cnt=region_mean(Ec,lab,n); Dr,_=region_mean(Dc,lab,n)
    # region confidence = mean token confidence in the region
    idx=lab.reshape(-1); Cr=np.bincount(idx,Cf.reshape(-1),minlength=n)/np.maximum(cnt,1)
    big=(cnt>=H*W*0.0004); big[0]=False
    wr=np.clip(Cr,0,1)*w_max
    mix=Er*wr[:,None]+Dr*(1-wr[:,None])
    # text bubbles and paper margins stay neutral: many small dark pieces inside, or bright and touching the page edge
    holes=np.zeros(n); 
    dn,dlab,dstats,_=cv2.connectedComponentsWithStats(line,connectivity=4)
    small=[j for j in range(1,dn) if 4<=dstats[j,cv2.CC_STAT_AREA]<=H*W*0.0006]
    if small:
        # the region around each small dark piece
        cent=np.round(_[small]).astype(int) if False else None
    mean_g=np.bincount(idx,y.reshape(-1),minlength=n)/np.maximum(cnt,1)
    # edge-touching bright regions are paper
    edge_ids=set(np.unique(np.concatenate([lab[0,:],lab[-1,:],lab[:,0],lab[:,-1]])))
    chroma=np.zeros((H,W,2),np.float32)
    keep=big.copy()
    for r in edge_ids:
        if r>0 and mean_g[r]>225: keep[r]=False
    chroma=mix[lab].astype(np.float32)*keep[lab][...,None]
    k=np.clip((y-60)/80,0,1)
    cb=chroma[...,0]*k*boost; cr=chroma[...,1]*k*boost
    R=y+1.402*cr; G=y-0.344136*cb-0.714136*cr; B=y+1.772*cb
    return np.stack([R,G,B],-1).clip(0,255).astype(np.uint8)

if __name__=='__main__':
    L=lambda n: np.asarray(Image.open(D+n+'.png').convert('RGB'))
    pairs=[('na_group','na_poster'),('na_poster','na_group'),('op_crew','op_event'),('op_event','op_crew')]
    for tgt,ref in pairs:
        T=L(tgt); R=L(ref); G=ex.grayify(T); bank=ex.ref_bank(R)
        e=ex.colorize(G,[bank],'region'); h=hybrid(G,[bank]); h2=hybrid(G,[bank],boost=1.4)
        dd_only=hybrid(G,[bank],w_max=0.0)           # region-smoothed DDColor
        d=ddcolor(G)
        print(f'{tgt:9s} ref={ref:9s} gray {delta(G,T):5.1f} ddcolor {delta(d,T):5.1f} dd-regions {delta(dd_only,T):5.1f} exemplar {delta(e,T):5.1f} hybrid {delta(h,T):5.1f} hybrid*1.4 {delta(h2,T):5.1f}')
        Image.fromarray(h2).save(O+f'hy_{tgt}.png'); Image.fromarray(dd_only).save(O+f'ddr_{tgt}.png')
