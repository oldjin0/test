// 앱 아이콘, 스플래시, 스토어 그래픽을 게임의 캐릭터 그리기 코드로 렌더링한다.
//   node tools/make-res.mjs   → resources/ 에 저장 (CI가 안드로이드 프로젝트로 복사)
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const server = http.createServer((req, res) => {
  // res.html은 tools/ 에 있어서 assets/ 를 www/assets 로 이어 준다 (생성한 캐릭터 이미지 사용)
  const p = path.join(ROOT, decodeURIComponent(req.url.split('?')[0]).replace(/^\/tools\/assets\//, '/www/assets/'));
  if (!p.startsWith(ROOT) || !fs.existsSync(p) || fs.statSync(p).isDirectory()) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { 'Content-Type': p.endsWith('.js') ? 'text/javascript' : p.endsWith('.html') ? 'text/html' : p.endsWith('.png') ? 'image/png' : 'application/octet-stream' });
  fs.createReadStream(p).pipe(res);
});
await new Promise((r) => server.listen(0, r));
const browser = await chromium.launch(process.env.CHROMIUM ? { executablePath: process.env.CHROMIUM } : {});
const page = await browser.newPage();
await page.goto(`http://127.0.0.1:${server.address().port}/tools/res.html`);
await page.waitForFunction(() => window.ready);
await page.waitForTimeout(800);

const RES = path.join(ROOT, 'resources', 'android', 'res');
async function out(file, kind, w, h) {
  const data = await page.evaluate(([k, ww, hh]) => window.draw(k, ww, hh), [kind, w, h]);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, Buffer.from(data.split(',')[1], 'base64'));
}
const DPI = { mdpi: 1, hdpi: 1.5, xhdpi: 2, xxhdpi: 3, xxxhdpi: 4 };
for (const [d, k] of Object.entries(DPI)) {
  await out(path.join(RES, `mipmap-${d}`, 'ic_launcher.png'), 'icon', 48 * k, 48 * k);
  await out(path.join(RES, `mipmap-${d}`, 'ic_launcher_round.png'), 'round', 48 * k, 48 * k);
  await out(path.join(RES, `mipmap-${d}`, 'ic_launcher_foreground.png'), 'fg', 108 * k, 108 * k);
}
const SPLASH = { mdpi: [320, 480], hdpi: [480, 800], xhdpi: [720, 1280], xxhdpi: [960, 1600], xxxhdpi: [1280, 1920] };
for (const [d, [w, h]] of Object.entries(SPLASH)) {
  await out(path.join(RES, `drawable-port-${d}`, 'splash.png'), 'splash', w, h);
  await out(path.join(RES, `drawable-land-${d}`, 'splash.png'), 'splash', h, w);
}
await out(path.join(RES, 'drawable', 'splash.png'), 'splash', 480, 800);
const STORE = path.join(ROOT, 'resources', 'store');
await out(path.join(STORE, 'icon-512.png'), 'store', 512, 512);
await out(path.join(STORE, 'feature-1024x500.png'), 'feature', 1024, 500);
await browser.close(); server.close();
console.log('resources/ 생성 완료');
