import { CHAPTERS, CLASSES, ensureDaily } from './data.js';

const KEY = 'echoDungeon.v2';
const OLD_KEY = 'echoDungeon.v1';
const N = CHAPTERS.length;
const arr = (v) => Array.from({ length: N }, () => (typeof v === 'function' ? v() : v));

export function defaultSave() {
  return {
    v: 2, name: '용사', cls: 'sword', gold: 0, unlocked: 1, lastChapter: 0,
    best: arr(0), clears: arr(0), runs: 0, wins: 0, kills: 0,
    echoes: arr(() => []), nemesis: arr(null), friend: arr(null),
    shop: {}, settings: { sfx: true, music: true, vib: true, shake: true },
    daily: null, tutorial: 0,
  };
}

// 저장 데이터가 일부 깨져 있어도 기본값으로 메운다
function normalize(s) {
  const d = defaultSave();
  const out = Object.assign(d, s);
  out.settings = Object.assign(defaultSave().settings, s.settings || {});
  for (const k of ['best', 'clears']) out[k] = arr(0).map((z, i) => (Array.isArray(s[k]) && Number.isFinite(s[k][i]) ? s[k][i] : z));
  out.echoes = arr(0).map((z, i) => (Array.isArray(s.echoes) && Array.isArray(s.echoes[i]) ? s.echoes[i].filter((e) => e && Array.isArray(e.path) && e.path.length >= 4 && Array.isArray(e.picks)) : []));
  out.nemesis = arr(0).map((z, i) => (Array.isArray(s.nemesis) && s.nemesis[i] && s.nemesis[i].type ? s.nemesis[i] : null));
  out.cls = CLASSES[s.cls] ? s.cls : 'sword';
  out.friend = arr(0).map((z, i) => { const f = Array.isArray(s.friend) && s.friend[i]; return f && Array.isArray(f.path) && f.path.length >= 4 && Array.isArray(f.picks) ? f : null; });
  out.shop = typeof s.shop === 'object' && s.shop ? s.shop : {};
  out.unlocked = Math.max(1, out.unlocked | 0); // 열린 스테이지 수 (끝이 없다)
  out.lastChapter = Math.min(out.unlocked - 1, Math.max(-1, out.lastChapter | 0)); // -1 = 무한 던전
  out.gold = Math.max(0, out.gold | 0);
  return out;
}

export function loadSave() {
  try {
    const raw = localStorage.getItem(KEY);
    if (raw) {
      const s = JSON.parse(raw);
      if (s && s.v === 2) return withDaily(normalize(s));
    }
    const old = JSON.parse(localStorage.getItem(OLD_KEY) || 'null');
    if (old && old.v === 1) { // v1 → v2: 기존 메아리와 원수는 1챕터로 옮긴다
      const s = defaultSave();
      s.name = old.name || s.name; s.gold = old.gold | 0; s.runs = old.runs | 0; s.wins = old.wins | 0;
      s.best[0] = old.best | 0;
      s.echoes[0] = Array.isArray(old.echoes) ? old.echoes.map((e) => ({ path: e.path, picks: e.picks })) : [];
      s.nemesis[0] = old.nemesis || null;
      if (s.runs > 0) s.tutorial = 1;
      return withDaily(normalize(s));
    }
  } catch (e) { /* 저장소를 못 쓰거나 깨진 데이터 */ }
  return withDaily(defaultSave());
}
function withDaily(s) { ensureDaily(s); return s; }

export function persist(s) {
  try { localStorage.setItem(KEY, JSON.stringify(s)); return true; } catch (e) { return false; }
}

export function resetSave() {
  try { localStorage.removeItem(KEY); localStorage.removeItem(OLD_KEY); } catch (e) { /* ignore */ }
  return withDaily(defaultSave());
}

// 임무 진행. 새로 완료된 임무 목록을 돌려준다
export function progressMission(s, id, amount) {
  const daily = ensureDaily(s), done = [];
  for (const m of daily.list) {
    if (m.id !== id || m.done || amount <= 0) continue;
    m.prog = Math.min(m.goal, m.prog + amount);
    if (m.prog >= m.goal) { m.done = true; done.push(m); }
  }
  return done;
}
