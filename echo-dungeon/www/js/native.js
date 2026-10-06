// 안드로이드 앱(Capacitor)일 때만 동작하는 기능. 브라우저에서는 조용히 무시된다.
import { S } from './state.js';

// vendor/*.js (Capacitor 브라우저 빌드)가 전역에 올려 둔 플러그인을 쓴다
const core = window.capacitorExports;
const C = (core && core.Capacitor) || window.Capacitor;
export const isNative = !!(C && C.isNativePlatform && C.isNativePlatform());
// AdMob 플러그인의 브라우저 빌드는 전역 이름이 capacitorStripe 로 되어 있다 (플러그인 쪽 이름 실수)
const GLOBALS = { App: ['capacitorApp', 'App'], Haptics: ['capacitorHaptics', 'Haptics'], StatusBar: ['capacitorStatusBar', 'StatusBar'], AdMob: ['capacitorStripe', 'AdMob'] };
const plugin = (n) => {
  if (!isNative) return null;
  const [g, k] = GLOBALS[n];
  return (window[g] && window[g][k]) || (C.Plugins && C.Plugins[n]) || null;
};

let lastHaptic = 0;
export function haptic(kind) {
  if (!S.save || !S.save.settings.vib) return;
  const now = performance.now();
  if (now - lastHaptic < 60) return;
  lastHaptic = now;
  const Hp = plugin('Haptics');
  try {
    if (Hp) Hp.impact({ style: kind === 'heavy' ? 'HEAVY' : kind === 'medium' ? 'MEDIUM' : 'LIGHT' }).catch(() => {});
    else if (navigator.vibrate) navigator.vibrate(kind === 'heavy' ? 60 : kind === 'medium' ? 30 : 12);
  } catch (e) { /* ignore */ }
}

export function initNative({ onBack, onPause, onResume }) {
  const SB = plugin('StatusBar');
  if (SB) { SB.setOverlaysWebView({ overlay: true }).catch(() => {}); SB.hide().catch(() => {}); }
  const App = plugin('App');
  if (App) {
    App.addListener('backButton', onBack);
    App.addListener('pause', onPause);
    App.addListener('resume', onResume);
  }
  document.addEventListener('visibilitychange', () => (document.hidden ? onPause() : onResume()));
}

/* ---------- 보상형 광고 (AdMob) ----------
   광고는 플레이어가 고를 때만 나온다: 부활, 골드 2배. 강제 광고는 없다.
   아래 ID는 Google 공식 테스트 ID다. 출시 전에 AdMob 콘솔의 실제 보상형 광고 단위 ID로 바꾼다.
   앱 ID는 AndroidManifest에 들어간다 (tools/android-prep.sh 의 ADMOB_APP_ID). */
export const AD_REWARD_ID = 'ca-app-pub-3940256099942544/5224354917';
let adsOk = false;
export async function initAds() {
  const A = plugin('AdMob');
  if (!A) return;
  try {
    await A.initialize({});
    const info = await A.requestConsentInfo(); // 유럽 등 동의가 필요한 곳에서는 동의 창을 먼저 띄운다
    if (info && info.isConsentFormAvailable && info.status === 'REQUIRED') await A.showConsentForm();
    adsOk = true;
  } catch (e) { adsOk = false; }
}
// 끝까지 보면 true. 앱이 아니면(브라우저 판) 광고 없이 바로 보상한다.
export async function showRewardAd() {
  const A = plugin('AdMob');
  if (!A) return true;
  if (!adsOk) await initAds();
  if (!adsOk) return false;
  let rewarded = false;
  const subs = [];
  try {
    subs.push(await A.addListener('onRewardedVideoAdReward', () => { rewarded = true; }));
    const closed = new Promise((res) => {
      A.addListener('onRewardedVideoAdDismissed', res).then((h) => subs.push(h));
      A.addListener('onRewardedVideoAdFailedToShow', res).then((h) => subs.push(h));
    });
    await A.prepareRewardVideoAd({ adId: AD_REWARD_ID });
    await A.showRewardVideoAd();
    await Promise.race([closed, new Promise((res) => setTimeout(res, 90000))]);
  } catch (e) { /* 광고가 없거나 오프라인 */ }
  subs.forEach((h) => h && h.remove && h.remove());
  return rewarded;
}

export function exitApp() {
  const App = plugin('App');
  if (App) App.exitApp().catch(() => {});
}
