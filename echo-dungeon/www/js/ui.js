// DOM 화면들: 타이틀 · 강화 · 임무 · 설정 · 카드 선택 · 일시정지 · 결과
import { S } from './state.js';
import { CHAPTERS, STORY, stageChap, CLASSES, CLASS_IDS, BOSSES, ENEMIES, SHOP, RARITY, VERSION, shopLv, shopCost, echoSlots, ensureDaily, missionText } from './data.js';
import { persist, resetSave } from './save.js';
import { startRun, takeCard, reroll, endRun, revive, hooks } from './game.js';
import { encodeEcho, decodeEcho } from './share.js';
import { sfx, applyAudioSettings, playMusic, unlockAudio } from './audio.js';
import { haptic, exitApp, showRewardAd } from './native.js';

const $ = (id) => document.getElementById(id);
const OVERLAYS = ['title', 'pick', 'pause', 'result', 'shop', 'missions', 'settings', 'revive', 'privacy'];
const MENUS = ['shop', 'missions', 'settings', 'privacy'];
let current = 'title', menuFrom = 'title', modalYes = null;

export function show(id) {
  current = id;
  for (const s of OVERLAYS) $(s).classList.toggle('on', s === id);
  $('pauseBtn').classList.toggle('on', id === null && S.scene === 'play');
}
// 화면이 뜨자마자 손가락이 닿아 있던 터치가 버튼을 누르지 않도록 잠깐 막는다
function guard(el, ms = 380) {
  el.style.pointerEvents = 'none';
  setTimeout(() => { el.style.pointerEvents = ''; }, ms);
}

let toastT = 0;
export function toast(msg) {
  const t = $('toast');
  t.textContent = msg; t.classList.add('on');
  clearTimeout(toastT); toastT = setTimeout(() => t.classList.remove('on'), 1800);
}
function confirmBox(html, onYes) {
  $('mtext').innerHTML = html; modalYes = onYes;
  $('modal').classList.add('on');
}
function closeModal() { $('modal').classList.remove('on'); modalYes = null; }

// 생성한 아이콘 이미지. 파일이 없으면 이모지로 대신한다.
const ico = (name, emoji) => `<img class="ico" src="assets/icons/${name}.png" alt="" onerror="this.outerHTML='${emoji}'">`;

/* ---------- 타이틀 ---------- */
export function goTitle() {
  S.G = null; S.scene = 'title'; S.joy.active = false;
  refreshTitle(); show('title'); playMusic('title');
}
export function refreshTitle() {
  const sv = S.save, k = S.chapter, cp = stageChap(k), ch = cp.ch;
  const locked = k < 0 ? sv.unlocked <= STORY : k >= sv.unlocked;
  $('tgold').textContent = `🪙 ${sv.gold}`;
  $('cnum').textContent = k < 0 ? '♾ 생존 모드' : `스테이지 ${k + 1}${cp.depth ? ` · ${cp.depth + 1}번째 바퀴` : ''}`;
  $('cname').textContent = (locked ? '🔒 ' : '') + cp.name;
  $('cinfo').textContent = locked ? (k < 0 ? '스테이지 5를 깨면 열립니다' : `스테이지 ${k}의 보스를 쓰러뜨리면 열립니다`)
    : cp.endless ? `끝없이 강해지는 적 · 최고 ${sv.best[ch]}점`
    : `보스: ${BOSSES[cp.boss].name} · ${cp.time}초${cp.mid.length ? ` · 중간 보스 ${cp.mid.length}` : ''} · 최고 ${sv.best[ch]}점${sv.clears[ch] ? ' · ✔ 클리어' : ''}`;
  $('cprev').disabled = k <= 0;
  $('cnext').disabled = k < 0 || k >= sv.unlocked; // 다음 잠긴 스테이지까지만 보여 준다
  $('tendless').classList.toggle('on', k < 0);
  const n = sv.echoes[ch].length;
  const fr = sv.friend[ch];
  $('techo').textContent = locked ? '' : (n ? `👻 메아리 ${Math.min(n, echoSlots())}/${echoSlots()}명이 함께 싸웁니다` : '👻 이번 판의 당신이 다음 판의 메아리가 됩니다') + (fr ? ` · 👥 ${fr.name}` : '');
  const nem = sv.nemesis[ch], box = $('tnem');
  box.style.display = nem && !locked ? 'block' : 'none';
  if (nem) box.textContent = `☠ ${sv.name}의 원수 · ${ENEMIES[nem.type].name} Lv.${nem.lvl}가 기다린다`;
  $('tcls').innerHTML = CLASS_IDS.map((id) => `<button data-cls="${id}" class="${id === sv.cls ? 'on' : ''}"><span class="i">${ico('cls_' + id, CLASSES[id].ic)}</span>${CLASSES[id].name}<small>${CLASSES[id].tag}</small></button>`).join('');
  $('tclsinfo').textContent = CLASSES[sv.cls].desc;
  $('start').disabled = locked;
  $('start').textContent = locked ? '🔒 잠김' : '출발!';
  const daily = ensureDaily(sv);
  $('misBadge').style.display = daily.list.some((m) => m.done && !m.claimed) ? 'block' : 'none';
}
function beginRun() {
  unlockAudio(); sfx.click();
  S.save.lastChapter = S.chapter; persist(S.save);
  startRun(S.chapter);
  show(null);
}

/* ---------- 메뉴 ---------- */
function openMenu(id) {
  if (!MENUS.includes(current)) menuFrom = current; // 메뉴끼리 옮겨 다닐 때는 처음 화면을 기억한다
  sfx.click();
  if (id === 'shop') renderShop();
  if (id === 'missions') renderMissions();
  if (id === 'settings') renderSettings();
  show(id);
}
function backFromMenu() {
  if (current === 'privacy') { openMenu('settings'); return; }
  sfx.click();
  if (menuFrom === 'title') { refreshTitle(); show('title'); } else show(menuFrom);
}
function renderShop() {
  const sv = S.save;
  $('sgold').textContent = `🪙 ${sv.gold}`;
  const list = $('shopList'); list.innerHTML = '';
  for (const it of SHOP) {
    const lv = shopLv(it.id), maxed = lv >= it.max, cost = shopCost(it, lv);
    const row = document.createElement('div');
    row.className = 'item';
    row.innerHTML = `<div class="ic">${ico('shop_' + it.id, it.ic)}</div><div class="tx"><b>${it.name} <span class="lv">Lv.${lv}/${it.max}</span></b>` +
      `<small>${lv ? it.desc(lv) : '아직 없음'}${maxed ? '' : ` → ${it.desc(lv + 1)}`}</small></div>`;
    const b = document.createElement('button');
    b.className = 'btn2 buy'; b.textContent = maxed ? '최대' : `🪙 ${cost}`;
    b.disabled = maxed || sv.gold < cost;
    b.onclick = () => {
      if (shopLv(it.id) !== lv || sv.gold < cost) return;
      sv.gold -= cost; sv.shop[it.id] = lv + 1; persist(sv);
      sfx.buy(); haptic('light'); toast(`${it.name} Lv.${lv + 1}!`);
      renderShop();
    };
    row.appendChild(b); list.appendChild(row);
  }
}
function renderMissions() {
  const sv = S.save, daily = ensureDaily(sv);
  $('mgold').textContent = `🪙 ${sv.gold}`;
  const list = $('misList'); list.innerHTML = '';
  for (const m of daily.list) {
    const row = document.createElement('div');
    row.className = 'item';
    row.innerHTML = `<div class="ic">${m.claimed ? '✅' : m.done ? '🎁' : '📜'}</div><div class="tx"><b>${missionText(m)}</b>` +
      `<small>보상 🪙 ${m.reward}</small><div class="bar"><i style="width:${Math.round(m.prog / m.goal * 100)}%"></i></div></div>`;
    const b = document.createElement('button');
    b.className = 'btn2 buy';
    b.textContent = m.claimed ? '완료' : m.done ? '받기' : `${m.prog}/${m.goal}`;
    b.disabled = !m.done || m.claimed;
    b.onclick = () => {
      if (!m.done || m.claimed) return;
      m.claimed = true; sv.gold += m.reward; persist(sv);
      sfx.buy(); haptic('light'); toast(`🪙 +${m.reward}`);
      renderMissions();
    };
    row.appendChild(b); list.appendChild(row);
  }
}
function renderSettings() {
  const sv = S.save;
  document.querySelectorAll('.tog').forEach((b) => b.classList.toggle('on', !!sv.settings[b.dataset.set]));
  $('nameIn').value = sv.name;
  $('statLine').textContent = `${sv.runs}판 · ${sv.wins}승 · ${sv.kills}처치`;
  $('ver').textContent = `메아리 던전 v${VERSION}`;
}

/* ---------- 카드 ---------- */
hooks.pick = (choices) => {
  const G = S.G;
  S.joy.active = false;
  $('pickTitle').textContent = G.tut && G.cards === 0 ? '10초마다 카드를 한 장 고릅니다' : G.pendingPicks > 1 || (G.cards >= 5) ? '보물 카드!' : '카드를 고르세요';
  renderCards(choices);
  show('pick');
  guard($('pick'));
};
function renderCards(choices) {
  const G = S.G, box = $('cards');
  box.innerHTML = '';
  for (const c of choices) {
    const lv = G.hero.st.lv[c.id] || 0, rar = RARITY[c.rar];
    const b = document.createElement('button');
    b.className = 'card';
    b.style.borderColor = rar.col;
    const tag = c.fallback ? '' : c.rar === 3 ? '진화!' : lv ? `Lv.${lv + 1}` : 'NEW';
    b.innerHTML = `<div class="ic">${ico(c.id, c.ic)}</div><div><b>${c.name} <em style="color:${rar.col}">${tag}</em></b><span>${c.desc}</span><em style="color:${rar.col}">${c.fallback ? '' : rar.name}</em></div>`;
    b.onclick = () => { if (S.scene === 'pick') takeCard(c.id); };
    box.appendChild(b);
  }
  const rb = $('rerollBtn');
  rb.style.display = shopLv('reroll') > 0 ? '' : 'none';
  rb.textContent = `🎲 다시 뽑기 (${G.rerolls})`;
  rb.disabled = G.rerolls <= 0;
}

hooks.resume = () => show(null);

/* ---------- 일시정지 ---------- */
export function pauseGame() {
  if (S.scene !== 'play') return;
  S.scene = 'pause'; S.joy.active = false;
  show('pause');
}
function resumeGame() {
  if (S.scene !== 'pause') return;
  sfx.click(); S.scene = 'play'; show(null);
}

/* ---------- 결과 ---------- */
hooks.end = (r) => {
  S.scene = 'result';
  const sv = S.save, cp = stageChap(r.stage);
  $('rtitle').textContent = r.won ? `🏆 ${BOSSES[cp.boss].name} 처치!` : r.abandoned ? '던전에서 나왔다' : r.endless ? `♾ ${Math.floor(r.t / 60)}분 ${Math.floor(r.t % 60)}초 생존` : '쓰러졌다…';
  const L = [];
  L.push(`생존 <em>${Math.min(r.t, 999).toFixed(1)}초</em> · 처치 <em>${r.kills}</em>${r.echoKills ? ` (메아리 ${r.echoKills})` : ''}`);
  L.push(`점수 <em>${r.score}</em>${r.newBest ? ' 🎉 최고 기록!' : ''} · 골드 <em>+${r.gold}</em>`);
  if (r.bossLeft) L.push(`<span class="hl">보스 체력 <em>${r.bossLeft}%</em> 남음 — 한 번만 더!</span>`);
  else if (!r.won && !r.reachedBoss && !r.abandoned && !r.endless) L.push(`<span class="hl">보스까지 <em>${Math.max(1, Math.ceil(r.time - r.t))}초</em> 남았었다!</span>`);
  if (r.nemKilled) L.push('<span class="hl">☠ 원수를 갚았다! 보너스 골드</span>');
  if (r.nemNew) L.push(`<span class="hl">☠ ${ENEMIES[r.nemNew.type].name}이(가) <em>${sv.name}</em>의 이름을 얻었다 (Lv.${r.nemNew.lvl})<br>다음 판 25초에 나타난다</span>`);
  if (r.unlocked) L.push(`<span class="hl">🔓 스테이지 ${r.stage + 2} <em>${stageChap(r.stage + 1).name}</em> 해금!${r.stage + 1 === STORY ? '<br>♾ 생존 모드도 열렸다!' : ''}</span>`);
  if (r.missions.length) L.push(`<span class="hl">📜 임무 완료: ${r.missions.map(missionText).join(', ')}</span>`);
  if (!r.abandoned) L.push(`<span class="hl">👻 이번 판이 메아리가 되었다 (${Math.min(r.echoCount, echoSlots())}/${echoSlots()})${r.firstRun ? '<br>다음 판에서 지금의 당신이 똑같이 움직이며 함께 싸웁니다!' : ''}</span>`);
  $('rstat').innerHTML = L.map((x) => (x.startsWith('<span class="hl"') ? x : x + '<br>')).join('');
  // 광고 보고 골드 2배 (결과마다 한 번)
  const db = $('rdouble');
  db.disabled = false; db.textContent = r.gold >= 10 ? `📺 광고 보고 골드 2배 (+${r.gold})` : '';
  db.onclick = async () => {
    db.disabled = true;
    if (await showRewardAd()) { sv.gold += r.gold; persist(sv); db.textContent = `🪙 +${r.gold} 받았다!`; sfx.chest(); }
    else { db.disabled = false; toast('광고를 불러오지 못했습니다'); }
  };
  $('rshare').style.display = r.abandoned || !sv.echoes[r.ch].length ? 'none' : '';
  const next = r.won && r.stage >= 0;
  $('again').textContent = next ? '다음 스테이지 ▶' : '다시 도전';
  $('again').dataset.next = next ? '1' : '';
  show('result');
  guard($('result'), 600);
};

/* ---------- 부활 ---------- */
hooks.revive = () => { show('revive'); guard($('revive'), 500); };

/* ---------- 메아리 코드 ---------- */
async function shareEcho() {
  const r = S.G && S.G.result, sv = S.save;
  const rec = r && sv.echoes[r.ch][0];
  if (!rec) return;
  try {
    const code = await encodeEcho(rec, sv.name, r.ch);
    const text = `메아리 던전 · ${sv.name}의 메아리 (${CHAPTERS[r.ch].name})\n설정 › 친구 메아리 코드 넣기에 붙여 넣으세요\n${code}`;
    if (navigator.share) { await navigator.share({ text }); return; }
    await navigator.clipboard.writeText(text);
    toast('메아리 코드를 복사했습니다');
  } catch (e) { if (e && e.name !== 'AbortError') toast('공유하지 못했습니다'); }
}
function importFriend() {
  confirmBox('친구에게 받은 메아리 코드를 붙여 넣으세요.<br><small>그 챕터에서 친구가 함께 싸웁니다.</small><textarea id="codeIn" spellcheck="false"></textarea>', async () => {
    const raw = ($('codeIn') && $('codeIn').value) || '';
    try {
      const f = await decodeEcho(raw.slice(raw.indexOf('ED')));
      S.save.friend[f.ch] = { path: f.path, picks: f.picks, cls: f.cls, name: f.name };
      persist(S.save);
      toast(`👥 ${f.name}의 메아리가 ${CHAPTERS[f.ch].name}에 합류했습니다`);
    } catch (e) { toast(e.message && e.message.length < 40 ? e.message : '코드를 읽지 못했습니다'); }
  });
}

/* ---------- 뒤로 가기 (안드로이드 버튼 / Esc) ---------- */
export function onBack() {
  if ($('modal').classList.contains('on')) { closeModal(); return; }
  if (MENUS.includes(current)) { backFromMenu(); return; }
  if (S.scene === 'revive') { $('revNo').click(); return; }
  if (S.scene === 'play') { pauseGame(); return; }
  if (S.scene === 'pause') { resumeGame(); return; }
  if (S.scene === 'result') { goTitle(); return; }
  if (S.scene === 'title') confirmBox('게임을 종료할까요?', () => exitApp());
}

/* ---------- 연결 ---------- */
export function bindUi() {
  $('start').onclick = beginRun;
  $('tcls').onclick = (ev) => {
    const b = ev.target.closest('button');
    if (!b || b.dataset.cls === S.save.cls) return;
    S.save.cls = b.dataset.cls; persist(S.save); sfx.click(); refreshTitle();
  };
  $('cprev').onclick = () => { if (S.chapter > 0) { S.chapter--; sfx.click(); refreshTitle(); } };
  $('cnext').onclick = () => { if (S.chapter >= 0 && S.chapter < S.save.unlocked) { S.chapter++; sfx.click(); refreshTitle(); } };
  // 생존 모드 단추: 누를 때마다 생존 모드 ↔ 마지막으로 연 스테이지
  $('tendless').onclick = () => { sfx.click(); S.chapter = S.chapter < 0 ? Math.max(0, S.save.unlocked - 1) : -1; refreshTitle(); };
  $('tshop').onclick = () => openMenu('shop');
  $('tmis').onclick = () => openMenu('missions');
  $('tset').onclick = () => openMenu('settings');
  $('rshop').onclick = () => openMenu('shop');
  $('psettings').onclick = () => openMenu('settings');
  document.querySelectorAll('[data-back]').forEach((b) => { b.onclick = backFromMenu; });
  document.querySelectorAll('.tog').forEach((b) => {
    b.onclick = () => {
      const k = b.dataset.set;
      S.save.settings[k] = !S.save.settings[k];
      persist(S.save); applyAudioSettings(); renderSettings(); sfx.click();
      if (k === 'vib' && S.save.settings.vib) haptic('medium');
    };
  });
  $('nameIn').onchange = () => {
    const v = $('nameIn').value.replace(/[<>&"']/g, '').trim().slice(0, 8);
    S.save.name = v || '용사'; $('nameIn').value = S.save.name; persist(S.save);
  };
  $('resetBtn').onclick = () => confirmBox('모든 기록, 골드, 강화, 메아리가 지워집니다.<br>정말 초기화할까요?', () => {
    S.save = resetSave(); persist(S.save); S.chapter = 0; renderSettings(); toast('초기화했습니다');
  });
  $('myes').onclick = () => { const f = modalYes; closeModal(); if (f) f(); };
  $('mno').onclick = closeModal;
  $('rerollBtn').onclick = () => { const c = reroll(); if (c) { sfx.cards(); renderCards(c); } };
  $('pauseBtn').onclick = () => { sfx.click(); pauseGame(); };
  $('resume').onclick = resumeGame;
  $('quit').onclick = () => confirmBox('포기하면 이번 판은 메아리로 남지 않습니다.<br>모은 코인은 받아 갑니다.', () => { S.scene = 'play'; endRun(false, true); });
  $('again').onclick = () => {
    if ($('again').dataset.next) S.chapter = Math.min(S.save.unlocked - 1, S.chapter + 1);
    if (S.chapter >= S.save.unlocked) S.chapter = S.save.unlocked - 1;
    beginRun();
  };
  $('home').onclick = () => { sfx.click(); goTitle(); };
  $('rshare').onclick = () => { sfx.click(); shareEcho(); };
  $('friendBtn').onclick = () => { sfx.click(); importFriend(); };
  $('privBtn').onclick = () => { $('privFrame').src = 'privacy.html'; openMenu('privacy'); };
  let reviving = false;
  $('revAd').onclick = async () => {
    if (reviving) return;
    reviving = true; sfx.click();
    const ok = await showRewardAd();
    reviving = false;
    if (S.scene !== 'revive') return;
    if (ok) { revive(); show(null); sfx.win(); haptic('heavy'); } else toast('광고를 불러오지 못했습니다');
  };
  $('revNo').onclick = () => { if (S.scene !== 'revive' || reviving) return; sfx.click(); S.scene = 'play'; endRun(false); };
}
