// 신규 플레이어의 진행 곡선을 봇으로 측정한다: 챕터별로 몇 판 만에 깨는지
//   node tests/balance.mjs [판수] [반복]
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'www');
const server = http.createServer((req, res) => {
  const p = path.join(ROOT, decodeURIComponent(req.url.split('?')[0]).replace(/^\/$/, '/index.html'));
  if (!p.startsWith(ROOT) || !fs.existsSync(p) || fs.statSync(p).isDirectory()) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { 'Content-Type': p.endsWith('.js') ? 'text/javascript' : 'text/html' });
  fs.createReadStream(p).pipe(res);
});
await new Promise((r) => server.listen(0, r));
const RUNS = +process.argv[2] || 80, REPS = +process.argv[3] || 3, CLS = process.argv[4] || 'sword';
const browser = await chromium.launch(process.env.CHROMIUM ? { executablePath: process.env.CHROMIUM } : {});
const page = await browser.newPage();
await page.goto(`http://127.0.0.1:${server.address().port}/`);
await page.waitForFunction(() => window.__ed);

const all = [];
for (let rep = 0; rep < REPS; rep++) {
  const out = await page.evaluate(([RUNS, CLS]) => {
    localStorage.clear();
    const S = __ed.S;
    const fresh = JSON.parse(JSON.stringify(S.save));
    Object.assign(S.save, { gold: 0, unlocked: 1, best: [0, 0, 0, 0, 0, 0], clears: [0, 0, 0, 0, 0, 0], echoes: [[], [], [], [], [], []], nemesis: [null, null, null, null, null, null], shop: {}, runs: 0, wins: 0, tutorial: 1, cls: CLS });
    const PREF = ['storm', 'legion', 'thunder', 'blade', 'power', 'multi', 'rapid', 'bolt', 'echo', 'poison', 'crit', 'vital', 'shield', 'boom', 'leech', 'pierce', 'frost', 'boots', 'magnet', 'meat', 'purse'];
    const BUY = ['atk', 'hp', 'echo', 'reroll', 'greed', 'spd', 'slot'];
    const SHOP = { hp: [30, 15], atk: [40, 15], spd: [40, 5], echo: [60, 5], greed: [50, 5], reroll: [80, 3], slot: [300, 2] };
    const cost = (id, lv) => Math.round(SHOP[id][0] * Math.pow(lv + 1, 1.5));
    const log = [];
    for (let r = 0; r < RUNS; r++) {
      const ch = S.save.unlocked - 1;
      __ed.startRun(ch);
      __ed.autoPlay(60 * 400, PREF);
      const res = S.G.result;
      log.push({ killer: S.G.killer, nem: S.save.nemesis[ch] && S.save.nemesis[ch].lvl, ch, won: res.won, t: +res.t.toFixed(1), boss: res.reachedBoss, left: res.bossLeft, gold: res.gold, kills: res.kills, ek: res.echoKills, echoes: S.G.echoes.length });
      // 골드는 싼 강화부터 산다
      for (let guard = 0; guard < 30; guard++) {
        let best = null;
        for (const id of BUY) { const lv = S.save.shop[id] || 0; if (lv < SHOP[id][1]) { const c = cost(id, lv); if (c <= S.save.gold && (!best || c < best.c)) best = { id, c }; } }
        if (!best) break;
        S.save.gold -= best.c; S.save.shop[best.id] = (S.save.shop[best.id] || 0) + 1;
      }
      if (S.save.clears[4] > 0) break;
    }
    S.G = null; S.scene = 'title';
    return { log, shop: S.save.shop };
  }, [RUNS, CLS]);
  all.push(out);
}
for (const [i, o] of all.entries()) {
  console.log(`\n=== 플레이어 ${i + 1} === 최종 강화 ${JSON.stringify(o.shop)}`);
  for (let ch = 0; ch < 6; ch++) {
    const runs = o.log.filter((l) => l.ch === ch);
    if (!runs.length) continue;
    const firstWin = runs.findIndex((l) => l.won);
    const boss = runs.filter((l) => l.boss).length;
    const avgT = runs.reduce((a, l) => a + l.t, 0) / runs.length;
    console.log(`챕터 ${ch + 1}: ${runs.length}판, ${firstWin >= 0 ? firstWin + 1 + '판째 클리어' : '미클리어'}, 보스 도달 ${boss}/${runs.length}, 평균 생존 ${avgT.toFixed(1)}초, 판당 골드 ${(runs.reduce((a, l) => a + l.gold, 0) / runs.length).toFixed(0)}, 메아리 처치 비율 ${(runs.reduce((a, l) => a + l.ek, 0) / Math.max(1, runs.reduce((a, l) => a + l.kills, 0)) * 100).toFixed(0)}%`);
    const kc = {}; for (const l of runs) if (!l.won) kc[l.killer] = (kc[l.killer] || 0) + 1;
    console.log('   사망 원인 ' + JSON.stringify(kc) + ' / 마지막 원수 Lv.' + runs[runs.length - 1].nem);
    console.log('   ' + runs.map((l) => (l.won ? 'W' : l.boss ? `b${l.left}` : `${Math.round(l.t)}`)).join(' '));
  }
}
await browser.close(); server.close();
