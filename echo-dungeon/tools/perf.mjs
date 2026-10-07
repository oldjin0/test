// 후반부처럼 붐비는 장면(카드 다수, 효과 가득)에서 한 프레임 그리기·한 틱 계산 시간을 잰다.  node tools/perf.mjs
import { chromium } from 'playwright'; import http from 'node:http'; import fs from 'node:fs'; import path from 'node:path'; import { fileURLToPath } from 'node:url';
const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'www');
const T = { '.html': 'text/html', '.js': 'text/javascript', '.png': 'image/png', '.jpg': 'image/jpeg' };
const srv = http.createServer((q, r) => { const p = path.join(ROOT, decodeURIComponent(q.url.split('?')[0]).replace(/^\/$/, '/index.html')); if (!p.startsWith(ROOT) || !fs.existsSync(p) || fs.statSync(p).isDirectory()) { r.writeHead(404); r.end(); return; } r.writeHead(200, { 'Content-Type': T[path.extname(p)] || 'application/octet-stream' }); fs.createReadStream(p).pipe(r); });
await new Promise((r) => srv.listen(0, r));
const b = await chromium.launch(); const ctx = await b.newContext({ viewport: { width: 390, height: 760 }, deviceScaleFactor: 2 }); const p = await ctx.newPage();
await p.goto(`http://127.0.0.1:${srv.address().port}/`); await p.waitForFunction(() => window.__ed && document.getElementById('title').classList.contains('on')); await p.waitForTimeout(1200);
const r = await p.evaluate(async () => {
  const { renderGame } = await import('./js/render.js');
  const S = __ed.S; S.save.unlocked = 99; S.save.cls = 'mage'; __ed.startRun(9); __ed.show(null); // 스테이지 10: 적이 많고 단단하다
  const G = S.G, h = G.hero; h.hp = h.st.maxhp = 1e9;
  for (const id of ['aura', 'aura', 'blade', 'blade', 'blade', 'bolt', 'bolt', 'ember', 'poison', 'poison', 'multi', 'multi', 'nova', 'shield']) __ed.applyCard(h.st, id, h);
  const run = (n) => { for (let i = 0; i < n; i++) { S.scene = 'play'; __ed.step(); if (S.scene === 'pick') __ed.takeCard(G.choices[0].id); S.scene = 'pause'; } };
  run(60 * 45);
  const cv = document.getElementById('c'), c = cv.getContext('2d');
  const t0 = performance.now(); for (let i = 0; i < 120; i++) { S.clock += 1 / 60; renderGame(c); } const ms = (performance.now() - t0) / 120;
  const t1 = performance.now(); run(600); const sim = (performance.now() - t1) / 600;
  return { enemies: G.enemies.length, fx: G.fx.length, renderMs: +ms.toFixed(2), stepMs: +sim.toFixed(3), canvas: cv.width + 'x' + cv.height };
});
console.log(JSON.stringify(r));
await b.close(); srv.close();
