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

- [ ] `make build`가 성공한다
- [ ] `make test`가 모두 통과한다
- [ ] `swift test --filter MarkdownCoreParityTests`가 모두 통과한다

`make test`에는 `JenaNoteKitTests`와 `JenaNoteCoreTests`가 모두 포함된다.

### 오류가 나면

| 증상 | 뜻 | 조치 |
|---|---|---|
| `ambiguous use of 'Block'` 같은 이름 충돌 | 공유 라이브러리의 이름이 맥 SDK와 겹친다 | `JenaNoteCore.Block`처럼 모듈 이름을 붙인다 |
| `MarkdownSerializer.swift` 끝부분의 컴파일 오류 | 공유 코드 연결부는 맥에서 컴파일된 적이 없다 | 오류 내용을 공유한다 |
| `h2 drops bold marks`만 실패 | `.semibold` 글꼴에 bold 속성이 없다는 뜻이다 | `MarkdownWriter.headingBaseIsBold`를 `level == 1`로 바꾸고 말뭉치 기대값을 고친다 |
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
- [ ] AI 패널이 작품 문맥을 찾고, 작품 문맥 창을 열어 저장할 수 있다 (`AIWorkContext`를 옮겼다)

## 4. 저장 버그 재현

`docs/markdown-known-issues.md`의 문제는 코드를 읽어서 찾았다. 실제로 재현되는지 확인한다. 테스트용 문서로 시험한다.

- [ ] 표 뒤에 빈 줄을 두고 여러 번 저장하면 빈 줄이 늘어난다
- [ ] 끝 줄이 빈 코드 블록을 저장하면 닫는 펜스가 사라진다

## 5. 통과한 뒤에 할 일

맥 확인이 끝나면 다음 작업을 진행한다.

1. `MarkdownSerializer.parse`와 `serialize`가 `coreParse`와 `coreSerialize`를 호출하도록 바꾼다
2. `MarkdownSerializer`의 기존 변환 코드를 지운다
3. `markdown-known-issues.md`의 문제를 공유 코드에서 고친다
4. `feature-windows`를 `main`에 합친다

## 6. 다른 프로그램에서 열어 보기

Windows 앱에서 내보낸 파일이다. Word는 Windows에서 확인했다. 한글이 있는 PC에서 아래를 확인한다.

- [ ] HWPX 파일이 한글에서 열리고 제목, 본문, 표가 맞다
