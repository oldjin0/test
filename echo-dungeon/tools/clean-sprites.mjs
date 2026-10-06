// 스프라이트에서 본체와 떨어진 작은 얼룩(생성 모델이 가끔 남기는 글자·점)을 지운다.  node tools/clean-sprites.mjs 이름...
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { PNG } from 'pngjs';
const DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'www', 'assets');
for (const name of process.argv.slice(2)) {
  const f = path.join(DIR, `${name}.png`), png = PNG.sync.read(fs.readFileSync(f)), { width: w, height: h, data } = png;
  const seen = new Int32Array(w * h), sizes = [];
  for (let i = 0; i < w * h; i++) {
    if (seen[i] || data[i * 4 + 3] < 40) continue;
    const id = sizes.length + 1, st = [i]; let n = 0; seen[i] = id;
    while (st.length) {
      const p = st.pop(); n++;
      const x = p % w, y = (p / w) | 0;
      for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1], [1, 1], [-1, -1], [1, -1], [-1, 1]]) { // 8방향: 가는 선으로 이어진 조각도 한 몸
        const nx = x + dx, ny = y + dy; if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
        const q = ny * w + nx; if (!seen[q] && data[q * 4 + 3] >= 40) { seen[q] = id; st.push(q); }
      }
    }
    sizes.push(n);
  }
  const big = Math.max(...sizes); let removed = 0;
  for (let i = 0; i < w * h; i++) if (seen[i] && sizes[seen[i] - 1] < big * 0.012) { data[i * 4 + 3] = 0; removed++; }
  fs.writeFileSync(f, PNG.sync.write(png));
  console.log(name, '지운 점', removed);
}
