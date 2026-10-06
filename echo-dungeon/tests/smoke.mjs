// 헤드리스 브라우저로 게임 전체 흐름을 검증한다.
//   node tests/smoke.mjs            (SHOTS=폴더 를 주면 스크린샷 저장)
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'www');
const SHOTS = process.env.SHOTS;
const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.png': 'image/png', '.json': 'application/json' };
const server = http.createServer((req, res) => {
  const p = path.join(ROOT, decodeURIComponent(req.url.split('?')[0]).replace(/^\/$/, '/index.html'));
  if (!p.startsWith(ROOT) || !fs.existsSync(p) || fs.statSync(p).isDirectory()) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { 'Content-Type': TYPES[path.extname(p)] || 'application/octet-stream' });
  fs.createReadStream(p).pipe(res);
});
await new Promise((r) => server.listen(0, r));
const URL_ = `http://127.0.0.1:${server.address().port}/`;

let failed = 0;
const ok = (cond, msg) => { console.log(`${cond ? 'PASS' : 'FAIL'}  ${msg}`); if (!cond) failed++; };

const browser = await chromium.launch(process.env.CHROMIUM ? { executablePath: process.env.CHROMIUM } : {});
const ctx = await browser.newContext({ viewport: { width: 390, height: 760 }, hasTouch: true, isMobile: true, deviceScaleFactor: 2 });
const page = await ctx.newPage();
const errors = [];
page.on('pageerror', (e) => errors.push(e.message));
page.on('console', (m) => { if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(m.text()); });
const shot = async (n) => { if (SHOTS) { fs.mkdirSync(SHOTS, { recursive: true }); await page.screenshot({ path: path.join(SHOTS, n + '.png') }); } };
const ev = (f, a) => page.evaluate(f, a);

await page.goto(URL_);
await page.waitForFunction(() => window.__ed && document.getElementById('title').classList.contains('on'));
await page.waitForTimeout(300);
await shot('01-title');
ok(await ev(() => !document.getElementById('start').disabled), '타이틀: 1챕터 출발 가능');
ok(await ev(() => document.getElementById('cnext').disabled === false && document.getElementById('cname').textContent === '이끼 동굴'), '타이틀: 챕터 표시');
await page.click('#cnext');
ok(await ev(() => document.getElementById('start').disabled), '타이틀: 2챕터는 잠김');
await page.click('#cprev');

// 1판: 시작 → 터치 이동
await page.click('#start');
ok(await ev(() => __ed.S.scene === 'play'), '게임 시작');
const cdp = await ctx.newCDPSession(page);
const x0 = await ev(() => __ed.S.G.hero.x);
await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: 150, y: 520 }] });
for (let i = 1; i <= 8; i++) { await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x: 150 + i * 7, y: 520 }] }); await page.waitForTimeout(60); }
const mv = await ev(() => ({ x: __ed.S.G.hero.x, sp: __ed.S.G.hero.sp, ph: __ed.S.G.hero.phase }));
await shot('02-play-touch');
await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
ok(mv.x > x0 + 20 && mv.sp > 0.5 && mv.ph > 0, `터치 드래그로 이동 + 걷기 모션 (x ${x0.toFixed(0)}→${mv.x.toFixed(0)})`);

// 일시정지
await page.click('#pauseBtn');
const tPause = await ev(() => __ed.S.G.t);
await page.waitForTimeout(300);
ok(await ev((t) => __ed.S.scene === 'pause' && __ed.S.G.t === t, tPause), '일시정지 중에는 시간이 멈춤');
await shot('03-pause');
await page.click('#resume');
ok(await ev(() => __ed.S.scene === 'play'), '계속하기');

// 카드 선택 화면 (DOM 클릭)
await ev(() => { while (__ed.S.scene === 'play') __ed.S.G && __ed.step(); });
ok(await ev(() => __ed.S.scene === 'pick' && document.querySelectorAll('#cards .card').length === 3), '10초에 카드 3장');
await page.waitForTimeout(450);
await shot('04-pick');
await page.click('#cards .card');
ok(await ev(() => __ed.S.scene === 'play' && __ed.S.G.picks.length === 1), '카드 선택 반영');

// 봇으로 끝까지
await ev(() => __ed.autoPlay(60 * 200, ['blade', 'power', 'multi', 'rapid']));
await page.waitForFunction(() => __ed.S.scene === 'result', null, { timeout: 5000 });
await shot('05-result');
const r1 = await ev(() => ({ res: __ed.S.G.result, echoes: __ed.S.save.echoes[0].length, gold: __ed.S.save.gold }));
ok(r1.echoes === 1, '판이 끝나면 메아리 1개 저장');
ok(r1.gold > 0, `골드 획득 (${r1.gold})`);
ok(true, `1판 결과: ${r1.res.won ? '보스 처치' : `${r1.res.t.toFixed(1)}초 생존`}, 처치 ${r1.res.kills}`);

// 2판: 메아리 재생 + 원수
await page.click('#home');
ok(await ev(() => __ed.S.scene === 'title' && __ed.S.G === null), '타이틀로 복귀');
if (!r1.res.won) ok(await ev(() => document.getElementById('tnem').style.display === 'block'), '타이틀에 원수 표시');
await page.click('#start');
await ev(() => __ed.autoPlay(60 * 27, ['bolt', 'poison', 'crit']));
const r2 = await ev(() => { const G = __ed.S.G; return { ended: G.ended, echo: G.echoes[0] && { alive: G.echoes[0].alive, x: G.echoes[0].x, y: G.echoes[0].y }, nem: G.enemies.some((e) => e.nem) || G.nemKilled }; });
if (!r2.ended) {
  // 메아리는 지난 판이 끝난 시점에 사라진다 (1판째 생존 시간이 27초 이상이면 아직 움직여야 함)
  ok(!!r2.echo && (Math.abs(r1.res.t - 27) < 2 || r2.echo.alive === (r1.res.t > 27)), `메아리 재생 (지난 판 ${r1.res.t.toFixed(0)}초 → ${r2.echo && r2.echo.alive ? '함께 움직임' : '이미 사라짐'})`);
  if (!r1.res.won) ok(r2.nem, '25초에 원수 등장');
  await page.waitForTimeout(100);
  await shot('06-echo-nemesis');
}
// 포기
if (await ev(() => __ed.S.scene === 'play')) {
  await page.click('#pauseBtn');
  await page.click('#quit');
  await page.click('#myes');
  await page.waitForFunction(() => __ed.S.scene === 'result', null, { timeout: 3000 });
  ok(await ev(() => __ed.S.G.result.abandoned && __ed.S.save.echoes[0].length === 1), '포기하면 메아리로 남지 않음');
  await page.click('#home');
}

// 상점
await ev(() => { __ed.S.save.gold += 1000; });
await page.click('#tshop');
await shot('07-shop');
const g0 = await ev(() => __ed.S.save.gold);
await page.click('#shopList .item:first-child button');
const s1 = await ev(() => ({ gold: __ed.S.save.gold, hp: __ed.S.save.shop.hp }));
ok(s1.hp === 1 && s1.gold < g0, '강화 구매');
await page.click('#shop [data-back]');

// 임무
await page.click('#tmis');
ok(await ev(() => document.querySelectorAll('#misList .item').length === 3), '오늘의 임무 3개');
await shot('08-missions');
await page.click('#missions [data-back]');

// 설정 + 저장 유지
await page.click('#tset');
await page.click('[data-set="music"]');
await page.fill('#nameIn', '테스터'); await page.press('#nameIn', 'Enter');
await shot('09-settings');
await page.click('#settings [data-back]');
await page.reload();
await page.waitForFunction(() => window.__ed && document.getElementById('title').classList.contains('on'));
const saved = await ev(() => ({ music: __ed.S.save.settings.music, name: __ed.S.save.name, hp: __ed.S.save.shop.hp, echoes: __ed.S.save.echoes[0].length }));
ok(saved.music === false && saved.name === '테스터' && saved.hp === 1 && saved.echoes >= 1, '새로고침 후 저장 유지');

// 모든 챕터: 판 길이, 중간 보스, 최종 보스, 생존 모드(-1), 두 번째 바퀴(스테이지 8)
for (const ch of [0, 1, 2, 3, 4, -1, 7]) {
  const r = await ev((c) => {
    const s = __ed.S, cp = __ed.stageChap(c);
    s.save.unlocked = 99; s.chapter = c;
    __ed.startRun(c);
    const G = s.G;
    G.hero.st.maxhp = G.hero.hp = 1e9; // 끝까지 살아남게
    G.hero.st.dmg *= 4; // 넓은 월드에서 봇이 중간 보스를 늦게 잡아도 다음 중간 보스 순서를 확인할 수 있게
    const t0 = performance.now();
    __ed.autoPlay(60 * (cp.endless ? 135 : cp.time + 30), ['blade', 'bolt', 'poison', 'boom', 'power', 'multi']);
    const ms = performance.now() - t0;
    return { name: cp.name, time: cp.time, endless: !!cp.endless, mids: cp.mid.length, midIdx: G.midIdx, boss: !!G.boss, bossName: G.boss && G.boss.name, t: G.t, ticks: G.tick, ms, ended: G.ended, picks: G.picks.length };
  }, ch);
  if (r.endless) {
    ok(!r.boss && r.t > 130 && r.midIdx >= 2, `${r.name} 무한 던전: ${r.t.toFixed(0)}초 생존, 중간 보스 ${r.midIdx}번, 최종 보스 없음`);
  } else {
    ok(r.boss, `${r.name}: ${r.time}초 / 중간 보스 ${r.midIdx}/${r.mids} / 최종 보스 ${r.bossName}`);
    ok(r.midIdx === r.mids, `${r.name}: 중간 보스가 모두 등장`);
    ok(r.picks >= Math.floor((r.time - 1) / 10), `${r.name}: 카드 ${r.picks}장`);
  }
  ok(r.ms / r.ticks < 4, `${r.name}: 시뮬레이션 성능 (틱당 ${(r.ms / r.ticks).toFixed(2)}ms)`);
  if (ch === 2 || ch === 4) { await page.waitForTimeout(50); await shot(`10-chapter${ch + 1}`); }
  await ev(() => { if (!__ed.S.G.ended) { __ed.S.scene = 'play'; __ed.endRun(false, true); } });
  await page.waitForFunction(() => __ed.S.scene === 'result', null, { timeout: 3000 });
  await ev(() => __ed.goTitle());
}

// 스테이지 5를 깨면 스테이지 6(두 번째 바퀴)과 생존 모드가 열린다
const unlockT = await ev(() => {
  const s = __ed.S; s.save.unlocked = 5; s.chapter = 4;
  __ed.startRun(4);
  const G = s.G; G.hero.st.maxhp = G.hero.hp = 1e9; G.hero.st.dmg = 1e5; G.hero.st.shots = 6;
  __ed.autoPlay(60 * 200, ['power']);
  return { won: G.won, unlocked: s.save.unlocked, clears: s.save.clears[4] };
});
ok(unlockT.won && unlockT.unlocked === 6 && unlockT.clears >= 1, '스테이지 5 클리어 → 스테이지 6·생존 모드 해금');
ok(await ev(() => { const a = __ed.stageChap(5), b = __ed.stageChap(0); return a.ch === 0 && a.hp > b.hp && a.mid.length > b.mid.length; }), '두 번째 바퀴는 더 강하고 중간 보스가 많다');
await ev(() => __ed.goTitle());

// v1 저장 데이터 이전
await ev(() => {
  localStorage.clear();
  localStorage.setItem('echoDungeon.v1', JSON.stringify({ v: 1, name: '옛날', gold: 77, best: 300, runs: 4, wins: 1, echoes: [{ path: [100, 100, 110, 100, 120, 100], picks: [], kills: 3 }], nemesis: { type: 'bat', lvl: 2 } }));
});
await page.reload();
await page.waitForFunction(() => window.__ed && document.getElementById('title').classList.contains('on'));
const mig = await ev(() => ({ name: __ed.S.save.name, gold: __ed.S.save.gold, e: __ed.S.save.echoes[0].length, nem: __ed.S.save.nemesis[0] }));
ok(mig.name === '옛날' && mig.gold === 77 && mig.e === 1 && mig.nem && mig.nem.type === 'bat', 'v1 저장 데이터 이전');

// 깨진 저장 데이터
await ev(() => { localStorage.setItem('echoDungeon.v2', '{"v":2,"echoes":"x","best":null,"gold":-5,"unlocked":99}'); });
await page.reload();
await page.waitForFunction(() => window.__ed && document.getElementById('title').classList.contains('on'));
ok(await ev(() => __ed.S.save.gold === 0 && __ed.S.save.unlocked === 99 && Array.isArray(__ed.S.save.echoes[0]) && __ed.S.save.echoes.length === 6), '깨진 저장 데이터 복구');

// 직업: 타이틀에서 고르면 저장되고, 직업마다 사거리·체력이 다르며, 모두 전투가 된다
await page.reload();
await page.waitForFunction(() => window.__ed && document.getElementById('title').classList.contains('on'));
const stats = {};
for (const id of ['sword', 'archer', 'mage']) {
  await page.click('#tcharBtn');
  await page.click(`#ctabs button[data-cls="${id}"]`);
  await page.click('#cpick');
  ok(await ev((i) => __ed.S.save.cls === i && document.getElementById('title').classList.contains('on') && document.getElementById('tcharBtn').innerHTML.includes(i === 'sword' ? 'hero' : i === 'archer' ? 'archer' : 'wizard'), id), `캐릭터 선택 화면에서 고르기: ${id}`);
  stats[id] = await ev(() => {
    __ed.startRun(0);
    const G = __ed.S.G, st = G.hero.st, base = { range: st.range, hp: st.maxhp }; // 카드를 받기 전 기본 능력치
    __ed.autoPlay(60 * 25, ['rapid', 'power']);
    return { ...base, kills: G.kills, sprite: G.hero.sprite };
  });
  ok(stats[id].kills > 0, `직업 ${id}: 25초 동안 ${stats[id].kills}마리 처치`);
  await ev(() => __ed.goTitle());
}
ok(stats.sword.range < stats.mage.range && stats.mage.range < stats.archer.range, '사거리: 검사 < 법사 < 궁사');
ok(stats.sword.hp > stats.mage.hp && stats.mage.hp > stats.archer.hp, '체력: 검사 > 법사 > 궁사');
ok(stats.archer.sprite === 'archer' && stats.mage.sprite === 'wizard', '직업별 이미지');
// 카드 70여 장: 전부 한 번씩 받고 전투를 돌려도 오류가 없고, 새 효과가 실제로 작동한다
const cardsT = await ev(() => {
  const S = __ed.S; S.save.unlocked = 99; S.save.tutorial = 1;
  const ids = __ed.CARDS.filter((c) => !c.fallback).map((c) => c.id);
  const out = { total: ids.length, legend: __ed.CARDS.filter((c) => c.rar === 4).length, bad: [] };
  for (const id of ids) { // 카드마다: 받자마자 능력치가 NaN이 되지 않는지
    __ed.startRun(0); const h = S.G.hero; __ed.applyCard(h.st, id, h);
    for (const k of Object.keys(h.st)) if (typeof h.st[k] === 'number' && !Number.isFinite(h.st[k])) out.bad.push(id + '.' + k);
  }
  for (const cls of ['sword', 'archer', 'mage']) { // 전부 가진 채로 90초 전투 (모든 효과가 한꺼번에 돌아간다)
    S.save.cls = cls; __ed.startRun(2); const G = S.G, h = G.hero;
    for (const id of ids) __ed.applyCard(h.st, id, h);
    h.hp = h.st.maxhp = 1e9; h.st.cd = 0.15;
    __ed.autoPlay(60 * 90, []);
    out[cls] = { kills: G.kills, t: +G.t.toFixed(0), scene: S.scene };
  }
  return out;
});
ok(cardsT.total >= 70 && cardsT.legend === 3, `카드 ${cardsT.total}장 (전설 ${cardsT.legend}장)`);
ok(cardsT.bad.length === 0, `모든 카드의 능력치가 정상 ${cardsT.bad.slice(0, 5)}`);
ok(['sword', 'archer', 'mage'].every((c) => cardsT[c].kills > 50 && cardsT[c].t >= 80), `카드 전부 가진 채 90초 전투: ${JSON.stringify(['sword', 'archer', 'mage'].map((c) => cardsT[c].kills))}`);
const fx = await ev(() => { // 새 효과가 실제로 작동하는지
  const S = __ed.S; S.save.cls = 'archer'; S.save.unlocked = 99; const r = {};
  const fresh = (ids) => { __ed.startRun(0); S.G.enemies.length = 0; S.G.spawnT = 1e9; S.G.nextPick = 1e9; const h = S.G.hero; for (const id of ids) __ed.applyCard(h.st, id, h); return S.G; };
  let G = fresh(['regen', 'regen']); G.hero.hp = 10; for (let i = 0; i < 120; i++) __ed.step(); r.regen = G.hero.hp > 12.5;
  G = fresh(['secondwind']); G.t = 20; G.hero.hp = 1; G.hero.inv = 0; G.enemies.push({ type: 'slime', x: G.hero.x, y: G.hero.y, r: 11, hp: 99, maxhp: 99, sp: 0, dmg: 50, seed: 1, flash: 0, bt: 0, dead: false, face: 1, t: 1, z: 0, slowT: 0, slow: 0 }); __ed.step();
  r.second = S.scene === 'play' && G.hero.hp > 20 && G.lsUsed;
  G = fresh(['judgment']); G.enemies.push({ type: 'slime', x: 100, y: 200, r: 11, hp: 500, maxhp: 500, sp: 0, dmg: 1, seed: 1, flash: 0, bt: 0, dead: false, face: 1, t: 1, z: 0, slowT: 0, slow: 0 });
  for (let i = 0; i < 60 * 4; i++) __ed.step(); r.smite = G.enemies[0].hp < 500 - 20;
  G = fresh(['ember']); const e = { type: 'slime', x: G.hero.x + 60, y: G.hero.y, r: 11, hp: 5000, maxhp: 5000, sp: 0, dmg: 1, seed: 1, flash: 0, bt: 0, dead: false, face: 1, t: 1, z: 0, slowT: 0, slow: 0 }; G.enemies.push(e);
  for (let i = 0; i < 60 * 3; i++) { e.x = G.hero.x + 60; e.y = G.hero.y; __ed.step(); } r.burn = e.hp < 5000 - 60;
  G = fresh(['crown']); r.crown = G.hero.st.dmg > 13 && G.hero.st.maxhp > 100;
  return r;
});
ok(fx.regen, '재생: 체력이 차오른다');
ok(fx.second, '질긴 생명력: 쓰러져도 한 번 일어선다');
ok(fx.smite, '천벌: 화면의 적에게 번개');
ok(fx.burn, '불씨: 맞은 적이 불탄다');
ok(fx.crown, '만능의 왕관: 능력치 상승');

// 부활: 쓰러지면 한 번 기회. 브라우저에서는 광고 없이 바로 보상된다
await ev(() => { const S = __ed.S; S.save.unlocked = 99; S.save.tutorial = 1; __ed.startRun(0); __ed.show(null); S.G.t = 10; S.G.nextPick = 999; });
await ev(() => { const G = __ed.S.G; G.hero.inv = 0; G.hero.st.shield = 0; G.hero.hp = 1; G.enemies.push({ type: 'slime', x: G.hero.x, y: G.hero.y, r: 11, hp: 99, maxhp: 99, sp: 0, dmg: 50, seed: 1, flash: 0, bt: 0, dead: false, face: 1, t: 1, z: 0, slowT: 0, slow: 0 }); __ed.step(); });
ok(await ev(() => __ed.S.scene === 'revive' && document.getElementById('revive').classList.contains('on')), '쓰러지면 부활 화면');
await page.waitForTimeout(600);
await page.click('#revAd');
await page.waitForFunction(() => __ed.S.scene === 'play', null, { timeout: 3000 });
ok(await ev(() => { const h = __ed.S.G.hero; return h.hp === Math.ceil(h.st.maxhp / 2) && h.inv > 0; }), '광고 보고 부활: 체력 절반, 잠깐 무적');
await ev(() => { const G = __ed.S.G; G.coinsGot = 50; G.hero.inv = 0; G.hero.hp = 1; __ed.step(); });
await page.waitForFunction(() => __ed.S.scene === 'result', null, { timeout: 4000 });
ok(true, '두 번째로 쓰러지면 부활 없이 결과');
const goldBefore = await ev(() => __ed.S.save.gold);
const dbl = await ev(() => { const b = document.getElementById('rdouble'); return { text: b.textContent, gold: __ed.S.G.result.gold }; });
if (dbl.gold >= 10) {
  await page.click('#rdouble');
  await page.waitForFunction((g) => __ed.S.save.gold > g, goldBefore, { timeout: 3000 });
  ok(await ev((g) => __ed.S.save.gold === g + __ed.S.G.result.gold && document.getElementById('rdouble').disabled, goldBefore), `골드 2배 (+${dbl.gold})`);
} else ok(dbl.text === '', '골드가 적으면 2배 단추 숨김');
await ev(() => __ed.goTitle());

// 메아리 코드: 만들고 되읽기, 이상한 코드는 거절
const share = await ev(async () => {
  const { encodeEcho, decodeEcho } = await import('./js/share.js');
  const path = []; for (let i = 0; i < 1800; i++) path.push(150 + Math.round(Math.sin(i / 20) * 80), 300 + Math.round(Math.cos(i / 30) * 120));
  const rec = { path, picks: [{ t: 600, id: 'power' }, { t: 1200, id: 'multi' }], cls: 'archer' };
  const code = await encodeEcho(rec, '친구<b>', 2);
  const back = await decodeEcho(code.slice(0, 50) + '\n ' + code.slice(50)); // 메신저가 줄을 바꿔도 읽힌다
  let bad = 0;
  for (const c of ['hello', 'ED0.' + btoa('{"d":[1,2,"x",4]}'), 'ED0.' + btoa('{"d":[1]}')]) { try { await decodeEcho(c); } catch (e) { bad++; } }
  const evil = await decodeEcho('ED0.' + btoa(JSON.stringify({ n: '<img src=x onerror=alert(1)>', c: 'hacker', h: 99, k: [[1, 'nope'], [5, 'power']], d: [9999, -9999, 1, 1] })));
  return { len: code.length, same: JSON.stringify(back.path) === JSON.stringify(path) && back.picks.length === 2 && back.cls === 'archer' && back.ch === 2, name: back.name, bad, evil };
});
ok(share.same, `메아리 코드 왕복 (1800점 → ${share.len}자)`);
ok(share.bad === 3 && !/[<>]/.test(share.name) && !/[<>]/.test(share.evil.name), '잘못된 코드 거절, 이름의 태그 제거');
ok(share.evil.cls === 'sword' && share.evil.ch === 0 && share.evil.picks.length === 1 && share.evil.path[0] <= 720 && share.evil.path[1] >= 0, '범위 밖 값은 안전한 값으로');
// 친구 메아리는 다음 판에 이름표를 달고 함께 싸운다
ok(await ev(async () => {
  const { encodeEcho, decodeEcho } = await import('./js/share.js');
  const S = __ed.S, path = []; for (let i = 0; i < 900; i++) path.push(180, 300 + (i % 50));
  const f = await decodeEcho(await encodeEcho({ path, picks: [], cls: 'mage' }, '철수', 0));
  S.save.friend[0] = { path: f.path, picks: f.picks, cls: f.cls, name: f.name };
  __ed.startRun(0);
  const e = S.G.echoes.find((x) => x.friend === '철수');
  __ed.goTitle();
  return !!e && e.cls === 'mage';
}), '친구 메아리가 함께 싸운다');

// 개인정보처리방침
await page.click('#tset'); await page.click('#privBtn');
await page.waitForFunction(() => { const f = document.getElementById('privFrame'); const d = f.contentDocument; return !!(d && d.body && /개인정보/.test(d.body.innerText)); }, null, { timeout: 4000 });
ok(true, '개인정보처리방침 열림');
await ev(() => document.querySelector('#privacy [data-back]').click());
ok(await ev(() => document.getElementById('settings').classList.contains('on')), '방침에서 돌아가면 설정 화면');
await ev(() => __ed.goTitle());

ok(errors.length === 0, `페이지 오류 없음 ${errors.length ? JSON.stringify(errors.slice(0, 5)) : ''}`);
await browser.close();
server.close();
console.log(failed ? `\n${failed}개 실패` : '\n모두 통과');
process.exit(failed ? 1 : 0);
