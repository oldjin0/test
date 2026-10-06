// 곡을 OfflineAudioContext로 렌더링해 WAV로 저장하고, 소리가 깨지거나 비지 않았는지 수치로 확인한다.
//   node tools/render-music.mjs <출력 폴더> [곡 이름...] [--sec 40]
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
const args = process.argv.slice(2), secI = args.indexOf('--sec'), SEC = secI >= 0 ? +args[secI + 1] : 40;
if (secI >= 0) args.splice(secI, 2);
const [out, ...names] = args;
fs.mkdirSync(out, { recursive: true });
const browser = await chromium.launch();
const page = await browser.newPage();
const errors = [];
page.on('pageerror', (e) => errors.push(e.message));
await page.goto(`http://127.0.0.1:${server.address().port}/`);
const all = await page.evaluate(async () => (await import('./js/music.js')).SONGS && Object.keys((await import('./js/music.js')).SONGS));
const SR = 32000;
const stats = [];
for (const name of names.length ? names : all) {
  const pcm = await page.evaluate(async ([name, SEC, SR]) => {
    const { createMusic } = await import('./js/music.js');
    const off = new OfflineAudioContext(2, SR * SEC, SR);
    const bus = off.createGain(); bus.gain.value = 0.32; bus.connect(off.destination); // 게임의 음악 볼륨과 같게
    const m = createMusic(off, bus);
    m.play(name, 0); m.scheduleUntil(SEC);
    const buf = await off.startRendering();
    const L = buf.getChannelData(0), R = buf.getChannelData(1), o = new Int16Array(L.length * 2);
    let peak = 0, sq = 0, clip = 0;
    for (let i = 0; i < L.length; i++) {
      for (const [k, v] of [[0, L[i]], [1, R[i]]]) { const a = Math.abs(v); if (a > peak) peak = a; sq += v * v; if (a >= 0.999) clip++; o[i * 2 + k] = Math.max(-1, Math.min(1, v)) * 32767; }
    }
    // 1초 단위 소리 크기: 중간에 끊기는 구간이 없는지
    const sec = []; for (let s = 0; s < SEC; s++) { let e = 0; for (let i = s * SR; i < (s + 1) * SR; i++) e += L[i] * L[i]; sec.push(Math.sqrt(e / SR)); }
    const bytes = new Uint8Array(o.buffer); let bin = '';
    for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return { b64: btoa(bin), peak, rms: Math.sqrt(sq / (L.length * 2)), clip, quietSecs: sec.filter((e) => e < 0.002).length };
  }, [name, SEC, SR]).catch((e) => ({ err: e.message }));
  if (pcm.err) { stats.push({ name, err: pcm.err }); continue; }
  const data = Buffer.from(pcm.b64, 'base64'), h = Buffer.alloc(44); // WAV 머리말 (16비트 스테레오)
  h.write('RIFF', 0); h.writeUInt32LE(36 + data.length, 4); h.write('WAVEfmt ', 8); h.writeUInt32LE(16, 16); h.writeUInt16LE(1, 20); h.writeUInt16LE(2, 22);
  h.writeUInt32LE(SR, 24); h.writeUInt32LE(SR * 4, 28); h.writeUInt16LE(4, 32); h.writeUInt16LE(16, 34); h.write('data', 36); h.writeUInt32LE(data.length, 40);
  fs.writeFileSync(path.join(out, `${name}.wav`), Buffer.concat([h, data]));
  stats.push({ name, peak: +pcm.peak.toFixed(3), rms: +pcm.rms.toFixed(4), clip: pcm.clip, quietSecs: pcm.quietSecs });
}
console.table(stats);
if (errors.length) console.log('오류', errors);
await browser.close(); server.close();
