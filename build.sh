#!/bin/bash
# Xcode 없이 Command Line Tools 만으로 SwiftUI .app 번들을 만든다.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/ClaudeUsage.app"
BIN="$APP/Contents/MacOS/ClaudeUsage"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ClaudeUsage</string>
  <key>CFBundleDisplayName</key><string>Claude 사용량</string>
  <key>CFBundleExecutable</key><string>ClaudeUsage</string>
  <key>CFBundleIdentifier</key><string>kr.backpac.claude-usage</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><true/>
</dict>
</plist>
PLIST

# SDK 선택: CLT 기본 SDK 가 호스트보다 새 베타(예: macOS 27)면 SwiftUI 의 @State 가 매크로로
# 정의되는데 CLT 에는 SwiftUIMacros 플러그인이 없어 빌드가 깨진다 (2026-09-11 실측).
# → 호스트 macOS 메이저 버전과 같은 SDK 가 있으면 그것을 SDKROOT 로 고정한다.
SDK_DIR=/Library/Developer/CommandLineTools/SDKs
HOST_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if [ -d "$SDK_DIR/MacOSX${HOST_MAJOR}.sdk" ]; then
  export SDKROOT="$SDK_DIR/MacOSX${HOST_MAJOR}.sdk"
  echo "sdk: $SDKROOT"
fi

swiftc -O -parse-as-library -swift-version 5 \
  -framework SwiftUI -framework Charts -framework AppKit \
  Sources/*.swift -o "$BIN"

codesign --force --sign - "$APP" 2>/dev/null || true
echo "built: $APP"
