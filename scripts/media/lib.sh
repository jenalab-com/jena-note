# 캡처 스크립트 공용 함수. source 해서 쓴다.
ROOT=${ROOT:-${0:A:h:h:h}}
DEMO_ID=com.jenalab.jenanote.demo
OUT=${OUT:-$ROOT/docs/media}
WININFO=$ROOT/.build/window-info
[[ -x $WININFO ]] || swiftc -O "$ROOT/scripts/media/window.swift" -o "$WININFO"
WINLIST=$ROOT/.build/window-list
[[ -x $WINLIST ]] || swiftc -O "$ROOT/scripts/media/windows.swift" -o "$WINLIST"
TEXTPOS=$ROOT/.build/textpos
[[ -x $TEXTPOS ]] || swiftc -O "$ROOT/scripts/media/textpos.swift" -o "$TEXTPOS"
AXFIND=$ROOT/.build/axfind
[[ -x $AXFIND ]] || swiftc -O "$ROOT/scripts/media/axfind.swift" -o "$AXFIND"
mkdir -p "$OUT"

# System Events로 데모 앱(번들 ID로 식별)에 AppleScript를 보낸다.
as_app() {
  osascript -e "tell application \"System Events\" to tell (first process whose bundle identifier is \"$DEMO_ID\")" -e "$1" -e "end tell"
}
activate() { osascript -e "tell application id \"$DEMO_ID\" to activate"; sleep 0.3; }
# 메뉴 클릭: menu "보기" "격자"
menu() { as_app "click menu item \"$2\" of menu 1 of menu bar item \"$1\" of menu bar 1"; }
# $2=수식키(예: "command down"). 중괄호를 ${2:+...} 안에 두면 빈 값일 때 '}'가 새어 나온다.
mods() { [[ -n ${1:-} ]] && print -rn -- " using {$1}"; }
key() { as_app "keystroke \"$1\"$(mods "${2:-}")"; }
keycode() { as_app "key code $1$(mods "${2:-}")"; }
# 메인 창을 고정 크기로 둔다(포인트 단위).
frame_window() {
  as_app "set position of window 1 to {${1:-80}, ${2:-60}}"
  as_app "set size of window 1 to {${3:-1400}, ${4:-880}}"
}
# 창만 캡처(그림자 포함). $1=파일명 $2=제목 필터(선택)
shot() {
  local info=($($WININFO $DEMO_ID ${2:-}))
  screencapture -x -l ${info[1]} "$OUT/$1"
  echo "captured $OUT/$1"
}

# 툴팁·팝오버까지 담아 캡처한다. $1=파일명
# 팝오버는 메인 창과 별도 창이지만, 맨 앞(팝오버) 창을 -l로 찍으면 부모 창과 함께 한 장에 담긴다.
shot_all() {
  local front=$($WINLIST $DEMO_ID | tail -1 | cut -d' ' -f1)
  screencapture -x -l $front "$OUT/$1"
  echo "captured $OUT/$1"
}
# 메인 창 외의 창(툴팁·팝오버)이 뜰 때까지 기다린다. $1=최대 초(기본 10)
wait_popup() {
  local i
  for i in {1..$(( ${1:-10} * 4 ))}; do
    (( $($WINLIST $DEMO_ID | wc -l) > 1 )) && return 0
    sleep 0.25
  done
  echo "popup did not appear" >&2; return 1
}

# 접근성 이름으로 요소의 중심 좌표 "x y"를 빠르게 찾는다(없으면 실패). $1=이름 $2=역할(선택)
ax_at() { $AXFIND $DEMO_ID "$1" ${2:-}; }
# AI 응답이 끝날 때까지 기다린다. 응답 중에는 '보내기' 버튼이 '중지'로 바뀐다. $1=최대 초
wait_ai_reply() {
  local deadline=$((EPOCHSECONDS + ${1:-180}))
  sleep 2
  until ax_at "보내기" AXButton >/dev/null; do
    (( EPOCHSECONDS > deadline )) && { echo "AI 응답 시간 초과" >&2; return 1; }
    sleep 0.5
  done
}

# 본문 문자열 위에 마우스를 올려 교정 툴팁을 띄운다. 검사가 아직 안 끝났으면 마우스를
# 움직이지 않는 한 다시 판정하지 않으므로, 안 뜨면 잠깐 비켰다가 다시 올린다. $1=문자열 $2=이동 초
hover_text() {
  local c=($(text_at "$1")) try
  for try in 1 2 3 4 5; do
    $MOUSE move $((c[1] - 40)) $((c[2] + 40)) 0.2
    $MOUSE move ${c[1]} ${c[2]} ${2:-0.5}
    wait_popup 3 2>/dev/null && return 0
  done
  echo "popup did not appear: $1" >&2; return 1
}

# 본문에서 문자열의 화면 중심 좌표 "x y". $1=문자열 $2=몇 번째(기본 1)
text_at() { local r=($($TEXTPOS $DEMO_ID "$1" ${2:-1})); print -r -- "${r[1]} ${r[2]}"; }

MOUSE=$ROOT/.build/mouse
[[ -x $MOUSE ]] || swiftc -O "$ROOT/scripts/media/mouse.swift" -o "$MOUSE"

# 접근성 설명(description)·도움말(help)·이름(title)·라벨 값(value)으로 요소를 찾아 중심 좌표 "x y"를 출력한다. $2=역할(선택), $3=창 번호(기본 1)
center_of() {
  # 같은 이름이 사이드바와 목록에 함께 있으면 가장 오른쪽(목록) 요소를 고른다.
  perl -e 'alarm 60; exec @ARGV' osascript <<OSA
tell application "System Events"
  set p to first process whose bundle identifier is "$DEMO_ID"
  set els to entire contents of window ${3:-1} of p
  set best to ""
  set bestX to -100000
  repeat with e in els
    try
      set names to {description of e, help of e, name of e}
      try
        set end of names to (value of e as text)
      end try
      if names contains "$1" and ("${2:-}" is "" or (role of e) is "${2:-}") then
        set {x, y} to position of e
        set {w, h} to size of e
        if x > bestX then
          set bestX to x
          set best to ((x + w / 2) as integer as text) & " " & ((y + h / 2) as integer as text)
        end if
      end if
    end try
  end repeat
  if best is "" then error "not found: $1"
  return best
end tell
OSA
}
# 설명으로 찾은 요소를 마우스로 이동해 클릭. $1=설명 $2=동작(click|dclick|rclick|move) $3=역할
# 빠른 axfind를 먼저 쓰고, 못 찾으면 AppleScript 탐색(이름 속성이 다른 요소)으로 넘어간다.
press() {
  activate
  local c=($(ax_at "$1" "${3:-}" || center_of "$1" "${3:-}"))
  $MOUSE ${2:-click} ${c[1]} ${c[2]} ${MOVE_SEC:-0.6}
}
# 맨 앞 창(정보·비교 같은 보조 창)을 닫기 버튼으로 닫는다. 정보 창은 메인 창과 제목이 같을 수 있다.
close_front() { as_app 'click (first button of window 1 whose subrole is "AXCloseButton")'; sleep 1; }

# --- 화면 녹화(ffmpeg avfoundation) ---
zmodload zsh/datetime
# SCREEN_DEVICE: avfoundation 화면 장치 이름. 번호는 카메라 연결에 따라 바뀌므로 이름으로 고른다.
SCREEN_DEVICE=${SCREEN_DEVICE:-Capture screen 0}
RAW=${RAW:-$ROOT/.build/media-raw}
mkdir -p "$RAW"
REC_PID=
# 녹화 시작. $1=이름. 메인 창 영역(그림자 제외)을 Retina 픽셀로 잘라 저장한다.
rec_start() {
  local info=($($WININFO $DEMO_ID)) scale=${RETINA_SCALE:-2}
  rm -f "$RAW/$1.mp4"
  ffmpeg -hide_banner -loglevel error -f avfoundation -capture_cursor 1 -capture_mouse_clicks 1 \
    -framerate 30 -pixel_format nv12 -i "$SCREEN_DEVICE:none" \
    -vf "crop=$((info[4] * scale)):$((info[5] * scale)):$((info[2] * scale)):$((info[3] * scale))" \
    -c:v libx264 -preset ultrafast -crf 14 "$RAW/$1.mp4" </dev/null &
  REC_PID=$!
  REC_T0=$EPOCHREALTIME
  sleep 1.5   # 캡처 장치 워밍업
}
# 녹화 시작 이후 경과 초
rec_elapsed() { printf '%.2f' $(( EPOCHREALTIME - REC_T0 )); }
rec_stop() { sleep 1; kill -TERM $REC_PID;   # 스크립트의 백그라운드 작업은 SIGINT를 무시한다
  wait $REC_PID 2>/dev/null || true
  # 녹화는 화면 영역을 찍는다. 도중에 앱이 죽으면 그 뒤의 다른 창(메신저 등)이 담기므로 버린다.
  if ! pgrep -f "demo/JenaNote.app/Contents/MacOS" >/dev/null; then
    rm -f "$RAW/$1.mp4"
    echo "데모 앱이 녹화 중 종료되어 $1 원본을 지웠다(크래시 기록: ~/Library/Logs/DiagnosticReports)" >&2
    return 1
  fi
  echo "recorded $RAW/$1.mp4"; }
