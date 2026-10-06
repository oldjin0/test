import { S } from './state.js';
import { W, H, ARENA, PICK_EVERY, CHAPTERS, BOSSES, CARD_BY_ID, CLASSES, stageChap } from './data.js';
import { clamp, mulberry32 } from './util.js';

const OL = '#3a2540';

/* ---------- 이미지 에셋 (있으면 사용, 없으면 도형) ---------- */
export const SPR = {};
// 이름.png = 정면, 이름_b.png = 뒷모습, 이름_s.png = 옆모습(오른쪽을 봄)
const PLAYER_ART = ['hero', 'archer', 'wizard']; // 8방향(앞·비스듬한 앞·옆·비스듬한 뒤·뒤 + 좌우 반전)
['hero', 'archer', 'wizard', 'slime', 'bat', 'brute', 'mage', 'boar', 'blob', ...Object.keys(BOSSES)].forEach((n) => {
  for (const sfx of PLAYER_ART.includes(n) ? ['', '_b', '_s', '_fd', '_bd'] : ['', '_b', '_s']) {
    const im = new Image();
    im.onload = () => { SPR[n + sfx] = im; };
    im.onerror = () => {};
    im.src = 'assets/' + n + sfx + '.png';
  }
});

// UI 아이콘 (카드·HUD). 없으면 이모지로 대신한다.
export const ICO = {};
[...Object.keys(CARD_BY_ID), 'ui_coin', 'ui_heart', 'ui_kills'].forEach((n) => {
  const im = new Image();
  im.onload = () => { ICO[n] = im; };
  im.src = `assets/icons/${n}.png`;
});

/* ---------- 컷아웃 애니메이션 ----------
   생성 이미지는 한 장짜리라서, 그림이 있는 영역(bbox)을 머리·몸통·다리로 잘라 따로 움직인다.
   다리는 번갈아 딛고, 몸은 튀고, 머리는 한 박자 늦게 따라오며, 맞으면 흰색/빨간색 실루엣이 번쩍인다. */
function prep(im) {
  if (im._bb) return im._bb;
  const w = im.naturalWidth, h = im.naturalHeight, cv = document.createElement('canvas');
  cv.width = w; cv.height = h;
  const g = cv.getContext('2d'); g.drawImage(im, 0, 0);
  let bb = { x0: 0, y0: 0, x1: w, y1: h };
  try {
    const d = g.getImageData(0, 0, w, h).data;
    let x0 = w, y0 = h, x1 = 0, y1 = 0;
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) if (d[(y * w + x) * 4 + 3] > 60) { if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; }
    if (x1 > x0) bb = { x0, y0, x1: x1 + 1, y1: y1 + 1 };
  } catch (e) { /* 읽을 수 없으면 이미지 전체 */ }
  const tint = (col) => {
    const t = document.createElement('canvas'); t.width = w; t.height = h;
    const q = t.getContext('2d'); q.drawImage(im, 0, 0); q.globalCompositeOperation = 'source-atop'; q.fillStyle = col; q.fillRect(0, 0, w, h);
    return t;
  };
  im._white = tint('#ffffff'); im._red = tint('#ff2a4a');
  return (im._bb = bb);
}
// 발밑이 원점, 그림 높이가 hgt. P: { legs, view, ph(걸음 위상), sp(0~1), bob, headBob, headRot, wings(날개 각도), white, red }
function puppet(c, im, hgt, P) {
  const bb = prep(im), bw = bb.x1 - bb.x0, bh = bb.y1 - bb.y0, k = hgt / bh, dw = bw * k, X = -dw / 2, Y = -hgt;
  const draw = (src) => {
    const part = (a, b, xa, xb, dx, dy, rot, px, py) => {
      const sx = bb.x0 + bw * xa, sy = bb.y0 + bh * a, sw = bw * (xb - xa), sh = bh * (b - a);
      if (rot) { c.save(); c.translate(px, py); c.rotate(rot); c.translate(-px, -py); }
      c.drawImage(src, sx, sy, sw, sh, X + dw * xa + dx, Y + hgt * a + dy, sw * k, sh * k);
      if (rot) c.restore();
    };
    if (P.wings) { // 박쥐: 좌우 반쪽을 가운데를 축으로 펄럭인다
      const py = Y + hgt * 0.45;
      part(0, 1, 0, 0.52, 0, 0, -P.wings, 0, py);
      part(0, 1, 0.48, 1, 0, 0, P.wings, 0, py);
      return;
    }
    if (!P.legs) { part(0, 1, 0, 1, 0, 0); return; }
    const L = 0.8, N = 0.52, s = Math.sin(P.ph || 0), sp = P.sp || 0, lift = hgt * 0.1 * sp, bob = P.bob || 0;
    if (P.view === 's') { // 옆모습: 앞뒤로 내딛는다
      const st = s * sp * dw * 0.13;
      part(L, 1, 0, 0.5, -st, -Math.max(0, -s) * lift);
      part(L, 1, 0.5, 1, st, -Math.max(0, s) * lift);
    } else { // 앞·뒷모습: 번갈아 든다
      part(L, 1, 0, 0.5, 0, -Math.max(0, s) * lift);
      part(L, 1, 0.5, 1, 0, -Math.max(0, -s) * lift);
    }
    part(N - 0.03, L + 0.03, 0, 1, 0, bob);
    part(0, N, 0, 1, 0, bob + (P.headBob || 0), P.headRot || 0, 0, Y + hgt * N + bob);
  };
  draw(im);
  const a0 = c.globalAlpha;
  if (P.white > 0) { c.globalAlpha = a0 * Math.min(1, P.white); draw(im._white); }
  if (P.red > 0) { c.globalAlpha = a0 * Math.min(1, P.red); draw(im._red); }
  c.globalAlpha = a0;
}
// 이동 거리로 걸음 위상을 쌓는다 (프레임당 한 번)
function stride(o) {
  const d = Math.hypot(o._dx || 0, o._dy || 0);
  o._sp = (o._sp || 0) + (Math.min(1, d / 1.6) - (o._sp || 0)) * 0.2;
  o._ph = (o._ph || 0) + d * 0.2;
}

// 움직이는 방향으로 보는 방향을 정한다: f 앞, fd 비스듬한 앞, s 옆, bd 비스듬한 뒤, b 뒤 (왼쪽은 좌우 반전). 멈추면 마지막 방향을 유지한다.
// 속도 방향을 부드럽게 걸러서 경계 근처에서 깜빡이지 않게 하고, 현재 방향에서 벗어날 때는 더 큰 각도를 요구한다(히스테리시스).
function viewOf(o) {
  const dx = o.x - (o._px ?? o.x), dy = o.y - (o._py ?? o.y);
  o._px = o.x; o._py = o.y; o._dx = dx; o._dy = dy;
  o._sx = (o._sx || 0) * 0.78 + dx * 0.22; o._sy = (o._sy || 0) * 0.78 + dy * 0.22;
  if (o._sx * o._sx + o._sy * o._sy > 0.02) {
    const ax = Math.abs(o._sx), ay = Math.abs(o._sy), cur = o._v;
    const kv = cur === 'f' || cur === 'b' ? 2.0 : 2.8, ks = cur === 's' ? 2.0 : 2.8; // 세로/가로로 기울었다고 보는 비율
    let v;
    if (ay > ax * kv) v = o._sy > 0 ? 'f' : 'b';
    else if (ax > ay * ks) v = 's';
    else v = o._sy > 0 ? 'fd' : 'bd';
    o._v = v;
  }
  return o._v || 'f';
}
const ROBED = ['wizard', 'archer'];
// 방향에 맞는 이미지. 비스듬한 그림이 없으면 가까운 그림(옆/뒤)으로 대신한다
function pick(c, o, n) {
  const v = o._v || 'f';
  return SPR[n + (v === 'f' ? '' : '_' + v)] || (v === 'fd' ? SPR[n + '_s'] : v === 'bd' ? SPR[n + '_b'] : null) || SPR[n];
}
// 좌우 반전은 순간이동 대신 몸이 얇아졌다 돌아서듯 부드럽게 바꾼다. 앞/뒷모습 이미지를 쓸 때는 반전하지 않는다. 프레임당 한 번만 부른다.
function flipX(o, name) {
  o._fx = (o._fx ?? o.face) + (o.face - (o._fx ?? o.face)) * 0.3;
  const v = o._v, dirImg = name && SPR[name] && (v === 'f' || v === 'b') && SPR[name + (v === 'f' ? '' : '_b')];
  return dirImg ? 1 : o._fx;
}
const easeBack = (k) => 1 + 2.4 * Math.pow(k - 1, 3) + 1.4 * Math.pow(k - 1, 2);

function ell(c, x, y, rx, ry) { c.beginPath(); c.ellipse(x, y, Math.max(0.1, rx), Math.max(0.1, ry), 0, 0, 6.2832); }
function fs(c, fill, lw) { c.fillStyle = fill; c.fill(); c.lineWidth = lw || 1.6; c.strokeStyle = OL; c.stroke(); }
function rr(c, x, y, w, h, r) { c.beginPath(); c.roundRect(x, y, w, h, r); }

/* ---------- 배경 ---------- */
// 챕터마다 투기장 전체를 그린 한 장짜리 그림(assets/bg/arenaN.jpg)을 월드 크기로 늘려 쓴다. 없거나 로딩 중이면 코드로 그린 타일 배경.
const BGI = CHAPTERS.map((_, i) => {
  const im = new Image();
  im.src = `assets/bg/arena${i}.jpg`;
  return im;
});
const BGS = 1.5; // 월드 배경 캔버스의 해상도 배율
const bgCache = {}, procCache = {};
function newCanvas() {
  const cv = document.createElement('canvas'); cv.width = Math.round(ARENA.w * BGS); cv.height = Math.round(ARENA.h * BGS);
  const b = cv.getContext('2d'); b.scale(BGS, BGS);
  return [cv, b];
}
function paintBase(b, ch) {
  const cp = CHAPTERS[ch], rnd = mulberry32(ch * 99 + 1), T = 37;
  b.fillStyle = cp.wall; b.fillRect(0, 0, ARENA.w, ARENA.h);
  for (let y = 0; y < ARENA.h; y += T) for (let x = 0; x < ARENA.w; x += T) {
    b.fillStyle = ((x + y) / T) % 2 ? cp.floor[0] : cp.floor[1];
    b.fillRect(x, y, Math.min(T, ARENA.w - x), Math.min(T, ARENA.h - y));
  }
  for (let i = 0; i < 140; i++) { b.fillStyle = 'rgba(0,0,0,.12)'; ell(b, rnd() * ARENA.w, rnd() * ARENA.h, 4 + rnd() * 9, 2 + rnd() * 5); b.fill(); }
}
// 월드 가장자리는 어둡게 눌러서 "벽이 있다"는 것을 알 수 있게 한다
function paintEdge(b, ch) {
  const cp = CHAPTERS[ch], E = 46, w = ARENA.w, h = ARENA.h;
  for (const [x0, y0, x1, y1, rx, ry, rw, rh] of [[0, 0, E, 0, 0, 0, E, h], [w, 0, w - E, 0, w - E, 0, E, h], [0, 0, 0, E, 0, 0, w, E], [0, h, 0, h - E, 0, h - E, w, E]]) {
    const g = b.createLinearGradient(x0, y0, x1, y1); g.addColorStop(0, 'rgba(6,3,12,.85)'); g.addColorStop(1, 'rgba(6,3,12,0)');
    b.fillStyle = g; b.fillRect(rx, ry, rw, rh);
  }
  b.strokeStyle = cp.accent + '66'; b.lineWidth = 2; b.strokeRect(1, 1, w - 2, h - 2);
}
function procBg(ch) {
  if (procCache[ch]) return procCache[ch];
  const [cv, b] = newCanvas(); paintBase(b, ch); paintEdge(b, ch);
  return (procCache[ch] = cv);
}
function chapterBg(ch) {
  if (bgCache[ch]) return bgCache[ch];
  const im = BGI[ch];
  if (!im.complete || !im.naturalWidth) return procBg(ch);
  const [cv, b] = newCanvas();
  const k = Math.max(ARENA.w / im.naturalWidth, ARENA.h / im.naturalHeight), sw = ARENA.w / k, sh = ARENA.h / k;
  b.drawImage(im, (im.naturalWidth - sw) / 2, (im.naturalHeight - sh) / 2, sw, sh, 0, 0, ARENA.w, ARENA.h);
  paintEdge(b, ch);
  return (bgCache[ch] = cv);
}
// 카메라가 보는 부분만 화면에 그린다
function drawBgView(c, ch, cam) {
  c.drawImage(chapterBg(ch), cam.x * BGS, cam.y * BGS, W * BGS, H * BGS, 0, 0, W, H);
}
// 용암·그림자처럼 빛나는 무늬가 있는 챕터는 그림의 밝은 부분이 천천히 숨 쉬듯 빛난다
const GLOW = [0.05, 0.06, 0.16, 0.07, 0.12, 0.08];
function drawGlow(c, ch, cam) {
  const im = BGI[ch];
  if (!im.complete || !im.naturalWidth) return;
  const a = GLOW[ch] * (0.5 + 0.5 * Math.sin(S.clock * 1.6)) + GLOW[ch] * 0.3 * Math.sin(S.clock * 5.3);
  if (a <= 0) return;
  const k = Math.max(ARENA.w / im.naturalWidth, ARENA.h / im.naturalHeight), ox = (im.naturalWidth * k - ARENA.w) / 2, oy = (im.naturalHeight * k - ARENA.h) / 2;
  c.save(); c.globalCompositeOperation = 'lighter'; c.globalAlpha = a;
  c.drawImage(im, (cam.x + ox) / k, (cam.y + oy) / k, W / k, H / k, 0, 0, W, H);
  c.restore();
}
// 화면 고정 효과: 위쪽 HUD 자리를 어둡게, 가장자리 비네팅
let fxCv = null;
function drawScreenFx(c) {
  if (!fxCv) {
    fxCv = document.createElement('canvas'); fxCv.width = W * 2; fxCv.height = H * 2;
    const b = fxCv.getContext('2d'); b.scale(2, 2);
    const top = b.createLinearGradient(0, 0, 0, 110); top.addColorStop(0, 'rgba(8,4,16,.78)'); top.addColorStop(1, 'rgba(8,4,16,0)');
    b.fillStyle = top; b.fillRect(0, 0, W, 110);
    const g = b.createRadialGradient(W / 2, H * 0.55, H * 0.28, W / 2, H * 0.55, H * 0.78);
    g.addColorStop(0, 'rgba(0,0,0,0)'); g.addColorStop(1, 'rgba(0,0,0,.45)');
    b.fillStyle = g; b.fillRect(0, 0, W, H);
  }
  c.drawImage(fxCv, 0, 0, W, H);
}
// 화면 밖의 보스·원수는 가장자리 화살표로 알려 준다
function drawOffscreenArrows(c, G) {
  const cam = G.cam, t = S.clock;
  for (const e of G.enemies) {
    if (e.dead || !(e.boss || e.nem)) continue;
    const sx = e.x - cam.x, sy = e.y - cam.y;
    if (sx > -6 && sx < W + 6 && sy > 40 && sy < H + 6) continue;
    const dx = sx - W / 2, dy = sy - H / 2, k = Math.min((W / 2 - 24) / Math.abs(dx || 1e-3), (H / 2 - 70) / Math.abs(dy || 1e-3));
    const ang = Math.atan2(dy, dx), pul = 1 + Math.sin(t * 8) * 0.12, col = e.nem ? '#ff4d6d' : e.final ? '#ff5d73' : '#ffb15c';
    c.save(); c.translate(W / 2 + dx * k, H / 2 + dy * k); c.rotate(ang); c.scale(pul, pul);
    c.fillStyle = 'rgba(20,6,20,.85)'; c.beginPath(); c.moveTo(15, 0); c.lineTo(-8, -11); c.lineTo(-3, 0); c.lineTo(-8, 11); c.closePath(); c.fill();
    c.fillStyle = col; c.beginPath(); c.moveTo(12, 0); c.lineTo(-6, -8); c.lineTo(-2, 0); c.lineTo(-6, 8); c.closePath(); c.fill();
    c.restore();
  }
}

/* ---------- 살아 있는 배경: 챕터마다 다른 입자와 흐르는 안개 ---------- */
const AMB = CHAPTERS.map((_, ch) => { const r = mulberry32(ch * 31 + 7); return Array.from({ length: 34 }, () => ({ x: r() * W, y: r() * H, sp: 0.5 + r(), amp: 8 + r() * 22, ph: r() * 6.28, sz: 1 + r() * 1.8 })); });
const AMB_COL = ['#d8ff7a', '#c9a0ff', '#ffa040', '#eaf8ff', '#ff4d6d', '#ffd34a'];
const AMB_RISE = [0, 10, 34, -22, 12, 8]; // 위로 뜨는 속도 (음수는 눈처럼 떨어진다, 0은 제자리 맴돌기)
function drawAmbient(c, ch, cam) {
  const t = S.clock, P = AMB[ch], col = AMB_COL[ch] || '#fff', rise = AMB_RISE[ch] || 0, acc = CHAPTERS[ch].accent;
  for (let k = 0; k < 2; k++) { // 안개
    const fx = W * (0.5 + 0.4 * Math.sin(t * 0.07 + k * 3)), fy = H * (0.35 + 0.3 * k + 0.08 * Math.sin(t * 0.11 + k));
    const g = c.createRadialGradient(fx, fy, 10, fx, fy, 200);
    g.addColorStop(0, acc + '1c'); g.addColorStop(1, acc + '00');
    c.fillStyle = g; c.fillRect(0, 0, W, H);
  }
  c.save(); c.globalCompositeOperation = 'lighter'; c.fillStyle = col;
  for (const p of P) {
    const x = (((p.x + Math.sin(t * 0.5 * p.sp + p.ph) * p.amp - cam.x * 0.35) % W) + W) % W;
    const y = rise ? (((p.y - t * rise * p.sp - cam.y * 0.35) % H) + H) % H : (((p.y + Math.cos(t * 0.4 * p.sp + p.ph * 1.3) * p.amp * 0.7 - cam.y * 0.35) % H) + H) % H;
    const tw = 0.5 + 0.5 * Math.sin(t * (ch === 2 ? 9 : 2.2) * p.sp + p.ph);
    c.globalAlpha = 0.1 + 0.28 * tw; c.beginPath(); c.arc(x, y, p.sz * 3.2, 0, 6.3); c.fill();
    c.globalAlpha = 0.35 + 0.55 * tw; c.beginPath(); c.arc(x, y, p.sz, 0, 6.3); c.fill();
  }
  c.restore();
}
const TORCHES = [[70, 56], [215, 56], [360, 56], [505, 56], [650, 56]];
function drawTorches(c, ch) {
  const t = S.clock, acc = CHAPTERS[ch].accent;
  for (let i = 0; i < TORCHES.length; i++) {
    const [x, y] = TORCHES[i], fl = 1 + Math.sin(t * 13 + i * 2) * 0.12 + Math.sin(t * 7.3 + i) * 0.08;
    const g = c.createRadialGradient(x, y - 6, 1, x, y - 6, 34 * fl);
    g.addColorStop(0, 'rgba(255,200,120,.35)'); g.addColorStop(1, 'rgba(255,200,120,0)');
    c.fillStyle = g; c.fillRect(x - 40, y - 46, 80, 80);
    c.fillStyle = '#5a3a2a'; c.fillRect(x - 2, y - 4, 4, 8);
    c.fillStyle = ch === 3 ? '#9fe6ff' : ch === 4 ? '#ff4d9a' : '#ffb03a';
    ell(c, x, y - 9, 4 * fl, 7 * fl); c.fill();
    c.fillStyle = '#fff2b0'; ell(c, x, y - 7, 2, 3.5 * fl); c.fill();
  }
  c.fillStyle = acc;
}

/* ---------- 치비 영웅 / 메아리 ---------- */
export const PAL_HERO = { skin: '#ffd9b8', hair: '#6a4cff', body: '#4aa3ff', belt: '#ffd34a', boots: '#7a4a2a', blade: '#e9f6ff', sprite: 'hero' };
export const PAL_ECHO = { skin: '#cfefff', hair: '#38c8ff', body: '#5ee0ff', belt: '#e8ffff', boots: '#3a9ac0', blade: '#aef3ff', sprite: 'hero' };

export function drawChibi(c, o, pal, alpha, scale) {
  const sp = o.sp, ph = o.phase, clock = S.clock;
  o._v = viewOf(o);
  const fx = flipX(o, o.sprite || pal.sprite);
  o._lean = (o._lean || 0) + (clamp(o._dx * 0.05, -0.14, 0.14) - (o._lean || 0)) * 0.25; // 달리는 쪽으로 기운다
  const idle = Math.sin(clock * 3 + o.id) * (1 - sp);
  c.save();
  c.globalAlpha = alpha;
  c.translate(o.x, o.y);
  if (scale) c.scale(scale, scale);
  c.fillStyle = 'rgba(0,0,0,.28)'; ell(c, 0, 8, 11 - Math.abs(Math.sin(ph)) * 2 * sp, 4); c.fill();
  const bob = Math.abs(Math.sin(ph)) * 3.4 * sp + idle * 0.9;
  const atkK = o.atk > 0.75 ? (1 - o.atk) * 4 : o.atk / 0.75; // 공격: 살짝 웅크렸다(예비 동작) 튀어 나간다
  const sq = Math.sin(ph * 2) * 0.05 * sp + idle * 0.025 + (o.atk > 0.75 ? 0.1 * atkK : -0.06 * atkK);
  const spr = o.sprite || pal.sprite, im = SPR[spr] && pick(c, o, spr);
  const robed = ROBED.includes(spr); // 긴 옷은 다리를 따로 자르면 어색하다: 통째로 통통 튀며 흔들린다
  if (!im || robed) c.translate(0, -bob);
  c.translate(o.face * (o.atk > 0.75 ? -2 : 5) * atkK - o.face * Math.min(o.hit, 0.2) * 14, 0); // 공격은 내딛고, 맞으면 밀린다
  c.rotate(o.face * (robed ? 0.075 : 0.05) * sp * Math.sin(ph) + o._lean - o.face * Math.min(o.hit, 0.25) * 0.8);
  c.scale(fx * (1 + sq), 1 - sq);
  if (im) {
    puppet(c, im, 64, {
      legs: !robed, view: o._v, ph, sp, bob: -bob,
      headBob: Math.sin(ph * 2 - 0.9) * 1.2 * sp + Math.sin(clock * 3 + o.id) * 0.6 * (1 - sp),
      headRot: -o._lean * 0.6 + Math.sin(ph - 0.6) * 0.05 * sp,
      red: o.isHero && o.hit > 0 ? o.hit * 3 : 0, white: !o.isHero && o.hit > 0 ? o.hit * 3 : 0,
    });
  } else {
    const swing = Math.sin(ph) * 5 * sp;
    rr(c, -7 + swing * 0.5, -7, 6, 9 - Math.max(0, -swing) * 0.4, 3); fs(c, pal.boots);
    rr(c, 1 - swing * 0.5, -7, 6, 9 - Math.max(0, swing) * 0.4, 3); fs(c, pal.boots);
    c.beginPath(); c.arc(-9, -16 + swing * 0.6, 3.6, 0, 6.3); fs(c, pal.skin);
    rr(c, -8, -21, 16, 15, 6); fs(c, pal.body);
    c.fillStyle = pal.belt; c.fillRect(-8, -12, 16, 3);
    c.beginPath(); c.arc(0, -31, 13, 0, 6.3); fs(c, pal.skin);
    c.beginPath(); c.arc(0, -33, 13.5, Math.PI * 1.02, Math.PI * 1.98); c.lineTo(9, -34); c.quadraticCurveTo(2, -30, -3, -35); c.quadraticCurveTo(-8, -31, -12, -33); fs(c, pal.hair);
    c.beginPath(); c.moveTo(-2, -44); c.quadraticCurveTo(3, -52, 9 + Math.sin(clock * 6) * 1.5, -47); c.quadraticCurveTo(4, -45, 2, -43); fs(c, pal.hair);
    const blink = (clock * 0.9 + o.id * 0.7) % 3.2 < 0.12;
    c.fillStyle = '#2a1830';
    if (blink) { c.fillRect(-7, -30, 5, 1.5); c.fillRect(2, -30, 5, 1.5); }
    else {
      ell(c, -4.5, -30, 2.4, 3.2); c.fill(); ell(c, 4.5, -30, 2.4, 3.2); c.fill();
      c.fillStyle = '#fff'; c.beginPath(); c.arc(-3.7, -31.2, 0.9, 0, 6.3); c.arc(5.3, -31.2, 0.9, 0, 6.3); c.fill();
    }
    c.fillStyle = 'rgba(255,110,140,.5)'; ell(c, -8, -26, 3, 2); c.fill(); ell(c, 8, -26, 3, 2); c.fill();
    c.strokeStyle = OL; c.lineWidth = 1.2; c.beginPath();
    if (o.hit > 0) c.arc(0, -23, 2, Math.PI, 0); else c.arc(0, -25, 2, 0.15, Math.PI - 0.15);
    c.stroke();
    const sw = -1.1 + o.atk * 2.3;
    c.save(); c.translate(9, -15); c.rotate(sw);
    rr(c, -1.6, -20, 3.2, 17, 1.5); fs(c, pal.blade, 1.3);
    c.fillStyle = '#c9902a'; c.fillRect(-4, -4, 8, 2.4);
    c.beginPath(); c.arc(0, 0, 3.6, 0, 6.3); fs(c, pal.skin);
    c.restore();
  }
  if (o.hit > 0 && !im) { c.globalAlpha = alpha * 0.55; c.fillStyle = '#fff'; c.beginPath(); c.arc(0, -26, 17, 0, 6.3); c.fill(); }
  c.restore();
  if (o.atk > 0.4 && o.cls === 'mage') { // 법사: 지팡이 끝에 마력이 모인다
    const k = (o.atk - 0.4) / 0.6, gx = o.x + o.face * 14, gy = o.y - 34, g = c.createRadialGradient(gx, gy, 1, gx, gy, 16 * k + 4);
    g.addColorStop(0, `rgba(255,240,255,${0.9 * k})`); g.addColorStop(0.4, `rgba(190,130,255,${0.6 * k})`); g.addColorStop(1, 'rgba(150,80,255,0)');
    c.save(); c.globalCompositeOperation = 'lighter'; c.fillStyle = g; c.fillRect(gx - 22, gy - 22, 44, 44); c.restore();
  }
  const st = o.st;
  if (st && st.blades > 0) {
    c.save(); c.globalAlpha = alpha;
    for (let i = 0; i < st.blades; i++) {
      const a = o.ang + i * Math.PI * 2 / st.blades;
      c.save(); c.translate(o.x + Math.cos(a) * st.bladeR, o.y - 10 + Math.sin(a) * st.bladeR); c.rotate(a + Math.PI / 2); c.scale(st.bladeSize, st.bladeSize);
      c.beginPath(); c.moveTo(0, -10); c.lineTo(4.5, 4); c.lineTo(-4.5, 4); c.closePath(); fs(c, st.bladeDmg > 7 ? '#ffe27a' : pal.blade, 1.3);
      c.restore();
    }
    c.restore();
  }
  if (o.isHero && st && st.shield > 0 && o.shieldReady) {
    c.save(); c.strokeStyle = `rgba(143,233,255,${0.5 + Math.sin(clock * 5) * 0.2})`; c.lineWidth = 2;
    c.beginPath(); c.arc(o.x, o.y - 20, 24, 0, 6.3); c.stroke(); c.restore();
  }
}

/* ---------- 몬스터 ---------- */
function drawSlime(c, e, col, belly) {
  const t = S.clock, q = Math.sin(t * 7 + e.seed), w = e.r * (1.1 + 0.13 * q), h = e.r * (0.95 - 0.13 * q);
  const n = e.type === 'slime' ? 'slime' : e.type === 'blob' ? 'blob' : null, im = n && SPR[n] && pick(c, e, n);
  if (im) { // 통통 뛰어다닌다: 뜨면 늘어나고, 떨어지면 납작해진다
    const hp = Math.sin(t * 7 + e.seed), air = Math.max(0, hp), land = Math.max(0, -hp);
    c.translate(0, -air * e.r * 0.7); c.scale(1 - air * 0.12 + land * 0.18, 1 + air * 0.16 - land * 0.2);
    puppet(c, im, e.r * 2.7, { white: e.wf }); return;
  }
  ell(c, 0, -h, w, h); fs(c, col || '#7ee06b');
  c.fillStyle = belly || 'rgba(255,255,255,.55)'; ell(c, -w * 0.4, -h * 1.5, w * 0.25, h * 0.18); c.fill();
  c.fillStyle = '#2a1830'; ell(c, -w * 0.32, -h * 1.0, 2, 3); c.fill(); ell(c, w * 0.32, -h * 1.0, 2, 3); c.fill();
  c.strokeStyle = OL; c.lineWidth = 1.2; c.beginPath(); c.arc(0, -h * 0.75, 2.4, 0.2, 2.9); c.stroke();
}
function drawBat(c, e) {
  const t = S.clock, s = e.seed, fl = Math.sin(t * 20 + s), by = -16 - Math.sin(t * 6 + s) * 3, k = e.r / 9;
  c.scale(k, k);
  if (SPR.bat) {
    const im = pick(c, e, 'bat');
    c.translate(0, by + 19);
    puppet(c, im, 38, e._v === 's' ? { white: e.wf } : { wings: fl * 0.32, white: e.wf });
    return;
  }
  for (const sd of [-1, 1]) {
    c.beginPath(); c.moveTo(sd * 5, by); c.quadraticCurveTo(sd * 18, by - 10 - fl * 8, sd * 22, by + 2 - fl * 4); c.quadraticCurveTo(sd * 15, by + 2, sd * 11, by + 7); c.quadraticCurveTo(sd * 8, by + 3, sd * 5, by + 5); fs(c, '#8a5cd8');
  }
  c.beginPath(); c.arc(0, by, 8, 0, 6.3); fs(c, '#b58cff');
  c.fillStyle = '#fff'; c.beginPath(); c.moveTo(-3, by + 4); c.lineTo(-1.5, by + 8); c.lineTo(0, by + 4); c.moveTo(0, by + 4); c.lineTo(1.5, by + 8); c.lineTo(3, by + 4); c.fill();
  c.fillStyle = '#ff4d6d'; c.beginPath(); c.arc(-3, by - 1, 1.8, 0, 6.3); c.arc(3, by - 1, 1.8, 0, 6.3); c.fill();
  c.beginPath(); c.moveTo(-6, by - 5); c.lineTo(-8, by - 12); c.lineTo(-2, by - 7); c.moveTo(6, by - 5); c.lineTo(8, by - 12); c.lineTo(2, by - 7); fs(c, '#b58cff');
}
function drawBrute(c, e) {
  const t = S.clock, s = e.seed, st = Math.abs(Math.sin(t * 4 + s)), by = -st * 3, r = e.r;
  if (SPR.brute) { puppet(c, pick(c, e, 'brute'), r * 3.3, { legs: true, view: e._v, ph: e._ph, sp: e._sp, bob: -Math.abs(Math.sin(e._ph)) * 2.5 * e._sp, headBob: Math.sin(e._ph * 2 - 1) * 1.2 * e._sp, white: e.wf }); return; }
  rr(c, -r * 0.6, by - r * 1.0, r * 1.2, r * 1.0, 7); fs(c, '#ff9c4a');
  rr(c, -r * 0.55, by - 3, r * 0.45, 7, 3); fs(c, '#7a4a2a');
  rr(c, r * 0.1, by - 3, r * 0.45, 7, 3); fs(c, '#7a4a2a');
  c.beginPath(); c.arc(0, by - r * 1.5, r * 0.85, 0, 6.3); fs(c, '#ffb870');
  c.fillStyle = '#fff'; c.beginPath(); c.moveTo(-r * 0.4, by - r * 1.15); c.lineTo(-r * 0.3, by - r * 0.85); c.lineTo(-r * 0.2, by - r * 1.15); c.moveTo(r * 0.4, by - r * 1.15); c.lineTo(r * 0.3, by - r * 0.85); c.lineTo(r * 0.2, by - r * 1.15); c.fill();
  c.beginPath(); c.moveTo(-r * 0.7, by - r * 2.0); c.lineTo(-r * 0.95, by - r * 2.6); c.lineTo(-r * 0.3, by - r * 2.2); c.moveTo(r * 0.7, by - r * 2.0); c.lineTo(r * 0.95, by - r * 2.6); c.lineTo(r * 0.3, by - r * 2.2); fs(c, '#fff2d0');
  c.fillStyle = '#2a1830'; ell(c, -r * 0.3, by - r * 1.55, 2.2, 2.8); c.fill(); ell(c, r * 0.3, by - r * 1.55, 2.2, 2.8); c.fill();
  c.strokeStyle = OL; c.lineWidth = 2; c.beginPath(); c.moveTo(-r * 0.5, by - r * 1.85); c.lineTo(-r * 0.15, by - r * 1.72); c.moveTo(r * 0.5, by - r * 1.85); c.lineTo(r * 0.15, by - r * 1.72); c.stroke();
  c.save(); c.translate(r * 0.7, by - r * 0.8); c.rotate(-0.5 + Math.sin(t * 4 + s) * 0.25);
  rr(c, -2.5, -r * 1.1, 5, r * 1.1, 2); fs(c, '#8a5a2a'); c.beginPath(); c.arc(0, -r * 1.15, 5, 0, 6.3); fs(c, '#a87438'); c.restore();
}
function drawMage(c, e) {
  const t = S.clock, s = e.seed, r = e.r, fl = Math.sin(t * 3 + s) * 2, by = -4 + fl;
  if (SPR.mage) { c.translate(0, fl * 0.6); puppet(c, pick(c, e, 'mage'), r * 3.5, { legs: true, view: e._v, ph: e._ph, sp: e._sp * 0.6, headBob: Math.sin(t * 3 + s), headRot: e.cast ? Math.sin(t * 30) * 0.05 : 0, white: e.wf }); return; }
  c.beginPath(); c.moveTo(-r * 0.9, by); c.quadraticCurveTo(0, by - r * 2.2, r * 0.9, by); c.closePath(); fs(c, '#5b3d9a');
  c.beginPath(); c.arc(0, by - r * 1.7, r * 0.75, 0, 6.3); fs(c, '#efe6d0');
  c.fillStyle = '#2a1830'; ell(c, -r * 0.3, by - r * 1.7, 2.4, 3); c.fill(); ell(c, r * 0.3, by - r * 1.7, 2.4, 3); c.fill();
  c.fillStyle = e.cast ? '#ff7af0' : '#c99cff'; c.beginPath(); c.arc(-r * 0.3, by - r * 1.72, 1, 0, 6.3); c.arc(r * 0.3, by - r * 1.72, 1, 0, 6.3); c.fill();
  c.beginPath(); c.moveTo(-r * 0.85, by - r * 2.1); c.lineTo(0, by - r * 3.3); c.lineTo(r * 0.85, by - r * 2.1); c.closePath(); fs(c, '#4a2f80');
  c.strokeStyle = '#8a5a2a'; c.lineWidth = 2.5; c.beginPath(); c.moveTo(r * 1.0, by + 2); c.lineTo(r * 1.0, by - r * 2.3); c.stroke();
  const glow = e.cast ? 5 + Math.sin(t * 30) * 1.5 : 3.5;
  c.fillStyle = e.cast ? '#ff9af5' : '#b99cff'; c.beginPath(); c.arc(r * 1.0, by - r * 2.5, glow, 0, 6.3); c.fill();
}
function drawBoar(c, e) {
  const t = S.clock, s = e.seed, r = e.r;
  const wind = e.cs === 'wind', dash = e.cs === 'dash';
  const jit = wind ? Math.sin(t * 60) * 1.5 : 0, run = dash ? 14 : 5, by = -Math.abs(Math.sin(t * run + s)) * (dash ? 4 : 2);
  c.translate(jit, 0);
  if (SPR.boar) { puppet(c, pick(c, e, 'boar'), r * 2.65, { legs: true, view: e._v, ph: e._ph * (dash ? 1.6 : 1), sp: dash ? 1 : e._sp, bob: by, headRot: wind ? -0.08 : 0, white: e.wf, red: wind ? 0.25 + 0.2 * Math.sin(t * 30) : 0 }); return; }
  for (const lx of [-0.6, -0.2, 0.25, 0.65]) { rr(c, lx * r - 2, by - 5 + Math.sin(t * run + lx * 5) * (dash ? 2 : 1), 4, 7, 2); fs(c, '#5a3a2a'); }
  ell(c, 0, by - r * 0.8, r * 1.15, r * 0.75); fs(c, wind ? '#e0905a' : '#c98a5a');
  c.beginPath(); c.arc(r * 0.85, by - r * 0.95, r * 0.55, 0, 6.3); fs(c, '#d89a6a');
  ell(c, r * 1.3, by - r * 0.85, r * 0.25, r * 0.2); fs(c, '#f2b8a0');
  c.fillStyle = '#fff'; c.beginPath(); c.moveTo(r * 1.15, by - r * 0.6); c.quadraticCurveTo(r * 1.45, by - r * 0.6, r * 1.5, by - r * 1.05); c.lineTo(r * 1.3, by - r * 0.7); c.fill();
  c.fillStyle = wind ? '#ff3030' : '#2a1830'; c.beginPath(); c.arc(r * 0.95, by - r * 1.15, 2, 0, 6.3); c.fill();
  c.beginPath(); c.moveTo(r * 0.55, by - r * 1.35); c.lineTo(r * 0.65, by - r * 1.75); c.lineTo(r * 0.85, by - r * 1.4); fs(c, '#a86a3a');
  if (dash) { c.fillStyle = 'rgba(255,255,255,.4)'; for (let i = 0; i < 3; i++) c.fillRect(-r * 1.6 - i * 6, by - r * (0.5 + i * 0.3), 8, 2); }
}
function drawBossBody(c, e) {
  const t = S.clock, b = BOSSES[e.bid], col = b.col, r = e.r;
  if (SPR[e.bid]) {
    const q = Math.sin(t * 4);
    let sx = 1 + q * 0.03, sy = 1 - q * 0.03; // 숨쉬기
    if (b.pattern === 'jump') { if (e.js === 'crouch') { sx = 1.25; sy = 0.75; } else if (e.js === 'air') { sx = 0.85; sy = 1.2; } }
    c.translate(0, -(e.z || 0) + (e.bid === 'lich' ? Math.sin(t * 2) * 4 - 8 : 0)); c.scale(sx, sy);
    const walker = e.bid === 'dragon' || e.bid === 'shadow' || e.bid === 'slimeking';
    puppet(c, pick(c, e, e.bid), r * 3.2, { legs: walker && !e.z, view: e._v, ph: e._ph * 0.7, sp: e._sp, bob: -Math.abs(Math.sin(e._ph * 0.7)) * 3 * e._sp,
      headBob: Math.sin(t * 2.5) * 1.5, headRot: e.hp < e.maxhp * 0.5 ? Math.sin(t * 9) * 0.04 : 0, white: e.wf, red: e.hp < e.maxhp * 0.3 ? 0.12 + 0.1 * Math.sin(t * 8) : 0 });
    return;
  }
  if (e.bid === 'slimeking' || e.bid === 'frost') {
    let sx = 1, sy = 1;
    if (e.js === 'crouch') { sx = 1.25; sy = 0.75; } else if (e.js === 'air') { sx = 0.85; sy = 1.2; }
    else { const q = Math.sin(t * 4); sx = 1 + q * 0.05; sy = 1 - q * 0.05; }
    c.translate(0, -(e.z || 0)); c.scale(sx, sy);
    ell(c, 0, -r * 0.95, r * 1.25, r * 0.95); fs(c, col.body, 2.4);
    c.fillStyle = 'rgba(255,255,255,.45)'; ell(c, -r * 0.5, -r * 1.45, r * 0.3, r * 0.16); c.fill();
    for (let i = -2; i <= 2; i++) { c.beginPath(); c.moveTo(i * 8 - 5, -r * 1.75); c.lineTo(i * 8, -r * 1.75 - 12 - (i % 2 ? 0 : 6)); c.lineTo(i * 8 + 5, -r * 1.75); fs(c, col.crown); }
    const rage = e.hp < e.maxhp * 0.5;
    c.fillStyle = '#2a1830'; ell(c, -r * 0.4, -r * 1.05, 4, 6); c.fill(); ell(c, r * 0.4, -r * 1.05, 4, 6); c.fill();
    c.fillStyle = rage ? '#ff4d6d' : '#fff'; c.beginPath(); c.arc(-r * 0.36, -r * 1.12, 1.6, 0, 6.3); c.arc(r * 0.44, -r * 1.12, 1.6, 0, 6.3); c.fill();
    c.strokeStyle = OL; c.lineWidth = 2; c.beginPath(); c.arc(0, -r * 0.7, 6, 0.2, Math.PI - 0.2); c.stroke();
    return;
  }
  if (e.bid === 'lich') {
    const fl = Math.sin(t * 2) * 4;
    c.translate(0, fl - 8);
    c.beginPath(); c.moveTo(-r * 1.1, 0); c.quadraticCurveTo(-r * 0.6, -r * 2.2, 0, -r * 2.3); c.quadraticCurveTo(r * 0.6, -r * 2.2, r * 1.1, 0);
    for (let i = 4; i >= -4; i--) c.lineTo(i * r * 0.27, (i % 2 ? -6 : 0));
    c.closePath(); fs(c, col.body, 2.2);
    c.beginPath(); c.arc(0, -r * 2.1, r * 0.7, 0, 6.3); fs(c, col.belly, 2);
    c.fillStyle = '#1a0f22'; ell(c, -r * 0.28, -r * 2.12, 4, 5); c.fill(); ell(c, r * 0.28, -r * 2.12, 4, 5); c.fill();
    c.fillStyle = col.crown; c.beginPath(); c.arc(-r * 0.28, -r * 2.12, 1.8 + Math.sin(t * 8), 0, 6.3); c.arc(r * 0.28, -r * 2.12, 1.8 + Math.sin(t * 8), 0, 6.3); c.fill();
    c.beginPath(); c.moveTo(-r * 0.8, -r * 2.5); c.lineTo(0, -r * 3.6); c.lineTo(r * 0.8, -r * 2.5); c.closePath(); fs(c, col.body);
    c.strokeStyle = '#8a5a2a'; c.lineWidth = 3; c.beginPath(); c.moveTo(r * 1.2, 0); c.lineTo(r * 1.2, -r * 2.6); c.stroke();
    const g = c.createRadialGradient(r * 1.2, -r * 2.8, 1, r * 1.2, -r * 2.8, 14);
    g.addColorStop(0, '#fff'); g.addColorStop(0.4, col.crown); g.addColorStop(1, 'rgba(0,0,0,0)');
    c.fillStyle = g; c.beginPath(); c.arc(r * 1.2, -r * 2.8, 14, 0, 6.3); c.fill();
    return;
  }
  // radial / 용
  const pul = 1 + Math.sin(t * 3) * 0.04, by = -Math.abs(Math.sin(t * 2)) * 4;
  c.translate(0, -(e.z || 0)); c.scale(pul, 2 - pul);
  for (const sd of [-1, 1]) { c.beginPath(); c.moveTo(sd * r * 0.6, by - r * 1.2); c.quadraticCurveTo(sd * r * 1.9, by - r * 2.2 - Math.sin(t * 4) * 6, sd * r * 1.7, by - r * 0.6); c.closePath(); fs(c, col.body); }
  for (let i = -2; i <= 2; i++) { c.beginPath(); c.moveTo(i * 9 - 5, by - r * 1.6); c.lineTo(i * 9, by - r * 1.6 - 12 - (i % 2 ? 0 : 5)); c.lineTo(i * 9 + 5, by - r * 1.6); fs(c, col.crown); }
  ell(c, 0, by - r * 0.95, r * 1.1, r * 0.95); fs(c, col.body, 2.4);
  ell(c, 0, by - r * 0.55, r * 0.7, r * 0.5); fs(c, col.belly);
  const rage = e.hp < e.maxhp * 0.5;
  c.fillStyle = rage ? '#fff04a' : '#fff'; ell(c, -r * 0.4, by - r * 1.15, 5, 6); c.fill(); ell(c, r * 0.4, by - r * 1.15, 5, 6); c.fill();
  c.fillStyle = '#2a1830'; c.beginPath(); c.arc(-r * 0.36, by - r * 1.12, 2.4, 0, 6.3); c.arc(r * 0.36, by - r * 1.12, 2.4, 0, 6.3); c.fill();
  c.strokeStyle = OL; c.lineWidth = 2.5; c.beginPath(); c.moveTo(-r * 0.7, by - r * 1.5); c.lineTo(-r * 0.2, by - r * 1.3); c.moveTo(r * 0.7, by - r * 1.5); c.lineTo(r * 0.2, by - r * 1.3); c.stroke();
  c.fillStyle = '#fff'; c.beginPath(); for (let i = -2; i <= 2; i++) { c.moveTo(i * 5 - 2.5, by - r * 0.7); c.lineTo(i * 5, by - r * 0.5); c.lineTo(i * 5 + 2.5, by - r * 0.7); } c.fill();
}

function drawEnemy(c, e) {
  const t = S.clock;
  c.save(); c.translate(e.x, e.y);
  if (e.nem) { c.fillStyle = `rgba(255,60,90,${0.22 + Math.sin(t * 6) * 0.1})`; ell(c, 0, -e.r * 0.5, e.r * 1.6, e.r * 1.3); c.fill(); }
  if (e.elite) { c.fillStyle = `rgba(255,211,74,${0.2 + Math.sin(t * 5) * 0.08})`; ell(c, 0, -e.r * 0.5, e.r * 1.5, e.r * 1.2); c.fill(); }
  const shadowK = e.z ? Math.max(0.4, 1 - e.z / 160) : 1;
  c.fillStyle = 'rgba(0,0,0,.3)'; ell(c, 0, 4, e.r * 0.95 * shadowK, e.r * 0.32 * shadowK); c.fill();
  e._v = viewOf(e); stride(e);
  e.wf = e.dying != null ? Math.max(0, 1 - e.dying * 8) : e.flash > 0 ? 0.9 : 0;
  const nm = e.boss ? e.bid : { slime: 'slime', blob: 'blob', bat: 'bat', brute: 'brute', mage: 'mage', boar: 'boar' }[e.type];
  c.scale(flipX(e, nm), 1);
  // 등장: 통통 튀며 커지고, 맞으면 눌렸다 돌아오고, 쓰러지면 납작해지며 사라진다
  if (e.dying != null) {
    const k = clamp(e.dying / (e.boss ? 0.9 : 0.35), 0, 1);
    c.globalAlpha = 1 - k; c.scale(1 + 0.45 * k, 1 - 0.85 * k);
  } else {
    if (typeof e.t === 'number' && e.t < 0.35) { const p = easeBack(e.t / 0.35); c.scale(p, p); }
    if (e.flash > 0) c.scale(1.08, 0.93);
  }
  if (e.type === 'brute' || e.type === 'boar') c.rotate(Math.sin(S.clock * (e.cs === 'dash' ? 14 : 5) + e.seed) * 0.05);
  if (e.boss) drawBossBody(c, e);
  else if (e.type === 'slime') drawSlime(c, e);
  else if (e.type === 'blob') drawSlime(c, e, '#7fc8ff');
  else if (e.type === 'mini') drawSlime(c, e, '#a8dcff');
  else if (e.type === 'bat') drawBat(c, e);
  else if (e.type === 'brute') drawBrute(c, e);
  else if (e.type === 'mage') drawMage(c, e);
  else if (e.type === 'boar') drawBoar(c, e);
  if (e.flash > 0 && !(nm && SPR[nm])) { c.globalAlpha = 0.55; c.fillStyle = '#fff'; ell(c, 0, -e.r * 0.95 - (e.z || 0), e.r * 1.1, e.r * 1.0); c.fill(); }
  if (e.slowT > 0) { c.globalAlpha = 0.35; c.fillStyle = '#9fe6ff'; ell(c, 0, -e.r * 0.9, e.r * 1.05, e.r * 0.95); c.fill(); }
  c.restore();
  if (e.dying != null) return;
  if (e.cast && S.G && S.G.hero) { // 해골 마법사가 쏘기 직전: 붉은 조준선이 깜빡인다
    const h = S.G.hero, dx = h.x - e.x, dy = h.y - 14 - (e.y - 18), l = Math.hypot(dx, dy) || 1;
    c.save(); c.strokeStyle = `rgba(255,70,110,${0.25 + 0.3 * Math.sin(S.clock * 40)})`; c.lineWidth = 2; c.setLineDash([6, 6]);
    c.beginPath(); c.moveTo(e.x, e.y - 18); c.lineTo(e.x + dx / l * Math.min(l, 260), e.y - 18 + dy / l * Math.min(l, 260)); c.stroke(); c.restore();
  }
  if (!e.boss && (e.nem || e.elite || e.hp < e.maxhp)) {
    const bw = e.r * 2 + 6, by2 = e.y - e.r * 2.3 - 6;
    c.fillStyle = 'rgba(0,0,0,.55)'; c.fillRect(e.x - bw / 2, by2, bw, 4);
    c.fillStyle = e.nem ? '#ff4d6d' : e.elite ? '#ffd34a' : '#7dff9a'; c.fillRect(e.x - bw / 2, by2, bw * clamp(e.hp / e.maxhp, 0, 1), 4);
  }
  if (e.label) label(c, '☠ ' + e.label, e.x, e.y - e.r * 2.3 - 12, '#ff9fb0', '#2a0a18', 10);
  if (e.elite) label(c, '★ 정예', e.x, e.y - e.r * 2.3 - 12, '#ffe27a', '#2a1a00', 10);
}
function label(c, s, x, y, fill, stroke, size) {
  c.font = `800 ${size}px sans-serif`; c.textAlign = 'center';
  c.lineWidth = 3; c.strokeStyle = stroke; c.strokeText(s, x, y);
  c.fillStyle = fill; c.fillText(s, x, y);
}

/* ---------- HUD ---------- */
function drawHud(c) {
  const G = S.G, h = G.hero;
  c.fillStyle = 'rgba(0,0,0,.5)'; rr(c, 12, 10, 150, 18, 9); c.fill();
  const hpk = clamp(h.hp / h.st.maxhp, 0, 1);
  c.fillStyle = hpk > 0.3 ? '#ff5d8f' : (Math.floor(S.clock * 6) % 2 ? '#ff3030' : '#ff8080');
  rr(c, 14, 12, Math.max(0, 146 * hpk), 14, 7); c.fill();
  c.fillStyle = '#fff'; c.font = '800 11px sans-serif'; c.textAlign = 'center';
  const hpTxt = `${Math.max(0, Math.ceil(h.hp))}/${h.st.maxhp}`;
  if (ICO.ui_heart) { c.drawImage(ICO.ui_heart, 13, 8, 21, 21); c.fillText(hpTxt, 94, 24); } else c.fillText('❤ ' + hpTxt, 87, 24);
  c.textAlign = 'left'; c.font = '800 13px sans-serif';
  c.fillStyle = '#ffd34a';
  if (ICO.ui_coin) { c.drawImage(ICO.ui_coin, 170, 9, 19, 19); c.fillText(String(G.coinsGot), 192, 24); } else c.fillText(`🪙 ${G.coinsGot}`, 172, 24);
  c.fillStyle = '#fff';
  if (ICO.ui_kills) { c.drawImage(ICO.ui_kills, 236, 9, 19, 19); c.fillText(String(G.kills), 258, 24); } else c.fillText(`⚔ ${G.kills}`, 236, 24);

  const bb = G.boss && !G.boss.dead ? G.boss : G.mid && !G.mid.dead ? G.mid : null;
  if (bb) { // 보스(또는 중간 보스) 체력
    const k = clamp(bb.hp / bb.maxhp, 0, 1);
    c.fillStyle = 'rgba(0,0,0,.6)'; rr(c, 12, 36, W - 24, 16, 8); c.fill();
    c.fillStyle = bb.mid ? (k < 0.5 ? '#ff7a30' : '#ffb15c') : (k < 0.5 ? '#ff3060' : '#ff5d73'); rr(c, 14, 38, (W - 28) * k, 12, 6); c.fill();
    c.fillStyle = '#fff'; c.font = '800 11px sans-serif'; c.textAlign = 'center';
    c.fillText(`${bb.mid ? '중간 보스 ' : ''}${bb.name}  ${Math.ceil(k * 100)}%`, W / 2, 48);
  } else if (G.endless) { // 무한 던전: 생존 시간과 다음 중간 보스
    const m = Math.floor(G.t / 60), sec = Math.floor(G.t % 60);
    const nxt = 60 * (G.midIdx + 1) - G.t;
    const p = clamp(1 - nxt / 60, 0, 1);
    c.fillStyle = 'rgba(0,0,0,.5)'; rr(c, 12, 38, W - 24, 12, 6); c.fill();
    c.fillStyle = '#ffd34a'; rr(c, 13, 39, Math.max(0, (W - 26) * p), 10, 5); c.fill();
    c.font = '800 9px sans-serif'; c.textAlign = 'center'; c.lineWidth = 2.5; c.strokeStyle = 'rgba(0,0,0,.7)';
    const tl = `♾ ${m}:${String(sec).padStart(2, '0')}  ·  중간 보스까지 ${Math.max(0, Math.ceil(nxt))}초`;
    c.strokeText(tl, W / 2, 47.5); c.fillStyle = '#fff'; c.fillText(tl, W / 2, 47.5);
  } else {
    const p = clamp(G.t / G.time, 0, 1);
    c.fillStyle = 'rgba(0,0,0,.5)'; rr(c, 12, 38, W - 24, 12, 6); c.fill();
    c.fillStyle = '#ffd34a'; rr(c, 13, 39, Math.max(0, (W - 26) * p), 10, 5); c.fill();
    c.fillStyle = 'rgba(255,255,255,.75)'; // 10초마다 카드 눈금
    for (let t = PICK_EVERY; t < G.time; t += PICK_EVERY) c.fillRect(12 + (W - 24) * t / G.time - 0.5, 38, 1, 12);
    c.fillStyle = '#ffb15c'; // 중간 보스 표시
    for (const m of G.chap.mid) c.fillRect(12 + (W - 24) * m.t / G.time - 2, 36, 4, 16);
    c.font = '800 9px sans-serif'; c.textAlign = 'center'; c.lineWidth = 2.5; c.strokeStyle = 'rgba(0,0,0,.7)';
    const tl = `보스까지 ${Math.max(0, Math.ceil(G.time - G.t))}초`;
    c.strokeText(tl, W / 2, 47.5); c.fillStyle = '#fff'; c.fillText(tl, W / 2, 47.5);
  }
  // 획득한 카드
  const lv = h.st.lv, ids = Object.keys(lv);
  c.font = '11px sans-serif'; c.textAlign = 'left';
  let x = 13;
  for (const id of ids) {
    const card = CARD_BY_ID[id];
    if (!card || card.fallback) continue;
    c.fillStyle = 'rgba(0,0,0,.45)'; rr(c, x - 1, 55, lv[id] > 1 ? 30 : 19, 17, 5); c.fill();
    if (ICO[id]) c.drawImage(ICO[id], x, 56, 15, 15); else { c.fillStyle = '#fff'; c.fillText(card.ic, x + 1, 68); }
    if (lv[id] > 1) { c.font = '800 9px sans-serif'; c.fillStyle = '#ffe27a'; c.fillText(String(lv[id]), x + 19, 68); c.font = '11px sans-serif'; }
    x += lv[id] > 1 ? 33 : 22;
    if (x > W - 40) break;
  }
  if (G.combo >= 3) { // 콤보: 올라갈 때마다 튀어 오르고, 높을수록 뜨거운 색
    const pop = 1 + G.comboPop * 2.4, a = clamp(G.comboT / 0.6, 0, 1);
    c.save(); c.globalAlpha = a; c.translate(W - 52, 100); c.scale(pop, pop);
    label(c, `${G.combo} COMBO`, 0, 0, G.combo >= 30 ? '#ff6b6b' : G.combo >= 10 ? '#ffb347' : '#ffe27a', '#2a1230', 17);
    c.restore();
  }
  if (G.tut) tutorialHints(c, G);
}
function tutorialHints(c, G) {
  let s = null;
  if (G.t < 5) s = '화면 아무 데나 드래그해서 이동!';
  else if (G.t < 9) s = '공격은 자동! 적에게서 도망치며 싸우세요';
  else if (G.t > 24 && G.t < 30) s = '60초를 버티면 보스가 나타납니다';
  if (!s) return;
  c.globalAlpha = 0.6 + Math.sin(S.clock * 5) * 0.3;
  label(c, s, W / 2, 560, '#ffffff', '#1b1230', 15);
  c.globalAlpha = 1;
}

/* ---------- 프레임 ---------- */
export function renderGame(c) {
  const G = S.G;
  c.save();
  if (G.shake > 0 && S.save.settings.shake) c.translate((Math.random() - 0.5) * G.shake, (Math.random() - 0.5) * G.shake);
  const cam = G.cam || (G.cam = { x: 0, y: 0 });
  drawBgView(c, G.ch, cam);
  drawGlow(c, G.ch, cam);
  drawAmbient(c, G.ch, cam);
  c.save(); c.translate(-cam.x, -cam.y); // 여기서부터는 월드 좌표
  drawTorches(c, G.ch);
  // 독 웅덩이
  for (const p of G.puddles) {
    const a = clamp(p.life / p.max, 0, 1);
    c.fillStyle = p.src === 'echo' ? `rgba(110,230,255,${0.25 * a})` : `rgba(140,255,90,${0.28 * a})`;
    ell(c, p.x, p.y, p.r, p.r * 0.55); c.fill();
  }
  // 보스 착지 지점 예고
  for (const b of G.enemies) {
    if (!b.boss || b.dead || b.js !== 'air') continue;
    c.strokeStyle = `rgba(255,60,90,${0.5 + Math.sin(S.clock * 20) * 0.3})`; c.lineWidth = 3;
    ell(c, b.tx, b.ty, b.r + 26, (b.r + 26) * 0.45); c.stroke();
  }
  for (const r of G.rings) {
    if (r.star) { // 맞은 자리의 별 모양 섬광: 맞은 방향으로 길게 뻗는다
      c.save(); c.globalCompositeOperation = 'lighter'; c.globalAlpha = clamp(r.life / 0.1, 0, 1);
      c.translate(r.x, r.y); c.rotate(r.ang); c.fillStyle = r.col;
      c.beginPath();
      for (let i = 0; i < 8; i++) { const a = i * Math.PI / 4, l = i % 2 ? r.r * 0.22 : (i === 0 ? r.r * 1.5 : i === 4 ? r.r * 0.7 : r.r); c.lineTo(Math.cos(a) * l, Math.sin(a) * l); }
      c.fill(); c.fillStyle = '#fff'; c.beginPath(); c.arc(0, 0, r.r * 0.3, 0, 6.3); c.fill();
      c.restore(); continue;
    }
    c.strokeStyle = r.col || 'rgba(255,255,255,.8)'; c.globalAlpha = clamp(r.life / 0.35, 0, 1); c.lineWidth = r.round ? 3 : 4; ell(c, r.x, r.y, r.r, r.round ? r.r : r.r * 0.5); c.stroke();
  }
  c.globalAlpha = 1;
  // 코인
  for (const co of G.coins) {
    const s = Math.abs(Math.cos(S.clock * 6 + co.x));
    c.fillStyle = '#c98a1a'; ell(c, co.x, co.y + 1, 4.5 * s + 1, 4.5); c.fill();
    c.fillStyle = '#ffd34a'; ell(c, co.x, co.y, 4 * s + 0.8, 4); c.fill();
  }
  // y 정렬 그리기
  const list = [];
  for (const e of G.echoes) if (e.alive || e.fade > 0) list.push({ y: e.y, f: () => {
    c.save(); c.globalAlpha = 0.16 * e.fade; c.fillStyle = '#8fe9ff'; ell(c, e.x - e.face * 8 * e.sp, e.y - 14, 8, 12); c.fill(); c.restore();
    drawChibi(c, e, PAL_ECHO, 0.62 * (e.alive ? 1 : e.fade));
    if (e.friend && e.alive) label(c, '👥 ' + e.friend, e.x, e.y - 66, '#bfeeff', '#0a2030', 10);
  } });
  for (const e of G.enemies) list.push({ y: e.y, f: () => drawEnemy(c, e) });
  for (const e of G.corpses) list.push({ y: e.y - 1, f: () => drawEnemy(c, e) });
  const h = G.hero;
  if (!(G.ended && !G.won)) list.push({ y: h.y, f: () => { if (!(h.inv > 0 && Math.floor(S.clock * 20) % 2)) drawChibi(c, h, PAL_HERO, 1); } });
  list.sort((a, b2) => a.y - b2.y).forEach((o) => o.f());
  // 투사체
  for (const s of G.shots) {
    const echo = s.src === 'echo';
    if (s.kind === 'slash') { // 초승달 검기: 펼쳐지며 날아가고 꼬리가 남는다
      const k = clamp(s.life / s.st.shotLife, 0, 1), open = 0.7 + (1 - k) * 0.6, R = 15 + (1 - k) * 8;
      c.save(); c.translate(s.x, s.y); c.rotate(s.ang); c.globalCompositeOperation = 'lighter';
      for (const [col, w, a] of [[echo ? '#3fb8ff' : '#ffb347', 1.0, 0.45], [echo ? '#bff4ff' : '#fff6d0', 0.55, 0.95]]) {
        c.globalAlpha = a * (0.3 + 0.7 * k); c.fillStyle = col;
        c.beginPath(); c.arc(-10, 0, R, -open, open); c.arc(-10 - R * 0.45 * w, 0, R * (1 - 0.18 * w), open, -open, true); c.fill();
      }
      c.restore();
      continue;
    }
    if (s.kind === 'arrow') { // 화살: 어두운 테두리 + 밝은 몸통 + 꼬리빛이라 어떤 배경에서도 보인다
      const sp = Math.hypot(s.vx, s.vy) || 1, hot = echo ? '#7fe3ff' : '#ffe27a';
      c.save(); c.translate(s.x, s.y); c.rotate(s.ang); c.lineCap = 'round';
      const tr = c.createLinearGradient(-34, 0, 0, 0); tr.addColorStop(0, 'rgba(255,255,255,0)'); tr.addColorStop(1, echo ? 'rgba(127,227,255,.6)' : 'rgba(255,226,122,.65)');
      c.globalCompositeOperation = 'lighter'; c.strokeStyle = tr; c.lineWidth = 5; c.beginPath(); c.moveTo(-34, 0); c.lineTo(-8, 0); c.stroke();
      c.globalCompositeOperation = 'source-over';
      c.strokeStyle = 'rgba(20,10,40,.9)'; c.lineWidth = 6; c.beginPath(); c.moveTo(-14, 0); c.lineTo(8, 0); c.stroke();
      c.beginPath(); c.moveTo(14, 0); c.lineTo(5, -6); c.lineTo(5, 6); c.closePath(); c.fillStyle = 'rgba(20,10,40,.9)'; c.fill(); c.lineWidth = 2; c.strokeStyle = 'rgba(20,10,40,.9)'; c.stroke();
      c.strokeStyle = hot; c.lineWidth = 3; c.beginPath(); c.moveTo(-13, 0); c.lineTo(7, 0); c.stroke();
      c.fillStyle = '#ffffff'; c.beginPath(); c.moveTo(13, 0); c.lineTo(5.5, -4.6); c.lineTo(5.5, 4.6); c.fill();
      c.strokeStyle = '#ffffff'; c.lineWidth = 1.6; c.beginPath(); c.moveTo(-13, 0); c.lineTo(-17, -4); c.moveTo(-13, 0); c.lineTo(-17, 4); c.stroke();
      c.restore();
      continue;
    }
    if (s.kind === 'orb') { // 마법 구슬: 후광 + 어두운 테두리 + 밝은 핵
      const pul = 1 + Math.sin(S.clock * 24 + s.x) * 0.1, col = echo ? ['#7fe3ff', '#d6f7ff'] : ['#c27cff', '#f4e0ff'];
      c.save(); c.translate(s.x, s.y);
      const g = c.createRadialGradient(0, 0, 2, 0, 0, 20 * pul); g.addColorStop(0, echo ? 'rgba(127,227,255,.7)' : 'rgba(194,124,255,.75)'); g.addColorStop(1, 'rgba(194,124,255,0)');
      c.globalCompositeOperation = 'lighter'; c.fillStyle = g; c.beginPath(); c.arc(0, 0, 20 * pul, 0, 6.3); c.fill();
      c.globalCompositeOperation = 'source-over';
      c.fillStyle = 'rgba(25,8,45,.9)'; c.beginPath(); c.arc(0, 0, 9 * pul, 0, 6.3); c.fill();
      c.fillStyle = col[0]; c.beginPath(); c.arc(0, 0, 7 * pul, 0, 6.3); c.fill();
      c.fillStyle = col[1]; c.beginPath(); c.arc(-1.5, -1.5, 3.6, 0, 6.3); c.fill();
      c.restore();
      continue;
    }
    c.fillStyle = echo ? 'rgba(143,233,255,.35)' : 'rgba(255,210,90,.35)'; c.beginPath(); c.arc(s.x - s.vx * 0.018, s.y - s.vy * 0.018, 7, 0, 6.3); c.fill();
    c.fillStyle = 'rgba(20,10,40,.9)'; c.beginPath(); c.arc(s.x, s.y, 6.5, 0, 6.3); c.fill();
    c.fillStyle = s.st.frost ? '#d8f6ff' : echo ? '#8fe9ff' : '#fff6a8'; c.beginPath(); c.arc(s.x, s.y, 4.8, 0, 6.3); c.fill();
  }
  // 적 탄: 붉은 위험 고리 + 어두운 테두리 + 밝은 핵 + 꼬리 (플레이어 탄과 확실히 구분된다)
  for (const eb of G.ebul) {
    const pul = 1 + Math.sin(S.clock * 14 + eb.x * 0.1) * 0.12, r = eb.r + 2;
    c.save(); c.translate(eb.x, eb.y);
    const sp = Math.hypot(eb.vx, eb.vy) || 1;
    c.globalCompositeOperation = 'lighter'; c.strokeStyle = eb.col || '#ff5d73'; c.globalAlpha = 0.5; c.lineWidth = r * 1.3; c.lineCap = 'round';
    c.beginPath(); c.moveTo(0, 0); c.lineTo(-eb.vx / sp * 14, -eb.vy / sp * 14); c.stroke();
    c.globalAlpha = 0.55 + 0.25 * Math.sin(S.clock * 14); c.strokeStyle = '#ff3355'; c.lineWidth = 2;
    c.beginPath(); c.arc(0, 0, (r + 5) * pul, 0, 6.3); c.stroke();
    c.globalCompositeOperation = 'source-over'; c.globalAlpha = 1;
    c.fillStyle = 'rgba(35,0,20,.92)'; c.beginPath(); c.arc(0, 0, r + 2.2, 0, 6.3); c.fill();
    c.fillStyle = eb.col || '#ff5d73'; c.beginPath(); c.arc(0, 0, r, 0, 6.3); c.fill();
    c.fillStyle = '#fff'; c.beginPath(); c.arc(-r * 0.2, -r * 0.2, r * 0.48, 0, 6.3); c.fill();
    c.restore();
  }
  // 번개
  for (const bo of G.bolts) {
    c.strokeStyle = bo.echo ? '#9ff0ff' : '#fff59a'; c.lineWidth = 3; c.globalAlpha = clamp(bo.life / 0.22, 0, 1);
    c.beginPath();
    for (let i = 0; i < bo.pts.length; i++) {
      const p = bo.pts[i];
      if (i === 0) c.moveTo(p.x, p.y);
      else { const q = bo.pts[i - 1]; c.lineTo((p.x + q.x) / 2 + (Math.random() - 0.5) * 12, (p.y + q.y) / 2 + (Math.random() - 0.5) * 12); c.lineTo(p.x, p.y); }
    }
    c.stroke();
  }
  c.globalAlpha = 1;
  c.globalCompositeOperation = 'lighter'; // 빛나는 불꽃
  for (const p of G.fx) {
    c.globalAlpha = clamp(p.life / p.max, 0, 1);
    if (p.ln) { c.strokeStyle = p.col; c.lineWidth = p.r; c.lineCap = 'round'; c.beginPath(); c.moveTo(p.x, p.y); c.lineTo(p.x - p.vx * 0.05, p.y - p.vy * 0.05); c.stroke(); }
    else { c.fillStyle = p.col; c.beginPath(); c.arc(p.x, p.y, p.r, 0, 6.3); c.fill(); }
  }
  c.globalCompositeOperation = 'source-over'; c.globalAlpha = 1;
  for (const t of G.txt) {
    c.globalAlpha = clamp(t.life / t.max * 2, 0, 1);
    label(c, t.s, t.x, t.y - (1 - clamp(t.life / t.max, 0, 1)) * 14, t.col, '#1b1230', t.size * (1 + 0.7 * Math.max(0, 1 - (t.max - t.life) / 0.12)));
  }
  c.globalAlpha = 1;
  c.restore(); // 월드 좌표 끝
  drawScreenFx(c);
  drawOffscreenArrows(c, G);
  if (G.flash > 0) { c.fillStyle = `rgba(255,255,255,${Math.min(0.6, G.flash)})`; c.fillRect(0, 0, W, H); }
  if (G.hurt > 0) { // 맞으면 화면 가장자리가 붉게 번쩍인다
    const a = clamp(G.hurt / 0.45, 0, 1), g = c.createRadialGradient(W / 2, H / 2, H * 0.25, W / 2, H / 2, H * 0.7);
    g.addColorStop(0, 'rgba(255,40,70,0)'); g.addColorStop(1, `rgba(255,40,70,${0.6 * a})`);
    c.fillStyle = g; c.fillRect(0, 0, W, H);
  }
  c.restore();
  drawHud(c);
  const j = S.joy;
  if (j.active && S.scene === 'play') {
    c.strokeStyle = 'rgba(255,255,255,.3)'; c.lineWidth = 3; c.beginPath(); c.arc(j.ox, j.oy, 40, 0, 6.3); c.stroke();
    const dx = j.x - j.ox, dy = j.y - j.oy, l = Math.min(40, Math.hypot(dx, dy)), a = Math.atan2(dy, dx);
    c.fillStyle = 'rgba(255,255,255,.4)'; c.beginPath(); c.arc(j.ox + Math.cos(a) * l, j.oy + Math.sin(a) * l, 17, 0, 6.3); c.fill();
  }
}

// 타이틀 배경: 선택한 챕터의 던전에서 영웅과 메아리가 원을 그리며 걷는다
export function renderTitle(c) {
  const ch = stageChap(S.chapter).ch, cam = { x: (ARENA.w - W) / 2, y: ARENA.h - H - 90 };
  drawBgView(c, ch, cam);
  drawGlow(c, ch, cam);
  drawAmbient(c, ch, cam);
  c.fillStyle = 'rgba(10,5,20,.35)'; c.fillRect(0, 0, W, H);
  const n = Math.max(1, Math.min(4, S.save.echoes[ch].length + 1));
  const items = [];
  for (let i = 0; i < n; i++) {
    const a = S.clock * 0.8 - i * 0.6, cx = W / 2 + Math.cos(a) * 95, cy = 478 + Math.sin(a) * 20;
    items.push({ i, o: { id: i, sprite: CLASSES[S.save.cls].sprite, x: cx + cam.x, y: cy + cam.y, face: Math.sin(a) > 0 ? -1 : 1, phase: S.clock * 7 - i, sp: 1, atk: 0, hit: 0, ang: 0 } });
  }
  c.save(); c.translate(-cam.x, -cam.y);
  items.sort((a, b) => a.o.y - b.o.y).forEach(({ i, o }) => drawChibi(c, o, i === 0 ? PAL_HERO : PAL_ECHO, i === 0 ? 1 : 0.55));
  c.restore();
}
