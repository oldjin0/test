import { S } from './state.js';
import { W, H, CHAPTERS, stageChap } from './data.js';
import { loadSave } from './save.js';
import { DT, step, updateFx, startRun, takeCard, endRun } from './game.js';
import { renderGame, renderTitle } from './render.js';
import { bindUi, goTitle, onBack, pauseGame, show } from './ui.js';
import { unlockAudio, suspendAudio, resumeAudio } from './audio.js';
import { initNative, initAds } from './native.js';

// 구형 WebView(Chrome 99 미만)에는 roundRect가 없다
if (!CanvasRenderingContext2D.prototype.roundRect) {
  CanvasRenderingContext2D.prototype.roundRect = function (x, y, w, h, r) {
    r = Math.max(0, Math.min(typeof r === 'number' ? r : 0, Math.abs(w) / 2, Math.abs(h) / 2));
    this.moveTo(x + r, y); this.arcTo(x + w, y, x + w, y + h, r); this.arcTo(x + w, y + h, x, y + h, r);
    this.arcTo(x, y + h, x, y, r); this.arcTo(x, y, x + w, y, r); this.closePath();
  };
}
const $ = (id) => document.getElementById(id);
const stage = $('stage'), cv = $('c'), ctx = cv.getContext('2d');

S.save = loadSave();
S.chapter = S.save.lastChapter;

/* ---------- 화면 크기 ---------- */
function resize() {
  const iw = window.innerWidth, ih = window.innerHeight;
  const w = Math.min(iw, ih * W / H), h = w * H / W;
  stage.style.width = w + 'px'; stage.style.height = h + 'px';
  stage.style.setProperty('--u', String(w / W));
  const dpr = Math.min(window.devicePixelRatio || 1, 3);
  cv.width = Math.round(w * dpr); cv.height = Math.round(h * dpr);
  ctx.setTransform(cv.width / W, 0, 0, cv.height / H, 0, 0);
}
window.addEventListener('resize', resize);
resize();

/* ---------- 입력 ---------- */
const keyName = (e) => (e.key.length === 1 ? e.key.toLowerCase() : e.key);
window.addEventListener('keydown', (e) => {
  if (e.target.tagName === 'INPUT') return;
  if (e.key === 'Escape') { onBack(); return; }
  S.keys[keyName(e)] = true;
});
window.addEventListener('keyup', (e) => { S.keys[keyName(e)] = false; });
window.addEventListener('contextmenu', (e) => e.preventDefault());

function toLogical(ev) {
  const r = stage.getBoundingClientRect();
  return { x: (ev.clientX - r.left) / r.width * W, y: (ev.clientY - r.top) / r.height * H };
}
stage.addEventListener('pointerdown', (ev) => {
  unlockAudio();
  if (S.scene !== 'play' || ev.target.closest('button,input')) return;
  const p = toLogical(ev), j = S.joy;
  j.active = true; j.id = ev.pointerId; j.ox = j.x = p.x; j.oy = j.y = p.y;
  try { stage.setPointerCapture(ev.pointerId); } catch (e) { /* ignore */ }
});
stage.addEventListener('pointermove', (ev) => {
  const j = S.joy;
  if (!j.active || ev.pointerId !== j.id) return;
  const p = toLogical(ev);
  j.x = p.x; j.y = p.y;
  const dx = j.x - j.ox, dy = j.y - j.oy, l = Math.hypot(dx, dy);
  if (l > 60) { j.ox += dx / l * (l - 60); j.oy += dy / l * (l - 60); } // 조이스틱이 손가락을 따라온다
});
const endJoy = (ev) => { if (ev.pointerId === S.joy.id) S.joy.active = false; };
stage.addEventListener('pointerup', endJoy);
stage.addEventListener('pointercancel', endJoy);

/* ---------- 루프 ---------- */
let last = 0, acc = 0;
function frame(ts) {
  const dt = Math.min(0.1, (ts - last) / 1000 || 0);
  last = ts;
  S.clock += dt;
  const G = S.G;
  if (S.scene === 'play' && G) {
    if (G.stop > 0) G.stop -= dt; // 치명타 순간의 짧은 멈춤
    else {
      acc += dt;
      let n = 0;
      while (acc >= DT && S.scene === 'play' && n < 8) { acc -= DT; step(); n++; }
      if (n >= 8) acc = 0;
    }
  } else {
    acc = 0;
    if (G && S.scene === 'ending') {
      G.endT += dt; updateFx(dt);
      G.hero.hit = Math.max(0, G.hero.hit - dt); G.hero.sp = Math.max(0, G.hero.sp - dt * 3);
    }
  }
  try {
    if (S.G) renderGame(ctx); else renderTitle(ctx);
  } catch (e) { console.error(e); }
  requestAnimationFrame(frame);
}

/* ---------- 시작 ---------- */
bindUi();
initAds();
initNative({
  onBack,
  onPause: () => { pauseGame(); suspendAudio(); },
  onResume: () => resumeAudio(),
});
goTitle();
$('loading').remove();
requestAnimationFrame(frame);

/* ---------- 테스트·밸런스 측정용 봇 ---------- */
function botMove() {
  const G = S.G, h = G.hero;
  let fx = 0, fy = 0;
  for (const e of G.enemies) {
    const dx = h.x - e.x, dy = h.y - e.y, d = Math.max(1, Math.hypot(dx, dy) - e.r);
    if (d < 120) { const k = (e.boss ? 3 : 1) / (d * d); fx += dx * k; fy += dy * k; }
  }
  for (const b of G.ebul) {
    const dx = h.x - b.x, dy = h.y - b.y, d = Math.max(1, Math.hypot(dx, dy));
    if (d < 70 && (b.vx * dx + b.vy * dy) > 0) { const k = 4 / (d * d); fx += dx * k; fy += dy * k; }
  }
  // 돌진 예고와 보스 착지 지점을 피한다 (사람처럼)
  for (const e of G.enemies) {
    if (e.type === 'boar' && (e.cs === 'wind' || e.cs === 'dash')) {
      const dx = h.x - e.x, dy = h.y - e.y, d = Math.hypot(dx, dy);
      if (d < 230) {
        const along = dx * e.cdx + dy * e.cdy, px = dx - along * e.cdx, py = dy - along * e.cdy, pd = Math.max(1, Math.hypot(px, py));
        if (along > 0 && pd < 40) { const k = 0.05 / pd; fx += (px || -e.cdy) * k; fy += (py || e.cdx) * k; }
      }
    }
    if (e.boss && e.js === 'air') {
      const dx = h.x - e.tx, dy = h.y - e.ty, d = Math.max(1, Math.hypot(dx, dy));
      if (d < 90) { fx += dx / d * 0.05; fy += dy / d * 0.05; }
    }
  }
  // 벽에서 멀어지고, 중앙으로 살짝 끌린다
  const wl = (d) => 1 / Math.max(6, d) ** 2;
  fx += wl(h.x - 14) * 0.6 - wl(346 - h.x) * 0.6;
  fy += wl(h.y - 108) * 0.6 - wl(606 - h.y) * 0.6;
  fx += (180 - h.x) * 0.000002; fy += (350 - h.y) * 0.000002;
  for (const c of G.coins) { const dx = c.x - h.x, dy = c.y - h.y, d = Math.max(8, Math.hypot(dx, dy)); if (d < 90) { fx += dx / d * 0.00003; fy += dy / d * 0.00003; } }
  const l = Math.hypot(fx, fy);
  const j = S.joy;
  j.active = l > 1e-5; j.id = -1; j.ox = 0; j.oy = 0;
  if (j.active) { j.x = fx / l * 40; j.y = fy / l * 40; }
}
window.__ed = {
  S, CHAPTERS, stageChap, startRun, step, takeCard, endRun, show, goTitle,
  autoPlay(maxTicks, pref) {
    let i = 0;
    for (; i < maxTicks && S.G && !S.G.ended; i++) {
      if (S.scene === 'pick') {
        const ch = S.G.choices;
        const c = (pref && pref.map((id) => ch.find((x) => x.id === id)).find(Boolean)) || ch[0];
        takeCard(c.id);
      }
      if (S.scene === 'revive') endRun(false); // 봇은 부활하지 않는다
      if (S.scene === 'play') { botMove(); step(); }
      else if (S.scene !== 'pick') break;
    }
    S.joy.active = false;
    return i;
  },
};
