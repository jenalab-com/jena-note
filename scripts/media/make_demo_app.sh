#!/bin/zsh
# 캡처 전용 JenaNote 사본을 만든다.
# 번들 ID를 바꿔 UserDefaults(등록 폴더·읽기 진행·AI 설정)를 실제 앱과 분리하고,
# 데모 문서 폴더만 등록된 상태로 시작한다. 데모 문서는 매번 저장소 원본에서 새로 복사한다.
set -euo pipefail

ROOT=${0:A:h:h:h}
DEMO_LIB=${DEMO_LIB:-$HOME/JenaNote Demo}
DEMO_ID=com.jenalab.jenanote.demo
DEMO_APP=$ROOT/.build/demo/JenaNote.app

[[ -n ${SKIP_BUILD:-} ]] || make -C "$ROOT" build >/dev/null
osascript -e "tell application id \"$DEMO_ID\" to quit" 2>/dev/null || true
sleep 1

rm -rf "$DEMO_LIB"
mkdir -p "$DEMO_LIB"
cp -R "$ROOT/scripts/media/demo-library/" "$DEMO_LIB/"

rm -rf "$DEMO_APP"
mkdir -p "${DEMO_APP:h}"
cp -R "$ROOT/.build/JenaNote.app" "$DEMO_APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $DEMO_ID" "$DEMO_APP/Contents/Info.plist"
codesign --force --deep --sign - "$DEMO_APP" 2>/dev/null

# 이전 데모 상태(창 위치 포함)를 지우고 다시 심는다.
defaults delete "$DEMO_ID" 2>/dev/null || true
rm -rf "$HOME/Library/Saved Application State/$DEMO_ID.savedState"

defaults write "$DEMO_ID" jn_language -string "${DEMO_LANG:-ko}"
defaults write "$DEMO_ID" jn_appearance -string light
defaults write "$DEMO_ID" jn_readingPageMode -string scroll
defaults write "$DEMO_ID" jn_readingFont -string kopubBatang
defaults write "$DEMO_ID" jn_readingLineSpacing -float 1.6
# 영상은 GIF로 줄어들므로 본문 배율을 키워 글자가 읽히게 한다.
defaults write "$DEMO_ID" jn_readingFontScale -float "${DEMO_FONT_SCALE:-1.0}"
defaults write "$DEMO_ID" jn_documentPaperSize -string automatic
defaults write "$DEMO_ID" jn_sidebarSortKey -string name
defaults write "$DEMO_ID" jn_sidebarSortOrder -string asc
defaults write "$DEMO_ID" ai.provider -string claude
defaults write "$DEMO_ID" com.jenalab.jenanote.sidebar.bookmarks -array "$DEMO_LIB"

echo "$DEMO_APP"
