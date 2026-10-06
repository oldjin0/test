// 효과음과 배경음악을 모두 WebAudio로 합성한다 (음원 파일 없음 → 저작권 걱정 없음, 용량 0)
import { S } from './state.js';

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
      if (cur && !timer) { nextT = ac.currentTime + 0.05; timer = setInterval(schedule, 25); }
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

/* ---------- 배경음악: 간단한 칩튠 시퀀서 ---------- */
// 코드 진행(근음 MIDI)과 아르페지오 패턴으로 곡을 만든다
const TRACKS = {
  title: { bpm: 92, chords: [57, 53, 48, 55], arp: [0, 7, 12, 16, 12, 7, 0, 7], minor: true, lead: 'triangle', drums: false },
  battle: { bpm: 138, chords: [57, 53, 55, 52], arp: [0, 12, 7, 12, 3, 12, 7, 12], minor: true, lead: 'square', drums: true },
  boss: { bpm: 156, chords: [52, 53, 52, 50], arp: [0, 12, 0, 13, 0, 12, 7, 6], minor: true, lead: 'sawtooth', drums: true },
};
let cur = null, step = 0, nextT = 0, timer = null;

export function playMusic(name) {
  if (cur === name) return;
  cur = name; step = 0;
  if (!ac) return;
  nextT = ac.currentTime + 0.05;
  if (!timer) timer = setInterval(schedule, 25);
}
export function stopMusic() { cur = null; }

function schedule() {
  if (!ac || !cur || ac.state !== 'running') return;
  const tr = TRACKS[cur], s16 = 60 / tr.bpm / 4;
  while (nextT < ac.currentTime + 0.12) {
    const bar = Math.floor(step / 16) % tr.chords.length, i = step % 16;
    const root = tr.chords[bar];
    const third = tr.minor && bar % 2 === 0 ? 3 : 4;
    if (i % 4 === 0) tone(musBus, mtof(root - 12), nextT, s16 * 3.5, 'triangle', 0.22);
    if (i % 2 === 0) {
      let n = tr.arp[(i / 2) % tr.arp.length];
      if (n === 4 || n === 16) n += third - 4;
      tone(musBus, mtof(root + 12 + n), nextT, s16 * 1.6, tr.lead, tr.lead === 'triangle' ? 0.1 : 0.045);
    }
    if (tr.drums) {
      if (i % 8 === 0) tone(musBus, 140, nextT, 0.12, 'sine', 0.35, 45);
      if (i % 8 === 4) noise(musBus, nextT, 0.08, 0.12, 1500);
      if (i % 2 === 1) noise(musBus, nextT, 0.025, 0.05, 7000);
    }
    nextT += s16; step++;
  }
}
