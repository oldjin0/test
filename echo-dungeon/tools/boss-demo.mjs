// 보스 공격 예고를 장면별로 캡처한다.  node tools/boss-demo.mjs <출력 폴더>
import http from 'node:http'; import fs from 'node:fs'; import path from 'node:path'; import { fileURLToPath } from 'node:url'; import { chromium } from 'playwright';
const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'www');
const T = { '.html': 'text/html', '.js': 'text/javascript', '.png': 'image/png', '.jpg': 'image/jpeg' };
const srv = http.createServer((q, r) => { const p = path.join(ROOT, decodeURIComponent(q.url.split('?')[0]).replace(/^\/$/, '/index.html')); if (!p.startsWith(ROOT) || !fs.existsSync(p) || fs.statSync(p).isDirectory()) { r.writeHead(404); r.end(); return; } r.writeHead(200, { 'Content-Type': T[path.extname(p)] || 'application/octet-stream' }); fs.createReadStream(p).pipe(r); });
await new Promise((r) => srv.listen(0, r));
const out = process.argv[2]; fs.mkdirSync(out, { recursive: true });
const b = await chromium.launch(); const ctx = await b.newContext({ viewport: { width: 390, height: 760 }, deviceScaleFactor: 2 }); const p = await ctx.newPage();
const errors = []; p.on('pageerror', (e) => errors.push(e.message));
await p.goto(`http://127.0.0.1:${srv.address().port}/`); await p.waitForFunction(() => window.__ed && document.getElementById('title').classList.contains('on')); await p.waitForTimeout(1000);
// 보스를 불러내고 멈춘 채로 원하는 순간을 만든다 (S.scene='pause'로 자동 진행을 막고 step으로 한 틱씩)
const boss = (ch, prep) => p.evaluate(([ch, prep]) => {
  const S = __ed.S; S.save.unlocked = 99; S.save.tutorial = 1; S.save.cls = 'archer'; __ed.startRun(ch); __ed.show(null);
  const G = S.G, h = G.hero; h.hp = h.st.maxhp = 1e9; h.st.dmg = 0.001; G.enemies.length = 0; G.spawnT = 1e9; G.nextPick = 1e9; G.eliteT = 1e9;
  G.t = G.time + 0.01; S.scene = 'play'; __ed.step(); S.scene = 'pause';
  const e = G.boss; e.x = h.x + 10; e.y = h.y - 170; G.ebul.length = 0;
  new Function('e', 'G', 'h', prep)(e, G, h);
  for (let i = 0; i < 2; i++) { S.scene = 'play'; __ed.step(); S.scene = 'pause'; }
  return e.name;
}, [ch, prep]);
const shot = (n) => p.screenshot({ path: `${out}/${n}.png` });
console.log(await boss(0, "e.js = 'walk'; e.jt = 0.01;")); await p.waitForTimeout(200); await shot('jump-1-웅크림');
await p.evaluate(() => { const S = __ed.S; for (let i = 0; i < 30 + 30; i++) { S.scene = 'play'; __ed.step(); S.scene = 'pause'; } }); await p.waitForTimeout(150); await shot('jump-2-공중');
console.log(await boss(2, 'e.ft = 0.35;')); await p.waitForTimeout(200); await shot('radial-예고');
console.log(await boss(2, 'e.ft = 0.35; e.hp = e.maxhp * 0.3;')); await p.waitForTimeout(200); await shot('radial-예고-분노');
console.log(await boss(1, 'e.ft = 0.3;')); await p.waitForTimeout(200); await shot('lich-예고');
console.log('errors', JSON.stringify(errors));
await b.close(); srv.close();
