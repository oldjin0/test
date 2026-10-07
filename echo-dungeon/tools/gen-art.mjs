// Cloudflare Workers AI(FLUX)로 치비 카툰 에셋을 생성해 www/assets/ 에 저장한다.
//   CLOUDFLARE_ACCOUNT_ID=... CLOUDFLARE_API_TOKEN=... node tools/gen-art.mjs [hero slime ...]
// 이미지가 없으면 게임은 도형으로 그려진 기본 캐릭터를 쓰므로, 생성한 파일만 골라서 교체된다.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import jpeg from 'jpeg-js';
import { PNG } from 'pngjs';

const ACCOUNT = process.env.CLOUDFLARE_ACCOUNT_ID;
const TOKEN = process.env.CLOUDFLARE_API_TOKEN;
const MODEL = process.env.CF_IMAGE_MODEL || '@cf/black-forest-labs/flux-1-schnell';
const OUT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'www', 'assets');

// 모든 이미지에 같은 화풍 문구를 붙여 일관성을 유지한다.
const STYLE = 'cute chibi cartoon game character, big head small body, thick dark outline, flat bright colors with soft cel shading, ' +
  'kawaii mobile game art, full body centered, plain pure white background, no text, no shadow';
// 이동 방향별 모습. 파일명: 정면 <이름>.png, 뒷모습 <이름>_b.png, 옆모습 <이름>_s.png (오른쪽을 본다. 왼쪽은 게임이 뒤집어 쓴다)
const VIEWS = {
  '': 'front view, facing the viewer',
  _b: 'back view, seen from behind, facing away from the viewer, no face visible',
  _s: 'side profile view, facing right',
};
const SIZE = 320;
const VIEW_FILES = ['', '_fd', '_s', '_bd', '_b']; // 정면, 비스듬한 앞(오른쪽), 옆(오른쪽), 비스듬한 뒤(오른쪽), 뒤 // 생성 원본은 1024px. 게임에서는 작게 그려서 줄여 저장한다.

// 세 방향(앞·뒤·옆)을 한 장에 그리게 해서 같은 캐릭터로 통일한다 (따로 그리면 매번 다른 캐릭터가 나온다).
const DETAIL = 'highly detailed, intricate costume details, rich shading and highlights, clean thick outline';
const ASSETS = {
  hero: { prompt: `a brave young swordsman hero with spiky purple hair, blue tunic with gold trim, brown belt and boots, a short cape, holding a steel sword, ${DETAIL}` },
  archer: { prompt: `an elf archer girl with a green hooded cloak, orange hair, brown leather vest, holding a wooden longbow, a quiver of arrows on her back, ${DETAIL}` },
  wizard: { prompt: `a young wizard with a big blue pointed hat, blue robe with star patterns, holding a wooden staff topped with a glowing crystal, ${DETAIL}` },
  slime: { prompt: `a cute green jelly slime monster with big shiny eyes, glossy translucent body, little highlights, ${DETAIL}` },
  bat: { prompt: `a small purple vampire bat monster with big ears, tiny fangs and spread leathery wings, ${DETAIL}` },
  brute: { prompt: `a burly orange ogre monster with two small horns, tusks, a loincloth, holding a spiked wooden club, ${DETAIL}` },
  mage: { prompt: `a skeleton mage in a tattered purple hooded robe holding a glowing staff with a purple flame, ${DETAIL}` },
  boar: { prompt: `an angry brown wild boar with white tusks, bristly fur and a scar, ${DETAIL}` },
  blob: { prompt: `a big round blue jelly slime monster, glossy and wobbly with a goofy face, ${DETAIL}` },
  slimeking: { prompt: `a giant green slime king boss wearing a golden jeweled crown and a red cape, ${DETAIL}` },
  lich: { prompt: `a floating lich boss with a skull face in a dark purple robe with gold ornaments, holding a skull staff with green flame, ${DETAIL}` },
  dragon: { prompt: `a fierce red dragon boss with a golden crown, orange belly scales, horns and small wings, ${DETAIL}` },
  frost: { prompt: `a giant icy blue frost lord boss with a crystal ice crown, frost armor and ice spikes, ${DETAIL}` },
  shadow: { prompt: `a dark purple shadow dragon king boss with a glowing red crown, black armor plates, red glowing eyes, ${DETAIL}` },
};
const SHEETED = ['hero', 'archer', 'wizard']; // 플레이어 캐릭터만 앞·뒤·옆을 한 장에 그려 통일한다. 몬스터·보스는 정면 한 장을 모든 방향에 쓴다(좌우 반전).
for (const [k, v] of Object.entries(ASSETS)) { v.key = true; v.sheet = SHEETED.includes(k); }
ASSETS.slime.prompt = `a single dome-shaped green jelly slime blob with absolutely no arms and no legs, big shiny eyes and a happy smile, glossy translucent body with highlights, ${DETAIL}`;
ASSETS.blob.prompt = `a single big round blue jelly slime blob with absolutely no arms and no legs, a goofy face, glossy wobbly translucent body, ${DETAIL}`;
ASSETS.bat.prompt = `a cute purple bat creature flying, big pointed ears, red eyes, tiny fangs, wide spread leathery wings, front view, ${DETAIL}`;

// 상자 평균으로 1/f 축소 (알파 가중)
function shrink(buf, size) {
  const src = PNG.sync.read(buf), f = src.width / size;
  if (f <= 1) return buf;
  const out = new PNG({ width: size, height: size });
  for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) {
    let r = 0, g = 0, b = 0, a = 0;
    for (let j = 0; j < f; j++) for (let i = 0; i < f; i++) {
      const k = ((y * f + j) * src.width + x * f + i) * 4, al = src.data[k + 3];
      r += src.data[k] * al; g += src.data[k + 1] * al; b += src.data[k + 2] * al; a += al;
    }
    const o = (y * size + x) * 4;
    if (a) { out.data[o] = r / a; out.data[o + 1] = g / a; out.data[o + 2] = b / a; }
    out.data[o + 3] = a / (f * f);
  }
  return PNG.sync.write(out);
}

if (process.argv[2] === '--resize') { // 이미 만든 큰 이미지를 줄인다
  for (const fn of fs.readdirSync(OUT).filter((n) => n.endsWith('.png'))) {
    const p = path.join(OUT, fn), b = fs.readFileSync(p), w = PNG.sync.read(b).width;
    if (w > SIZE) { fs.writeFileSync(p, shrink(b, SIZE)); console.log(fn, w, '->', SIZE); }
  }
  process.exit(0);
}

// FLUX.2 klein: 기준 그림을 주고 "같은 캐릭터를 다른 각도에서" 그리게 한다 (따로 그리면 매번 다른 캐릭터가 나오지만, 기준 그림을 주면 같은 캐릭터로 나온다)
const REF_MODEL = process.env.CF_REF_MODEL || '@cf/black-forest-labs/flux-2-klein-4b';
const VIEW_PROMPTS = {
  _fd: 'the same character turned to a three-quarter front view, body and face angled 45 degrees toward the right side of the image, front of the body still mostly visible',
  _s: 'the same character in a strict side profile view, exactly 90 degrees turned, the face in profile with the nose pointing to the right edge of the image, the chest facing right, only the left side of the body visible, like a classic side-scrolling game sprite',
  _bd: 'the same character turned to a three-quarter back view, seen from behind and slightly from the right side, face mostly hidden, the back and the right side visible',
  _b: 'the same character seen directly from behind, back view, face not visible',
  // 16방향용 중간 각도 (22.5도 간격): 앞에서 옆으로, 옆에서 뒤로
  _a1: 'the same character turned slightly to the right, about 22 degrees from the front view, almost facing the viewer',
  _a2: 'the same character turned to the right about 67 degrees from the front view, mostly side view but a little of the front visible',
  _a3: 'the same character turned away from the viewer about 112 degrees from the front view, side view slightly turned toward the back, a little of the back visible',
  _a4: 'the same character turned away from the viewer about 157 degrees from the front view, almost fully seen from behind, a little of the right side visible',
};
async function generateRef(prompt, refPng) {
  const white = new PNG({ width: refPng.width, height: refPng.height }); // 투명한 곳은 흰색으로 깔아서 기준 그림으로 쓴다
  for (let i = 0; i < refPng.data.length; i += 4) { const a = refPng.data[i + 3] / 255; for (let k = 0; k < 3; k++) white.data[i + k] = Math.round(refPng.data[i + k] * a + 255 * (1 - a)); white.data[i + 3] = 255; }
  const form = new FormData();
  form.append('prompt', `${prompt}. Keep exactly the same outfit, colors, hairstyle, proportions, weapon and art style as the reference image. Full body, standing, centered, plain pure white background, no text, no shadow, cute chibi cartoon game art`);
  const RS = process.env.REF_SIZE || '512'; // 게임에서는 320px로 줄여 쓰므로 512면 충분하고 한도를 덜 쓴다
  form.append('width', RS); form.append('height', RS);
  form.append('input_image_0', new Blob([PNG.sync.write(white)], { type: 'image/png' }), 'ref.png');
  const res = await fetch(`https://api.cloudflare.com/client/v4/accounts/${process.env.CLOUDFLARE_ACCOUNT_ID}/ai/run/${REF_MODEL}`, { method: 'POST', headers: { Authorization: `Bearer ${process.env.CLOUDFLARE_API_TOKEN}` }, body: form });
  const j = await res.json().catch(() => ({}));
  if (!res.ok || !j.result || !j.result.image) throw new Error(`${res.status} ${JSON.stringify(j.errors || j).slice(0, 300)}`);
  return Buffer.from(j.result.image, 'base64');
}
const spec0 = (name) => `Reference: ${String((ASSETS[name] || {}).prompt || name).split(', highly')[0]}.`;
const OFFLINE_CMDS = ['--swap', '--flip', '--assign', '--selftest', '--resize']; // 키가 필요 없는 명령
if ((!ACCOUNT || !TOKEN) && !OFFLINE_CMDS.includes(process.argv[2])) {
  console.error('CLOUDFLARE_ACCOUNT_ID 와 CLOUDFLARE_API_TOKEN 환경 변수가 필요합니다.');
  process.exit(1);
}

async function generate(name, spec, view) {
  const prompt = spec.plain ? spec.prompt : spec.raw ? `${spec.prompt}, cute chibi cartoon style` : `${spec.prompt}. ${STYLE}, ${view}`;
  const res = await fetch(`https://api.cloudflare.com/client/v4/accounts/${ACCOUNT}/ai/run/${MODEL}`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ prompt, steps: 6 }),
  });
  const j = await res.json();
  if (!res.ok || !j.result || !j.result.image) throw new Error(`${name}: ${res.status} ${JSON.stringify(j.errors || j).slice(0, 300)}`);
  return Buffer.from(j.result.image, 'base64');
}

function jpgToPng(jpgBuf) {
  const d = jpeg.decode(jpgBuf, { useTArray: true });
  const png = new PNG({ width: d.width, height: d.height });
  png.data = Buffer.from(d.data);
  return PNG.sync.write(png);
}

// 흰 배경을 가장자리부터 번져 나가며 투명하게 만든다 (캐릭터 안쪽의 흰색은 보존).
export function keyOutWhite(jpgBuf, tol = 40) {
  const { width: w, height: h, data } = jpeg.decode(jpgBuf, { useTArray: true });
  const png = new PNG({ width: w, height: h });
  png.data = Buffer.from(data);
  const isBg = (i) => data[i] > 255 - tol && data[i + 1] > 255 - tol && data[i + 2] > 255 - tol;
  const seen = new Uint8Array(w * h), stack = [];
  const push = (x, y) => { const p = y * w + x; if (x < 0 || y < 0 || x >= w || y >= h || seen[p] || !isBg(p * 4)) return; seen[p] = 1; stack.push(p); };
  for (let x = 0; x < w; x++) { push(x, 0); push(x, h - 1); }
  for (let y = 0; y < h; y++) { push(0, y); push(w - 1, y); }
  while (stack.length) {
    const p = stack.pop(), x = p % w, y = (p / w) | 0;
    png.data[p * 4 + 3] = 0;
    push(x + 1, y); push(x - 1, y); push(x, y + 1); push(x, y - 1);
  }
  return PNG.sync.write(png);
}

// 한 장에 앞·뒤·옆모습을 나란히 그린 시트에서, 빈 세로줄로 갈라지는 덩어리 세 개를 찾아 각각 SIZE 정사각형(바닥 정렬)에 맞춘다.
function runsOf(png, ya = 0, yb = png.height - 1, want = 3) {
  const { width: w, data } = png, col = new Uint8Array(w);
  for (let x = 0; x < w; x++) for (let y = ya; y <= yb; y++) if (data[(y * w + x) * 4 + 3] > 40) { col[x] = 1; break; }
  let runs = [], x = 0;
  while (x < w) { if (!col[x]) { x++; continue; } let e = x; while (e < w && col[e]) e++; runs.push([x, e - 1]); x = e; }
  // 사이가 12px 미만인 덩어리는 한 몸으로 본다 (지팡이·날개 끝 등)
  for (let i = 1; i < runs.length;) { if (runs[i][0] - runs[i - 1][1] < 6) { runs[i - 1][1] = runs[i][1]; runs.splice(i, 1); } else i++; }
  // 너무 좁은 조각(60px 미만)은 더 가까운 이웃에 붙인다
  for (let i = 0; i < runs.length && runs.length > want;) {
    if (runs[i][1] - runs[i][0] >= 60) { i++; continue; }
    const l = i > 0 ? runs[i][0] - runs[i - 1][1] : 1e9, r = i < runs.length - 1 ? runs[i + 1][0] - runs[i][1] : 1e9;
    if (l <= r) { runs[i - 1][1] = runs[i][1]; } else { runs[i + 1][0] = runs[i][0]; }
    runs.splice(i, 1);
  }
  return runs;
}
// 가로 구간 [rx0, rx1]에 그려진 그림만 잘라 SIZE 정사각형(바닥 정렬)에 맞춘다
function fitRun(png, rx0, rx1, ya = 0, yb = png.height - 1) {
  const { width: w, height: h, data } = png;
  {
    let y0 = h, y1 = -1;
    for (let y = ya; y <= yb; y++) for (let x = rx0; x <= rx1; x++) if (data[(y * w + x) * 4 + 3] > 40) { y0 = Math.min(y0, y); y1 = Math.max(y1, y); break; }
    let xa = rx1, xb = rx0; // 실제로 그려진 가로 범위로 좁힌다
    for (let x = rx0; x <= rx1; x++) for (let y = y0; y <= y1; y++) if (data[(y * w + x) * 4 + 3] > 40) { xa = Math.min(xa, x); xb = Math.max(xb, x); break; }
    const x0 = xa, bw = xb - xa + 1, bh = y1 - y0 + 1, sc = Math.min(SIZE * 0.94 / bw, SIZE * 0.94 / bh);
    const dst = new PNG({ width: SIZE, height: SIZE }), ow = Math.round(bw * sc), oh = Math.round(bh * sc);
    const ox = Math.round((SIZE - ow) / 2), oy = SIZE - oh - Math.round(SIZE * 0.03);
    for (let y = 0; y < oh; y++) for (let x = 0; x < ow; x++) {
      let r = 0, g = 0, b = 0, a = 0, n = 0;
      const sx0 = x0 + Math.floor(x / sc), sx1 = Math.max(sx0 + 1, x0 + Math.floor((x + 1) / sc));
      const sy0 = y0 + Math.floor(y / sc), sy1 = Math.max(sy0 + 1, y0 + Math.floor((y + 1) / sc));
      for (let sy = sy0; sy < sy1 && sy < h; sy++) for (let sx = sx0; sx < sx1 && sx <= rx1; sx++) {
        const i = (sy * w + sx) * 4, al = data[i + 3]; r += data[i] * al; g += data[i + 1] * al; b += data[i + 2] * al; a += al; n++;
      }
      const o = ((oy + y) * SIZE + ox + x) * 4;
      if (a) { dst.data[o] = r / a; dst.data[o + 1] = g / a; dst.data[o + 2] = b / a; }
      dst.data[o + 3] = n ? a / n : 0;
    }
    return PNG.sync.write(dst);
  }
}
function valleySplit(png) { // 몸이 맞닿아 덩어리가 3개로 안 갈릴 때: 가운데 두 지점의 가장 빈 세로줄에서 자른다
  const { width: w, height: h, data } = png, col = new Uint32Array(w);
  let first = -1, last = -1;
  for (let x = 0; x < w; x++) { for (let y = 0; y < h; y++) if (data[(y * w + x) * 4 + 3] > 40) col[x]++; if (col[x]) { if (first < 0) first = x; last = x; } }
  if (first < 0 || last - first < 300) return null;
  const span = last - first, best = (a, b) => { let bx = a, bv = 1e9; for (let x = Math.floor(a); x <= b; x++) if (col[x] < bv) { bv = col[x]; bx = x; } return bx; };
  const s1 = best(first + span * 0.27, first + span * 0.40), s2 = best(first + span * 0.60, first + span * 0.73);
  return [[first, s1 - 1], [s1, s2 - 1], [s2, last]];
}
// 5방향 시트(윗줄 3명, 아랫줄 2명)를 읽는 순서(윗줄 왼→오, 아랫줄 왼→오)대로 자른다
function rowsOf(png) { // 빈 가로줄로 갈라지는 줄 덩어리
  const { width: w, height: h, data } = png, rowOn = new Uint8Array(h);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) if (data[(y * w + x) * 4 + 3] > 40) { rowOn[y] = 1; break; }
  const rows = []; let y = 0;
  while (y < h) { if (!rowOn[y]) { y++; continue; } let e = y; while (e < h && rowOn[e]) e++; rows.push([y, e - 1]); y = e; }
  for (let i = 1; i < rows.length;) { if (rows[i][0] - rows[i - 1][1] < 8) { rows[i - 1][1] = rows[i][1]; rows.splice(i, 1); } else i++; }
  return rows.filter((r) => r[1] - r[0] > 80);
}
function splitSheet5(png) {
  const rows = rowsOf(png);
  if (rows.length !== 2) throw new Error(`두 줄이 아님 (${rows.length})`);
  const top = runsOf(png, rows[0][0], rows[0][1], 3), bot = runsOf(png, rows[1][0], rows[1][1], 2);
  if (top.length !== 3 || bot.length !== 2) throw new Error(`3+2가 아님 (${top.length}+${bot.length})`);
  return [...top.map((r) => fitRun(png, r[0], r[1], rows[0][0], rows[0][1])), ...bot.map((r) => fitRun(png, r[0], r[1], rows[1][0], rows[1][1]))];
}
// 몬스터용: 가로 세 덩어리 시트 (예전 방식, 필요할 때만)
function splitSheet(png) {
  let runs = runsOf(png);
  if (runs.length !== 3) { runs = valleySplit(png); if (!runs) throw new Error('세 덩어리가 아님'); }
  return runs.map(([rx0, rx1]) => fitRun(png, rx0, rx1));
}

/* ---------- 아이콘 · 배경 ---------- */
// node tools/gen-art.mjs icons   → www/assets/icons/<id>.png (128px, 투명 배경)
// node tools/gen-art.mjs bg      → www/assets/bg/<id>.jpg (512px)
const ICON_STYLE = 'cute chunky mobile game UI icon, single large object filling most of the frame, centered, thick dark outline, glossy bright flat colors with soft shading, plain pure white background, no text, no shadow';
const ICONS = {
  rapid: 'a yellow lightning bolt', power: 'a red and orange explosion burst star', multi: 'three arrows fanning out',
  pierce: 'a single arrow piercing through a round target', boots: 'a pair of leather boots with small wings',
  vital: 'a shiny red heart with a white plus sign', blade: 'a ring of three small flying swords',
  bolt: 'a blue storm cloud with a lightning bolt', poison: 'a green bubbling potion bottle',
  echo: 'a cute cyan ghost with glowing sound waves', crit: 'a red bullseye target with a star in the center',
  leech: 'a red blood drop with tiny fangs', magnet: 'a red and blue horseshoe magnet pulling gold coins',
  shield: 'a round blue shield with a gold border', boom: 'a colorful firework explosion', frost: 'a light blue snowflake crystal',
  storm: 'two crossed glowing swords inside a whirlwind', legion: 'three cyan ghost silhouettes standing together',
  thunder: 'a dark thundercloud with many yellow lightning bolts', meat: 'a roasted meat drumstick',
  purse: 'a brown coin pouch overflowing with gold coins',
  shop_hp: 'a strong flexed arm with a small red heart', shop_atk: 'a shiny steel sword with a red gem',
  shop_spd: 'a running shoe with speed lines', shop_echo: 'a glowing magic mirror showing a ghost reflection',
  shop_greed: 'a golden treasure chest full of gold coins', shop_reroll: 'a pair of white dice', shop_slot: 'an ornate standing magic mirror',
  cls_sword: 'two crossed swords emblem', cls_archer: 'a bow with an arrow emblem', cls_mage: 'a magic crystal ball on a gold stand with sparkles',
  sharp: 'a sharp curved dagger with a glowing red edge', longshot: 'a brass telescope with a crosshair', swiftshot: 'a speeding arrow with blue wind swoosh lines',
  bigshot: 'a big glowing energy orb with a thick ring', splash: 'a magic orb exploding into many small sparks', heavy: 'a heavy iron war hammer',
  flurry: 'a whirlwind of many small slashes', twin: 'two identical glowing arrows side by side', pierce2: 'a long needle spear piercing through three stacked shields',
  homing: 'a curved arrow chasing a target with a spiral trail', ricochet: 'a glowing ball bouncing between two walls with a zigzag path',
  ember: 'a single small flame ember with sparks', inferno: 'a huge roaring fire tornado', execute: 'a cute skull with crossed bones and a red axe',
  bossbane: 'a golden crown pierced by a sword', elitebane: 'a gold star medal pierced by a sword', berserk: 'an angry red face with flames',
  momentum: 'a running figure with speed lines and a red flame trail', still: 'a calm meditating figure in a blue circle', sniper: 'a sniper scope reticle with a red dot',
  brawler: 'a red boxing glove with impact lines', revenge: 'a red broken heart with a lightning bolt', killhaste: 'a dripping red blood drop with yellow lightning',
  overdrive: 'a glowing green battery with lightning bolts', knock: 'a leather boot kicking with impact stars', blast: 'a lit round bomb with a fuse and sparks',
  aura: 'a glowing sun with orange rays', glacier: 'a blue ice crystal circle with frost', nova: 'a bright white shockwave ring explosion',
  bigblade: 'a giant spinning sword', regen: 'a green leaf with a glowing plus sign', armor: 'a steel knight helmet', ironskin: 'a strong metal arm with rivets',
  phase: 'a translucent ghostly silhouette of a person', thorns: 'a green cactus with sharp spikes', drain: 'a syringe with red liquid and a heart',
  feast: 'a roasted whole chicken on a plate', dodge: 'a figure leaping away leaving afterimages', barrier: 'a glowing blue energy shield bubble',
  secondwind: 'a white dove with spread wings and a glowing halo', coinmul: 'a big stack of shiny gold coins', treasure: 'a sparkling blue diamond gem',
  greedy: 'a gold coin with a red heart', lucky: 'a four leaf clover', echohaste: 'a cyan ghost with fast forward arrows', echoguard: 'a cyan ghost holding a shield',
  echoheal: 'a cyan ghost with a pink heart', echocrit: 'a cyan ghost with a sparkling star', haste: 'a swirling green wind gust', giant: 'a big muscular chest silhouette with a heart',
  phoenix: 'a majestic fire phoenix bird with spread flaming wings', judgment: 'a huge golden lightning bolt striking down from a storm cloud',
  crown: 'a glorious golden crown with rainbow gems and light rays',
  ui_coin: 'a shiny round gold coin with a simple star symbol, no text, no letters, no numbers', ui_heart: 'a glossy red heart', ui_kills: 'a cute white skull',
};
const THEMES = [
  'mossy green cave, damp stones and moss', 'haunted purple graveyard crypt, bones and cracked stone', 'lava mine, dark red rock with glowing orange cracks',
  'frozen ice fortress, pale blue ice bricks and frost', 'dark shadow throne room, black purple stone with crimson accents', 'endless deep dungeon, dark navy stone with golden runes',
];
// 챕터마다 투기장 전체를 한 장으로 그린다. 1024 정사각형에서 세로 9:16을 잘라 576x1024로 저장한다.
const BGS = {};
THEMES.forEach((t, i) => {
  BGS[`arena${i}`] = `top-down view looking straight down at the floor of a large fantasy dungeon arena room, ${t}, ` +
    'detailed stone floor filling the whole image, cracks, puddles, scattered small rocks, glowing details, thick walls only at the very top edge, ' +
    'no characters, no creatures, no people, no text, no UI, rich colors, painterly hand-painted mobile game background, soft lighting';
});

function cropPortrait(jpgBuf) { // 가운데 9:16 세로 영역만 남긴다
  const src = jpeg.decode(jpgBuf, { useTArray: true }), h = src.height, w = Math.round(h * 9 / 16), x0 = Math.round((src.width - w) / 2);
  const sb = Buffer.from(src.data.buffer, src.data.byteOffset, src.data.length), d = Buffer.alloc(w * h * 4);
  for (let y = 0; y < h; y++) sb.copy(d, y * w * 4, (y * src.width + x0) * 4, (y * src.width + x0 + w) * 4);
  return jpeg.encode({ data: d, width: w, height: h }, 84).data;
}

// 투명 배경 PNG에서 그림이 있는 부분만 잘라 size 정사각형 가운데에 꽉 차게(92%) 맞춘다. 아이콘 크기를 통일한다.
function fitIcon(buf, size) {
  const png = PNG.sync.read(buf), { width: w, height: h, data } = png;
  let x0 = w, x1 = -1, y0 = h, y1 = -1;
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) if (data[(y * w + x) * 4 + 3] > 40) { x0 = Math.min(x0, x); x1 = Math.max(x1, x); y0 = Math.min(y0, y); y1 = Math.max(y1, y); }
  if (x1 < 0) return shrink(buf, size);
  const bw = x1 - x0 + 1, bh = y1 - y0 + 1, sc = Math.min(size * 0.92 / bw, size * 0.92 / bh);
  const ow = Math.round(bw * sc), oh = Math.round(bh * sc), ox = Math.round((size - ow) / 2), oy = Math.round((size - oh) / 2);
  const dst = new PNG({ width: size, height: size });
  for (let y = 0; y < oh; y++) for (let x = 0; x < ow; x++) {
    let r = 0, g = 0, b = 0, a = 0, n = 0;
    const sx0 = x0 + Math.floor(x / sc), sx1 = Math.max(sx0 + 1, x0 + Math.floor((x + 1) / sc));
    const sy0 = y0 + Math.floor(y / sc), sy1 = Math.max(sy0 + 1, y0 + Math.floor((y + 1) / sc));
    for (let sy = sy0; sy < sy1 && sy < h; sy++) for (let sx = sx0; sx < sx1 && sx < w; sx++) {
      const i = (sy * w + sx) * 4, al = data[i + 3]; r += data[i] * al; g += data[i + 1] * al; b += data[i + 2] * al; a += al; n++;
    }
    const o = ((oy + y) * size + ox + x) * 4;
    if (a) { dst.data[o] = r / a; dst.data[o + 1] = g / a; dst.data[o + 2] = b / a; }
    dst.data[o + 3] = n ? a / n : 0;
  }
  return PNG.sync.write(dst);
}

async function runGroup(group, want, force) {
  const icons = group === 'icons', specs = icons ? ICONS : BGS, dir = path.join(OUT, icons ? 'icons' : 'bg');
  fs.mkdirSync(dir, { recursive: true });
  for (const [id, text] of Object.entries(specs)) {
    if (want.length && !want.includes(id)) continue;
    const file = path.join(dir, `${id}.${icons ? 'png' : 'jpg'}`);
    if (!force && fs.existsSync(file)) continue;
    process.stdout.write(`${group}/${id} ... `);
    try {
      const img = await generate(id, { prompt: icons ? `${text}. ${ICON_STYLE}` : text, raw: true, plain: true });
      fs.writeFileSync(file, icons ? fitIcon(keyOutWhite(img), 128) : cropPortrait(img));
      console.log('ok');
    } catch (e) { console.log('FAIL', e.message); if (/429|4006|allocation/.test(e.message)) process.exit(3); } // 하루 한도: 바깥 스크립트가 다음 계정으로
  }
}

if (process.argv[2] === '--selftest') { // 5방향 시트 자르기 점검: 가짜 시트(3+2 색 상자)로 다섯 장이 순서대로 나오는지
  const W5 = 1024, png = new PNG({ width: W5, height: W5 });
  const box = (x, y, w, h, c) => { for (let j = y; j < y + h; j++) for (let i = x; i < x + w; i++) { const o = (j * W5 + i) * 4; png.data[o] = c[0]; png.data[o + 1] = c[1]; png.data[o + 2] = c[2]; png.data[o + 3] = 255; } };
  [[40, 30, 260, 420], [380, 30, 260, 420], [720, 30, 260, 420]].forEach(([x, y, w, h], i) => box(x, y, w, h, [60 * (i + 1), 0, 0]));
  [[200, 540, 260, 440], [560, 540, 260, 440]].forEach(([x, y, w, h], i) => box(x, y, w, h, [0, 80 * (i + 1), 0]));
  const parts = splitSheet5(png);
  const reds = parts.map((b) => { const q = PNG.sync.read(b); let hit = [0, 0]; for (let i = 0; i < q.data.length; i += 4) if (q.data[i + 3] > 200) { hit[0] += q.data[i]; hit[1] += q.data[i + 1]; } return hit[0] > hit[1] ? 'R' : 'G'; }).join('');
  const sizes = parts.map((b) => { const q = PNG.sync.read(b); return `${q.width}x${q.height}`; });
  // 아이콘·배경 경로도 점검: 투명 PNG → 128 정사각형, 큰 JPEG → 세로 9:16 (이번에 fitIcon이 사라져 있었는데 몰랐다)
  const ic = PNG.sync.read(fitIcon(PNG.sync.write(png), 128)), jp = jpeg.decode(cropPortrait(jpeg.encode({ data: Buffer.alloc(1024 * 1024 * 4, 200), width: 1024, height: 1024 }, 80).data), { useTArray: true });
  if (ic.width !== 128 || jp.width !== 576 || jp.height !== 1024) { console.log('아이콘/배경 경로 실패', ic.width, jp.width, jp.height); process.exit(1); }
  console.log(reds === 'RRRGG' && parts.length === 5 ? '시트 자르기 OK' : `시트 자르기 실패 ${reds}`, sizes.join(' '));
  process.exit(reds === 'RRRGG' ? 0 : 1);
}
if (process.argv[2] === '--assign') { // node tools/gen-art.mjs --assign hero f=0 fd=1 s=2 bd=3 b=4  → 방금 저장된 다섯 파일(그려진 순서)을 눈으로 본 대로 재배치
  const [, , , name, ...pairs] = process.argv, keyFile = { f: '', fd: '_fd', s: '_s', bd: '_bd', b: '_b' };
  const bufs = VIEW_FILES.map((x) => fs.readFileSync(path.join(OUT, `${name}${x}.png`)));
  for (const pr of pairs) { const [k, i] = pr.split('='); fs.writeFileSync(path.join(OUT, `${name}${keyFile[k]}.png`), bufs[+i]); }
  process.exit(0);
}
if (process.argv[2] === '--swap') { // node tools/gen-art.mjs --swap hero 0 2 1  → 새 정면=기존0, 새 뒷모습=기존2, 새 옆모습=기존1
  const [, , , name, ...ord] = process.argv, sf = ['', '_b', '_s'], files = sf.map((x) => path.join(OUT, `${name}${x}.png`));
  const bufs = files.map((f) => fs.readFileSync(f));
  ord.map(Number).forEach((from, to) => fs.writeFileSync(files[to], bufs[from]));
  process.exit(0);
}
if (process.argv[2] === '--flip') { // node tools/gen-art.mjs --flip hero_s  → 좌우 반전
  const f = path.join(OUT, `${process.argv[3]}.png`), src = PNG.sync.read(fs.readFileSync(f)), o = new PNG({ width: src.width, height: src.height });
  for (let y = 0; y < src.height; y++) for (let x = 0; x < src.width; x++) src.data.copy(o.data, (y * src.width + x) * 4, (y * src.width + src.width - 1 - x) * 4, (y * src.width + src.width - x) * 4);
  fs.writeFileSync(f, PNG.sync.write(o));
  process.exit(0);
}
if (path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  fs.mkdirSync(OUT, { recursive: true });
  const force = process.argv.includes('--force');
  const want = process.argv.slice(2).filter((a) => a !== '--force');
  if (want[0] === '--views') { // node tools/gen-art.mjs --views hero archer wizard [--sixteen]  → 정면 그림을 기준으로 나머지 방향을 같은 캐릭터로 그린다
    let keys = process.argv.includes('--sixteen') ? ['_fd', '_s', '_bd', '_b', '_a1', '_a2', '_a3', '_a4'] : ['_fd', '_s', '_bd', '_b'];
    const oi = process.argv.indexOf('--only'); if (oi > 0) keys = process.argv[oi + 1].split(','); // 예: --only _s,_bd (그 방향만 다시)
    for (const name of want.slice(1).filter((n) => !n.startsWith('--') && !n.startsWith('_') && n !== process.argv[process.argv.indexOf('--only') + 1])) {
      const front = path.join(OUT, `${name}.png`);
      if (!fs.existsSync(front)) { console.log(`${name}: 정면 그림이 없다`); continue; }
      const ref = PNG.sync.read(fs.readFileSync(front));
      for (const k of keys) {
        const file = path.join(OUT, `${name}${k}.png`);
        if (!force && fs.existsSync(file) && fs.statSync(file).mtimeMs > fs.statSync(front).mtimeMs) continue; // 이번 정면 그림 이후에 만든 것은 건너뛴다
        let ok2 = false;
        for (let attempt = 1; attempt <= 2 && !ok2; attempt++) {
          process.stdout.write(`${name}${k} (${attempt}) ... `);
          try {
            const img = await generateRef(`${spec0(name)} ${VIEW_PROMPTS[k]}`, ref);
            fs.mkdirSync(path.join(OUT, '..', '..', 'tools', 'out', 'views'), { recursive: true });
            fs.writeFileSync(path.join(OUT, '..', '..', 'tools', 'out', 'views', `${name}${k}-${attempt}.jpg`), img);
            const png = PNG.sync.read(keyOutWhite(img));
            fs.writeFileSync(file, fitRun(png, 0, png.width - 1));
            console.log('ok'); ok2 = true;
          } catch (e) { console.log('FAIL', e.message); if (/429|4006|allocation/.test(e.message)) process.exit(3); }
        }
      }
    }
    process.exit(0);
  }
  if (want[0] === 'icons' || want[0] === 'bg') { await runGroup(want[0], want.slice(1), force); process.exit(0); }
  const SHEET5 = 'character model sheet showing the same exact character five times with identical outfit, colors and proportions, arranged in two rows with clear empty white space between figures. Top row of three figures from left to right: front view facing the viewer, three-quarter front view turned to the right, side profile view facing right. Bottom row of two figures from left to right: three-quarter back view turned to the right, back view facing away. Full body, standing, plain pure white background, no text, no labels, cute chibi cartoon game art, big head small body';
  const SHEET = 'character turnaround sheet, the same exact character drawn three times side by side in one row, evenly spaced with clear empty white space between each figure, identical outfit and colors and proportions, left: front view, middle: back view seen from behind, right: side profile facing right, full body, standing, plain pure white background, no text, no labels, cute chibi cartoon game art, big head small body';
  fs.mkdirSync(path.join(OUT, '..', '..', 'tools', 'out', 'sheets'), { recursive: true });
  for (const [name, spec] of Object.entries(ASSETS)) {
    if (want.length && !want.includes(name)) continue;
    if (!force && fs.existsSync(path.join(OUT, `${name}.png`))) continue;
    if (!spec.sheet) { // 정면 한 장
      let ok1 = false;
      for (let attempt = 1; attempt <= 2 && !ok1; attempt++) {
        process.stdout.write(`${name} (정면 ${attempt}) ... `);
        try {
          const img = await generate(name, spec, VIEWS['']);
          const png = PNG.sync.read(keyOutWhite(img));
          fs.writeFileSync(path.join(OUT, `${name}.png`), fitRun(png, 0, png.width - 1));
          for (const sfx of ['_b', '_s']) fs.rmSync(path.join(OUT, `${name}${sfx}.png`), { force: true }); // 예전 방향별 그림이 남아 섞이지 않게
          console.log('ok'); ok1 = true;
        } catch (e) { console.log('FAIL', e.message); if (/429|4006|allocation/.test(e.message)) process.exit(3); }
      }
      continue;
    }
    let done = false;
    for (let attempt = 1; attempt <= 3 && !done; attempt++) {
      process.stdout.write(`${name} (시트 ${attempt}) ... `);
      try {
        const img = await generate(name, { ...spec, plain: true, prompt: `${spec.prompt}. ${SHEET5}` }, '');
        fs.writeFileSync(path.join(OUT, '..', '..', 'tools', 'out', 'sheets', `${name}-${attempt}.jpg`), img);
        const parts = splitSheet5(PNG.sync.read(keyOutWhite(img)));
        // 읽는 순서 [정면, 비스듬한 앞, 옆, 비스듬한 뒤, 뒤]로 시켰지만 모델이 어길 수 있다. 눈으로 확인해 바꾼다: node tools/gen-art.mjs --assign 이름 f=0 fd=1 s=2 bd=3 b=4
        VIEW_FILES.forEach((sfx, i) => fs.writeFileSync(path.join(OUT, `${name}${sfx}.png`), parts[i]));
        console.log('ok'); done = true;
      } catch (e) {
        console.log('FAIL', e.message);
        if (/429|4006|allocation/.test(e.message)) process.exit(3); // 하루 한도: 다른 계정으로
      }
    }
  }
}
