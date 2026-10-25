# 2026-10-25 — 페이지 직접 편집과 점진적 재조판

## 변경

- 읽기 페이지에서 입력·삭제·붙여넣기를 해도 스크롤로 전환하지 않는다.
- `IncrementalPaginator`가 TextKit 저장소/레이아웃 매니저/컨테이너를 유지한다. 수정 지점의 유효 페이지 범위를 무효화하고 현재 펼침면·캐럿을 우선 조판한다.
- 뒤쪽은 메인 큐에서 최대 2페이지씩 계산한다. 자동 background layout은 끈다. 전체 쪽수는 계산 중 `…`, 배치 불가능한 내용은 `!`와 안내 툴팁을 표시한다.
- 페이지 뷰를 재사용하고, 해제할 때는 기존 포커스 회수/컨테이너 연결 해제 방침을 유지한다. 같은 펼침면의 다른 쪽으로 넘어간 캐럿도 해당 페이지 뷰로 인계한다.
- 한글 marked text 중에는 페이지 뷰를 교체하지 않는다. Undo/Redo·문서 교체·모드 종료 시 조합을 종료해 오래된 조합 범위로 원문을 덮어쓰지 않게 한다.
- 변경된 범위만 원본 스타일로 되돌려 문서에 반영한다. 문서가 Undo 역연산을 소유하므로 페이지/모드 전환 뒤에도 이력이 남는다. 저장은 조판 완료와 독립적이다.
- 책갈피 오프셋은 변경 범위로 보정한다. 문자 수 계산은 짧게 지연해 입력 경로에서 분리한다.
- 방향키는 커서 이동에 사용하며, Page Up/Down과 스크롤 제스처로 페이지를 넘긴다.
- 화면 교체 직후 `viewDidAppear`에만 의존하지 않고 페이지 모드를 명시적으로 초기화한다.

## 설계상 발견

- TextKit은 다음 컨테이너가 없을 때 마지막 행을 다르게 배치할 수 있다. 한 페이지 앞의 빈 컨테이너를 확보하고 해당 페이지의 geometry cache를 갱신해야 점진 조판과 최초 조판이 일치한다. UI는 컨테이너 수가 아닌 유효 `ranges`를 사용한다.
- `NSTextStorage.didProcessEditing` 안에서는 레이아웃을 호출하지 않는다. 그 콜백에서 변경분을 문서에 전달하고 이후 이벤트에서 조판한다.
- 원본 변화 없는 attribute fixing은 문서를 수정하거나 페이지 계산을 다시 예약하지 않는다.
- NSDocument 기본 Undo를 쓰면 변경 카운트도 자동 관리된다. 직접 `.changeDone`을 추가하면 전체 Undo 뒤에도 dirty가 남는다. 실제 이벤트 단위 그룹으로 확인했다.
- 테스트 창에 contentViewController를 지정하면 초기 크기가 0으로 줄어드는 경우가 있다. 명시적 content size와 높이 검증을 추가해 실제 페이지 크기로 테스트한다.
- 글자 크기 변경 시 편집 커서가 다른 페이지로 이동할 수 있다. 리더에 포커스가 있으면 페이지 시작 앵커 대신 선택 위치까지 먼저 조판한다.

## 검증

- 전체 **181개 테스트, 실패 0**. 기존 157개 + IncrementalPaginator 11개 + 페이지 편집 통합 13개.
- 삽입/삭제/연속 편집 후 최초 조판과 같은 페이지 경계, bounded batch, 빈 문서, 마지막 개행, 큰 이미지, 컨테이너/저장소 수명 검사.
- 실제 NSTextView 입력, 한글 조합과 조합 중 Undo, 페이지 경계 붙여넣기, 문서 저장 데이터, 메뉴 액션의 responder chain, 모드 전환 후 Undo/Redo, dirty 상태 복구, 서식 보존, 문서 교체, 책갈피 이동, 글자 크기 변경 검사.
- 181,890 UTF-16 문자 문서의 앞부분 입력: 동기 처리 **9.6ms**, 화면 갱신과 테스트용 20ms run loop를 포함해 **41.8ms**. 단일 머신의 회귀 검사 측정이며 모든 문서의 최대 지연을 보장하지 않는다.
- 릴리스 실행 파일 빌드 성공. 아이콘/KoPub 글꼴을 포함한 별도 미리보기 앱 번들을 `.build/paged-reader-preview-*`에 생성했다. 기존 설치 앱은 교체하지 않았다.
- `git diff --check` 통과.

## 검증 환경과 기존 빌드 문제

현재 기본 Xcode의 Swift 6.4는 변경 전부터 `HwpxWriter.swift:339`의 긴 문자열 식을 타입 검사하지 못했다. 내보내기 코드나 프로젝트 빌드 설정은 변경하지 않았다.

> 후속 수정: 사용자 빌드 오류 보고에 따라 해당 문자열 식을 수정했다. 이제 기본 Swift 6.4의 `make build`와 `make test`(181개)가 통과한다. 아래 도구 체인 우회는 수정 전 검증 기록이다. 자세한 내용은 `2026-10-25-swift64-build-fix.md` 참조.

설치된 Command Line Tools **Swift 6.3.3**, `MacOSX26.5.sdk`, `arm64-apple-macosx13.0`으로 빌드했다. 주요 옵션:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
  /Library/Developer/CommandLineTools/usr/bin/swift build \
  --build-system native --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  --triple arm64-apple-macosx13.0 -c release --product JenaNote
```

테스트 빌드는 같은 도구 체인에서 Xcode의 XCTest framework와 Swift overlay 경로를 명시했다. CLT의 `swift test` 자동 발견이 0개를 보고해 성공으로 간주하지 않고, 생성된 `.xctest` 번들을 Xcode의 `xctest` 실행기로 직접 실행하여 위 181개 결과를 확인했다. 당시 명령은 `/tmp/jena-reader-check.sh`, 전체 결과는 미리보기 앱 옆 `tests.log`, 릴리스 결과는 `build.log`에 보존했다.

## 범위와 남은 확인

- 실제 macOS 한글 입력기의 후보창 및 트랙패드 사용감은 수동 확인이 남는다. 자동 테스트는 NSTextInputClient marked text 경로를 검증한다.
- 매우 긴 단일 문단, 큰 붙여넣기, 먼 위치로 직접 이동할 때 필요한 선행 조판은 동기 비용이 남는다. 페이지 하나의 TextKit 계산 자체를 중단하는 기능은 없다.
- 기존 한글 이탤릭 직렬화 결함은 별개이며 변경하지 않았다. 이번 작업은 텍스트 직접 수정과 기존 서식 보존이며 페이지 화면에 새 서식 툴바를 추가하지 않았다.
- 사전 미커밋 `ReaderViewController.swift` 및 패치는 `/tmp/jena-note-reader-backup-20261025`에 보존했고 수명 관리 수정을 포함해 통합했다.
- 병렬 작업 워크트리: `/Users/byeongmukna/orca/workspaces/jena-note/reader-pagination`. 엔진과 테스트만 부모 작업 공간으로 통합하고 워크트리는 보존했다.
