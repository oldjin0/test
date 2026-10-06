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
const SIZE = 256; // 생성 원본은 1024px. 게임에서는 작게 그려서 줄여 저장한다.

const ASSETS = {
  hero: { prompt: 'a brave little hero kid with purple spiky hair, blue tunic, holding a small sword', key: true },
  slime: { prompt: 'a happy green jelly slime monster with big shiny eyes', key: true },
  bat: { prompt: 'a small purple bat monster with tiny fangs, wings spread', key: true },
  brute: { prompt: 'a chubby orange ogre monster with little horns holding a wooden club', key: true },
  mage: { prompt: 'a small skeleton mage in a purple hood holding a glowing staff', key: true },
  boar: { prompt: 'an angry brown wild boar with white tusks', key: true },
  blob: { prompt: 'a big round blue slime monster, wobbly and cute', key: true },
  slimeking: { prompt: 'a giant green slime king boss wearing a golden crown', key: true },
  lich: { prompt: 'a floating lich boss in a purple robe with a skull face and glowing staff', key: true },
  dragon: { prompt: 'a chubby red dragon boss with a golden crown and small wings', key: true },
  frost: { prompt: 'a giant icy blue slime boss with an ice crown', key: true },
  archer: { prompt: 'a young elf archer kid with a green hood, brown leather vest, holding a small wooden bow with a quiver of arrows', key: true },
  wizard: { prompt: 'a little wizard kid with a big blue pointed hat, blue robe, holding a glowing magic staff with a crystal', key: true, sheet: true },
  shadow: { prompt: 'a dark purple shadow dragon king boss with a red crown', key: true },
};

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

if (!ACCOUNT || !TOKEN) {
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

// 한 장에 앞·뒤·옆모습을 나란히 그린 시트를 세 칸으로 잘라 각각 SIZE 정사각형(바닥 정렬)에 맞춘다.
function splitSheet(png) {
  const { width: w, height: h, data } = png, third = Math.floor(w / 3), out = [];
  for (let k = 0; k < 3; k++) {
    let x0 = w, x1 = -1, y0 = h, y1 = -1;
    for (let y = 0; y < h; y++) for (let x = k * third; x < (k + 1) * third; x++) {
      if (data[(y * w + x) * 4 + 3] > 40) { x0 = Math.min(x0, x); x1 = Math.max(x1, x); y0 = Math.min(y0, y); y1 = Math.max(y1, y); }
    }
    if (x1 < 0) throw new Error('빈 칸');
    const bw = x1 - x0 + 1, bh = y1 - y0 + 1, sc = Math.min(SIZE * 0.9 / bw, SIZE * 0.9 / bh);
    const dst = new PNG({ width: SIZE, height: SIZE }), ow = Math.round(bw * sc), oh = Math.round(bh * sc);
    const ox = Math.round((SIZE - ow) / 2), oy = SIZE - oh - Math.round(SIZE * 0.05);
    for (let y = 0; y < oh; y++) for (let x = 0; x < ow; x++) {
      let r = 0, g = 0, b = 0, a = 0, n = 0;
      const sx0 = x0 + Math.floor(x / sc), sx1 = Math.max(sx0 + 1, x0 + Math.floor((x + 1) / sc));
      const sy0 = y0 + Math.floor(y / sc), sy1 = Math.max(sy0 + 1, y0 + Math.floor((y + 1) / sc));
      for (let sy = sy0; sy < sy1 && sy < h; sy++) for (let sx = sx0; sx < sx1 && sx < w; sx++) {
        const i = (sy * w + sx) * 4, al = data[i + 3]; r += data[i] * al; g += data[i + 1] * al; b += data[i + 2] * al; a += al; n++;
      }
      const o = ((oy + y) * SIZE + ox + x) * 4;
      if (a) { dst.data[o] = r / a; dst.data[o + 1] = g / a; dst.data[o + 2] = b / a; }
      dst.data[o + 3] = n ? a / n : 0;
    }
    out.push(PNG.sync.write(dst));
  }
  return out; // [정면, 뒷모습, 옆모습]
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
    } catch (e) { console.log('FAIL', e.message); }
  }
}

if (path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  fs.mkdirSync(OUT, { recursive: true });
  const force = process.argv.includes('--force');
  const want = process.argv.slice(2).filter((a) => a !== '--force');
  if (want[0] === 'icons' || want[0] === 'bg') { await runGroup(want[0], want.slice(1), force); process.exit(0); }
  for (const [name, spec] of Object.entries(ASSETS)) {
    if (want.length && !want.includes(name)) continue;
    if (spec.sheet) { // 시트 한 장 = 호출 1번
      if (!force && fs.existsSync(path.join(OUT, `${name}.png`))) continue;
      process.stdout.write(`${name} (sheet) ... `);
      try {
        const img = await generate(name, spec, 'character turnaround sheet, three views of the same character standing in a row, evenly spaced, left to right: front view, back view, side profile view facing right');
        const parts = splitSheet(PNG.sync.read(keyOutWhite(img)));
        ['', '_b', '_s'].forEach((sfx, i) => fs.writeFileSync(path.join(OUT, `${name}${sfx}.png`), parts[i]));
        console.log('ok');
      } catch (e) { console.log('FAIL', e.message); }
      continue;
    }
    for (const [suffix, view] of Object.entries(VIEWS)) {
      const file = path.join(OUT, `${name}${suffix}.png`);
      if (!force && fs.existsSync(file)) continue;
      process.stdout.write(`${name}${suffix} ... `);
      try {
        const img = await generate(name, spec, view);
        fs.writeFileSync(file, shrink(spec.key ? keyOutWhite(img) : jpgToPng(img), SIZE));
        console.log('ok');
      } catch (e) { console.log('FAIL', e.message); }
    }
  }
}
