"""Pipeline of the work order (cover palette -> denoise -> bubble lock -> 5-channel hints -> colorizer),
run with the real ONNX models. fill: also paint each hinted region with its hint chroma (the app's own hint fill)."""
import numpy as np, cv2, sys, time
import onnxruntime as ort
from PIL import Image
sys.path.insert(0,'/tmp/claude-0/exp')
from tone_palette import luma, cbcr
D='/tmp/claude-0/exp/data/'; O='/tmp/claude-0/exp/out/'
so=ort.SessionOptions(); so.log_severity_level=3
col=ort.InferenceSession('/tmp/onnx_out/colorizer_fp32.onnx',so,providers=['CPUExecutionProvider'])
dn=ort.InferenceSession('/tmp/onnx_out/denoiser.onnx',so,providers=['CPUExecutionProvider'])
IW,IH=448,640

def cover_palette(cover_rgb,k=5):
    a=cv2.resize(cover_rgb,(cover_rgb.shape[1]//3,cover_rgb.shape[0]//3),interpolation=cv2.INTER_AREA).astype(np.float32)
    y=luma(a); cb,cr=cbcr(a); ch=np.hypot(cb,cr)
    m=(ch>14)&(y>45)&(y<245)
    pts=np.stack([cb[m],cr[m],y[m]*0.4],1).astype(np.float32)
    crit=(cv2.TERM_CRITERIA_EPS+cv2.TERM_CRITERIA_MAX_ITER,40,0.5)
    _,lab,_=cv2.kmeans(pts,k,None,crit,4,cv2.KMEANS_PP_CENTERS)
    pal=[]
    for i in range(k):
        s=lab[:,0]==i
        if s.sum()<len(pts)*0.03: continue
        pal.append(dict(y=float(y[m][s].mean()),cb=float(cb[m][s].mean()),cr=float(cr[m][s].mean()),share=float(s.mean())))
    return pal

def rgb_of(y,cb,cr): return np.array([y+1.402*cr,y-0.344136*cb-0.714136*cr,y+1.772*cb]).clip(0,255)

def pipeline(page_rgb, pal, r=8, fill=0.0, bubble_holes=6, hint_gain=1.0, min_area=0.0003):
    H,W=page_rgb.shape[:2]; y=luma(page_rgb.astype(np.float32))
    s=min(IW/W,IH/H); pw,ph=round(W*s),round(H*s)
    small=cv2.resize(y.clip(0,255).astype(np.uint8),(pw,ph),interpolation=cv2.INTER_LINEAR).astype(np.float32)/255
    g=np.ones((IH,IW),np.float32); g[:ph,:pw]=small
    g=dn.run(None,{'input':g[None,None]})[0][0,0]; g[ph:,:]=1; g[:,pw:]=1
    # regions on the denoised page
    line=(g<0.45).astype(np.uint8); line[ph:,:]=1; line[:,pw:]=1           # outside the page counts as wall
    n,lab,stats,cent=cv2.connectedComponentsWithStats(1-line,connectivity=4)
    area=pw*ph
    # holes: small dark pieces per region (letters in bubbles)
    dn_,dl,dst,_=cv2.connectedComponentsWithStats(line,connectivity=8)
    holes=np.zeros(n)
    for j in range(1,dn_):
        a=dst[j,cv2.CC_STAT_AREA]
        if a<3 or a>area*0.0006: continue
        x,y0,w_,h_=dst[j,:4]
        xa,ya,xb,yb=max(0,x-3),max(0,y0-3),min(IW,x+w_+3),min(IH,y0+h_+3)
        ring=lab[ya:yb,xa:xb][(dl[ya:yb,xa:xb]!=j)&(line[ya:yb,xa:xb]==0)]
        if ring.size: holes[np.bincount(ring).argmax()]+=1
    edge=set(np.unique(np.concatenate([lab[0,:pw],lab[ph-1,:pw],lab[:ph,0],lab[:ph,pw-1]])))
    cnt=np.bincount(lab.reshape(-1),minlength=n); mean=np.bincount(lab.reshape(-1),g.reshape(-1),minlength=n)/np.maximum(cnt,1)
    locked=np.zeros(n,bool)   # bubbles and margins: white
    for i in range(1,n):
        if mean[i]>0.90 and (i in edge or holes[i]>=bubble_holes): locked[i]=True
    inp=np.zeros((1,5,IH,IW),np.float32); inp[0,0]=g
    hint_chroma=np.zeros((IH,IW,2),np.float32); hinted=np.zeros((IH,IW),bool)
    dt=cv2.distanceTransform((1-line).astype(np.uint8),cv2.DIST_L2,3)
    used=0
    for i in range(1,n):
        if locked[i] or cnt[i]<area*min_area or mean[i]>0.94 or mean[i]<0.12: continue
        m=lab==i
        yy,xx=np.unravel_index(np.argmax(np.where(m,dt,-1)),m.shape)
        G=mean[i]*255
        best=min(pal,key=lambda p: abs(p['y']-G)/40-0.5*np.log(p['share']+1e-3))
        rgb=rgb_of(G,best['cb']*hint_gain,best['cr']*hint_gain)
        yy0,yy1,xx0,xx1=max(0,yy-r),min(IH,yy+r+1),max(0,xx-r),min(IW,xx+r+1)
        Y,X=np.ogrid[yy0:yy1,xx0:xx1]; disc=((Y-yy)**2+(X-xx)**2<=r*r)
        for c in range(3): inp[0,1+c,yy0:yy1,xx0:xx1][disc]=rgb[c]/127.5-1
        inp[0,4,yy0:yy1,xx0:xx1][disc]=1
        hint_chroma[m]=[best['cb']*hint_gain,best['cr']*hint_gain]; hinted|=m; used+=1
    o=col.run(None,{'input':inp})[0][0][:,:ph,:pw]*255
    r_,g_,b_=o; cb=-0.168736*r_-0.331264*g_+0.5*b_; cr=0.5*r_-0.418688*g_-0.081312*b_
    ch=np.stack([cb,cr],-1)
    if fill>0:
        hc=hint_chroma[:ph,:pw]; hm=hinted[:ph,:pw][...,None]
        ch=np.where(hm,ch*(1-fill)+hc*fill,ch)
    lockmap=locked[lab][:ph,:pw]
    ch[lockmap]=0
    up=lambda a: cv2.resize(a,(W,H),interpolation=cv2.INTER_CUBIC)
    cbF=up(ch[...,0]); crF=up(ch[...,1]); lk=cv2.resize(lockmap.astype(np.float32),(W,H),interpolation=cv2.INTER_LINEAR)
    k=np.clip((y-60)/80,0,1)*(1-lk)
    out=np.stack([y+1.402*crF*k,y-0.344136*cbF*k-0.714136*crF*k,y+1.772*cbF*k],-1).clip(0,255).astype(np.uint8)
    return out,used

if __name__=='__main__':
    L=lambda n: np.asarray(Image.open(D+n+'.png').convert('RGB'))
    sets={'naruto':['bw_n1621_R','bw_n1621_L','bw_n4649_L','bw_n4649_R'],
          'onepiece':['bw_o11_L','bw_o11_R','bw_o11765_L','bw_o11765_R','bw_o11767_L','bw_o11767_R'],
          'anyong':['bw_a45_L','bw_a45_R']}
    for name,pages in sets.items():
        pal=cover_palette(L('cover_'+name))
        print(name,[ (round(p['y']),round(p['cb']),round(p['cr']),round(p['share'],2)) for p in pal])
        for p in pages:
            t=time.time()
            a,u=pipeline(L(p),pal,r=8,fill=0.0); Image.fromarray(a).save(O+f'pl_{p}_model.png')
            b,_=pipeline(L(p),pal,r=8,fill=0.7); Image.fromarray(b).save(O+f'pl_{p}_fill.png')
            print(' ',p,'hints',u,'%.1fs'%(time.time()-t))
