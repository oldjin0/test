#!/usr/bin/env bash
# 안드로이드 프로젝트(android/)를 만들고 아이콘·세로 고정·광고 ID·버전을 넣는다. CI와 로컬 빌드가 같이 쓴다.
#   VERSION_CODE=12 ADMOB_APP_ID=ca-app-pub-...~... bash tools/android-prep.sh
set -e
cd "$(dirname "$0")/.."
# 기본값은 Google 공식 테스트 앱 ID. 출시할 때는 AdMob 콘솔의 실제 앱 ID를 ADMOB_APP_ID로 넘긴다.
ADMOB_APP_ID="${ADMOB_APP_ID:-ca-app-pub-3940256099942544~3347511713}"
VERSION_CODE="${VERSION_CODE:-1}"

node tools/vendor.mjs
[ -d android ] || npx cap add android
npx cap sync android

RES=android/app/src/main/res
MANIFEST=android/app/src/main/AndroidManifest.xml
cp -r resources/android/res/. "$RES/"
rm -f "$RES/drawable-v24/ic_launcher_foreground.xml"
sed -i 's|#FFFFFF|#2A1D4A|' "$RES/values/ic_launcher_background.xml"
grep -q windowSplashScreenBackground "$RES/values/styles.xml" || \
  sed -i 's|<item name="android:background">@drawable/splash</item>|<item name="android:background">@drawable/splash</item>\n        <item name="windowSplashScreenBackground">#120B22</item>|' "$RES/values/styles.xml"
grep -q screenOrientation "$MANIFEST" || sed -i 's|<activity|<activity android:screenOrientation="portrait"|' "$MANIFEST"
# AdMob 앱 ID가 없으면 광고 SDK가 앱을 바로 종료시킨다
MANIFEST="$MANIFEST" ADMOB_APP_ID="$ADMOB_APP_ID" node -e "
const fs = require('fs'), p = process.env.MANIFEST;
let s = fs.readFileSync(p, 'utf8');
if (!s.includes('com.google.android.gms.ads.APPLICATION_ID'))
  s = s.replace(/<application[^>]*>/, (tag) => tag + '\n        <meta-data android:name=\"com.google.android.gms.ads.APPLICATION_ID\" android:value=\"' + process.env.ADMOB_APP_ID + '\"/>');
fs.writeFileSync(p, s);"
VERSION=$(node -p "require('./package.json').version")
sed -i "s|versionCode [0-9]*$|versionCode ${VERSION_CODE}|; s|versionName \"[^\"]*\"|versionName \"${VERSION}\"|" android/app/build.gradle
grep -n "versionCode\|versionName" android/app/build.gradle
grep -n "screenOrientation\|APPLICATION_ID" "$MANIFEST"
