#!/bin/bash
# TestFlight に上げる ipa を作る。App Store Connect への登録とアップロードは、このスクリプトの外でやる。
#
#   ./scripts/archive-ios.sh 3              ビルド番号 3 でアーカイブして ipa を書き出す
#   ./scripts/archive-ios.sh 3 --no-sign    署名なしでアーカイブだけ（ビルドが通るかの確認用）
#
# 注意: 署名つきで回すと、Xcode の自動署名が Apple Developer に App ID（${BUNDLE_ID_PREFIX}.esepad）と
# 配布用のプロビジョニングプロファイルを作る。外に出る操作なので、App Store Connect の登録と同じ時に回す。
# 生成物は build/ に出る（git 管理外）。
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_NUMBER="${1:?ビルド番号を渡してください（例: ./scripts/archive-ios.sh 3）}"
NO_SIGN="${2:-}"
OUT=build/archive
rm -rf "$OUT"
mkdir -p "$OUT"

cfg() { grep -E "^$1[[:space:]]*=" Config/Local.xcconfig 2>/dev/null | head -1 | sed -E 's/^[^=]*=[[:space:]]*//' || true; }
TEAM="$(cfg DEVELOPMENT_TEAM)"

if [[ "$NO_SIGN" == "--no-sign" ]]; then
  xcodebuild archive -project esepad.xcodeproj -scheme esepad -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$OUT/esepad.xcarchive" \
    CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION="$BUILD_NUMBER" 2>&1 | grep -E "error:|warning: [^M]|ARCHIVE|BUILD" || true
  echo "署名なしのアーカイブ: $OUT/esepad.xcarchive"
  exit 0
fi

[[ -n "$TEAM" ]] || { echo "Config/Local.xcconfig に DEVELOPMENT_TEAM を書いてください" >&2; exit 1; }

xcodebuild archive -project esepad.xcodeproj -scheme esepad -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$OUT/esepad.xcarchive" \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD_NUMBER" 2>&1 | grep -E "error:|ARCHIVE|BUILD" || true

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>export</string>
	<key>teamID</key><string>$TEAM</string>
	<key>signingStyle</key><string>automatic</string>
	<key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST

xcodebuild -exportArchive -archivePath "$OUT/esepad.xcarchive" -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates 2>&1 | grep -E "error:|EXPORT" || true
ls -la "$OUT/export"
echo "ipa: $OUT/export/esepad.ipa（Transporter か Xcode の Organizer でアップロード）"
