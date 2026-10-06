// 절차적 작곡 엔진: 곡마다 음계·코드 진행·베이스·아르페지오·패드·드럼·멜로디(모티프를 변주)를 만들어 WebAudio로 연주한다.
// 음원 파일이 없으니 저작권 문제가 없고 용량도 0이다. 멜로디는 곡마다 고정된 시드로 만들어서 들을 때마다 같다.
// createMusic(ctx, out): ctx는 AudioContext 또는 OfflineAudioContext(미리 듣기 WAV를 만들 때), out은 음악이 흘러갈 노드.

const SCALES = {
  dorian: [0, 2, 3, 5, 7, 9, 10], minor: [0, 2, 3, 5, 7, 8, 10], harmonic: [0, 2, 3, 5, 7, 8, 11],
  phrygian: [0, 1, 3, 5, 7, 8, 10], phrygDom: [0, 1, 4, 5, 7, 8, 10], lydian: [0, 2, 4, 6, 7, 9, 11],
};
// 음계 위의 칸 번호(idx, 옥타브를 넘어도 됨) → MIDI 음
const noteOf = (root, sc, idx) => { const n = sc.length, o = Math.floor(idx / n); return root + o * 12 + sc[((idx % n) + n) % n]; };
const mtof = (m) => 440 * Math.pow(2, (m - 69) / 12);
function rngOf(seed) { let a = seed >>> 0; return () => { a = (a + 0x6d2b79f5) >>> 0; let t = a; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }

// A, B: 8마디짜리 두 악절의 코드(음계 칸 번호). 곡은 A B A B … 로 돈다.
export const SONGS = {
  title: { bpm: 88, root: 57, scale: 'dorian', A: [0, 3, 6, 0, 0, 3, 6, 4], B: [2, 6, 3, 0, 2, 6, 4, 4], bass: 'half', arp: 'up', arpV: 'pluck', pad: 0.7, drums: 'none', lead: 'flute', dens: 0, seed: 11 },
  ch0: { bpm: 112, root: 50, scale: 'dorian', A: [0, 3, 0, 6, 0, 3, 6, 4], B: [3, 3, 0, 0, 6, 6, 4, 4], bass: 'pulse', arp: 'up', arpV: 'pluck', pad: 0, drums: 'soft', lead: 'flute', dens: 1, seed: 23 },
  ch1: { bpm: 100, root: 57, scale: 'harmonic', A: [0, 3, 4, 0, 5, 3, 4, 4], B: [0, 5, 3, 4, 0, 3, 4, 0], bass: 'half', arp: 'up', arpV: 'bell', pad: 0.9, drums: 'sparse', lead: 'bell', dens: 0, seed: 37 },
  ch2: { bpm: 132, root: 52, scale: 'phrygian', A: [0, 1, 0, 6, 0, 1, 6, 5], B: [5, 6, 0, 0, 5, 6, 1, 0], bass: 'drive', arp: 'fast', arpV: 'pluck', pad: 0, drums: 'rock', lead: 'saw', dens: 2, seed: 41 },
  ch3: { bpm: 116, root: 53, scale: 'lydian', A: [0, 1, 4, 0, 0, 1, 5, 4], B: [5, 1, 4, 0, 5, 1, 4, 4], bass: 'walk', arp: 'fast', arpV: 'bell', pad: 0.8, drums: 'soft', lead: 'bell', dens: 1, seed: 53 },
  ch4: { bpm: 140, root: 48, scale: 'minor', A: [0, 5, 2, 6, 0, 5, 6, 4], B: [3, 5, 0, 6, 3, 5, 6, 6], bass: 'drive', arp: 'fast', arpV: 'pluck', pad: 0.8, drums: 'drive', lead: 'saw', dens: 2, seed: 67 },
  ch5: { bpm: 150, root: 55, scale: 'harmonic', A: [0, 5, 3, 4, 0, 5, 4, 4], B: [0, 3, 4, 5, 3, 4, 0, 0], bass: 'drive', arp: 'fast', arpV: 'pluck', pad: 0.6, drums: 'drive', lead: 'square', dens: 2, seed: 71 },
  mid: { bpm: 152, root: 50, scale: 'phrygDom', A: [0, 1, 0, 1, 0, 6, 1, 0], B: [5, 6, 0, 0, 5, 6, 1, 1], bass: 'drive', arp: 'fast', arpV: 'pluck', pad: 0.5, drums: 'boss', lead: 'saw', dens: 2, seed: 79 },
  boss: { bpm: 168, root: 50, scale: 'harmonic', A: [0, 5, 3, 4, 0, 5, 4, 4], B: [3, 4, 0, 5, 3, 4, 0, 0], bass: 'drive', arp: 'fast', arpV: 'pluck', pad: 0.9, drums: 'boss', lead: 'saw', dens: 2, seed: 97 },
};

// 박자 안의 음 길이·시작 위치(16분음표 칸)
const RHYTHMS = [
  [[0, 6, 8, 12], [0, 8], [0, 4, 8, 12], [0, 6, 10]], // 성기게 (느린 곡)
  [[0, 3, 6, 8, 11, 14], [0, 4, 6, 8, 12, 14], [0, 2, 4, 8, 10, 12], [0, 3, 6, 10, 12]],
  [[0, 2, 4, 6, 8, 10, 12, 14], [0, 3, 4, 6, 8, 11, 12, 14], [0, 2, 3, 6, 8, 10, 11, 14], [0, 1, 2, 4, 6, 8, 10, 12, 14]],
];
const ARPS = { up: [0, 1, 2, 3, 2, 1, 2, 1], fast: [0, 1, 2, 3, 4, 3, 2, 1, 0, 1, 2, 3, 5, 3, 2, 1] };
const DRUMS = {
  soft: { k: [0, 10], s: [12], h: [0, 4, 8, 12], hv: 0.5 },
  sparse: { k: [0], s: [], h: [8], hv: 0.5 },
  rock: { k: [0, 6, 8], s: [4, 12], h: [0, 2, 4, 6, 8, 10, 12, 14], hv: 0.8 },
  drive: { k: [0, 4, 8, 12], s: [4, 12], h: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15], hv: 0.8 },
  boss: { k: [0, 3, 6, 8, 10, 13], s: [4, 12], h: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15], hv: 1, oh: [14], clap: [12] },
};

// 음계 칸 번호로 된 멜로디 16마디를 만든다 (각 마디는 {step, idx, len} 목록)
function composeLead(song, sc) {
  const rng = rngOf(song.seed), pick = (a) => a[Math.floor(rng() * a.length)], lead = [];
  const tonesOf = (deg) => [deg, deg + 2, deg + 4, deg + 7, deg + 9, deg + 11, deg - 3, deg - 5];
  const nearest = (p, tones) => tones.reduce((b, t) => (Math.abs(t - p) < Math.abs(b - p) ? t : b), tones[0]);
  const LO = 6, HI = 15;
  const bar = (rhythm, start, tones) => {
    const out = []; let p = start;
    rhythm.forEach((step, k) => {
      if (step % 4 === 0 || k === 0) p = nearest(p + pick([-2, -1, 0, 1, 2]), tones); // 강박은 코드음
      else p += pick([-2, -1, -1, 0, 1, 1, 2]);
      p = Math.max(LO, Math.min(HI, p));
      out.push({ step, idx: p, len: ((rhythm[k + 1] ?? 16) - step) });
    });
    return out;
  };
  for (const sec of [song.A, song.B]) {
    const secBars = [];
    const base = sec === song.A ? 8 : 10; // B는 한 음계 단계 위에서 시작
    const dens = RHYTHMS[song.dens];
    const ph = { rA: pick(dens), rB: pick(dens) };
    for (let b = 0; b < 8; b++) {
      const deg = sec[b], tones = tonesOf(deg);
      const first = b % 4, second = Math.floor(b / 4);
      let rhythm, start = base + (deg > 3 ? -1 : 0);
      if (first === 0) rhythm = ph.rA;
      else if (first === 1) rhythm = ph.rA; // 같은 리듬을 코드에 맞게 옮겨 되풀이
      else if (first === 2) rhythm = ph.rB;
      else rhythm = pick(dens).slice(0, 4);
      let notes = bar(rhythm, start, tones);
      if (first === 3) { // 악절 끝: 마지막 음은 코드의 으뜸음(또는 B로 넘어갈 땐 5도)에 길게
        const last = notes[notes.length - 1];
        last.idx = nearest(second === 1 && b === 7 ? deg + 4 : deg + 7, tones);
        last.len = 8;
      }
      secBars.push(notes);
    }
    // 뒤 악절(5~8마디)은 앞 악절의 모양을 되풀이하되 끝만 바꾼다
    for (let b = 4; b < 7; b++) if (rng() < 0.7) secBars[b] = secBars[b - 4].map((n) => ({ ...n, idx: nearest(n.idx + (sec[b] - sec[b - 4]), tonesOf(sec[b])) }));
    lead.push(...secBars);
  }
  return lead;
}

export function createMusic(ctx, out) {
  const mix = ctx.createGain();
  const comp = ctx.createDynamicsCompressor();
  comp.threshold.value = -16; comp.knee.value = 14; comp.ratio.value = 3; comp.attack.value = 0.004; comp.release.value = 0.22;
  mix.connect(comp); comp.connect(out);
  // 리버브: 감쇠하는 잡음으로 만든 임펄스
  const rev = ctx.createConvolver(), len = Math.floor(ctx.sampleRate * 1.7), ir = ctx.createBuffer(2, len, ctx.sampleRate);
  for (let c = 0; c < 2; c++) { const d = ir.getChannelData(c); for (let i = 0; i < len; i++) d[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / len, 2.6); }
  rev.buffer = ir;
  const revIn = ctx.createGain(), revOut = ctx.createGain(); revOut.gain.value = 0.55;
  revIn.connect(rev); rev.connect(revOut); revOut.connect(mix);
  // 잡음 버퍼 (드럼용)
  const nb = ctx.createBuffer(1, ctx.sampleRate, ctx.sampleRate), nd = nb.getChannelData(0);
  for (let i = 0; i < nd.length; i++) nd[i] = Math.random() * 2 - 1;

  let trk = null;

  /* ----- 악기 ----- */
  function voice(dest, type, f, t, d, vol, o = {}) {
    const osc = ctx.createOscillator(), g = ctx.createGain(); let node = osc;
    osc.type = type; osc.frequency.setValueAtTime(f, t);
    if (o.detune) osc.detune.value = o.detune;
    if (o.slide) osc.frequency.exponentialRampToValueAtTime(o.slide, t + d);
    if (o.lp) {
      const fl = ctx.createBiquadFilter(); fl.type = 'lowpass'; fl.Q.value = o.q || 0.7;
      fl.frequency.setValueAtTime(o.lp, t); if (o.lpEnd) fl.frequency.exponentialRampToValueAtTime(o.lpEnd, t + d);
      osc.connect(fl); node = fl;
    }
    const a = o.a || 0.008;
    g.gain.setValueAtTime(0.0001, t); g.gain.exponentialRampToValueAtTime(vol, t + a);
    if (o.hold) g.gain.setValueAtTime(vol, t + Math.max(a, d - o.hold));
    g.gain.exponentialRampToValueAtTime(0.0001, t + d);
    if (o.vib) { const l = ctx.createOscillator(), lg = ctx.createGain(); l.frequency.value = o.vib[0]; lg.gain.value = o.vib[1]; l.connect(lg); lg.connect(osc.detune); l.start(t); l.stop(t + d + 0.05); }
    node.connect(g); g.connect(dest); osc.start(t); osc.stop(t + d + 0.05);
  }
  function noise(dest, t, d, vol, type, freq, q) {
    const s = ctx.createBufferSource(), g = ctx.createGain(), f = ctx.createBiquadFilter();
    s.buffer = nb; f.type = type; f.frequency.value = freq; f.Q.value = q || 0.7;
    g.gain.setValueAtTime(vol, t); g.gain.exponentialRampToValueAtTime(0.0001, t + d);
    s.connect(f); f.connect(g); g.connect(dest); s.start(t, Math.random() * 0.5); s.stop(t + d + 0.02);
  }
  const kick = (T, t, v) => { voice(T.drum, 'sine', 150, t, 0.16, 0.5 * v, { slide: 42 }); noise(T.drum, t, 0.02, 0.1 * v, 'highpass', 3000); };
  const snare = (T, t, v) => { noise(T.drum, t, 0.17, 0.24 * v, 'bandpass', 1900, 0.8); voice(T.drum, 'triangle', 200, t, 0.09, 0.18 * v, { slide: 140 }); };
  const hat = (T, t, v, open) => noise(T.drum, t, open ? 0.14 : 0.035, 0.07 * v, 'highpass', 7500);
  const clap = (T, t, v) => { for (let i = 0; i < 3; i++) noise(T.drum, t + i * 0.012, 0.07, 0.14 * v, 'bandpass', 1500, 0.9); };
  const tom = (T, t, f, v) => voice(T.drum, 'sine', f, t, 0.22, 0.4 * v, { slide: f * 0.6 });

  function leadNote(T, song, f, t, d, vol) {
    const D = T.lead;
    switch (song.lead) {
      case 'bell': voice(D, 'sine', f, t, Math.max(d * 1.8, 0.5), vol, { a: 0.004 }); voice(D, 'sine', f * 2.01, t, Math.max(d * 1.2, 0.3), vol * 0.35, { a: 0.004 }); break;
      case 'saw': voice(D, 'sawtooth', f, t, d, vol * 0.8, { lp: 3400, lpEnd: 1700, q: 1.2, vib: [5.5, 7], hold: 0.05 }); voice(D, 'sawtooth', f, t, d, vol * 0.5, { lp: 2600, detune: 9 }); break;
      case 'square': voice(D, 'square', f, t, d, vol * 0.6, { lp: 2400, lpEnd: 1400, vib: [6, 5], hold: 0.04 }); break;
      default: voice(D, 'triangle', f, t, d, vol * 1.3, { lp: 2800, vib: [5.2, 9], hold: 0.08, a: 0.03 }); voice(D, 'sine', f * 2, t, d, vol * 0.25, { a: 0.03 });
    }
  }
  function arpNote(T, song, f, t, d, vol) {
    if (song.arpV === 'bell') { voice(T.arp, 'sine', f, t, d * 2.2, vol * 1.3, { a: 0.003 }); voice(T.arp, 'sine', f * 3, t, d * 0.8, vol * 0.25, { a: 0.003 }); }
    else voice(T.arp, 'triangle', f, t, d * 1.4, vol * 1.6, { lp: 3200, lpEnd: 900, a: 0.004 });
  }

  /* ----- 곡 만들기 ----- */
  function start(name, t0) {
    const song = SONGS[name]; if (!song) return;
    const now = t0 ?? ctx.currentTime;
    if (trk) { const old = trk, og = old.T.tg; og.gain.cancelScheduledValues(now); og.gain.setTargetAtTime(0, now, 0.18); old.dead = true; setTimeout(() => { try { og.disconnect(); } catch (e) { /* ignore */ } }, 1800); }
    const tg = ctx.createGain(); tg.gain.setValueAtTime(0.0001, now); tg.gain.linearRampToValueAtTime(1, now + 0.5); tg.connect(mix);
    const mk = (g, send) => { const b = ctx.createGain(); b.gain.value = g; b.connect(tg); if (send) { const s = ctx.createGain(); s.gain.value = send; b.connect(s); s.connect(revIn); } return b; };
    const T = { tg, bass: mk(1, 0), pad: mk(1, 0.7), arp: mk(1, 0.35), lead: mk(1, 0.35), drum: mk(1, 0.1) };
    // 리드에 점 8분음표 딜레이
    const dly = ctx.createDelay(1), fb = ctx.createGain(), dOut = ctx.createGain(); dly.delayTime.value = 60 / song.bpm * 0.75; fb.gain.value = 0.32; dOut.gain.value = 0.22;
    T.lead.connect(dly); dly.connect(fb); fb.connect(dly); dly.connect(dOut); dOut.connect(tg); dOut.connect(revIn);
    const sc = SCALES[song.scale], lead = composeLead(song, sc);
    trk = { name, song, sc, lead, T, step: 0, loops: 0, nextT: now + 0.06, s16: 60 / song.bpm / 4, dead: false };
  }

  function bar(trk, barNo, t0) {
    const { song, sc, T, s16 } = trk, sec = barNo < 8 ? song.A : song.B, deg = sec[barNo % 8], loopBar = barNo;
    const tones = [deg, deg + 2, deg + 4];
    const R = song.root;
    // 패드: 코드를 한 마디 동안 길게
    if (song.pad) for (const k of tones) {
      const f = mtof(noteOf(R - 12, sc, k + 7)), d = s16 * 16 * 1.02;
      voice(T.pad, 'sawtooth', f, t0, d, 0.034 * song.pad, { a: s16 * 5, lp: 800, detune: -7, hold: s16 * 4 });
      voice(T.pad, 'sawtooth', f, t0, d, 0.034 * song.pad, { a: s16 * 5, lp: 800, detune: 7, hold: s16 * 4 });
    }
    // 베이스
    const bn = (idx) => mtof(noteOf(R - 12, sc, idx));
    const bv = (type, f, t, d, vol, hi) => voice(T.bass, type, f, t, d, vol, { lp: hi || 520, lpEnd: 160, q: 1.4, a: 0.006 });
    if (song.bass === 'half') { bv('sawtooth', bn(deg), t0, s16 * 7.5, 0.2); bv('sawtooth', bn(deg + 4), t0 + s16 * 8, s16 * 7.5, 0.17); }
    else if (song.bass === 'pulse') { const p = [0, 0, 7, 0, 0, 0, 7, 4]; for (let i = 0; i < 8; i++) bv('sawtooth', bn(deg + p[i]), t0 + i * 2 * s16, s16 * 1.7, 0.17); }
    else if (song.bass === 'walk') { [0, 2, 4, 2].forEach((o, i) => bv('triangle', bn(deg + o), t0 + i * 4 * s16, s16 * 3.6, 0.28, 900)); }
    else for (let i = 0; i < 16; i++) { const o = i % 8 === 6 ? 7 : i % 8 === 3 ? 4 : 0; bv('sawtooth', bn(deg + o), t0 + i * s16, s16 * 0.9, i % 4 === 0 ? 0.2 : 0.13, 620); }
    // 아르페지오
    const pat = ARPS[song.arp], stepN = pat.length === 8 ? 2 : 1;
    const ct = [deg, deg + 2, deg + 4, deg + 7, deg + 9, deg + 11];
    for (let i = 0; i < pat.length; i++) arpNote(T, song, mtof(noteOf(R, sc, ct[pat[i]])), t0 + i * stepN * s16, s16 * stepN, i % 4 === 0 ? 0.055 : 0.04);
    // 멜로디 (첫 바퀴의 첫 두 마디는 쉬어서 곡이 서서히 열린다)
    if (!(trk.loops === 0 && barNo < 2 && song.drums !== 'none')) for (const n of trk.lead[loopBar]) {
      leadNote(T, song, mtof(noteOf(R, sc, n.idx)), t0 + n.step * s16, Math.max(s16 * 0.9, n.len * s16 * 0.92), 0.085);
    }
    // 드럼
    const dr = DRUMS[song.drums];
    if (dr) {
      const fill = barNo % 8 === 7;
      for (const i of dr.k) if (!(fill && i > 11)) kick(T, t0 + i * s16, 1);
      for (const i of dr.s) if (!(fill && i > 11)) snare(T, t0 + i * s16, 1);
      for (const i of dr.h) hat(T, t0 + i * s16, (dr.hv || 1) * (i % 2 === 0 ? 1 : 0.55), dr.oh && dr.oh.includes(i));
      if (dr.clap) for (const i of dr.clap) clap(T, t0 + i * s16, 0.8);
      if (fill) { for (let i = 12; i < 16; i++) { snare(T, t0 + i * s16, 0.5 + (i - 12) * 0.2); if (song.drums === 'boss') tom(T, t0 + i * s16 + s16 * 0.5, 180 - (i - 12) * 25, 0.7); } }
      if (barNo % 8 === 0 && (song.drums === 'boss' || song.drums === 'drive')) noise(T.drum, t0, 1.1, 0.1, 'highpass', 4500);
    }
  }

  function scheduleUntil(limit) {
    if (!trk || trk.dead) return;
    while (trk.nextT < limit) {
      if (trk.step % 16 === 0) {
        const barNo = (trk.step / 16) % 16;
        if (barNo === 0 && trk.step > 0) trk.loops = (trk.loops || 0) + 1;
        bar(trk, barNo, trk.nextT);
      }
      trk.nextT += trk.s16; trk.step++;
    }
  }
  // 한 마디(16칸)를 통째로 미리 예약하므로, 시간이 마디 경계를 넘기 전에만 호출하면 된다
  return {
    play(name, t0) { if (trk && trk.name === name && !trk.dead) return; start(name, t0); },
    stop() { if (trk) { trk.dead = true; trk.T.tg.gain.setTargetAtTime(0, ctx.currentTime, 0.1); trk = null; } },
    tick() { if (ctx.state === 'running') scheduleUntil(ctx.currentTime + 0.5); },
    scheduleUntil,
    get name() { return trk && trk.name; },
  };
}
