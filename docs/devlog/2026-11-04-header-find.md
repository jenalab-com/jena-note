# 헤더 검색창으로 문서 내 찾기 이동

툴바의 돋보기 버튼을 없애고 헤더 맨 왼쪽에 검색창을 넣었다. 글자를 치면 바로 찾고, Enter/⇧Enter로 일치를 오가며, Esc는 현재 일치를 선택한 채 본문으로 돌아간다. ⌘F는 검색창으로 가고 ⌘G/⇧⌘G는 일치를 오간다. ⌥⌘F 바꾸기는 찾기 바를 그대로 쓴다.

찾기 바는 바깥에서 검색어를 넣는 공개 API가 없어 `DocumentFinder`가 찾기와 강조를 직접 맡는다. 페이지 조판 전용 `PagedFindClient`는 지웠다.

페이지 조판에서 찾기 바가 보이지 않던 원인은 `PagedHostView.draw`가 `dirtyRect`를 칠하는데 macOS 14부터 뷰가 경계 밖 그리기를 자르지 않아서였다. 프레임은 겹치지 않아 프레임 검사로는 잡히지 않았고 픽셀을 찍어 확인했다. `clipsToBounds = true`로 막았다.

찾는 동안 일치를 선택하면 비활성 선택의 회색이 강조를 덮어서, 선택은 Esc로 끝낼 때만 한다.

`LiveProofreadingController.refresh`의 재진입도 막았다. 일반 `NSTextView`의 `layoutManager`를 처음 읽으면 편집 알림이 나가 `refresh` 안에서 `schedule`이 불리고, 그 뒤에 revision을 읽어 두 회차가 같은 번호로 통과하며 후보가 두 번 들어갔다. 앞 테스트의 타이밍에 따라 `PersonalDictionaryTests`가 실패했다. revision을 맨 앞에서 잡고 바뀌었으면 이번 회차를 멈춘다.
