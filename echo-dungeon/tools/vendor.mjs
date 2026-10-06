// Capacitor 코어와 플러그인의 브라우저용 빌드를 www/vendor 로 복사한다 (번들러 없이 사용)
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const OUT = path.join(ROOT, 'www', 'vendor');
fs.mkdirSync(OUT, { recursive: true });
const files = {
  'capacitor.js': '@capacitor/core/dist/capacitor.js',
  'app.js': '@capacitor/app/dist/plugin.js',
  'haptics.js': '@capacitor/haptics/dist/plugin.js',
  'status-bar.js': '@capacitor/status-bar/dist/plugin.js',
  'admob.js': '@capacitor-community/admob/dist/plugin.js',
};
for (const [out, src] of Object.entries(files)) {
  const code = fs.readFileSync(path.join(ROOT, 'node_modules', src), 'utf8').replace(/\/\/# sourceMappingURL=.*$/m, '');
  fs.writeFileSync(path.join(OUT, out), code);
}
console.log('www/vendor 갱신');
