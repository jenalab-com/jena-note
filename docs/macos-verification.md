# 맥에서 확인할 것

`feature-windows` 브랜치는 Windows에서만 빌드하고 테스트했다. `main`에 합치기 전에 맥에서 한 번에 확인한다. 항목이 끝나면 체크하고, 실패하면 오류 내용을 남긴다.

## 1. 준비

```sh
git fetch origin
git switch feature-windows
git pull
bash Vendor/Kiwi/scripts/fetch-kiwi-model.sh
```

마지막 줄은 처음 한 번만 실행한다. Kiwi 모델 폴더를 `Sources/JenaNoteKit/Resources/`에서 `shared/JenaNoteCore/Resources/`로 옮기며, 다시 내려받지 않는다. 안 하면 `make test`가 모델이 없다는 오류로 멈춘다.

## 2. 빌드와 테스트

- [x] `make build`가 성공한다
- [x] `make test`가 모두 통과한다
- [x] `swift test --filter MarkdownCoreParityTests`가 모두 통과한다

`make test`에는 `JenaNoteKitTests`와 `JenaNoteCoreTests`가 모두 포함된다.

2026-11-09 맥(macOS 26, arm64)에서 확인했다. 처음에는 아래 오류가 나서 고친 뒤 582개가 모두 통과했다.

- 빌드: `FileSearcher`에 공개 `init`이 없어 `SidebarViewController`가 만들지 못했다 → `public init() {}` 추가
- 테스트 빌드: `AIProofreadingTests`가 `AILocalInferenceQueue`의 내부 `init`을 쓴다 → `@testable import JenaNoteCore` 추가
- `h3 keeps bold marks`: 맥의 h3 글꼴(시스템 Medium)은 굵은 글꼴을 trait로 만들 수 없어, 문서를 열 때부터 h3 안의 굵게가 사라졌다(기존 맥 버그). `MemoFont.bold(from:)`가 시스템 글꼴일 때만 굵은 시스템 글꼴로 대신하도록 고쳤다. 다른 글꼴은 그대로 둔다
- `heading starting with an image stays a heading`, `inline code can hold backticks`: `macLegacy` 추정값이 실제와 달라 실측값으로 고쳤다
- `testSharedExportMatchesTheCurrentBuilder`의 `h1/h2 drops bold marks`: 제목의 굵게를 지운 뒤 같은 모양의 글 조각이 둘로 남았다. AppKit처럼 하나로 합치도록 `MarkdownExport`를 고쳤다(제목에서만, 텍스트 조각끼리만)

### 오류가 나면

| 증상 | 뜻 | 조치 |
|---|---|---|
| `ambiguous use of 'Block'` 같은 이름 충돌 | 공유 라이브러리의 이름이 맥 SDK와 겹친다 | `JenaNoteCore.Block`처럼 모듈 이름을 붙인다 |
| `MarkdownSerializer.swift` 끝부분의 컴파일 오류 | 공유 코드 연결부는 맥에서 컴파일된 적이 없다 | 오류 내용을 공유한다 |
| `h2 drops bold marks`만 실패 | `.semibold` 글꼴에 bold 속성이 없다는 뜻이다 | `MarkdownWriter.headingBaseIsBold`를 `level == 1`로 바꾸고 말뭉치 기대값을 고친다 |
| `testCorpusDescribesTheCurrentSerializer` 실패 | 코드를 읽어 적은 `macLegacy` 값이 실제 맥 동작과 다르다 | 항목 이름과 함께 공유한다 |
| `testFixedEntriesSurviveTheSharedPath` 실패 | 고친 저장 동작이 맥 연결부에서 사라진다. 전환 전에 고쳐야 한다 | 항목 이름과 함께 공유한다 |
| `MarkdownCoreParityTests`의 다른 항목 실패 | 공유 코드가 맥과 다르게 동작한다 | 항목 이름과 함께 공유한다 |
| `testSharedExportMatchesTheCurrentBuilder` 실패 | 공유 내보내기 변환이 `DocumentModelBuilder`와 다르다 | 항목 이름과 함께 공유한다. Windows 내보내기에만 영향이 있다 |

## 3. 앱 동작

`make run`으로 실행한다. 이번 작업은 아래 기능의 코드 위치를 옮겼다.

- [ ] 문서를 열고 저장해도 내용과 서식이 그대로다
- [ ] 맞춤법 교정 제안이 나오고 적용된다
- [ ] 개인 사전에 등록한 단어가 교정에서 빠진다
- [ ] 작품 폴더를 옮겨도 개인 사전의 작품 범위가 유지된다
- [ ] 이미지가 든 문서를 DOCX와 HWPX로 내보내면 이미지 비율이 맞다
- [ ] 글자 크기와 자간을 바꿔 DOCX와 HWPX로 내보내면 반영된다
- [ ] 내보낸 문서에 빈 줄이 유지된다
- [ ] 화면 글자 크기가 이전과 같다 (`MemoFont`가 `MemoFontSize`를 쓰도록 바뀌었다)
- [ ] 언어를 바꾸면 바로 적용되고, 다시 켜도 유지된다
- [ ] 책갈피와 이어읽기가 유지된다
- [ ] 파일 전체 검색이 동작한다
- [ ] 맞춤법이 `내보내기`나 `내려받지` 같은 동사를 띄우라고 제안하지 않는다 (공유 맞춤법 엔진을 고쳤다)
- [ ] 버전 이력에서 비교, 이름 붙이기, 복원이 동작하고 예전 백업도 보인다 (`DocumentBackupStore`를 옮겼다)
- [ ] 설정 → AI → 재확인이 연결 확인으로 끝난다 (CLI 인자와 응답 읽기를 `AICommand`로 옮겼다)
- [ ] AI 패널에 모델 목록과 사용률이 나온다 (`AIMetadata`를 옮겼다)
- [ ] 가이드 질문에 답이 온다. 직접 수정이 본문에 적용되고 ⌘Z로 되돌려진다 (프롬프트를 `AIChatPrompt`로 옮겼다)
- [ ] 응답을 기다리다 중지하면 CLI가 멈춘다 (`AIProcess`의 환경 변수를 `AICommand`에서 가져온다)
- [ ] 작품 문맥을 켠 작품에서 질문하면 "확인한 원문" 목록이 나오고, 현재 화 이후 내용이 답에 섞이지 않는다 (탐색을 `AIWorkRetrievalSession`으로 옮겼다)
- [ ] 작품 설정 파일을 열어 저장 전에 고친 내용이 AI 요청에 반영된다 (`AIWorkContextResolver.useOpenDocuments`를 앱 시작 때 연결한다)
- [ ] 지난 화 탭의 인덱스 상태와 기기 내 요약 개수가 전과 같다 (`AIWorkIndex`를 옮겼다)
- [ ] 작품을 다시 열어도 기기 내 요약을 처음부터 다시 만들지 않는다 (`AIWorkIndex.split`을 빠르게 고쳤다. 조각 ID가 같아야 한다)
- [ ] 원문 탐색이 대소문자와 한글을 전처럼 찾는다 (검색을 `AIWorkSearchCorpus`로 바꿨다)
- [ ] 설정 → AI → Local(llama.cpp)에서 실행·대화·중지가 전처럼 된다 (main의 `.local`을 공유 `AIProvider`로 옮겼다. Windows 공급자 목록에도 나온다)
- [ ] AI 패널이 작품 문맥을 찾고, 작품 문맥 창을 열어 저장할 수 있다 (`AIWorkContext`를 옮겼다)

## 4. 저장 버그 재현

`docs/markdown-known-issues.md`의 문제는 코드를 읽어서 찾았다. 실제로 재현되는지 확인한다. 테스트용 문서로 시험한다.

- [x] 표 뒤에 빈 줄을 두고 여러 번 저장하면 빈 줄이 늘어난다
- [x] 끝 줄이 빈 코드 블록을 저장하면 닫는 펜스가 사라진다

2026-11-09 맥 `MarkdownSerializer`로 재현했다. 표 뒤 빈 줄은 저장할 때마다 1개씩 늘고(`\n\n` → `\n\n\n` → …), 코드 블록은 닫는 펜스가 사라져 뒤의 글까지 코드가 된다. 같은 입력을 `coreParse`/`coreSerialize`로 세 번 저장하면 그대로다.

## 5. 통과한 뒤에 할 일

맥 확인이 끝나면 다음 작업을 진행한다.

1. `MarkdownSerializer.parse`와 `serialize`가 `coreParse`와 `coreSerialize`를 호출하도록 바꾼다
2. `MarkdownSerializer`의 기존 변환 코드를 지운다
3. `MarkdownCorpus`의 `macLegacy`와 `markdown-known-issues.md`의 맥 열을 지운다. 저장 문제는 공유 코드에서 이미 고쳤으므로 전환하면 맥에서도 함께 고쳐진다
4. `feature-windows`를 `main`에 합친다

## 6. 다른 프로그램에서 열어 보기

Windows 앱에서 내보낸 파일이다. Word는 Windows에서 확인했다. 한글이 있는 PC에서 아래를 확인한다.

- [ ] HWPX 파일이 한글에서 열리고 제목, 본문, 표가 맞다
