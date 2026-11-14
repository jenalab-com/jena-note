#!/bin/zsh
# 주요 기능 데모 영상을 녹화한다. 원본은 .build/media-raw/, 편집본은 scripts/media/encode_videos.sh로 만든다.
# usage: record_videos.sh [editing|proofreading|book|ai ...]   (인자가 없으면 전부)
# 실행 중에는 마우스·키보드를 만지지 않는다. ai는 연결된 Claude Code로 본문 수정을 한 번 요청한다.
#
# 접근성 탐색은 녹화 전에 해 두고(P[...]) 녹화 중에는 마우스 이동과 키 입력만 한다.
# 영문 타이핑은 한글 입력 상태에서 깨지므로 녹화 동안 입력 소스를 ABC로 바꿨다가 되돌린다.
set -euo pipefail
ROOT=${0:A:h:h:h}
source "$ROOT/scripts/media/lib.sh"
scenes=($@); (( $#scenes )) || scenes=(editing proofreading book ai)

INPUTSOURCE=$ROOT/.build/inputsource
[[ -x $INPUTSOURCE ]] || swiftc -O "$ROOT/scripts/media/inputsource.swift" -o "$INPUTSOURCE"
ORIG_INPUT=$($INPUTSOURCE get)
# 시나리오가 중간에 실패해도 녹화 프로세스를 남기지 않고 입력 소스를 되돌린다.
trap '[[ -n ${REC_PID:-} ]] && kill -TERM $REC_PID 2>/dev/null; $INPUTSOURCE set "$ORIG_INPUT"; true' EXIT

typeset -A P
# 좌표를 재서 P[이름]="x y"로 기억한다. $2=역할(선택)
measure() { P[$1]=$(ax_at "$1" "${2:-}" || center_of "$1" "${2:-}"); }
# 기억한 좌표로 마우스 동작. $1=이름 $2=동작 $3=이동 시간
go() { local c=(${=P[$1]}); $MOUSE ${2:-click} ${c[1]} ${c[2]} ${3:-0.7}; }
# 사람이 치는 속도로 한 글자씩 입력한다.
type_slow() { local ch; for ch in ${(s::)1}; do key "$ch"; sleep 0.04; done; }
# 본문 문자열의 끝 바로 뒤 좌표 "x y"
text_end() { local r=($($TEXTPOS $DEMO_ID "$1")); print -r -- "$((r[3] + r[5] + 2)) ${r[2]}"; }
# 교정 후보에 마우스를 올려 툴팁을 띄운 뒤 '적용'을 누른다.
apply_candidate() {
  hover_text "$1" 0.8; sleep 1.2
  local a=($(ax_at "적용" AXButton))
  $MOUSE click ${a[1]} ${a[2]} 0.6; sleep 1.2
}
open_doc() { activate; press "$1" click; sleep ${2:-2.5}; }
park_mouse() { $MOUSE move 1500 500 ${1:-0.4}; }

# 장면마다 데모 앱을 새로 띄운다(문서 상태 초기화). $1=본문 배율
# 영상은 GIF로 줄어들어 글자가 작아지므로 배율을 키운다. 양면 배치는 배율이 크면 한 쪽으로 바뀐다.
launch_demo() {
  DEMO_FONT_SCALE=$1 "$ROOT/scripts/media/make_demo_app.sh" >/dev/null
  open "$ROOT/.build/demo/JenaNote.app"
  sleep 4
  activate
  frame_window 80 60 1280 800
  local folder
  for folder in "에세이" "소설 - 등대지기" "메모"; do
    press "$folder"; sleep 0.4; keycode 124; sleep 0.6
  done
}
typeset -A SCALE=(editing 1.25 proofreading 1.25 book 1.0 ai 1.15)
# 빌드는 한 번만 하고 장면마다 사본만 새로 만든다.
[[ -n ${SKIP_BUILD:-} ]] || make -C "$ROOT" build >/dev/null
export SKIP_BUILD=1

# 툴바 좌표는 창 크기에 따라 바뀌므로 장면마다 창 크기를 정한 뒤 잰다.

scene_editing() {
  frame_window 80 60 960 600; sleep 0.8
  measure "굵게" AXCheckBox; measure "기울임" AXCheckBox; measure "원문 보기" AXCheckBox
  open_doc "Release checklist.md"
  $INPUTSOURCE set com.apple.keylayout.ABC
  sleep 2   # 입력 소스 전환 표시가 사라질 때까지
  local endpos=($(text_end "Write the release notes")) dmg=($(text_at "DMG")) ver=($(text_at "version"))
  park_mouse 0.2
  rec_start editing
  $MOUSE click ${endpos[1]} ${endpos[2]} 0.8; sleep 0.4
  type_slow " for v1.8"; sleep 0.8
  # Enter로 새 목록 항목을 만든다(읽기 조판 서체가 이어져야 한다).
  local last=($(text_end "Attach the DMG"))
  $MOUSE click ${last[1]} ${last[2]} 0.7; sleep 0.3
  keycode 36; sleep 0.4
  type_slow "Record a demo video"; sleep 0.8
  $MOUSE dclick ${dmg[1]} ${dmg[2]} 0.7; sleep 0.4
  go "굵게" click 0.7; sleep 0.9
  $MOUSE dclick ${ver[1]} ${ver[2]} 0.7; sleep 0.4
  go "기울임" click 0.7; sleep 1.2
  go "원문 보기" click 0.8; sleep 2.8      # 저장되는 마크다운 원문
  go "원문 보기" click 0.4; sleep 1.5
  rec_stop editing
  $INPUTSOURCE set "$ORIG_INPUT"
}

scene_proofreading() {
  frame_window 80 60 960 600; sleep 0.8
  open_doc "편지 초고.md" 5   # 첫 검사(모델 준비)를 기다린다
  park_mouse 0.2
  rec_start proofreading
  apply_candidate "됬"
  apply_candidate "들를께요"
  park_mouse 0.6; sleep 0.6
  key "z" "command down"; sleep 1.8     # ⌘Z로 마지막 적용 되돌리기
  rec_stop proofreading
}

scene_book() {
  frame_window 80 60 1400 860; sleep 0.8
  measure "페이징" AXRadioButton; measure "스크롤" AXRadioButton; measure "보기 설정" AXButton
  open_doc "1화 - 마지막 불빛.md"
  go "스크롤" click 0.2; sleep 1.5
  park_mouse 0.2
  rec_start book
  go "페이징" click 0.8; sleep 2.2
  # 행간을 먼저 바꾼다. 페이지를 넘기면 커서가 따라가 재배치 후 그 쪽으로 이동한다.
  go "보기 설정" click 0.8
  wait_popup 5; sleep 0.8
  local wide=($(ax_at "넓게"))
  $MOUSE click ${wide[1]} ${wide[2]} 0.7; sleep 2
  go "보기 설정" click 0.7; sleep 0.6   # 버튼을 다시 눌러 팝오버를 닫는다
  park_mouse 0.5; sleep 0.8
  keycode 121; sleep 1.6   # Page Down
  keycode 116; sleep 1.6   # Page Up
  rec_stop book
}

scene_ai() {
  frame_window 80 60 1280 800; sleep 0.8
  measure "AI 채팅" AXButton
  local prompt="인용문 한 줄을 조금 더 서정적으로 다듬어 주세요."
  open_doc "봄날의 산책.md"
  # 입력창·모드 좌표를 재기 위해 패널을 한 번 열었다 닫는다.
  go "AI 채팅" click 0.2; sleep 2.5
  measure "요청 내용" AXTextArea
  measure "직접 수정" AXRadioButton
  go "AI 채팅" click 0.2; sleep 1.5
  park_mouse 0.2
  rec_start ai
  go "AI 채팅" click 0.8; sleep 1.5
  go "직접 수정" click 0.7; sleep 0.6
  go "요청 내용" click 0.6; sleep 0.3
  # 한글은 IME 조합 문제로 붙여넣기로 입력한다. 한글 입력 상태에서는 keystroke ⌘V가
  # 단축키로 잡히지 않으므로 메뉴를 누른다.
  print -rn -- "$prompt" | pbcopy
  menu "편집" "붙여넣기" >/dev/null; sleep 1.2
  keycode 36                                       # Enter = 보내기
  local sent=$(rec_elapsed)
  park_mouse 0.4
  wait_ai_reply ${AI_TIMEOUT:-240} || true
  local done_at=$(rec_elapsed)
  sleep 4
  rec_stop ai
  # 대기 구간 표시(편집에서 빨리 감기에 사용)
  print "$sent $done_at" > "$RAW/ai.marks"
}

for s in $scenes; do launch_demo ${SCALE[$s]}; scene_$s; done
echo "done -> $RAW"
