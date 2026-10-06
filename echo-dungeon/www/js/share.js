// 메아리 코드: 한 판의 움직임과 고른 카드를 글자로 바꿔 친구와 주고받는다.
// 받은 코드는 남이 만든 입력이므로 모든 값을 검사하고, 범위를 벗어나면 거절한다.
import { ARENA, OLD_TO_NEW, CARD_BY_ID, CLASSES, CHAPTERS } from './data.js';

const PRE = 'ED1.'; // deflate 압축
const PRE_RAW = 'ED0.'; // 압축을 못 쓰는 환경
const MAX_POINTS = 18000; // 녹화 상한(5분)과 같다

const b64 = (bytes) => { let s = ''; for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000)); return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''); };
const unb64 = (s) => { const t = atob(s.replace(/-/g, '+').replace(/_/g, '/')); const u = new Uint8Array(t.length); for (let i = 0; i < t.length; i++) u[i] = t.charCodeAt(i); return u; };
const pipe = async (bytes, stream) => new Uint8Array(await new Response(new Blob([bytes]).stream().pipeThrough(stream)).arrayBuffer());

export async function encodeEcho(rec, name, ch) {
  const p = rec.path, d = [p[0], p[1]];
  for (let i = 2; i < p.length; i++) d.push(p[i] - p[i - 2]); // 앞 점과의 차이만 적는다 (작은 수라 잘 줄어든다)
  const json = JSON.stringify({ w: 2, n: name, c: rec.cls, h: ch, k: rec.picks.map((x) => [x.t, x.id]), d });
  const raw = new TextEncoder().encode(json);
  if (typeof CompressionStream === 'undefined') return PRE_RAW + b64(raw);
  return PRE + b64(await pipe(raw, new CompressionStream('deflate-raw')));
}

export async function decodeEcho(code) {
  code = String(code || '').replace(/\s+/g, '');
  let bytes;
  if (code.startsWith(PRE)) {
    if (typeof DecompressionStream === 'undefined') throw new Error('이 기기에서는 열 수 없는 코드입니다');
    bytes = await pipe(unb64(code.slice(PRE.length)), new DecompressionStream('deflate-raw'));
  } else if (code.startsWith(PRE_RAW)) bytes = unb64(code.slice(PRE_RAW.length));
  else throw new Error('메아리 코드가 아닙니다');
  if (bytes.length > 400000) throw new Error('코드가 너무 큽니다');
  const o = JSON.parse(new TextDecoder().decode(bytes));
  const d = o && o.d;
  if (!Array.isArray(d) || d.length < 4 || d.length > MAX_POINTS || d.length % 2 || !d.every(Number.isFinite)) throw new Error('움직임 기록이 잘못되었습니다');
  const path = [d[0], d[1]];
  for (let i = 2; i < d.length; i++) path.push(path[i - 2] + d[i]);
  if (!o.w) for (let i = 0; i < path.length; i += 2) { path[i] += OLD_TO_NEW.x; path[i + 1] += OLD_TO_NEW.y; } // 예전 코드는 좁은 방 좌표
  for (let i = 0; i < path.length; i += 2) { // 월드 밖으로 나간 점은 안쪽으로 붙인다
    path[i] = Math.min(ARENA.x + ARENA.w, Math.max(ARENA.x, Math.round(path[i])));
    path[i + 1] = Math.min(ARENA.y + ARENA.h, Math.max(ARENA.y, Math.round(path[i + 1])));
  }
  const picks = (Array.isArray(o.k) ? o.k : []).slice(0, 200)
    .filter((x) => Array.isArray(x) && Number.isFinite(x[0]) && x[0] >= 0 && CARD_BY_ID[x[1]])
    .map((x) => ({ t: Math.floor(x[0]), id: x[1] }));
  const ch = Number.isInteger(o.h) && o.h >= 0 && o.h < CHAPTERS.length ? o.h : 0;
  const cls = CLASSES[o.c] ? o.c : 'sword';
  const name = String(o.n || '친구').replace(/[<>&"'`]/g, '').trim().slice(0, 8) || '친구';
  return { name, ch, cls, path, picks };
}
