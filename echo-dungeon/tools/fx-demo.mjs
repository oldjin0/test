// 효과 하나하나를 실제 게임에서 띄워 확대 캡처한다.  node tools/fx-demo.mjs <출력 폴더> [효과 이름...]
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'www');
const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.png': 'image/png', '.jpg': 'image/jpeg' };
const server = http.createServer((req, res) => {
  const p = path.join(ROOT, decodeURIComponent(req.url.split('?')[0]).replace(/^\/$/, '/index.html'));
  if (!p.startsWith(ROOT) || !fs.existsSync(p) || fs.statSync(p).isDirectory()) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { 'Content-Type': TYPES[path.extname(p)] || 'application/octet-stream' });
  fs.createReadStream(p).pipe(res);
});
await new Promise((r) => server.listen(0, r));
const [out, ...only] = process.argv.slice(2);
fs.mkdirSync(out, { recursive: true });
const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 390, height: 760 }, deviceScaleFactor: 2, hasTouch: true, isMobile: true });
const page = await ctx.newPage();
const errors = [];
page.on('pageerror', (e) => errors.push(e.message));
await page.goto(`http://127.0.0.1:${server.address().port}/`);
await page.waitForFunction(() => window.__ed && document.getElementById('title').classList.contains('on'));
await page.waitForTimeout(600);

// [이름, 직업, 카드 목록, 시작 후 캡처 시각(ms) 목록, 추가 설정]
const FX = {
  aura_fire: ['mage', ['aura', 'aura'], [700]],
  aura_ice: ['mage', ['glacier', 'glacier'], [700]],
  nova: ['sword', ['nova', 'nova'], [350, 700], (G) => { G.hero.nvT = 0.05; }],
  burn: ['archer', ['ember', 'ember', 'rapid'], [1500]],
  bolt: ['mage', ['bolt', 'bolt', 'bolt'], [90, 160, 230], (G) => { G.hero.bT = 0.05; }],
  blades: ['sword', ['blade', 'blade', 'blade', 'bigblade'], [500]],
  shield: ['sword', ['shield'], [500]],
  poison: ['archer', ['poison', 'poison'], [1500], null, true],
  smite: ['mage', ['judgment'], [80, 150, 260], (G) => { G.hero.smT = 0.05; }],
  crit: ['archer', ['crit', 'crit', 'crit', 'crit', 'sharp', 'rapid'], [500, 800, 1100]],
  melee: ['sword', ['rapid', 'rapid'], [300, 600, 900]],
};
for (const [name, [cls, cards, times, setup, walk]] of Object.entries(FX)) {
  if (only.length && !only.includes(name)) continue;
  await page.evaluate(([cls, cards, walk]) => {
    const S = __ed.S; S.save.cls = cls; S.save.unlocked = 99; S.save.tutorial = 1;
    __ed.startRun(2); __ed.show(null);
    const G = S.G, h = G.hero;
    G.enemies.length = 0; G.spawnT = 1e9; G.nextPick = 1e9; G.eliteT = 1e9;
    h.x = 360; h.y = 600; h.hp = h.st.maxhp = 1e9;
    for (const id of cards) __ed.applyCard(h.st, id, h);
    if (cls === 'archer') h.st.range = 400;
    const mk = (x, y, type = 'slime') => ({ type, x, y, r: 12, hp: 1e7, maxhp: 1e7, sp: 0, dmg: 0, seed: Math.random() * 9, flash: 0, bt: 0, dead: false, face: 1, t: 1, z: 0, slowT: 0, slow: 0 });
    for (const [dx, dy] of [[60, -20], [-65, 10], [20, 70], [-30, -75], [95, 50], [-90, -40]]) G.enemies.push(mk(h.x + dx, h.y + dy));
    if (walk) S.keys.ArrowRight = true;
  }, [cls, cards, walk]);
  if (setup) await page.evaluate(`(${setup.toString()})(__ed.S.G)`);
  let last = 0;
  for (const t of times) {
    await page.waitForTimeout(t - last); last = t;
    const b = await page.evaluate(() => { const G = __ed.S.G, h = G.hero, cam = G.cam, cv = document.getElementById('c').getBoundingClientRect(), k = cv.width / 360; return { x: cv.left + (h.x - cam.x - 120) * k, y: cv.top + (h.y - cam.y - 140) * k, w: 240 * k, h: 220 * k }; });
    await page.screenshot({ path: `${out}/${name}-${t}.png`, clip: { x: Math.max(0, b.x), y: Math.max(0, b.y), width: b.w, height: b.h } });
  }
  await page.evaluate(() => { __ed.S.keys.ArrowRight = false; __ed.goTitle(); });
}
console.log('errors', JSON.stringify(errors));
await browser.close(); server.close();
