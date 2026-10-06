import { S } from './state.js';
import { mulberry32, dateKey } from './util.js';

export const VERSION = '0.7.0';
export const W = 360, H = 640;
// 월드는 화면(W×H)보다 훨씬 넓고, 카메라가 영웅을 따라간다
export const ARENA = { x: 0, y: 0, w: 720, h: 1100 };
export const OLD_TO_NEW = { x: 180, y: 277 }; // 예전(좁은 방) 좌표로 저장된 메아리를 새 월드로 옮기는 값
export const RUN_TIME = 60;
export const PICK_EVERY = 10;

/* ---------- 몬스터 ---------- */
export const ENEMIES = {
  slime: { name: '슬라임', hp: 22, sp: 38, r: 11, dmg: 8 },
  bat: { name: '박쥐', hp: 12, sp: 80, r: 9, dmg: 6 },
  brute: { name: '오우거', hp: 70, sp: 30, r: 15, dmg: 14 },
  mage: { name: '해골 마법사', hp: 26, sp: 34, r: 11, dmg: 9 },
  boar: { name: '멧돼지', hp: 42, sp: 34, r: 13, dmg: 12 },
  blob: { name: '왕방울 슬라임', hp: 55, sp: 28, r: 16, dmg: 10 },
  mini: { name: '꼬마 슬라임', hp: 9, sp: 58, r: 7, dmg: 5 },
};

/* ---------- 보스 ---------- */
export const BOSSES = {
  slimeking: { name: '슬라임 왕', hp: 620, r: 30, sp: 24, dmg: 16, pattern: 'jump', col: { body: '#5fd36b', belly: '#c9f5b8', crown: '#ffd34a' } },
  lich: { name: '리치', hp: 760, r: 24, sp: 30, dmg: 14, pattern: 'lich', col: { body: '#5b3d9a', belly: '#efe6d0', crown: '#7dffd1' } },
  dragon: { name: '화염 용', hp: 900, r: 30, sp: 26, dmg: 16, pattern: 'radial', col: { body: '#ff5d73', belly: '#ffd0b0', crown: '#ffd34a' } },
  frost: { name: '얼음 군주', hp: 1050, r: 32, sp: 24, dmg: 18, pattern: 'jump', col: { body: '#7fd4ff', belly: '#eefaff', crown: '#e6fbff' } },
  shadow: { name: '그림자 왕', hp: 1250, r: 30, sp: 28, dmg: 18, pattern: 'all', col: { body: '#4b3478', belly: '#b9a0e6', crown: '#ff4d6d' } },
};

/* ---------- 챕터 ---------- */
// mix: [종류, 가중치, 등장 시작 시간(초)]
export const CHAPTERS = [
  { name: '이끼 동굴', time: 60, elite: 20, mid: [], boss: 'slimeking', mix: [['slime', 6, 0], ['bat', 3, 6], ['blob', 1, 20]], hp: 1, dmg: 1, rate: 1,
    floor: ['#2f4a3c', '#2a4235'], wall: '#1b2e24', accent: '#7ee0a0' },
  { name: '해골 묘지', time: 75, elite: 20, mid: [], boss: 'lich', mix: [['slime', 3, 0], ['bat', 3, 4], ['mage', 3, 12]], hp: 1.35, dmg: 1.1, rate: 1.04,
    floor: ['#3a2a63', '#34255a'], wall: '#21173d', accent: '#b99cff' },
  { name: '용암 광산', time: 90, elite: 20, mid: [{ t: 45, id: 'slimeking' }], boss: 'dragon', mix: [['slime', 2, 0], ['bat', 3, 0], ['boar', 3, 10], ['brute', 2, 20]], hp: 1.65, dmg: 1.15, rate: 1.06,
    floor: ['#4a2a26', '#432520'], wall: '#2a1512', accent: '#ff9c4a' },
  { name: '얼음 성채', time: 105, elite: 15, mid: [{ t: 55, id: 'lich' }], boss: 'frost', mix: [['slime', 2, 0], ['bat', 2, 0], ['blob', 2, 6], ['mage', 2, 10], ['boar', 1, 18]], hp: 1.85, dmg: 1.2, rate: 1.06,
    floor: ['#2a3f5a', '#253852'], wall: '#172538', accent: '#8fd8ff' },
  { name: '그림자 왕좌', time: 120, elite: 16, mid: [{ t: 45, id: 'dragon' }, { t: 85, id: 'frost' }], boss: 'shadow', mix: [['bat', 2, 0], ['slime', 1, 0], ['brute', 1.5, 8], ['mage', 2, 8], ['boar', 1.5, 12], ['blob', 1.5, 15]], hp: 2.2, dmg: 1.25, rate: 1.08,
    floor: ['#251c33', '#20182c'], wall: '#120c1b', accent: '#ff4d6d' },
  { name: '무한 던전', time: 1e9, endless: true, elite: 18, mid: [], boss: null, mix: [['slime', 2, 0], ['bat', 2, 0], ['blob', 2, 6], ['mage', 2, 10], ['boar', 2, 14], ['brute', 2, 20]], hp: 2, dmg: 1.2, rate: 1.1,
    floor: ['#1f2a3a', '#1a2433'], wall: '#0e141e', accent: '#ffd34a' },
];
export const ENDLESS_BOSSES = ['slimeking', 'lich', 'dragon', 'frost', 'shadow'];
export const STORY = 5, ENDLESS = 5; // 이야기 챕터 5개를 끝없이 돈다. CHAPTERS[5]는 무한 던전(생존 모드)

// 스테이지 k(0부터 끝없이): 다섯 챕터를 차례로 돌고, 한 바퀴(깊이)마다 적이 강해지고 중간 보스가 늘어난다.
// k < 0 이면 무한 던전. 메아리·원수·최고 기록은 챕터(ch)별로 남는다.
export function stageChap(k) {
  if (k < 0) return { ...CHAPTERS[ENDLESS], ch: ENDLESS, stage: -1, depth: 0, bossHp: 1 };
  const ch = k % STORY, depth = Math.floor(k / STORY), b = CHAPTERS[ch];
  if (!depth) return { ...b, ch, stage: k, depth, bossHp: 1 };
  const mid = b.mid.slice();
  for (let i = 0; i < Math.min(depth, 3); i++) { // 깊어질수록 중간 보스가 하나씩 늘어난다 (최대 3)
    const t = Math.round(b.time * (0.25 + 0.22 * i));
    if (mid.every((m) => Math.abs(m.t - t) >= 12)) mid.push({ t, id: ENDLESS_BOSSES[(ch + depth + i) % ENDLESS_BOSSES.length] });
  }
  mid.sort((x, y) => x.t - y.t);
  return {
    ...b, ch, stage: k, depth, mid, name: `${b.name} · 깊이 ${depth + 1}`,
    hp: b.hp * (1 + 0.75 * depth), dmg: b.dmg * (1 + 0.22 * depth), rate: b.rate * Math.min(1.5, 1 + 0.06 * depth),
    elite: Math.max(10, b.elite - 2 * depth), bossHp: 1 + 0.8 * depth,
  };
}
// 이 챕터에서 다음에 나올 중간 보스 (없으면 null)
export function nextMidBoss(chap, idx) {
  if (chap.endless) return { t: 60 * (idx + 1), id: ENDLESS_BOSSES[idx % ENDLESS_BOSSES.length], scale: 1 + 0.35 * idx };
  const m = chap.mid[idx];
  return m ? { t: m.t, id: m.id, scale: 1 } : null;
}

/* ---------- 카드 ---------- */
export const RARITY = [
  { name: '일반', col: '#b9c2d9', w: 60 },
  { name: '희귀', col: '#59b0ff', w: 30 },
  { name: '영웅', col: '#c56bff', w: 12 },
  { name: '진화', col: '#ffcf3e', w: 45 },
  { name: '전설', col: '#ff6b5d', w: 55 },
];
export const CARDS = [
  { id: 'rapid', ic: '⚡', name: '연사', rar: 0, max: 5, desc: '공격 속도 +20%', apply: (s) => { s.cd *= 0.83; } },
  { id: 'power', ic: '💥', name: '강타', rar: 0, max: 5, desc: '모든 피해 +25%', apply: (s) => { s.dmg *= 1.25; } },
  { id: 'multi', ic: '🔱', name: '다중 발사', rar: 1, max: 4, desc: '투사체 +1', apply: (s) => { s.shots += 1; } },
  { id: 'pierce', ic: '🏹', name: '관통', rar: 0, max: 3, desc: '투사체가 적을 하나 더 뚫는다', apply: (s) => { s.pierce += 1; } },
  { id: 'boots', ic: '👟', name: '신속', rar: 0, max: 3, desc: '이동 속도 +12%', apply: (s) => { s.speed *= 1.12; } },
  { id: 'vital', ic: '❤️', name: '튼튼', rar: 0, max: 5, desc: '최대 체력 +25, 체력 25 회복',
    apply: (s, o) => { s.maxhp += 25; if (o && o.hp != null) o.hp = Math.min(s.maxhp, o.hp + 25); } },
  { id: 'blade', ic: '🌀', name: '회전검', rar: 1, max: 5, desc: '몸 주위를 도는 검 +1', apply: (s) => { s.blades += 1; } },
  { id: 'bolt', ic: '🌩️', name: '번개', rar: 1, max: 4, desc: '주기적으로 적 사이를 튀는 번개', apply: (s) => { s.bolt += 1; } },
  { id: 'poison', ic: '🧪', name: '독 발자국', rar: 1, max: 4, desc: '지나간 자리에 독 웅덩이 (메아리도 남긴다)', apply: (s) => { s.poison += 1; } },
  { id: 'echo', ic: '👻', name: '공명', rar: 1, max: 3, desc: '모든 메아리의 피해 +35%', apply: (s) => { s.echoAmp += 1; } },
  { id: 'crit', ic: '🎯', name: '급소', rar: 0, max: 4, desc: '치명타 확률 +12%', apply: (s) => { s.crit += 0.12; } },
  { id: 'leech', ic: '🩸', name: '흡혈', rar: 1, max: 3, desc: '적을 처치하면 확률적으로 체력 회복', apply: (s) => { s.leech += 1; } },
  { id: 'magnet', ic: '🧲', name: '자석', rar: 0, max: 3, desc: '코인을 끌어오는 범위 증가', apply: (s) => { s.magnet += 1; } },
  { id: 'shield', ic: '🛡️', name: '방패', rar: 1, max: 3, desc: '주기적으로 피해를 한 번 막는다', apply: (s, o) => { s.shield += 1; if (o) o.shieldReady = true; } },
  { id: 'boom', ic: '🎆', name: '폭발', rar: 2, max: 3, desc: '적이 쓰러질 때 확률적으로 폭발', apply: (s) => { s.boom += 1; } },
  { id: 'frost', ic: '❄️', name: '냉기', rar: 1, max: 2, desc: '투사체에 맞은 적이 느려진다', apply: (s) => { s.frost += 1; } },
  // 진화: 조건을 채우면 등장
  { id: 'storm', ic: '⚔️', name: '폭풍검', rar: 3, max: 1, desc: '회전검이 커지고 피해 2배', req: (s) => (s.lv.blade || 0) >= 3 && (s.lv.power || 0) >= 1,
    apply: (s) => { s.bladeDmg *= 2; s.bladeSize *= 1.5; s.bladeR += 8; } },
  { id: 'legion', ic: '👥', name: '메아리 군단', rar: 3, max: 1, desc: '메아리 투사체 +1, 메아리 피해 대폭 증가', req: (s) => (s.lv.echo || 0) >= 2,
    apply: (s) => { s.legion = 1; s.echoAmp += 1.5; } },
  { id: 'thunder', ic: '⛈️', name: '천둥 폭풍', rar: 3, max: 1, desc: '번개가 3번 더 튀고 항상 치명타', req: (s) => (s.lv.bolt || 0) >= 2 && (s.lv.crit || 0) >= 1,
    apply: (s) => { s.boltChain += 3; s.boltCrit = 1; } },
  /* ---------- 새 카드 50장 ---------- */
  // 공격
  { id: 'sharp', ic: '🗡️', name: '날카로운 날', rar: 0, max: 4, desc: '치명타 피해 +30%', apply: (s) => { s.critMul += 0.3; } },
  { id: 'longshot', ic: '🔭', name: '장거리 사격', rar: 0, max: 3, desc: '사거리 +18%', apply: (s) => { s.range *= 1.18; s.shotLife *= 1.18; } },
  { id: 'swiftshot', ic: '💨', name: '쾌속탄', rar: 0, max: 3, desc: '투사체 속도 +25%', apply: (s) => { s.shotSpeed *= 1.25; } },
  { id: 'bigshot', ic: '⭕', name: '대형탄', rar: 0, max: 3, desc: '투사체가 커져 맞추기 쉽다', apply: (s) => { s.hitR *= 1.35; } },
  { id: 'splash', ic: '💫', name: '파편탄', rar: 1, max: 3, desc: '맞은 적 주변에도 60% 피해', apply: (s) => { s.splash = (s.splash || 0) + 24; } },
  { id: 'heavy', ic: '🔨', name: '묵직한 일격', rar: 0, max: 3, desc: '피해 +40%, 공격 속도 -10%', apply: (s) => { s.dmg *= 1.4; s.cd *= 1.1; } },
  { id: 'flurry', ic: '🌪️', name: '난사', rar: 1, max: 3, desc: '공격 속도 +33%, 피해 -10%', apply: (s) => { s.cd *= 0.75; s.dmg *= 0.9; } },
  { id: 'twin', ic: '👯', name: '쌍둥이 탄', rar: 2, max: 2, desc: '투사체 +1, 피해 -15%', apply: (s) => { s.shots += 1; s.dmg *= 0.85; } },
  { id: 'pierce2', ic: '🪡', name: '천공', rar: 1, max: 3, desc: '관통 +2, 피해 +10%', apply: (s) => { s.pierce += 2; s.dmg *= 1.1; } },
  { id: 'homing', ic: '🎯', name: '유도탄', rar: 1, max: 3, desc: '투사체가 적을 따라 휘어진다', apply: (s) => { s.homing += 1; } },
  { id: 'ricochet', ic: '↪️', name: '도탄', rar: 2, max: 3, desc: '맞은 투사체가 다른 적에게 튕긴다', apply: (s) => { s.ricochet += 1; } },
  // 상태 이상 · 조건부 피해
  { id: 'ember', ic: '🔥', name: '불씨', rar: 1, max: 3, desc: '맞은 적이 3초 동안 불탄다', apply: (s) => { s.burn += 1; } },
  { id: 'inferno', ic: '🌋', name: '지옥불', rar: 2, max: 2, desc: '불타는 피해 2배', req: (s) => (s.lv.ember || 0) >= 1, apply: (s) => { s.burn += 2; } },
  { id: 'execute', ic: '☠️', name: '처형', rar: 1, max: 3, desc: '체력 25% 이하 적에게 피해 +60%', apply: (s) => { s.execute += 0.6; } },
  { id: 'bossbane', ic: '👑', name: '왕 사냥꾼', rar: 1, max: 3, desc: '보스에게 피해 +35%', apply: (s) => { s.bossDmg += 0.35; } },
  { id: 'elitebane', ic: '🏅', name: '정예 사냥꾼', rar: 0, max: 3, desc: '정예 몬스터에게 피해 +40%', apply: (s) => { s.eliteDmg += 0.4; } },
  { id: 'berserk', ic: '😡', name: '광전사', rar: 1, max: 3, desc: '체력 50% 이하일 때 피해 +60%', apply: (s) => { s.berserk += 1; } },
  { id: 'momentum', ic: '🏃', name: '질주 타격', rar: 0, max: 3, desc: '움직이는 동안 피해 +25%', apply: (s) => { s.moveDmg += 1; } },
  { id: 'still', ic: '🧘', name: '침착', rar: 0, max: 3, desc: '멈춰 있는 동안 피해 +30%', apply: (s) => { s.stillDmg += 1; } },
  { id: 'sniper', ic: '🔬', name: '저격 자세', rar: 1, max: 3, desc: '멀리 있는 적(150 이상)에게 피해 +50%', apply: (s) => { s.sniper += 1; } },
  { id: 'brawler', ic: '🥊', name: '난투', rar: 1, max: 3, desc: '가까운 적(60 이내)에게 피해 +40%', apply: (s) => { s.brawler += 1; } },
  { id: 'revenge', ic: '💢', name: '반격', rar: 1, max: 3, desc: '맞은 뒤 3초 동안 피해 +60%', apply: (s) => { s.revenge += 1; } },
  { id: 'killhaste', ic: '🩸', name: '학살의 흥분', rar: 1, max: 3, desc: '처치하면 2초 동안 공격 속도 +40%', apply: (s) => { s.killHaste += 1; } },
  { id: 'overdrive', ic: '🔋', name: '과충전', rar: 2, max: 2, desc: '주기적으로 몇 초간 공격 속도 +60%', apply: (s) => { s.overdrive += 1; } },
  { id: 'knock', ic: '🥾', name: '강력 넉백', rar: 0, max: 3, desc: '적을 더 멀리 밀어낸다', apply: (s) => { s.kbMul += 0.5; } },
  { id: 'blast', ic: '🧨', name: '폭죽', rar: 2, max: 3, desc: '치명타가 작은 폭발을 일으킨다', apply: (s) => { s.critBoom += 1; } },
  // 주변 공격
  { id: 'aura', ic: '☀️', name: '불꽃 오라', rar: 1, max: 4, desc: '몸 주변의 적에게 계속 피해', apply: (s) => { s.aura += 1; } },
  { id: 'glacier', ic: '🧊', name: '서리 오라', rar: 1, max: 3, desc: '몸 주변의 적이 느려진다', apply: (s) => { s.auraSlow += 1; } },
  { id: 'nova', ic: '💥', name: '충격파', rar: 1, max: 3, desc: '주기적으로 주변을 밀쳐내는 충격파', apply: (s) => { s.nova += 1; } },
  { id: 'bigblade', ic: '🗂️', name: '거대한 회전검', rar: 1, max: 3, desc: '회전검이 커지고 멀리 돈다', req: (s) => (s.lv.blade || 0) >= 1, apply: (s) => { s.bladeSize *= 1.25; s.bladeR += 6; } },
  // 방어 · 회복
  { id: 'regen', ic: '🌿', name: '재생', rar: 0, max: 4, desc: '초당 체력 +1', apply: (s) => { s.regen += 1; } },
  { id: 'armor', ic: '🪖', name: '갑옷', rar: 0, max: 4, desc: '받는 피해 -10%', apply: (s) => { s.armor += 0.1; } },
  { id: 'ironskin', ic: '🦾', name: '강철 피부', rar: 1, max: 3, desc: '최대 체력 +40, 받는 피해 -5%', apply: (s, o) => { s.maxhp += 40; s.armor += 0.05; if (o && o.hp != null) o.hp += 40; } },
  { id: 'phase', ic: '👤', name: '위상 이동', rar: 1, max: 3, desc: '맞은 뒤 무적 시간 +0.35초', apply: (s) => { s.invT += 0.35; } },
  { id: 'thorns', ic: '🌵', name: '가시 갑옷', rar: 1, max: 3, desc: '몸에 닿은 적에게 피해', apply: (s) => { s.thorns += 1; } },
  { id: 'drain', ic: '💉', name: '생명력 흡수', rar: 1, max: 3, desc: '공격이 맞을 때마다 체력 회복', apply: (s) => { s.hitHeal += 1; } },
  { id: 'feast', ic: '🍗', name: '만찬', rar: 0, max: 3, desc: '처치할 때마다 체력 +1', apply: (s) => { s.killHeal += 1; } },
  { id: 'dodge', ic: '💨', name: '회피', rar: 1, max: 3, desc: '12% 확률로 피해를 피한다', apply: (s) => { s.dodge += 0.12; } },
  { id: 'barrier', ic: '🔰', name: '방어막 강화', rar: 1, max: 2, desc: '방패가 더 빨리 다시 생긴다', req: (s) => (s.lv.shield || 0) >= 1, apply: (s) => { s.shieldFast += 1; } },
  { id: 'secondwind', ic: '🕊️', name: '질긴 생명력', rar: 2, max: 1, desc: '쓰러질 때 체력 35%로 한 번 일어선다 (판마다 1번)', apply: (s) => { s.lastStand = Math.max(s.lastStand, 1); } },
  // 돈 · 운
  { id: 'coinmul', ic: '🪙', name: '금화 욕심', rar: 0, max: 3, desc: '코인이 50% 더 나온다', apply: (s) => { s.coinMul += 0.5; } },
  { id: 'treasure', ic: '💎', name: '보물 사냥꾼', rar: 1, max: 2, desc: '정예가 코인을 10개 더 떨군다', apply: (s) => { s.eliteCoins += 10; } },
  { id: 'greedy', ic: '🧿', name: '탐욕의 대가', rar: 0, max: 3, desc: '코인을 주울 때 체력 +1', apply: (s) => { s.coinHeal += 1; } },
  { id: 'lucky', ic: '🍀', name: '행운', rar: 1, max: 3, desc: '희귀 이상의 카드가 더 자주 나온다', apply: (s) => { s.luck += 1; } },
  // 메아리
  { id: 'echohaste', ic: '⏩', name: '메아리 가속', rar: 1, max: 3, desc: '메아리의 공격 속도 +30%', apply: (s) => { s.echoHaste += 1; } },
  { id: 'echoguard', ic: '🛡️', name: '메아리 수호', rar: 1, max: 3, desc: '살아 있는 메아리 1명당 받는 피해 -8%', apply: (s) => { s.echoGuard += 1; } },
  { id: 'echoheal', ic: '💞', name: '메아리의 속삭임', rar: 1, max: 3, desc: '메아리가 처치하면 체력 +2', apply: (s) => { s.echoHeal += 1; } },
  { id: 'echocrit', ic: '✨', name: '메아리 급소', rar: 1, max: 3, desc: '메아리의 치명타 확률 +20%', apply: (s) => { s.echoCrit += 1; } },
  // 능력치
  { id: 'haste', ic: '🌬️', name: '바람의 축복', rar: 0, max: 4, desc: '이동 속도 +8%, 공격 속도 +8%', apply: (s) => { s.speed *= 1.08; s.cd *= 0.92; } },
  { id: 'giant', ic: '🦣', name: '거인화', rar: 1, max: 3, desc: '최대 체력 +30%, 피해 +10%, 이동 -5%', apply: (s, o) => { const a = Math.round(s.maxhp * 0.3); s.maxhp += a; s.dmg *= 1.1; s.speed *= 0.95; if (o && o.hp != null) o.hp += a; } },
  // 전설: 가끔만 나오고, 효과가 확실히 크다
  { id: 'phoenix', ic: '🐦‍🔥', name: '불사조의 깃', rar: 4, max: 1, desc: '쓰러지면 체력을 전부 회복하고 주변을 불태운다 (판마다 1번). 재생 +2',
    req: (s) => Object.keys(s.lv).length >= 4, apply: (s) => { s.lastStand = 2; s.regen += 2; } },
  { id: 'judgment', ic: '⚡', name: '천벌', rar: 4, max: 1, desc: '5초마다 번개가 화면의 모든 적을 내리친다',
    req: (s) => Object.keys(s.lv).length >= 4, apply: (s) => { s.smite = 1; } },
  { id: 'crown', ic: '👑', name: '만능의 왕관', rar: 4, max: 1, desc: '피해 +50%, 공격 속도 +33%, 최대 체력 +40%, 이동 +15%, 치명타 +15%',
    req: (s) => Object.keys(s.lv).length >= 4,
    apply: (s, o) => { s.dmg *= 1.5; s.cd *= 0.75; const a = Math.round(s.maxhp * 0.4); s.maxhp += a; s.speed *= 1.15; s.crit += 0.15; if (o && o.hp != null) o.hp += a; } },
  // 고를 카드가 모자랄 때
  { id: 'meat', ic: '🍖', name: '고기', rar: 0, max: 99, fallback: true, desc: '체력 40 회복', apply: (s, o) => { if (o && o.hp != null) o.hp = Math.min(s.maxhp, o.hp + 40); } },
  { id: 'purse', ic: '💰', name: '금화 주머니', rar: 0, max: 99, fallback: true, desc: '코인 +15', apply: () => {} },
];
export const CARD_BY_ID = Object.fromEntries(CARDS.map((c) => [c.id, c]));

/* ---------- 직업 ---------- */
// 사거리(range)·투사체 속도·수명·판정 크기·범위 피해(splash)가 직업마다 다르다. 카드는 모든 직업에 똑같이 적용된다.
export const CLASSES = {
  sword: { name: '검사', ic: '⚔️', tag: '근접', sprite: 'hero', kind: 'slash',
    desc: '체력이 높고 강하다. 짧은 사거리의 넓은 베기가 줄지어 선 적을 모두 벤다.',
    st: { maxhp: 150, dmg: 15, cd: 0.5, speed: 118, range: 85, shotSpeed: 260, shotLife: 0.3, hitR: 15, pierce: 99, crit: 0.05 } },
  archer: { name: '궁사', ic: '🏹', tag: '원거리', sprite: 'archer', kind: 'arrow',
    desc: '체력이 낮지만 가장 멀리, 빠르게 쏜다. 화살이 적 하나를 뚫고 지나간다.',
    st: { maxhp: 75, dmg: 9, cd: 0.4, speed: 135, range: 340, shotSpeed: 400, shotLife: 1.0, hitR: 3, pierce: 1, crit: 0.14 } },
  mage: { name: '법사', ic: '🔮', tag: '중거리', sprite: 'wizard', kind: 'orb',
    desc: '균형 잡힌 사거리. 마법 구슬이 터지며 주변 적에게도 피해를 준다.',
    st: { maxhp: 95, dmg: 11, cd: 0.68, speed: 125, range: 240, shotSpeed: 220, shotLife: 1.25, hitR: 5, pierce: 0, splash: 36, crit: 0.05 } },
};
export const CLASS_IDS = Object.keys(CLASSES);

export function baseStats(cls) {
  return {
    dmg: 10, cd: 0.55, shots: 1, pierce: 0, speed: 125, maxhp: 100,
    range: 240, shotSpeed: 280, shotLife: 1.1, hitR: 4, splash: 0,
    blades: 0, bladeDmg: 7, bladeSize: 1, bladeR: 34,
    crit: 0.05, critMul: 2, bolt: 0, boltChain: 0, boltCrit: 0,
    poison: 0, echoAmp: 0, legion: 0, leech: 0, magnet: 0, shield: 0, boom: 0, frost: 0,
    // 새 카드가 쓰는 값들
    regen: 0, armor: 0, invT: 0.7, thorns: 0, hitHeal: 0, killHeal: 0, dodge: 0, shieldFast: 0, lastStand: 0,
    burn: 0, execute: 0, bossDmg: 0, eliteDmg: 0, berserk: 0, moveDmg: 0, stillDmg: 0, sniper: 0, brawler: 0, revenge: 0,
    killHaste: 0, overdrive: 0, kbMul: 1, critBoom: 0, homing: 0, ricochet: 0, aura: 0, auraSlow: 0, nova: 0, smite: 0,
    coinMul: 1, eliteCoins: 0, coinHeal: 0, luck: 0, echoHaste: 0, echoGuard: 0, echoHeal: 0, echoCrit: 0,
    lv: {},
    ...(CLASSES[cls] && CLASSES[cls].st),
  };
}
export function applyCard(st, id, owner) {
  const c = CARD_BY_ID[id];
  if (!c) return;
  c.apply(st, owner);
  st.lv[id] = (st.lv[id] || 0) + 1;
}
export function rollCards(st, rng, n = 3) {
  const pool = CARDS.filter((c) => !c.fallback && (st.lv[c.id] || 0) < c.max && (!c.req || c.req(st)));
  const out = [];
  while (out.length < n && pool.length) {
    let tot = 0;
    const wt = (c) => RARITY[c.rar].w * (c.rar === 1 || c.rar === 2 || c.rar === 4 ? 1 + 0.6 * (st.luck || 0) : 1);
    for (const c of pool) tot += wt(c);
    let r = rng() * tot, i = 0;
    for (; i < pool.length - 1; i++) { r -= wt(pool[i]); if (r <= 0) break; }
    out.push(pool.splice(i, 1)[0]);
  }
  const fb = CARDS.filter((c) => c.fallback);
  for (let k = 0; out.length < n; k++) out.push(fb[k % fb.length]);
  return out;
}

/* ---------- 영구 강화 ---------- */
export const SHOP = [
  { id: 'hp', ic: '❤️', name: '단련', desc: (l) => `시작 체력 +${l * 10}`, max: 999, base: 30 },
  { id: 'atk', ic: '⚔️', name: '예리함', desc: (l) => `모든 피해 +${l * 5}%`, max: 999, base: 40 },
  { id: 'spd', ic: '👟', name: '날렵함', desc: (l) => `이동 속도 +${l * 3}%`, max: 5, base: 40 },
  { id: 'echo', ic: '👻', name: '메아리 공명', desc: (l) => `메아리 피해 +${l * 8}%`, max: 999, base: 60 },
  { id: 'greed', ic: '💰', name: '탐욕', desc: (l) => `골드 획득 +${l * 10}%`, max: 10, base: 50 },
  { id: 'reroll', ic: '🎲', name: '다시 뽑기', desc: (l) => `판마다 카드 다시 뽑기 ${l}회`, max: 3, base: 80 },
  { id: 'slot', ic: '🪞', name: '메아리 슬롯', desc: (l) => `메아리 최대 ${3 + l}명`, max: 2, base: 300 },
];
export const shopLv = (id) => (S.save && S.save.shop[id]) || 0;
export const shopCost = (item, lv) => Math.round(item.base * Math.pow(lv + 1, 1.5));
export const echoSlots = () => 3 + shopLv('slot');

/* ---------- 일일 임무 ---------- */
export const MISSIONS = [
  { id: 'kill', text: (g) => `적 ${g}마리 처치`, goals: [150, 250, 400], reward: 40 },
  { id: 'boss', text: () => '보스 처치', goals: [1], reward: 80 },
  { id: 'nem', text: () => '원수에게 복수하기', goals: [1], reward: 60 },
  { id: 'runs', text: (g) => `${g}판 플레이`, goals: [3, 5], reward: 30 },
  { id: 'coins', text: (g) => `코인 ${g}개 줍기`, goals: [60, 120], reward: 40 },
  { id: 'echokill', text: (g) => `메아리로 적 ${g}마리 처치`, goals: [30, 60], reward: 50 },
  { id: 'cards', text: (g) => `카드 ${g}장 고르기`, goals: [10, 20], reward: 30 },
];
export function ensureDaily(save) {
  const today = dateKey();
  if (save.daily && save.daily.date === today) return save.daily;
  const rng = mulberry32(today * 31);
  const pool = MISSIONS.slice(), list = [];
  while (list.length < 3) {
    const m = pool.splice(Math.floor(rng() * pool.length), 1)[0];
    const goal = m.goals[Math.floor(rng() * m.goals.length)];
    list.push({ id: m.id, goal, prog: 0, done: false, claimed: false, reward: m.reward + (goal > m.goals[0] ? 20 : 0) });
  }
  save.daily = { date: today, list };
  return save.daily;
}
export function missionText(m) {
  return MISSIONS.find((x) => x.id === m.id).text(m.goal);
}
