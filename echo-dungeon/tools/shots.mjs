// 개발용: 게임을 띄워 장면을 캡처한다.  node tools/shots.mjs <출력 폴더> <장면...>
//   장면: walk(걷기 프레임), play(챕터별 전투), title
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
const [out, ...scenes] = process.argv.slice(2);
fs.mkdirSync(out, { recursive: true });
const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 390, height: 760 }, deviceScaleFactor: 2, hasTouch: true, isMobile: true });
const page = await ctx.newPage();
const errors = [];
page.on('pageerror', (e) => errors.push(e.message));
await page.goto(`http://127.0.0.1:${server.address().port}/`);
await page.waitForFunction(() => window.__ed && document.getElementById('title').classList.contains('on'));
await page.waitForTimeout(800);
const run = (ch, cls) => page.evaluate(([ch, cls]) => { const S = __ed.S; S.save.cls = cls; S.save.unlocked = 99; S.save.tutorial = 1; __ed.startRun(ch); __ed.show(null); }, [ch, cls]);
// 영웅 주변을 확대해 캡처
const heroClip = async (file) => {
  const b = await page.evaluate(() => { const h = __ed.S.G.hero, cv = document.getElementById('c').getBoundingClientRect(); const k = cv.width / 360; return { x: cv.left + (h.x - 40) * k, y: cv.top + (h.y - 70) * k, w: 80 * k, h: 85 * k }; });
  await page.screenshot({ path: file, clip: { x: b.x, y: b.y, width: b.w, height: b.h } });
};

for (const sc of scenes) {
  if (sc === 'title') await page.screenshot({ path: `${out}/title.png` });
  if (sc === 'chars') {
    await page.screenshot({ path: `${out}/title.png` });
    await page.click('#tcharBtn'); await page.waitForTimeout(400); await page.screenshot({ path: `${out}/chars-sword.png` });
    await page.click('#ctabs button[data-cls="archer"]'); await page.waitForTimeout(300); await page.screenshot({ path: `${out}/chars-archer.png` });
    await page.click('#ctabs button[data-cls="mage"]'); await page.waitForTimeout(300); await page.screenshot({ path: `${out}/chars-mage.png` });
  }
  if (sc === 'walk') {
    for (const cls of ['sword', 'archer', 'mage']) {
      await run(0, cls);
      await page.evaluate(() => { __ed.S.G.enemies.length = 0; __ed.S.G.spawnT = 99; });
      for (const key of ['ArrowRight', 'ArrowDown', 'ArrowUp']) {
        await page.keyboard.down(key); await page.waitForTimeout(500);
        for (let i = 0; i < 6; i++) { await heroClip(`${out}/walk-${cls}-${key}-${i}.png`); await page.waitForTimeout(70); }
        await page.keyboard.up(key);
      }
      await page.evaluate(() => __ed.goTitle());
    }
  }
  if (sc === 'play') {
    for (const [ch, cls] of [[0, 'sword'], [1, 'mage'], [2, 'archer'], [3, 'sword'], [4, 'mage'], [5, 'archer']]) {
      await run(ch, cls);
      await page.keyboard.down('ArrowLeft'); await page.waitForTimeout(500); await page.keyboard.up('ArrowLeft');
      await page.waitForTimeout(7000);
      await page.screenshot({ path: `${out}/play-${ch}-${cls}.png` });
      await page.evaluate(() => __ed.goTitle());
    }
  }
}
console.log('errors', JSON.stringify(errors));
await browser.close(); server.close();
