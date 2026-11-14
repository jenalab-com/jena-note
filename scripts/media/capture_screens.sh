#!/bin/zsh
# README·릴리스용 스크린샷을 docs/media/에 만든다.
# 실행 중에는 마우스·키보드를 만지지 않는다(커서를 직접 움직여 조작한다).
# 05-ai-chat은 연결된 Claude Code로 짧은 요청을 한 번 보낸다(계정 사용량 소모). NO_AI=1이면 건너뛴다.
set -euo pipefail
ROOT=${0:A:h:h:h}
source "$ROOT/scripts/media/lib.sh"

"$ROOT/scripts/media/make_demo_app.sh" >/dev/null
open "$ROOT/.build/demo/JenaNote.app"
sleep 4
activate
frame_window 80 60 1400 880
sleep 1

# 사이드바의 데모 폴더를 모두 펼친다(→ 키).
for folder in "에세이" "소설 - 등대지기" "메모"; do
  press "$folder"; sleep 0.4; keycode 124; sleep 0.6
done

# 1. 메인 편집 화면
press "봄날의 산책.md"
sleep 3
$MOUSE move 1600 500 0.2
shot 01-editor.png

# 2. 교정 후보 툴팁: 문서를 연 뒤 Kiwi 검사(첫 실행은 모델 준비)가 끝나길 기다렸다가 후보에 마우스를 올린다.
press "편지 초고.md"
sleep 5
hover_text "됬"
sleep 0.5
shot_all 02-proofreading.png
$MOUSE move 1600 500 0.2
sleep 1

# 3. 페이지(양면) 배치
press "1화 - 마지막 불빛.md"
sleep 2.5
press "페이징" click AXRadioButton
sleep 3
$MOUSE move 1600 500 0.2
shot 03-book.png

# 4. 보기 설정 팝오버
press "보기 설정" click AXButton
wait_popup 5
sleep 0.8
$MOUSE move 1600 500 0.2
shot_all 04-view-settings.png
keycode 53   # Esc로 팝오버 닫기
sleep 0.5
press "스크롤" click AXRadioButton
sleep 1.5

# 5. AI 채팅(가이드 모드) 응답
if [[ -z ${NO_AI:-} ]]; then
  press "봄날의 산책.md"
  sleep 2
  press "AI 채팅" click AXButton
  sleep 3
  press "요청 내용" click AXTextArea
  # 한글 입력 상태에서는 keystroke ⌘V가 단축키로 잡히지 않으므로 메뉴로 붙여넣는다.
  print -rn -- "첫 문단을 조금 더 생생하게 다듬으려면 어디부터 손보면 좋을까요? 짧게 두 가지만 알려 주세요." | pbcopy
  menu "편집" "붙여넣기" >/dev/null
  sleep 0.8
  keycode 36   # Enter = 보내기
  $MOUSE move 1600 500 0.4
  wait_ai_reply 180
  sleep 2
  # 응답이 길면 질문 말풍선이 위로 밀려나므로 대화 영역을 맨 위로 올린다.
  c=($(ax_at "문서별 AI 대화"))
  $MOUSE move ${c[1]} ${c[2]} 0.3
  $MOUSE scroll 3000 10
  sleep 1
  $MOUSE move 1600 500 0.2
  shot 05-ai-chat.png
fi

# Retina 원본(약 3000px)은 README에 과하므로 긴 변 1800px로 줄인다(그림자 투명도 유지).
# sips -Z는 작은 이미지를 키우기도 하므로 긴 변이 1800px을 넘을 때만 줄인다.
for f in "$OUT"/0*.png; do
  long=$(sips -g pixelWidth -g pixelHeight "$f" | awk '/pixel/{print $2}' | sort -n | tail -1)
  if (( long > 1800 )); then sips -Z 1800 "$f" >/dev/null; fi   # && 꼴은 set -e에서 루프 종료 코드를 1로 남긴다
done
echo "done -> $OUT"
