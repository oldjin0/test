// 화면 크기와 글꼴이 달라도 버튼·아이콘·글자가 서로 겹치거나 화면 밖으로 나가지 않는지 검사한다.
//   node tools/layout-check.mjs [--shots 폴더]
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
const shotDir = process.argv.includes('--shots') ? process.argv[process.argv.indexOf('--shots') + 1] : null;
if (shotDir) fs.mkdirSync(shotDir, { recursive: true });

// 다양한 기기: [너비, 높이, 글꼴 배율, 설명]. 글꼴 배율은 안드로이드의 "글꼴 크기" 설정과 기본 글꼴 차이를 흉내 낸다
const DEVICES = [[360, 640, 1, '기본'], [412, 915, 1, '긴 폰'], [320, 568, 1, '작은 폰'], [390, 844, 1.15, '글꼴 크게'], [360, 780, 1.3, '글꼴 아주 크게'], [800, 600, 1, '가로 태블릿'], [768, 1024, 1, '세로 태블릿']];
const browser = await chromium.launch();
let bad = 0;
for (const [w, h, fscale, label] of DEVICES) {
  const ctx = await browser.newContext({ viewport: { width: w, height: h }, deviceScaleFactor: 2, hasTouch: true, isMobile: w < 700 });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  await page.waitForFunction(() => window.__ed && document.getElementById('title').classList.contains('on'));
  // 글꼴이 더 크고 줄 간격이 넓은 기기를 흉내 낸다 (stage 안의 글자 크기만 키운다)
  await page.addStyleTag({ content: `#stage{font-size:${fscale}em} #stage *{letter-spacing:${(fscale - 1) * 0.5}px}` });
  if (fscale !== 1) await page.evaluate((k) => { for (const el of document.querySelectorAll('#stage *')) { const fs = parseFloat(getComputedStyle(el).fontSize); if (fs) el.style.fontSize = fs * k + 'px'; } }, fscale);
  const scenes = {
    title: () => { window.__ed.S.save.unlocked = 99; window.__ed.goTitle(); },
    'title-ch3': () => { const S = window.__ed.S; S.save.unlocked = 99; S.chapter = 2; S.save.nemesis[2] = { type: 'brute', lvl: 3 }; window.__ed.goTitle(); },
    chars: () => { window.__ed.goTitle(); document.getElementById('tcharBtn').click(); },
    shop: () => { window.__ed.goTitle(); document.getElementById('tshop').click(); },
    missions: () => { window.__ed.goTitle(); document.getElementById('tmis').click(); },
    settings: () => { window.__ed.goTitle(); document.getElementById('tset').click(); },
    pick: () => { const S = window.__ed.S; S.save.unlocked = 99; window.__ed.startRun(2); window.__ed.show(null); S.G.t = 9.99; S.G.nextPick = 0; window.__ed.step(); },
    pause: () => { const S = window.__ed.S; S.save.unlocked = 99; window.__ed.startRun(0); window.__ed.show(null); document.getElementById('pauseBtn').click(); },
    result: () => { const S = window.__ed.S; S.save.unlocked = 99; window.__ed.startRun(0); S.scene = 'play'; S.G.coinsGot = 60; S.G.kills = 40; S.G.t = 33; window.__ed.endRun(false); },
    revive: () => { const S = window.__ed.S; window.__ed.startRun(0); window.__ed.show(null); S.G.t = 10; S.G.nextPick = 1e9; S.scene = 'revive'; window.__ed.show('revive'); },
  };
  for (const [name, setup] of Object.entries(scenes)) {
    await page.evaluate(setup);
    if (name === 'result') await page.waitForFunction(() => window.__ed.S.scene === 'result', null, { timeout: 4000 });
    await page.waitForTimeout(450);
    const found = await page.evaluate(() => {
      const stage = document.getElementById('stage').getBoundingClientRect();
      const root = [...document.querySelectorAll('#stage > .scr.on, #stage > .menu.on, #pauseBtn.on, #toast.on')];
      const vis = (el) => { const r = el.getBoundingClientRect(), cs = getComputedStyle(el); return r.width > 2 && r.height > 2 && cs.visibility !== 'hidden' && cs.display !== 'none' && cs.opacity !== '0'; };
      const sel = 'button, .pill, .icon, h2, .stat, .item, .card, .chapbox, .tag, .logo, #techo, .nem, #cdesc, #cstats, #cimg, .cinfo, .ver, .set, .row, .echoes';
      const els = [];
      for (const r of root) for (const el of r.querySelectorAll(sel)) if (vis(el) && !el.closest('.list') || (el.closest('.list') && el.matches('.item, .set') && vis(el))) els.push(el);
      if (document.getElementById('pauseBtn').classList.contains('on')) els.push(document.getElementById('pauseBtn'));
      const problems = [];
      const label = (el) => el.id ? '#' + el.id : el.className ? '.' + String(el.className).split(' ')[0] : el.tagName.toLowerCase();
      // 스크롤되는 영역 안의 요소는 스크롤로 닿을 수 있으면 괜찮다. 목록 안에서 잘려 보이지 않는 부분은 겹침으로 세지 않는다
      const scroller = (el) => { for (let p = el.parentElement; p && p.id !== 'stage'; p = p.parentElement) { const o = getComputedStyle(p).overflowY; if ((o === 'auto' || o === 'scroll') && p.scrollHeight > p.clientHeight + 2) return p; } return null; };
      const rectOf = (el) => {
        const r = el.getBoundingClientRect(); let L = r.left, T = r.top, R = r.right, B = r.bottom;
        const sc = scroller(el);
        if (sc) { const q = sc.getBoundingClientRect(); L = Math.max(L, q.left); T = Math.max(T, q.top); R = Math.min(R, q.right); B = Math.min(B, q.bottom); }
        return { left: L, top: T, right: R, bottom: B, clipped: !!sc };
      };
      for (const el of els) { // 화면 밖으로 나갔는가
        const r = el.getBoundingClientRect();
        if (scroller(el)) continue;
        if (el.closest('.list') && !el.matches('.item, .set')) continue;
        if (r.left < stage.left - 2 || r.right > stage.right + 2 || r.top < stage.top - 2 || r.bottom > stage.bottom + 2) problems.push(`화면 밖: ${label(el)} "${(el.textContent || '').trim().slice(0, 14)}"`);
      }
      for (let i = 0; i < els.length; i++) for (let j = i + 1; j < els.length; j++) {
        const a = els[i], b = els[j];
        if (a.contains(b) || b.contains(a)) continue;
        const ra = rectOf(a), rb = rectOf(b);
        const ox = Math.min(ra.right, rb.right) - Math.max(ra.left, rb.left), oy = Math.min(ra.bottom, rb.bottom) - Math.max(ra.top, rb.top);
        if (ox > 3 && oy > 3) problems.push(`겹침: ${label(a)} "${(a.textContent || '').trim().slice(0, 12)}" × ${label(b)} "${(b.textContent || '').trim().slice(0, 12)}" (${ox.toFixed(0)}×${oy.toFixed(0)})`);
      }
      return problems;
    });
    if (found.length) { bad += found.length; console.log(`✗ ${label} ${w}×${h} [${name}]`); for (const f of found.slice(0, 6)) console.log('    ', f); }
    if (shotDir && (w === 360 || w === 390 || w === 320)) await page.screenshot({ path: path.join(shotDir, `${w}-${name}.png`) });
  }
  if (errors.length) { bad += errors.length; console.log('오류', errors.slice(0, 3)); }
  await ctx.close();
}
console.log(bad ? `\n겹침·오류 ${bad}건` : '\n모든 기기·화면에서 겹침 없음');
await browser.close(); server.close();
process.exit(bad ? 1 : 0);
