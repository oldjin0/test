// 한 판의 시뮬레이션. 고정 60Hz로 진행된다.
import { S } from './state.js';
import {
  W, H, ARENA, PICK_EVERY, ENEMIES, BOSSES, stageChap, CARD_BY_ID, nextMidBoss,
  CLASSES, baseStats, applyCard, shopLv, echoSlots, rollCards,
} from './data.js';
import { sfx, playMusic } from './audio.js';
import { haptic } from './native.js';
import { lerp, clamp, mulberry32, dateKey } from './util.js';
import { persist, progressMission } from './save.js';

export const DT = 1 / 60;
export const hooks = { pick: null, resume: null, end: null, revive: null };
const MAX_ENEMIES = 90;

function actor(x, y, id, st, cls) {
  return { id, cls, sprite: CLASSES[cls].sprite, x, y, vx: 0, vy: 0, face: 1, phase: 0, sp: 0, atk: 0, hit: 0, cd: 0.3, ang: 0, bT: 1, pT: 0, st };
}
function heroStats(cls) {
  const st = baseStats(cls);
  st.maxhp += 10 * shopLv('hp');
  st.dmg *= 1 + 0.05 * shopLv('atk');
  st.speed *= 1 + 0.03 * shopLv('spd');
  return st;
}

// k: 스테이지 번호(0부터 끝없이), 음수면 무한 던전
export function startRun(k) {
  const sv = S.save, chap = stageChap(k), ch = chap.ch;
  const hero = actor(ARENA.x + ARENA.w / 2, ARENA.y + ARENA.h * 0.62, 0, heroStats(sv.cls), sv.cls);
  hero.hp = hero.st.maxhp; hero.inv = 0; hero.shieldT = 0; hero.shieldReady = false; hero.isHero = true;
  const recs = sv.echoes[ch].slice(0, echoSlots());
  if (sv.friend[ch]) recs.push(sv.friend[ch]); // 친구 메아리는 슬롯과 따로 한 명 더
  const echoes = recs.map((rec, i) => {
    const cls = CLASSES[rec.cls] ? rec.cls : sv.cls;
    const e = actor(rec.path[0], rec.path[1], i + 1, heroStats(cls), cls);
    Object.assign(e, { path: rec.path, picks: rec.picks, pi: 0, alive: true, fade: 1, isEcho: true, friend: rec.name || null });
    return e;
  });
  S.G = {
    ch, stage: chap.stage, chap, t: 0, tn: 0, tick: 0, hero, echoes, time: chap.time, endless: !!chap.endless, midIdx: 0, mid: null,
    spawnRng: mulberry32(dateKey() * 7 + ch), rng: mulberry32((Math.random() * 4294967296) >>> 0),
    hurt: 0, combo: 0, comboT: 0, comboPop: 0,
    enemies: [], corpses: [], shots: [], ebul: [], fx: [], txt: [], puddles: [], bolts: [], rings: [], coins: [], booms: [],
    rec: [], picks: [], nextPick: PICK_EVERY, pendingPicks: 0, spawnT: 0.8, eliteT: chap.elite - 2, puddleTick: 0,
    boss: null, kills: 0, echoKills: 0, coinsGot: 0, cards: 0, dmgDealt: 0,
    killer: null, shake: 0, stop: 0, stopCd: 0, flash: 0,
    nemSpawned: false, nemKilled: false, nemGold: 0, ended: false, won: false,
    rerolls: shopLv('reroll'), tut: sv.tutorial === 0, endT: 0, result: null,
  };
  updateCam(S.G, true);
  S.scene = 'play';
  playMusic('ch' + ch);
}

// 카메라: 영웅을 따라가되 월드 밖은 보이지 않게 한다
function updateCam(G, snap) {
  const h = G.hero, tx = clamp(h.x - W / 2, ARENA.x, ARENA.x + ARENA.w - W), ty = clamp(h.y - H * 0.55, ARENA.y, ARENA.y + ARENA.h - H);
  if (!G.cam || snap) G.cam = { x: tx, y: ty };
  else { G.cam.x += (tx - G.cam.x) * 0.14; G.cam.y += (ty - G.cam.y) * 0.14; }
}

/* ---------- 입력 ---------- */
function moveVec() {
  const k = S.keys, j = S.joy;
  let x = 0, y = 0;
  if (k.ArrowLeft || k.a) x -= 1;
  if (k.ArrowRight || k.d) x += 1;
  if (k.ArrowUp || k.w) y -= 1;
  if (k.ArrowDown || k.s) y += 1;
  if (x || y) { const l = Math.hypot(x, y); return { x: x / l, y: y / l }; }
  if (j.active) {
    const dx = j.x - j.ox, dy = j.y - j.oy, l = Math.hypot(dx, dy);
    if (l > 5) { const m = Math.min(1, l / 40); return { x: dx / l * m, y: dy / l * m }; }
  }
  return { x: 0, y: 0 };
}

/* ---------- 카드 ---------- */
function openPick() {
  const G = S.G;
  G.choices = rollCards(G.hero.st, G.rng);
  S.scene = 'pick';
  sfx.cards();
  if (hooks.pick) hooks.pick(G.choices);
}
export function reroll() {
  const G = S.G;
  if (!G || G.rerolls <= 0) return null;
  G.rerolls--;
  G.choices = rollCards(G.hero.st, G.rng);
  return G.choices;
}
export function takeCard(id) {
  const G = S.G, h = G.hero;
  applyCard(h.st, id, h);
  if (id === 'purse') G.coinsGot += 15;
  G.picks.push({ t: G.tick, id });
  G.cards++; G.pendingPicks = Math.max(0, G.pendingPicks - 1);
  sfx.pick(); haptic('light');
  floatText(h.x, h.y - 46, CARD_BY_ID[id].name + '!', '#ffe27a', 1.3, 15);
  S.scene = 'play';
  if (hooks.resume) hooks.resume();
}

/* ---------- 전투 ---------- */
function nearest(x, y, range) {
  let best = null, bd = range;
  for (const e of S.G.enemies) {
    if (e.dead || e.z > 20) continue;
    const d = Math.hypot(e.x - x, e.y - y) - e.r - (e.boss ? 70 : 0); // 보스를 우선 노린다
    if (d < bd) { bd = d; best = e; }
  }
  return best;
}
function echoMult() {
  const h = S.G.hero;
  return 0.6 * (1 + 0.35 * h.st.echoAmp) * (1 + 0.08 * shopLv('echo'));
}
function fire(o, tgt, mult) {
  const G = S.G, st = o.st;
  const n = st.shots + (o.isEcho && G.hero.st.legion ? 1 : 0);
  const a = Math.atan2(tgt.y - tgt.r * 0.6 - (o.y - 12), tgt.x - o.x), am = atkMul(o);
  for (let i = 0; i < n; i++) {
    const ang = a + (i - (n - 1) / 2) * 0.17;
    G.shots.push({ x: o.x, y: o.y - 12, vx: Math.cos(ang) * st.shotSpeed, vy: Math.sin(ang) * st.shotSpeed, dmg: st.dmg * mult * am,
      pierce: st.pierce, hit: [], life: st.shotLife, src: o.isHero ? 'hero' : 'echo', st, kind: CLASSES[o.cls].kind, ang });
  }
  if (o.isHero) {
    sfx.shoot();
    const kind = CLASSES[o.cls].kind, mx = o.x + Math.cos(a) * 12, my = o.y - 12 + Math.sin(a) * 12;
    const col = kind === 'orb' ? '#d9b0ff' : kind === 'slash' ? '#ffffff' : '#fff6b0';
    for (let i = 0; i < 3; i++) spark(mx, my, col, a + (G.rng() - 0.5) * 0.7, 160, 0.14, 1.8);
    if (kind === 'slash') G.rings.push({ x: o.x + Math.cos(a) * 30, y: o.y - 12 + Math.sin(a) * 30, r: 6, max: 30, life: 0.16, col: '#fffbe0', round: true });
  }
}
// 법사의 구슬: 맞은 적 주변에 60% 피해
function splash(e, s) {
  const G = S.G, r = s.st.splash;
  G.rings.push({ x: e.x, y: e.y - e.r * 0.5, r: 4, max: r, life: 0.25, col: s.src === 'echo' ? '#8fe9ff' : '#c99cff' });
  for (const o of G.enemies) {
    if (o.dead || o === e || o.z > 20) continue;
    if (Math.hypot(o.x - e.x, o.y - e.y) < r + o.r) hurtEnemy(o, s.dmg * 0.6, s.src, false, true);
  }
}
function strike(e, d, src, st, quiet, dir) {
  const G = S.G;
  let crit = false;
  if (st) {
    const cc = st.crit + (src === 'echo' ? 0.2 * G.hero.st.echoCrit : 0);
    if (G.rng() < cc) { d *= st.critMul; crit = true; }
    if (st.execute && e.hp < e.maxhp * 0.25) d *= 1 + st.execute;
    if (st.bossDmg && e.boss) d *= 1 + st.bossDmg;
    if (st.eliteDmg && e.elite) d *= 1 + st.eliteDmg;
    if (st.sniper || st.brawler) {
      const dist = Math.hypot(e.x - G.hero.x, e.y - G.hero.y);
      if (st.sniper && dist > 150) d *= 1 + 0.5 * st.sniper;
      if (st.brawler && dist < 60) d *= 1 + 0.4 * st.brawler;
    }
    if (st.burn) { e.burnT = 3; e.burnDps = Math.max(e.burnDps || 0, 5 * st.burn * (st.dmg / 10)); }
    if (st.hitHeal && src === 'hero' && G.hero.hp > 0 && G.hero.hp < G.hero.st.maxhp) G.hero.hp = Math.min(G.hero.st.maxhp, G.hero.hp + 0.4 * st.hitHeal);
  }
  hurtEnemy(e, d, src, crit, quiet, dir);
}
// 공격 속도 배율: 학살의 흥분, 과충전, 메아리 가속
function haste(o, dt) {
  const G = S.G, st = o.st;
  let h = 1;
  if (st.killHaste && o.hasteT > 0) { o.hasteT -= dt; h += 0.4 * st.killHaste; }
  if (st.overdrive) { o.odC = (o.odC || 0) + dt; if (o.odC % 13 < 2.5 + st.overdrive * 1.5) h += 0.6; }
  if (!o.isHero && G.hero.st.echoHaste) h += 0.3 * G.hero.st.echoHaste;
  return h;
}
// 이번 공격의 피해 배율: 광전사, 질주 타격, 침착, 반격
function atkMul(o) {
  const st = o.st;
  let m = 1;
  if (st.berserk && o.hp != null && o.hp < st.maxhp * 0.5) m *= 1 + 0.6 * st.berserk;
  if (st.moveDmg && o.sp > 0.3) m *= 1 + 0.25 * st.moveDmg;
  if (st.stillDmg && o.sp < 0.1) m *= 1 + 0.3 * st.stillDmg;
  if (st.revenge && o.revT > 0) m *= 1 + 0.6 * st.revenge;
  return m;
}
function weapon(o, dt, mult) {
  const G = S.G, st = o.st, src = o.isHero ? 'hero' : 'echo';
  if (o.revT > 0) o.revT -= dt;
  o.cd -= dt * haste(o, dt);
  const tgt = nearest(o.x, o.y, st.range);
  if (tgt && o.cd <= 0) { o.cd = st.cd; o.atk = 1; o.face = tgt.x >= o.x ? 1 : -1; fire(o, tgt, mult); }
  o.atk = Math.max(0, o.atk - dt * 5);
  if (st.blades > 0) {
    o.ang += dt * 3.4;
    for (let i = 0; i < st.blades; i++) {
      const a = o.ang + i * Math.PI * 2 / st.blades;
      const bx = o.x + Math.cos(a) * st.bladeR, by = o.y - 10 + Math.sin(a) * st.bladeR;
      for (const e of G.enemies) {
        if (e.dead || e.bt > 0 || e.z > 20) continue;
        if (Math.hypot(e.x - bx, e.y - e.r * 0.6 - by) < e.r + 8 * st.bladeSize) {
          strike(e, st.bladeDmg * (st.dmg / 10) * mult, src, st); e.bt = 0.28;
        }
      }
    }
  }
  if (st.bolt > 0) {
    o.bT -= dt;
    if (o.bT <= 0) {
      const first = nearest(o.x, o.y, 260);
      if (first) { o.bT = Math.max(0.7, 2.2 - 0.35 * st.bolt); chainBolt(o, first, mult); } else o.bT = 0.3;
    }
  }
  if (st.aura || st.auraSlow) { // 오라: 0.25초마다 주변 적에게
    o.auT = (o.auT || 0) - dt;
    if (o.auT <= 0) {
      o.auT = 0.25;
      const R = 52 + 9 * Math.max(st.aura, st.auraSlow);
      for (const e of G.enemies) {
        if (e.dead || e.z > 20 || Math.hypot(e.x - o.x, e.y - o.y) > R + e.r) continue;
        if (st.aura) hurtEnemy(e, 9 * st.aura * (st.dmg / 10) * mult * 0.25 * 4 * 0.25, src, false, true);
        if (st.auraSlow) { e.slowT = Math.max(e.slowT, 0.4); e.slow = Math.max(e.slow || 0, 0.2 + 0.12 * st.auraSlow); }
      }
    }
  }
  if (st.nova) { // 충격파: 주변을 밀쳐낸다
    o.nvT = (o.nvT ?? 2.5) - dt;
    if (o.nvT <= 0) {
      o.nvT = 5.2 - 0.7 * st.nova;
      const R = 88 + 8 * st.nova;
      G.rings.push({ x: o.x, y: o.y - 8, r: 6, max: R, life: 0.45, maxLife: 0.45, col: o.isHero ? 'rgb(255,226,140)' : 'rgb(120,225,255)', wave: true });
      for (let i = 0; i < 18; i++) spark(o.x, o.y - 8, o.isHero ? '#ffe9a8' : '#8fe9ff', i / 18 * 6.283, 200, 0.35, 2);
      for (const e of G.enemies) {
        const dx = e.x - o.x, dy = e.y - o.y, d = Math.hypot(dx, dy) || 1;
        if (e.dead || e.z > 20 || d > R + e.r) continue;
        hurtEnemy(e, 16 * st.nova * (st.dmg / 10) * mult, src, false, true, { x: dx / d, y: dy / d, mul: 1.6 });
        if (!e.boss) { e.kx = (e.kx || 0) + dx / d * 300; e.ky = (e.ky || 0) + dy / d * 300; }
      }
      if (o.isHero) { G.shake = Math.max(G.shake, 3); sfx.boom(); }
    }
  }
  if (st.smite) { // 천벌: 화면의 모든 적에게 번개
    o.smT = (o.smT ?? 3) - dt;
    if (o.smT <= 0) {
      o.smT = 5;
      let n = 0;
      for (const e of G.enemies) {
        if (e.dead || e.z > 20) continue;
        if (n++ < 16) G.bolts.push({ pts: [{ x: e.x + (G.rng() - 0.5) * 20, y: Math.max(ARENA.y - 10, G.cam.y - 10) }, { x: e.x, y: e.y - e.r * 0.6 }], life: 0.3, echo: !o.isHero });
        hurtEnemy(e, 26 * (st.dmg / 10) * mult * (e.boss ? 0.6 : 1), src, false, true);
        for (let i = 0; i < 3; i++) spark(e.x, e.y - e.r * 0.6, '#fff59a', G.rng() * 6.283, 160, 0.3, 2);
      }
      if (o.isHero) { G.flash = Math.max(G.flash, 0.4); G.shake = Math.max(G.shake, 5); sfx.bolt(); haptic('medium'); }
    }
  }
  if (st.poison > 0) {
    o.pT -= dt;
    if (o.pT <= 0 && o.sp > 0.15) {
      o.pT = 0.22;
      G.puddles.push({ x: o.x, y: o.y, r: 12 + 3 * st.poison, life: 2.4, max: 2.4, dps: 9 * st.poison * (st.dmg / 10) * mult, src });
      if (G.puddles.length > 140) G.puddles.shift();
    }
  }
}
function chainBolt(o, first, mult) {
  const G = S.G, st = o.st;
  const n = 1 + st.bolt + st.boltChain;
  const dmg = 14 * (st.dmg / 10) * mult * (1 + 0.25 * (st.bolt - 1));
  const pts = [{ x: o.x, y: o.y - 16 }], seen = [];
  let cur = first;
  for (let k = 0; k < n && cur; k++) {
    seen.push(cur);
    pts.push({ x: cur.x, y: cur.y - cur.r * 0.6 });
    const crit = st.boltCrit || G.rng() < st.crit;
    hurtEnemy(cur, crit ? dmg * st.critMul : dmg, o.isHero ? 'hero' : 'echo', crit);
    let nb = null, bd = 130;
    for (const e of G.enemies) {
      if (e.dead || seen.includes(e) || e.z > 20) continue;
      const d = Math.hypot(e.x - cur.x, e.y - cur.y);
      if (d < bd) { bd = d; nb = e; }
    }
    cur = nb;
  }
  G.bolts.push({ pts, life: 0.22, echo: !o.isHero });
  if (o.isHero) sfx.bolt();
}

export function hurtEnemy(e, d, src, crit, quiet, dir) {
  const G = S.G;
  if (e.dead) return;
  e.hp -= d; e.flash = 0.1; G.dmgDealt += d;
  const echo = src === 'echo', col = echo ? '#8fe9ff' : crit ? '#ffd34a' : '#fff6b0';
  // 맞은 방향: 투사체가 날아간 쪽, 없으면 영웅 반대쪽
  let ux, uy;
  if (dir) { ux = dir.x; uy = dir.y; } else {
    const dx = e.x - G.hero.x, dy = e.y - G.hero.y, l = Math.hypot(dx, dy) || 1; ux = dx / l; uy = dy / l;
  }
  if (!quiet) { // 넉백: 가벼운 놈일수록 멀리, 보스는 거의 안 밀린다
    const kb = (crit ? 150 : 95) * (e.boss ? 0.12 : e.elite ? 0.5 : 1) * Math.min(1.6, 11 / e.r + 0.3) * ((dir && dir.mul) || 1) * (G.hero.st.kbMul || 1);
    e.kx = (e.kx || 0) + ux * kb; e.ky = (e.ky || 0) + uy * kb;
  }
  if (!quiet || crit) {
    if (crit) floatText(e.x + (G.rng() * 12 - 6), e.y - e.r * 1.6 - 8, Math.round(d) + '!', '#ffd34a', 0.8, 19);
    else floatText(e.x + (G.rng() * 10 - 5), e.y - e.r * 1.6 - 6, String(Math.round(d)), echo ? '#8fe9ff' : '#ffffff', 0.55, 12);
  }
  const ay = Math.atan2(uy, ux), py = e.y - e.r * 0.6;
  if (!quiet || crit) G.rings.push({ x: e.x - ux * e.r * 0.5, y: py, star: true, ang: ay, r: 4, max: crit ? 30 : 17, life: crit ? 0.16 : 0.1, col }); // 타격 순간의 섬광
  for (let i = 0, n = quiet ? 1 : crit ? 9 : 4; i < n; i++) spark(e.x, py, col, ay + (G.rng() - 0.5) * (crit ? 2.4 : 1.3), 130 + G.rng() * 120, 0.24, crit ? 2.4 : 1.7);
  if (crit && !echo && G.hero.st.critBoom && G.rng() < 0.55) G.booms.push({ x: e.x, y: py, r: 26 + 8 * G.hero.st.critBoom, dmg: 9 * G.hero.st.critBoom * (G.hero.st.dmg / 10) });
  if (crit) {
    G.rings.push({ x: e.x, y: py, r: 4, max: 30, life: 0.22, col: '#ffd34a', round: true });
    sfx.crit();
    if (G.stopCd <= 0) { G.stop = 0.05; G.stopCd = 0.2; }
    if (!echo) G.shake = Math.max(G.shake, 2.6);
  } else if (!quiet) {
    sfx.hit();
    if (!echo) G.shake = Math.max(G.shake, e.boss ? 1.8 : 0.8);
  }
  for (let i = 0; i < (quiet ? 1 : 2); i++) puff(e.x, py, col, 40, 0.25);
  if (e.boss) G.shake = Math.max(G.shake, 1.4);
  if (e.hp <= 0) killEnemy(e, src);
}
function killEnemy(e, src) {
  const G = S.G, h = G.hero;
  e.dead = true; e.dying = 0; G.corpses.push(e); G.kills++;
  if (src === 'echo') G.echoKills++;
  const col = { bat: '#b58cff', brute: '#ffb15c', mage: '#e9e2c8', boar: '#c98a5a', blob: '#7fc8ff', mini: '#7fc8ff' }[e.type] || '#8de38a';
  for (let i = 0; i < 10; i++) puff(e.x, e.y - e.r * 0.6, col, 90, 0.5);
  sfx.kill();
  // 처치 연출: 퍼지는 고리와 불꽃, 짧은 멈춤과 흔들림, 콤보
  const ky = e.y - e.r * 0.5;
  G.rings.push({ x: e.x, y: ky, r: 6, max: e.r * 2.2 + 16, life: 0.3, col, round: true });
  for (let i = 0, n = e.boss ? 40 : e.elite ? 22 : 12; i < n; i++) spark(e.x, ky, i % 3 ? col : '#ffffff', G.rng() * 6.283, 120 + G.rng() * 160, 0.4, 2);
  if (G.stopCd <= 0 || e.boss) { G.stop = e.boss ? 0.14 : e.elite ? 0.07 : 0.022; G.stopCd = e.boss ? 0.5 : 0.1; }
  if (src !== 'echo') G.shake = Math.max(G.shake, e.boss ? 8 : e.elite ? 4 : 1.8);
  G.combo++; G.comboT = 2.2; G.comboPop = 0.25;
  if (G.combo % 10 === 0) { floatText(h.x, h.y - 60, `${G.combo} COMBO!`, '#ffd34a', 1.1, 17); for (let i = 0; i < 16; i++) spark(h.x, h.y - 20, '#ffd34a', G.rng() * 6.283, 160, 0.45, 2.2); }
  if (h.st.killHaste && src !== 'echo') h.hasteT = 2;
  if (h.st.killHeal && h.hp > 0 && h.hp < h.st.maxhp) h.hp = Math.min(h.st.maxhp, h.hp + h.st.killHeal);
  if (src === 'echo' && h.st.echoHeal && h.hp > 0 && h.hp < h.st.maxhp) { h.hp = Math.min(h.st.maxhp, h.hp + 2 * h.st.echoHeal); floatText(h.x, h.y - 44, '+' + 2 * h.st.echoHeal, '#8fe9ff', 0.6, 12); }
  const baseCoins = e.boss ? (e.mid ? 15 : 30) : e.elite ? 10 + h.st.eliteCoins : e.nem ? 15 : 0.38;
  const cm = baseCoins * (h.st.coinMul || 1);
  const nCoins = Math.floor(cm) + (G.rng() < cm - Math.floor(cm) ? 1 : 0);
  for (let i = 0; i < nCoins; i++) {
    const a = G.rng() * 6.283, v = 40 + G.rng() * 90;
    G.coins.push({ x: e.x, y: e.y - 6, vx: Math.cos(a) * v, vy: Math.sin(a) * v, t: 0, v: 1 });
  }
  if (G.coins.length > 160) G.coins.splice(0, G.coins.length - 160);
  if (h.st.leech && G.rng() < 0.15 * h.st.leech && h.hp > 0 && h.hp < h.st.maxhp) {
    h.hp = Math.min(h.st.maxhp, h.hp + 3); floatText(h.x, h.y - 44, '+3', '#7dff9a', 0.6, 12);
  }
  if (h.st.boom && !e.boss && G.rng() < Math.min(0.9, 0.3 * h.st.boom)) {
    G.booms.push({ x: e.x, y: e.y - e.r * 0.5, r: 36 + 6 * h.st.boom, dmg: 16 * h.st.boom * (h.st.dmg / 10) });
  }
  if (e.type === 'blob' && !e.nem) {
    for (const s of [-1, 1]) if (G.enemies.filter((m) => !m.dead).length < 60) spawnEnemy('mini', e.x + s * 10, e.y);
  }
  if (e.elite) {
    G.pendingPicks++; sfx.chest(); haptic('medium');
    floatText(e.x, e.y - 34, '보물 카드!', '#ffe27a', 1.6, 15);
  }
  if (e.nem) {
    G.nemKilled = true; G.nemGold = 20 * (e.nemLv || 1);
    S.save.nemesis[G.ch] = null;
    G.shake = 7; G.flash = 0.35; haptic('heavy');
    floatText(e.x, e.y - 40, '복수 성공!', '#ff7a8a', 2, 20);
  }
  if (e.mid) {
    G.mid = null; playMusic('ch' + G.ch); G.pendingPicks++; G.shake = 9; G.flash = 0.35; haptic('heavy'); sfx.chest();
    floatText(e.x, e.y - 40, '중간 보스 처치! 보물 카드', '#ffe27a', 2, 16);
  }
  if (e.final) { G.shake = 12; G.flash = 0.6; haptic('heavy'); endRun(true); }
}
function spawnEnemy(type, x, y, extra) {
  const G = S.G, base = ENEMIES[type], chap = G.chap;
  const elite = extra && extra.elite;
  const hp = base.hp * chap.hp * (1 + G.tn / 45) * (elite ? 5 : 1); // tn: 판 길이와 무관하게 0~60으로 환산한 진행도
  const e = Object.assign({
    type, x, y, r: base.r * (elite ? 1.3 : 1), hp, sp: base.sp * (0.9 + G.spawnRng() * 0.25) * (elite ? 0.85 : 1),
    dmg: base.dmg * chap.dmg, seed: G.spawnRng() * 100, flash: 0, bt: 0, dead: false, face: 1, t: 0, z: 0, slowT: 0, slow: 0,
  }, extra || {});
  e.maxhp = e.hp;
  G.enemies.push(e);
  return e;
}
function spawnBoss(id, final, scale) {
  const G = S.G, b = BOSSES[id];
  const hp = (final ? b.hp * (1 + 0.15 * G.echoes.length) : b.hp * 0.5 * scale * (1 + 0.1 * G.echoes.length)) * G.chap.bossHp;
  const e = spawnEnemy('slime', clamp(G.cam.x + W / 2, ARENA.x + 60, ARENA.x + ARENA.w - 60), Math.max(ARENA.y + 60, G.cam.y + 70), {
    boss: true, final, mid: !final, bid: id, pattern: b.pattern, name: b.name, r: b.r, sp: b.sp, dmg: b.dmg * G.chap.dmg, hp,
  });
  e.maxhp = e.hp;
  if (final) G.boss = e;
  G.shake = 10; G.flash = 0.3; sfx.boss(); haptic('heavy');
  return e;
}
// 적은 화면 바로 바깥에서 나타난다 (월드 끝에 걸려 화면 안에 튀어나오는 쪽은 피한다)
function edgePoint() {
  const G = S.G, c = G.cam, m = 36;
  let x = 0, y = 0;
  for (let tries = 0; tries < 8; tries++) {
    const side = Math.floor(G.spawnRng() * 4), u = G.spawnRng();
    if (side === 0) { x = c.x + u * W; y = c.y - m; }
    else if (side === 1) { x = c.x + u * W; y = c.y + H + m; }
    else if (side === 2) { x = c.x - m; y = c.y + u * H; }
    else { x = c.x + W + m; y = c.y + u * H; }
    if (x > ARENA.x + 10 && x < ARENA.x + ARENA.w - 10 && y > ARENA.y + 10 && y < ARENA.y + ARENA.h - 10) return [x, y];
  }
  return [clamp(x, ARENA.x + 12, ARENA.x + ARENA.w - 12), clamp(y, ARENA.y + 12, ARENA.y + ARENA.h - 12)];
}
function edgeSpawn(type, extra) {
  const [x, y] = edgePoint();
  return spawnEnemy(type, x, y, extra);
}
function pickType() {
  const G = S.G;
  const mix = G.chap.mix.filter((m) => G.t >= m[2]);
  let tot = 0;
  for (const m of mix) tot += m[1];
  let r = G.spawnRng() * tot;
  for (const m of mix) { r -= m[1]; if (r <= 0) return m[0]; }
  return mix[0][0];
}
// fx, fy: 때린 쪽 위치 (그 반대로 밀려난다)
function hurtHero(d, src, fx, fy) {
  const G = S.G, h = G.hero;
  if (h.inv > 0 || G.ended) return;
  if (h.st.shield > 0 && h.shieldReady) {
    h.shieldReady = false; h.shieldT = 0; h.inv = 0.5;
    floatText(h.x, h.y - 46, '막음!', '#8fe9ff', 0.8, 14); sfx.block(); haptic('light');
    G.rings.push({ x: h.x, y: h.y - 22, r: 14, max: 52, life: 0.28, col: '#bff4ff', round: true });
    for (let i = 0; i < 14; i++) spark(h.x, h.y - 22, '#cfeeff', G.rng() * 6.283, 190, 0.3, 2);
    return;
  }
  const st = h.st;
  if (st.dodge && G.rng() < Math.min(0.6, st.dodge)) { h.inv = 0.3; floatText(h.x, h.y - 46, '회피!', '#cfe8ff', 0.7, 14); return; }
  const guard = st.echoGuard ? G.echoes.filter((e) => e.alive).length * 0.08 * st.echoGuard : 0;
  d *= 1 - Math.min(0.75, st.armor + guard);
  h.hp -= d; h.inv = st.invT; h.hit = 0.25; G.killer = src; h.revT = 3;
  if (fx != null) { const dx = h.x - fx, dy = h.y - fy, l = Math.hypot(dx, dy) || 1; h.kx = dx / l * 300; h.ky = dy / l * 300; }
  G.shake = Math.max(G.shake, 6); G.flash = Math.max(G.flash, 0.12);
  sfx.hurt(); haptic('medium');
  G.hurt = 0.45; G.stop = Math.max(G.stop, 0.06); G.shake = Math.max(G.shake, 8); G.combo = 0;
  G.rings.push({ x: h.x, y: h.y - 14, r: 6, max: 38, life: 0.25, col: '#ff5d73', round: true });
  for (let i = 0; i < 12; i++) spark(h.x, h.y - 14, '#ff6b81', G.rng() * 6.283, 150, 0.35, 2.2);
  floatText(h.x, h.y - 46, '-' + Math.round(d), '#ff5d73', 0.8, 14);
  if (h.hp <= 0 && h.st.lastStand && !G.lsUsed) { // 질긴 생명력 / 불사조의 깃
    G.lsUsed = true;
    const full = h.st.lastStand >= 2;
    h.hp = Math.ceil(h.st.maxhp * (full ? 1 : 0.35)); h.inv = 2.5;
    G.rings.push({ x: h.x, y: h.y - 14, r: 8, max: full ? 170 : 110, life: 0.5, col: full ? '#ff9a4a' : '#ffe27a', round: true });
    for (let i = 0; i < 34; i++) spark(h.x, h.y - 16, i % 2 ? '#ffb347' : '#fff3c0', G.rng() * 6.283, 240, 0.55, 2.4);
    if (full) for (const e of G.enemies) if (!e.dead && Math.hypot(e.x - h.x, e.y - h.y) < 170) { hurtEnemy(e, 60 * (h.st.dmg / 10), 'hero', false, true); e.burnT = 3; e.burnDps = 12; }
    G.flash = 0.5; G.shake = 8;
    floatText(h.x, h.y - 52, full ? '불사조의 부활!' : '다시 일어선다!', '#ffd34a', 1.5, 18);
    sfx.win(); haptic('heavy');
    return;
  }
  if (h.hp <= 0) {
    // 판마다 한 번, 광고를 보고 일어설 기회를 준다 (게임이 멈춘 채로 기다린다)
    if (!G.revived && hooks.revive && G.t > 5) { G.revived = true; h.hp = 0; S.scene = 'revive'; S.joy.active = false; hooks.revive(); }
    else endRun(false);
  }
}

/* ---------- 이펙트 ---------- */
// 방향이 있는 불꽃(선 모양 파티클)
function spark(x, y, col, ang, spd, life, w) {
  const G = S.G;
  if (G.fx.length > 280) return; // 입자 상한: 화면이 꽉 차도 휴대폰에서 프레임이 떨어지지 않게
  const v = spd * (0.6 + G.rng() * 0.7);
  G.fx.push({ x, y, vx: Math.cos(ang) * v, vy: Math.sin(ang) * v, life, max: life, col, r: w || 1.6, ln: true });
}
function puff(x, y, col, sp, life) {
  const G = S.G;
  if (G.fx.length > 220) return;
  const a = G.rng() * 6.283, v = sp * (0.4 + G.rng() * 0.6);
  G.fx.push({ x, y, vx: Math.cos(a) * v, vy: Math.sin(a) * v - 20, life, max: life, col, r: 2 + G.rng() * 3 });
}
export function floatText(x, y, s, col, life, size) {
  const G = S.G;
  if (G.txt.length > 40) G.txt.shift();
  G.txt.push({ x, y, s, col, life, max: life, size: size || 12 });
}

/* ---------- 보스 ---------- */
function bossLogic(e, dt, spMul) {
  const G = S.G, h = G.hero;
  let pat = e.pattern;
  if (pat === 'all') pat = ['radial', 'jump', 'lich'][Math.floor(e.t / 7) % 3];
  e.curPat = pat;
  const rage = e.hp < e.maxhp * 0.5;
  const dx = h.x - e.x, dy = h.y - e.y, d = Math.hypot(dx, dy) || 1;
  if (pat !== 'jump' && e.js && e.js !== 'walk') { e.js = 'walk'; e.z = 0; } // 패턴이 바뀌면 점프를 끝낸다

  if (pat === 'jump') {
    if (!e.js) { e.js = 'walk'; e.jt = 2.2; }
    e.jt -= dt;
    if (e.js === 'walk') {
      e.x += dx / d * e.sp * spMul * dt; e.y += dy / d * e.sp * spMul * dt;
      if (e.jt <= 0) { e.js = 'crouch'; e.jt = 0.5; }
    } else if (e.js === 'crouch') {
      if (e.jt <= 0) {
        e.js = 'air'; e.jt = 0.8; e.sx = e.x; e.sy = e.y;
        e.tx = clamp(h.x, ARENA.x + 40, ARENA.x + ARENA.w - 40); e.ty = clamp(h.y, ARENA.y + 60, ARENA.y + ARENA.h - 30);
      }
    } else if (e.js === 'air') {
      const k = clamp(1 - e.jt / 0.8, 0, 1);
      e.x = lerp(e.sx, e.tx, k); e.y = lerp(e.sy, e.ty, k); e.z = Math.sin(k * Math.PI) * 110;
      if (e.jt <= 0) {
        e.z = 0; e.js = 'walk'; e.jt = rage ? 1.3 : 2.1;
        G.shake = 9; sfx.land(); haptic('heavy');
        G.rings.push({ x: e.x, y: e.y, r: 10, max: 70, life: 0.35 });
        const n = rage ? 16 : 12, off = G.rng() * 6.28;
        for (let i = 0; i < n; i++) {
          const a = off + i * Math.PI * 2 / n;
          G.ebul.push({ x: e.x, y: e.y - 10, vx: Math.cos(a) * 100, vy: Math.sin(a) * 100, r: 5.5, life: 6, dmg: 10 * G.chap.dmg, src: 'boss', col: e.bid === 'frost' ? '#9fe6ff' : '#7dff9a' });
        }
        if (Math.hypot(h.x - e.x, h.y - e.y) < e.r + 26) hurtHero(e.dmg, 'boss', e.x, e.y);
        if (e.bid === 'slimeking') for (const s of [-1, 1]) if (G.enemies.length < MAX_ENEMIES) spawnEnemy('mini', e.x + s * 30, e.y + 10);
      }
    }
  } else if (pat === 'lich') {
    const want = d > 170 ? 1 : d < 130 ? -0.8 : 0.15;
    e.x += dx / d * e.sp * want * spMul * dt; e.y += dy / d * e.sp * want * spMul * dt;
    e.ft = (e.ft == null ? 1.2 : e.ft) - dt;
    if (e.ft <= 0) {
      e.ft = rage ? 1.25 : 1.85;
      const n = rage ? 7 : 5, a = Math.atan2(dy, dx);
      for (let i = 0; i < n; i++) {
        const aa = a + (i - (n - 1) / 2) * 0.2;
        G.ebul.push({ x: e.x, y: e.y - 26, vx: Math.cos(aa) * 125, vy: Math.sin(aa) * 125, r: 5, life: 5, dmg: 10 * G.chap.dmg, src: 'boss', col: '#c99cff' });
      }
      sfx.enemyShot();
    }
    e.sumT = (e.sumT == null ? 6 : e.sumT) - dt;
    if (e.sumT <= 0) {
      e.sumT = 8;
      const mages = G.enemies.filter((m) => m.type === 'mage' && !m.dead).length;
      for (let i = 0; i < 2; i++) if (mages + i < 5) spawnEnemy('mage', e.x + (i ? 30 : -30), e.y + 20);
    }
    e.tpT = (e.tpT == null ? 9 : e.tpT) - dt;
    if (e.tpT <= 0) {
      e.tpT = 9;
      for (let i = 0; i < 14; i++) puff(e.x, e.y - 20, '#b99cff', 120, 0.5);
      let nx = e.x, ny = e.y;
      for (let tries = 0; tries < 12; tries++) {
        nx = clamp(h.x + (G.rng() - 0.5) * 520, ARENA.x + 50, ARENA.x + ARENA.w - 50); ny = clamp(h.y + (G.rng() - 0.5) * 640, ARENA.y + 70, ARENA.y + ARENA.h - 70);
        if (Math.hypot(nx - h.x, ny - h.y) > 140) break;
      }
      e.x = nx; e.y = ny;
      for (let i = 0; i < 14; i++) puff(e.x, e.y - 20, '#b99cff', 120, 0.5);
    }
  } else { // radial
    e.x += dx / d * e.sp * spMul * dt; e.y += dy / d * e.sp * spMul * dt;
    e.ft = (e.ft == null ? 1.2 : e.ft) - dt;
    if (e.ft <= 0) {
      e.ft = rage ? 1.5 : 2.3;
      const n = rage ? 14 : 10, off = e.t;
      for (let i = 0; i < n; i++) {
        const a = off + i * Math.PI * 2 / n;
        G.ebul.push({ x: e.x, y: e.y - 20, vx: Math.cos(a) * 95, vy: Math.sin(a) * 95, r: 5, life: 6, dmg: 10 * G.chap.dmg, src: 'boss', col: '#ff7a5d' });
      }
      if (rage) {
        const a = Math.atan2(dy, dx);
        for (let k = -1; k <= 1; k++) G.ebul.push({ x: e.x, y: e.y - 20, vx: Math.cos(a + k * 0.2) * 150, vy: Math.sin(a + k * 0.2) * 150, r: 5, life: 5, dmg: 10 * G.chap.dmg, src: 'boss', col: '#ffd34a' });
      }
      sfx.enemyShot();
    }
  }
}

/* ---------- 한 틱 ---------- */
export function step() {
  const G = S.G, h = G.hero, dt = DT;
  G.t += dt; G.tick++;
  G.tn = G.endless ? G.t * 0.67 : G.t * 60 / G.time;
  if (G.stopCd > 0) G.stopCd -= dt;

  // 영웅 이동 (속도 보간으로 쫀득하게)
  const mv = moveVec();
  h.vx = lerp(h.vx, mv.x * h.st.speed, 0.25); h.vy = lerp(h.vy, mv.y * h.st.speed, 0.25);
  if (h.kx || h.ky) { h.vx += h.kx * 0.2; h.vy += h.ky * 0.2; const k = Math.max(0, 1 - dt * 12); h.kx *= k; h.ky *= k; if (Math.abs(h.kx) + Math.abs(h.ky) < 5) h.kx = h.ky = 0; }
  h.x = clamp(h.x + h.vx * dt, ARENA.x + 10, ARENA.x + ARENA.w - 10);
  h.y = clamp(h.y + h.vy * dt, ARENA.y + 30, ARENA.y + ARENA.h - 8);
  updateCam(G);
  const spd = Math.hypot(h.vx, h.vy);
  h.sp = clamp(spd / h.st.speed, 0, 1);
  h.phase += spd * dt * 0.115;
  if (Math.abs(h.vx) > 8) h.face = h.vx > 0 ? 1 : -1;
  if (h.sp > 0.5 && G.tick % 10 === 0) puff(h.x, h.y + 3, '#cfc8b0', 18, 0.28); // 달릴 때 먼지
  if (h.st.regen && h.hp > 0 && h.hp < h.st.maxhp) h.hp = Math.min(h.st.maxhp, h.hp + h.st.regen * dt);
  if (h.inv > 0) h.inv -= dt;
  if (h.hit > 0) h.hit -= dt;
  if (h.st.shield > 0 && !h.shieldReady) { h.shieldT += dt; if (h.shieldT >= 12 - 2 * h.st.shield - 2.5 * h.st.shieldFast) h.shieldReady = true; }
  if (G.tick % 2 === 0 && G.rec.length < 18000) G.rec.push(Math.round(h.x), Math.round(h.y)); // 최대 5분
  weapon(h, dt, 1);

  // 메아리: 녹화된 경로를 걷고, 그 판에서 고른 카드를 같은 순간에 다시 얻는다
  const em = echoMult();
  for (const e of G.echoes) {
    if (!e.alive) { e.fade = Math.max(0, e.fade - dt); continue; }
    const f = G.t * 30, n = e.path.length / 2;
    if (f >= n - 1) { e.alive = false; for (let i = 0; i < 8; i++) puff(e.x, e.y - 16, '#8fe9ff', 60, 0.5); continue; }
    const i = Math.floor(f), k = f - i;
    const nx = lerp(e.path[i * 2], e.path[i * 2 + 2], k), ny = lerp(e.path[i * 2 + 1], e.path[i * 2 + 3], k);
    const dx = nx - e.x, dy = ny - e.y, d = Math.hypot(dx, dy);
    e.x = nx; e.y = ny; e.sp = clamp(d / dt / 125, 0, 1); e.phase += d * 0.115;
    if (Math.abs(dx) > 0.2) e.face = dx > 0 ? 1 : -1;
    while (e.pi < e.picks.length && e.picks[e.pi].t <= G.tick) { applyCard(e.st, e.picks[e.pi].id, null); e.pi++; }
    weapon(e, dt, em);
  }

  // 카드 선택
  if (G.t >= G.nextPick && G.nextPick < G.time) { G.nextPick += PICK_EVERY; G.pendingPicks++; }
  if (G.pendingPicks > 0) { openPick(); return; }

  // 스폰
  const bossTime = G.t >= G.time;
  G.spawnT -= dt;
  if (G.spawnT <= 0) {
    G.spawnT = bossTime ? 2.6 : Math.max(0.3, (1.05 - G.tn * 0.011) / G.chap.rate);
    if (G.enemies.length < (bossTime ? 14 : MAX_ENEMIES)) edgeSpawn(pickType());
    if (G.tn > 35 && !bossTime && G.enemies.length < MAX_ENEMIES) edgeSpawn(pickType());
    if (G.endless && G.t > 80 && G.enemies.length < MAX_ENEMIES) edgeSpawn(pickType());
  }
  G.eliteT -= dt;
  if (G.eliteT <= 0 && !bossTime) { G.eliteT = G.chap.elite; edgeSpawn(pickType(), { elite: true }); }
  const nem = S.save.nemesis[G.ch];
  if (nem && !G.nemSpawned && G.t >= 25) {
    G.nemSpawned = true;
    const base = ENEMIES[nem.type] || ENEMIES.brute;
    edgeSpawn(ENEMIES[nem.type] ? nem.type : 'brute', {
      nem: true, nemLv: nem.lvl, hp: base.hp * G.chap.hp * (4 + nem.lvl * 1.5), r: base.r * 1.45,
      label: `${S.save.name}의 원수 Lv.${nem.lvl}`, dmg: base.dmg * G.chap.dmg * 1.3,
    });
    floatText(h.x, h.y - 64, '☠ 원수가 나타났다!', '#ff7a8a', 2, 16);
    haptic('medium');
  }
  if (bossTime && !G.boss) {
    spawnBoss(G.chap.boss, true, 1);
    for (const e of G.enemies) { // 보스의 포효에 잡몹이 흩어진다 (원수와 보스는 남는다)
      if (e.boss || e.nem) continue;
      e.dead = true;
      for (let i = 0; i < 4; i++) puff(e.x, e.y - e.r * 0.6, '#ffffff', 70, 0.4);
    }
    G.ebul = [];
    floatText(G.cam.x + W / 2, G.cam.y + 160, `${G.boss.name} 등장!`, '#ff5d73', 2.2, 20);
    playMusic('boss');
  }
  const nm = nextMidBoss(G.chap, G.midIdx);
  if (nm && !bossTime && !G.mid && G.t >= nm.t) { // 중간 보스
    G.midIdx++;
    const e = spawnBoss(nm.id, false, nm.scale);
    G.mid = e; playMusic('mid');
    floatText(G.cam.x + W / 2, G.cam.y + 160, `중간 보스 ${e.name}!`, '#ffb15c', 2, 18);
  }

  // 투사체
  for (const s of G.shots) {
    s.x += s.vx * dt; s.y += s.vy * dt; s.life -= dt;
    if (s.kind === 'orb' && G.tick % 2 === 0 && G.fx.length < 260) G.fx.push({ x: s.x, y: s.y, vx: (G.rng() - 0.5) * 24, vy: (G.rng() - 0.5) * 24, life: 0.28, max: 0.28, col: s.src === 'echo' ? '#8fe9ff' : '#b88cff', r: 2.6 });
    if (s.st.homing) { // 유도: 가까운 적 쪽으로 천천히 휘어진다
      let t = null, bd = 190;
      for (const e of G.enemies) { if (e.dead || e.z > 20 || s.hit.includes(e)) continue; const d = Math.hypot(e.x - s.x, e.y - e.r * 0.6 - s.y); if (d < bd) { bd = d; t = e; } }
      if (t) {
        const sp = Math.hypot(s.vx, s.vy), cur = Math.atan2(s.vy, s.vx), want = Math.atan2(t.y - t.r * 0.6 - s.y, t.x - s.x);
        let df = want - cur; while (df > Math.PI) df -= 6.283; while (df < -Math.PI) df += 6.283;
        const na = cur + clamp(df, -s.st.homing * 3.2 * dt, s.st.homing * 3.2 * dt);
        s.vx = Math.cos(na) * sp; s.vy = Math.sin(na) * sp; s.ang = na;
      }
    }
    for (const e of G.enemies) {
      if (e.dead || s.dead || e.z > 20 || s.hit.includes(e)) continue;
      if (Math.hypot(e.x - s.x, e.y - e.r * 0.6 - s.y) < e.r + s.st.hitR) {
        s.hit.push(e);
        if (s.st.frost) { e.slowT = 1.3; e.slow = 0.3 * s.st.frost; }
        const sp = Math.hypot(s.vx, s.vy) || 1;
        strike(e, s.dmg, s.src, s.st, false, { x: s.vx / sp, y: s.vy / sp, mul: s.kind === 'slash' ? 1.8 : s.kind === 'arrow' ? 0.8 : 1 });
        if (s.st.splash) splash(e, s);
        let bounced = false;
        if (s.st.ricochet && (s.rico || 0) < s.st.ricochet) { // 도탄: 아직 안 맞은 가까운 적에게 튕긴다
          let nb = null, bd = 150;
          for (const o of G.enemies) { if (o.dead || o.z > 20 || s.hit.includes(o)) continue; const d = Math.hypot(o.x - s.x, o.y - s.y); if (d < bd) { bd = d; nb = o; } }
          if (nb) {
            const sp = Math.hypot(s.vx, s.vy), na = Math.atan2(nb.y - nb.r * 0.6 - s.y, nb.x - s.x);
            s.vx = Math.cos(na) * sp; s.vy = Math.sin(na) * sp; s.ang = na; s.rico = (s.rico || 0) + 1; s.life = Math.max(s.life, 0.5); bounced = true;
            for (let i = 0; i < 4; i++) spark(s.x, s.y, '#ffffff', na + (G.rng() - 0.5) * 2, 150, 0.15, 1.6);
          }
        }
        if (!bounced && s.pierce-- <= 0) s.dead = true;
      }
    }
    if (s.life <= 0 || s.x < ARENA.x - 10 || s.x > ARENA.x + ARENA.w + 10 || s.y < ARENA.y - 20 || s.y > ARENA.y + ARENA.h + 10) s.dead = true;
  }
  G.shots = G.shots.filter((s) => !s.dead);

  // 독 웅덩이 (0.25초마다)
  G.puddleTick -= dt;
  if (G.puddleTick <= 0 && G.puddles.length) {
    G.puddleTick = 0.25;
    for (const p of G.puddles) for (const e of G.enemies) {
      if (!e.dead && e.z < 20 && Math.hypot(e.x - p.x, e.y - p.y) < p.r + e.r * 0.6) hurtEnemy(e, p.dps * 0.25, p.src, false, true);
    }
  }
  for (const p of G.puddles) p.life -= dt;
  G.puddles = G.puddles.filter((p) => p.life > 0);

  // 폭발 (연쇄 가능)
  if (G.booms.length) {
    const bs = G.booms; G.booms = [];
    for (const b of bs) {
      G.rings.push({ x: b.x, y: b.y, r: 6, max: b.r, life: 0.3, col: '#ffb15c' });
      for (let i = 0; i < 6; i++) puff(b.x, b.y, '#ffd34a', 110, 0.35);
      for (const e of G.enemies) if (!e.dead && Math.hypot(e.x - b.x, e.y - b.y) < b.r + e.r) hurtEnemy(e, b.dmg, 'hero', false, true);
    }
    sfx.boom();
  }

  // 적
  for (const e of G.enemies) {
    if (e.dead) continue;
    e.t += dt;
    if (e.kx || e.ky) { // 넉백: 빠르게 줄어드는 밀림
      e.x = clamp(e.x + e.kx * dt, ARENA.x + 4, ARENA.x + ARENA.w - 4); e.y = clamp(e.y + e.ky * dt, ARENA.y + 8, ARENA.y + ARENA.h - 4);
      const k = Math.max(0, 1 - dt * 9); e.kx *= k; e.ky *= k;
      if (Math.abs(e.kx) + Math.abs(e.ky) < 4) e.kx = e.ky = 0;
    }
    if (e.flash > 0) e.flash -= dt;
    if (e.burnT > 0) { // 불: 0.5초마다 피해
      e.burnT -= dt; e.burnAcc = (e.burnAcc || 0) + dt;
      if (e.burnAcc >= 0.5) { e.burnAcc = 0; for (let i = 0; i < 2; i++) spark(e.x, e.y - e.r, '#ff9a3a', -1.57 + (G.rng() - 0.5), 70, 0.35, 2); hurtEnemy(e, e.burnDps * 0.5, 'hero', false, true); if (e.dead) continue; }
    }
    if (e.bt > 0) e.bt -= dt;
    if (e.slowT > 0) e.slowT -= dt;
    const spMul = e.slowT > 0 ? 1 - e.slow : 1;
    const dx = h.x - e.x, dy = h.y - e.y, d = Math.hypot(dx, dy) || 1;
    e.face = dx >= 0 ? 1 : -1;
    if (e.boss) bossLogic(e, dt, spMul);
    else if (e.type === 'mage') {
      const want = d > 170 ? 1 : d < 115 ? -0.7 : 0;
      e.x += dx / d * e.sp * want * spMul * dt; e.y += dy / d * e.sp * want * spMul * dt;
      e.ft = (e.ft == null ? 1.2 + G.rng() * 1.5 : e.ft) - dt;
      e.cast = e.ft < 0.45;
      if (e.ft <= 0 && d < 300) {
        e.ft = 2.7;
        G.ebul.push({ x: e.x, y: e.y - 18, vx: dx / d * 115, vy: dy / d * 115, r: 4.5, life: 5, dmg: e.dmg, src: e.nem ? 'nem' : 'mage', col: '#c99cff' });
        sfx.enemyShot();
      }
    } else if (e.type === 'boar') {
      if (!e.cs) { e.cs = 'walk'; e.ct = 1.5 + G.rng() * 1.5; }
      e.ct -= dt;
      if (e.cs === 'walk') {
        e.x += dx / d * e.sp * spMul * dt; e.y += dy / d * e.sp * spMul * dt;
        if (e.ct <= 0 && d < 210) { e.cs = 'wind'; e.ct = 0.65; e.cdx = dx / d; e.cdy = dy / d; }
      } else if (e.cs === 'wind') {
        if (e.ct <= 0) { e.cs = 'dash'; e.ct = 0.55; }
      } else {
        e.x += e.cdx * 240 * spMul * dt; e.y += e.cdy * 240 * spMul * dt;
        if (e.ct <= 0) { e.cs = 'walk'; e.ct = 2.4 + G.rng() * 1.2; }
      }
    } else {
      let sp = e.sp * spMul;
      if (e.type === 'bat') sp *= 1 + 0.5 * Math.sin(e.t * 5 + e.seed);
      e.x += dx / d * sp * dt; e.y += dy / d * sp * dt;
    }
    e.x = clamp(e.x, ARENA.x + 4, ARENA.x + ARENA.w - 4);
    e.y = clamp(e.y, ARENA.y + 8, ARENA.y + ARENA.h - 2);
    if (e.z < 20 && d < e.r + 9) {
      const thorn = h.st.thorns && h.inv <= 0 ? h.st.thorns : 0;
      hurtHero(e.dmg, e.boss ? 'boss' : e.nem ? 'nem' : e.type, e.x, e.y);
      if (thorn) hurtEnemy(e, 22 * thorn * (h.st.dmg / 10), 'hero', false, true);
      if (!e.boss) { e.x -= dx / d * 14; e.y -= dy / d * 14; }
    }
  }
  for (let i = 0; i < G.enemies.length; i++) { // 겹침 해소
    const a = G.enemies[i];
    if (a.dead || a.boss) continue;
    for (let j = i + 1; j < G.enemies.length; j++) {
      const b = G.enemies[j];
      if (b.dead || b.boss) continue;
      const dx = b.x - a.x, dy = b.y - a.y, m = (a.r + b.r) * 0.8;
      if (Math.abs(dx) > m || Math.abs(dy) > m) continue;
      const d = Math.hypot(dx, dy);
      if (d > 0 && d < m) { const k = (m - d) / 2 / d; a.x -= dx * k; a.y -= dy * k; b.x += dx * k; b.y += dy * k; }
    }
  }
  G.enemies = G.enemies.filter((e) => !e.dead);

  // 적 탄환
  for (const b of G.ebul) {
    b.x += b.vx * dt; b.y += b.vy * dt; b.life -= dt;
    if (Math.hypot(b.x - h.x, b.y - (h.y - 12)) < b.r + 7) { hurtHero(b.dmg, b.src, b.x - b.vx, b.y - b.vy); b.life = 0; }
  }
  G.ebul = G.ebul.filter((b) => b.life > 0 && b.x > ARENA.x - 10 && b.x < ARENA.x + ARENA.w + 10 && b.y > ARENA.y - 10 && b.y < ARENA.y + ARENA.h + 10);

  updateCoins(dt);
  updateFx(dt);
}

function updateCoins(dt) {
  const G = S.G, h = G.hero;
  const R = 46 + 32 * h.st.magnet;
  for (const c of G.coins) {
    c.t += dt;
    if (c.t < 0.4) { c.x += c.vx * dt; c.y += c.vy * dt; c.vx *= 0.9; c.vy *= 0.9; }
    const dx = h.x - c.x, dy = h.y - 8 - c.y, d = Math.hypot(dx, dy) || 1;
    if (c.t > 0.3 && (d < R || c.mag)) c.mag = true;
    if (c.mag) { const s = Math.min(d, (220 + c.t * 120) * dt); c.x += dx / d * s; c.y += dy / d * s; }
    if (d < 12) { c.dead = true; G.coinsGot += c.v; sfx.coin(); if (h.st.coinHeal && h.hp > 0 && h.hp < h.st.maxhp) h.hp = Math.min(h.st.maxhp, h.hp + h.st.coinHeal); }
  }
  G.coins = G.coins.filter((c) => !c.dead);
}
export function updateFx(dt) {
  const G = S.G;
  for (const e of G.corpses) e.dying += dt;
  G.corpses = G.corpses.filter((e) => e.dying < (e.boss ? 0.9 : 0.35));
  for (const p of G.fx) {
    p.x += p.vx * dt; p.y += p.vy * dt; p.life -= dt;
    if (p.ln) { const k = Math.max(0, 1 - dt * 4.5); p.vx *= k; p.vy *= k; } else p.vy += 200 * dt;
  }
  G.hurt = Math.max(0, G.hurt - dt); G.comboPop = Math.max(0, G.comboPop - dt);
  if (G.comboT > 0 && (G.comboT -= dt) <= 0) G.combo = 0;
  G.fx = G.fx.filter((p) => p.life > 0);
  for (const t of G.txt) { t.y -= 26 * dt; t.life -= dt; }
  G.txt = G.txt.filter((t) => t.life > 0);
  for (const b of G.bolts) b.life -= dt;
  G.bolts = G.bolts.filter((b) => b.life > 0);
  for (const r of G.rings) { r.life -= dt; r.r += (r.max - r.r) * Math.min(1, dt * 14); }
  G.rings = G.rings.filter((r) => r.life > 0);
  G.shake = Math.max(0, G.shake - dt * 24);
  G.flash = Math.max(0, G.flash - dt * 2.5);
}

// 부활: 체력 절반, 잠깐 무적, 주변 적과 탄을 밀어낸다
export function revive() {
  const G = S.G, h = G.hero;
  if (!G || S.scene !== 'revive') return;
  h.hp = Math.ceil(h.st.maxhp * 0.5); h.inv = 2.5; h.hit = 0;
  G.ebul.length = 0;
  for (const e of G.enemies) {
    const dx = e.x - h.x, dy = e.y - h.y, d = Math.hypot(dx, dy) || 1;
    if (d < 140 && !e.boss) { e.kx = dx / d * 420; e.ky = dy / d * 420; }
  }
  G.rings.push({ x: h.x, y: h.y - 14, r: 8, max: 150, life: 0.45, col: '#ffe27a', round: true });
  for (let i = 0; i < 30; i++) spark(h.x, h.y - 16, i % 2 ? '#ffe27a' : '#ffffff', G.rng() * 6.283, 220, 0.5, 2.4);
  G.flash = 0.5; G.shake = 6;
  floatText(h.x, h.y - 50, '부활!', '#ffe27a', 1.4, 20);
  S.scene = 'play';
}

/* ---------- 판 종료 ---------- */
export function endRun(won, abandoned) {
  const G = S.G, sv = S.save, ch = G.ch, lvl = Math.max(0, G.stage) + 1; // lvl: 보상·점수 배율
  if (G.ended) return;
  G.ended = true; G.won = won;
  S.scene = 'ending'; G.endT = 0;
  for (const c of G.coins) G.coinsGot += c.v; // 남은 코인은 자동으로 줍는다
  G.coins = [];

  // 이번 판을 메아리로 박제
  if (!abandoned && G.rec.length >= 60) {
    sv.echoes[ch].unshift({ path: G.rec, picks: G.picks, cls: G.hero.cls, wv: 2 });
    sv.echoes[ch] = sv.echoes[ch].slice(0, echoSlots());
  }
  // 쓰러졌다면 나를 쓰러뜨린 놈이 내 이름을 얻는다
  let nemNew = null;
  if (!won && !abandoned) {
    const k = G.killer || 'slime', prev = sv.nemesis[ch];
    if (k === 'nem' && prev) prev.lvl = Math.min(5, prev.lvl + 1);
    else sv.nemesis[ch] = { type: ENEMIES[k] && k !== 'mini' ? k : 'brute', lvl: 1 };
    nemNew = sv.nemesis[ch];
  }
  const greed = 1 + 0.1 * shopLv('greed');
  const clearBonus = won ? 50 * lvl : 0;
  const cap = G.endless ? 300 : G.time;
  const surviveBonus = Math.floor(Math.min(G.t, cap) / 3) * (1 + (G.endless ? 2.5 : (lvl - 1) * 0.5));
  const gold = Math.round((G.coinsGot + clearBonus + G.nemGold + surviveBonus) * greed);
  const score = G.kills * 10 + Math.floor(Math.min(G.t, cap)) * 2 + (won ? 500 * lvl : 0);
  const newBest = score > sv.best[ch];
  sv.best[ch] = Math.max(sv.best[ch], score);
  sv.gold += gold; sv.runs++; sv.kills += G.kills;
  let unlocked = false;
  if (won) {
    sv.wins++; sv.clears[ch]++;
    if (G.stage >= 0 && sv.unlocked < G.stage + 2) { sv.unlocked = G.stage + 2; unlocked = true; }
  }
  const done = [
    ...progressMission(sv, 'kill', G.kills), ...progressMission(sv, 'runs', 1),
    ...progressMission(sv, 'coins', G.coinsGot), ...progressMission(sv, 'echokill', G.echoKills),
    ...progressMission(sv, 'cards', G.cards),
    ...(won ? progressMission(sv, 'boss', 1) : []), ...(G.nemKilled ? progressMission(sv, 'nem', 1) : []),
  ];
  const firstRun = sv.tutorial === 0;
  sv.tutorial = 1;
  persist(sv);

  G.result = {
    won, abandoned: !!abandoned, ch, stage: G.stage, t: G.t, kills: G.kills, echoKills: G.echoKills, score, newBest, gold, coins: G.coinsGot,
    bossLeft: G.boss && !won ? Math.max(1, Math.ceil(G.boss.hp / G.boss.maxhp * 100)) : 0,
    time: G.time, endless: G.endless, reachedBoss: !!G.boss, nemNew, nemKilled: G.nemKilled, unlocked, missions: done, firstRun,
    echoCount: sv.echoes[ch].length,
  };
  if (won) sfx.win(); else sfx.lose();
  playMusic('title');
  setTimeout(() => { if (S.G === G && hooks.end) hooks.end(G.result); }, abandoned ? 0 : won ? 1300 : 800);
}
