#!/bin/bash
# SmartBlind 빌드 → build/SmartBlind.app
#   ./build.sh            릴리스 빌드
#   ./build.sh test       핵심 로직 테스트 (첨부 스크린샷 케이스 포함)
#   ./build.sh install    빌드 후 ~/Applications 에 설치하고 실행
set -euo pipefail
cd "$(dirname "$0")"

say() { printf '\n\033[1;36m▶ %s\033[0m\n' "$1"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$1"; exit 1; }

command -v swift >/dev/null 2>&1 || fail "Swift가 없습니다. 터미널에서 'xcode-select --install' 로 Command Line Tools를 설치하세요."
SWIFT_VER="$(swift --version 2>/dev/null | head -1)"
echo "  $SWIFT_VER"
OS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$OS_MAJOR" -ge 14 ] || fail "macOS 14 (Sonoma) 이상이 필요합니다."

if [ "${1:-}" = "test" ]; then
  say "핵심 로직 테스트"
  swift test
  exit 0
fi

say "빌드 (release)"
swift build -c release --product SmartBlind
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/SmartBlind.app"
say "앱 번들 만들기 → $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/SmartBlind" "$APP/Contents/MacOS/SmartBlind"
cp Support/Info.plist "$APP/Contents/Info.plist"

# 아이콘 (SF Symbol 없이 간단히 생성: 회색 둥근 사각형 + 모자이크)
if command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1 && [ -f Support/AppIcon.png ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Support/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2)); sips -z $d $d Support/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" || true
fi

# 서명: 'SmartBlind Dev' 인증서가 키체인에 있으면 그것으로(다시 빌드해도 권한 유지), 없으면 임시(ad-hoc) 서명
IDENTITY="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "SmartBlind Dev"; then
  IDENTITY="SmartBlind Dev"
fi
say "서명 ($([ "$IDENTITY" = "-" ] && echo "ad-hoc" || echo "$IDENTITY"))"
codesign --force --deep --options runtime --sign "$IDENTITY" "$APP" 2>/dev/null \
  || codesign --force --deep --sign "$IDENTITY" "$APP"
codesign --verify --verbose=1 "$APP" && echo "  서명 확인 완료"

if [ "${1:-}" = "install" ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
  say "설치 → $DEST/SmartBlind.app"
  pkill -x SmartBlind 2>/dev/null || true
  sleep 0.5
  rm -rf "$DEST/SmartBlind.app"
  ditto "$APP" "$DEST/SmartBlind.app"
  open "$DEST/SmartBlind.app"
  echo "  메뉴 막대의 눈 아이콘(👁)에서 설정을 여세요."
fi

say "완료"
