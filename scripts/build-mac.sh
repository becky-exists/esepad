#!/bin/bash
# Mac のメニューバーアプリを、開発用の証明書で署名してビルドする（再ビルドしてもアクセシビリティの許可が残る）。
#   ./scripts/build-mac.sh          build/mac/EsepadMac.app を作る
#   ./scripts/build-mac.sh install  さらに /Applications にコピーする（動いていれば終了させてから）
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f Config/Local.xcconfig ]] || { echo "Config/Local.xcconfig（DEVELOPMENT_TEAM）を作ってください" >&2; exit 1; }

# 古いビルドの成果物を、新しいビルドと取り違えないよう、先に消してから作る
rm -rf build/derived/Build/Products/Release/EsepadMac.app

LOG="$(mktemp)"
if ! xcodebuild -project esepad.xcodeproj -scheme EsepadMac -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build/derived build >"$LOG" 2>&1; then
  grep -E "error:|BUILD" "$LOG" >&2 || tail -20 "$LOG" >&2
  echo "ビルドに失敗しました（古い成果物は使いません）" >&2
  exit 1
fi
grep -E "error:|BUILD" "$LOG" || true

APP=build/derived/Build/Products/Release/EsepadMac.app
[[ -d "$APP" ]] || { echo "ビルドは終わったが、成果物が見つかりません" >&2; exit 1; }
rm -rf build/mac && mkdir -p build/mac && cp -R "$APP" build/mac/
codesign -dv build/mac/EsepadMac.app 2>&1 | grep -E "Authority=Apple Development|TeamIdentifier" || echo "（署名が開発用の証明書ではありません）"
echo "できた: build/mac/EsepadMac.app"

if [[ "${1:-}" == "install" ]]; then
  pkill -x EsepadMac 2>/dev/null || true
  rm -rf /Applications/EsepadMac.app
  cp -R build/mac/EsepadMac.app /Applications/
  echo "入れた: /Applications/EsepadMac.app（初回は Bluetooth とアクセシビリティの許可を聞かれる）"
fi
