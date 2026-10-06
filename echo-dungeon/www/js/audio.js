// 효과음과 배경음악을 모두 WebAudio로 합성한다 (음원 파일 없음 → 저작권 걱정 없음, 용량 0)
import { S } from './state.js';
import { createMusic } from './music.js';

let ac = null, master = null, sfxBus = null, musBus = null;
const last = {};

export function unlockAudio() {
  try {
    if (!ac) {
      ac = new (window.AudioContext || window.webkitAudioContext)();
      master = ac.createGain(); master.gain.value = 0.9; master.connect(ac.destination);
      sfxBus = ac.createGain(); sfxBus.connect(master);
      musBus = ac.createGain(); musBus.gain.value = 0.32; musBus.connect(master);
      applyAudioSettings();
      ensureMusic();
    }
    if (ac.state === 'suspended') ac.resume();
  } catch (e) { ac = null; }
}
export function applyAudioSettings() {
  if (!ac) return;
  const st = S.save.settings;
  sfxBus.gain.value = st.sfx ? 1 : 0;
  musBus.gain.value = st.music ? 0.32 : 0;
}
export function suspendAudio() { try { ac && ac.suspend(); } catch (e) { /* ignore */ } }
export function resumeAudio() { try { ac && ac.resume(); } catch (e) { /* ignore */ } }

const mtof = (m) => 440 * Math.pow(2, (m - 69) / 12);

function tone(bus, f, t0, d, type, vol, f2) {
  const o = ac.createOscillator(), g = ac.createGain();
  o.type = type; o.frequency.setValueAtTime(f, t0);
  if (f2) o.frequency.exponentialRampToValueAtTime(f2, t0 + d);
  g.gain.setValueAtTime(0.0001, t0);
  g.gain.exponentialRampToValueAtTime(vol, t0 + 0.008);
  g.gain.exponentialRampToValueAtTime(0.0001, t0 + d);
  o.connect(g); g.connect(bus); o.start(t0); o.stop(t0 + d + 0.02);
}
let noiseBuf = null;
function noise(bus, t0, d, vol, hp) {
  if (!noiseBuf) {
    noiseBuf = ac.createBuffer(1, ac.sampleRate * 0.5, ac.sampleRate);
    const ch = noiseBuf.getChannelData(0);
    for (let i = 0; i < ch.length; i++) ch[i] = Math.random() * 2 - 1;
  }
  const s = ac.createBufferSource(), g = ac.createGain(), f = ac.createBiquadFilter();
  s.buffer = noiseBuf; f.type = 'highpass'; f.frequency.value = hp || 1000;
  g.gain.setValueAtTime(vol, t0); g.gain.exponentialRampToValueAtTime(0.0001, t0 + d);
  s.connect(f); f.connect(g); g.connect(bus); s.start(t0); s.stop(t0 + d + 0.02);
}

function play(name, gap, fn) {
  if (!ac || !S.save.settings.sfx) return;
  const now = ac.currentTime;
  if (last[name] && now - last[name] < gap) return; // 같은 소리 과다 재생 방지
  last[name] = now;
  try { fn(now); } catch (e) { /* ignore */ }
}

export const sfx = {
  shoot: () => play('shoot', 0.05, (t) => tone(sfxBus, 880 + Math.random() * 120, t, 0.05, 'square', 0.025, 600)),
  hit: () => play('hit', 0.03, (t) => tone(sfxBus, 300, t, 0.04, 'triangle', 0.05, 180)),
  crit: () => play('crit', 0.06, (t) => { tone(sfxBus, 1200, t, 0.08, 'square', 0.04, 700); noise(sfxBus, t, 0.05, 0.05, 3000); }),
  kill: () => play('kill', 0.035, (t) => { tone(sfxBus, 520, t, 0.08, 'triangle', 0.06, 1040); }),
  coin: () => play('coin', 0.04, (t) => { tone(sfxBus, 1318, t, 0.06, 'square', 0.03); tone(sfxBus, 1760, t + 0.05, 0.08, 'square', 0.03); }),
  hurt: () => play('hurt', 0.1, (t) => { tone(sfxBus, 220, t, 0.18, 'sawtooth', 0.08, 80); noise(sfxBus, t, 0.12, 0.08, 400); }),
  block: () => play('block', 0.1, (t) => { tone(sfxBus, 900, t, 0.15, 'triangle', 0.08, 1400); }),
  pick: () => play('pick', 0.05, (t) => { [72, 76, 79, 84].forEach((m, i) => tone(sfxBus, mtof(m), t + i * 0.05, 0.12, 'triangle', 0.07)); }),
  cards: () => play('cards', 0.1, (t) => { tone(sfxBus, mtof(79), t, 0.1, 'square', 0.04); tone(sfxBus, mtof(84), t + 0.08, 0.16, 'square', 0.04); }),
  click: () => play('click', 0.03, (t) => tone(sfxBus, 660, t, 0.05, 'triangle', 0.06)),
  bolt: () => play('bolt', 0.08, (t) => { noise(sfxBus, t, 0.15, 0.1, 2000); tone(sfxBus, 1600, t, 0.1, 'sawtooth', 0.03, 300); }),
  boom: () => play('boom', 0.06, (t) => { noise(sfxBus, t, 0.3, 0.14, 120); tone(sfxBus, 120, t, 0.25, 'sine', 0.12, 40); }),
  land: () => play('land', 0.2, (t) => { noise(sfxBus, t, 0.4, 0.2, 60); tone(sfxBus, 90, t, 0.4, 'sine', 0.2, 30); }),
  enemyShot: () => play('eshot', 0.12, (t) => tone(sfxBus, 400, t, 0.1, 'sine', 0.04, 250)),
  boss: () => play('boss', 1, (t) => { tone(sfxBus, 110, t, 0.9, 'sawtooth', 0.09, 55); tone(sfxBus, 82, t + 0.2, 0.9, 'square', 0.05, 41); }),
  chest: () => play('chest', 0.2, (t) => { [67, 71, 74, 79, 83].forEach((m, i) => tone(sfxBus, mtof(m), t + i * 0.06, 0.18, 'square', 0.04)); }),
  win: () => play('win', 1, (t) => { [72, 76, 79, 84, 79, 84, 88].forEach((m, i) => tone(sfxBus, mtof(m), t + i * 0.11, 0.25, 'square', 0.05)); }),
  lose: () => play('lose', 1, (t) => { [67, 63, 60, 55].forEach((m, i) => tone(sfxBus, mtof(m), t + i * 0.18, 0.3, 'triangle', 0.07)); }),
  buy: () => play('buy', 0.05, (t) => { tone(sfxBus, mtof(76), t, 0.08, 'square', 0.04); tone(sfxBus, mtof(83), t + 0.07, 0.15, 'square', 0.04); }),
};

/* ---------- 배경음악: music.js의 작곡 엔진 ---------- */
// 곡 이름: title, ch0~ch5(챕터별), mid(중간 보스), boss(최종 보스)
let music = null, want = null, tickT = null;
function ensureMusic() {
  if (music || !ac) return;
  music = createMusic(ac, musBus);
  tickT = setInterval(() => music.tick(), 40);
  if (want) music.play(want);
}
export function playMusic(name) {
  want = name;
  if (music) music.play(name);
}
export function stopMusic() { want = null; if (music) music.stop(); }
