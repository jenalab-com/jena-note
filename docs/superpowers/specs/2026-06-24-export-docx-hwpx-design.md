# 설계 문서 — Markdown 노트의 docx / hwpx 내보내기(Export)

- 날짜: 2026-06-24
- 대상: jena-note (macOS Markdown 노트 앱)
- 범위: **내보내기(Export) 전용** — `.docx`(Word), `.hwpx`(한글) 두 포맷

---

## 1. 배경과 목적

jena-note는 현재 Markdown(`.md`)·plain text(`.txt`)만 읽고 쓴다. 사용자가 작성한 노트를
다른 사람에게 전달할 때 Word·한글 포맷이 필요하다.

목적은 **결과물 전달(export)**이다. 따라서:

- **쓰기(작성)는 계속 Markdown 하나로** 한다. 에디터는 늘어나지 않는다.
- **내보내기만** 추가한다: `md → docx`, `md → hwpx`.
- **읽기(import)는 하지 않는다.** Markdown만 연다.

### 의도적으로 제외한 것 (YAGNI)

| 항목 | 제외 이유 |
|---|---|
| docx/hwpx **읽기(import)** | Markdown은 표현력이 좁아 왕복(round-trip) 시 표·각주·서식 손실이 불가피. "열었다 저장하면 망가지는 앱"이 되는 위험이 가장 큼. |
| `.doc` (구형 Word) | OLE 바이너리 포맷. 직접 파싱·생성이 사실상 불가능. |
| Google Docs | 로컬 파일이 아님. OAuth + Drive API + 네트워크 동기화가 필요 — 앱 성격이 바뀜. |

`.doc`·Google Docs는 후보에서 완전히 뺀다. 필요해지면 별도 프로젝트로 다룬다.

---

## 2. 핵심 설계 결정

### 결정 1 — 포맷 중립 중간표현(IR)을 한 겹 둔다

문서의 단일 진실 공급원(SSOT)은 `MarkdownDocument.content`의 **`NSAttributedString`**이다.
이미 제목·본문·목록·인용·코드블록·표·구분선·인라인 서식(굵게/기울임/인라인코드/링크/색상)·
이미지가 모두 속성으로 구조화돼 있다.

두 Writer(docx, hwpx)가 이 `NSAttributedString`을 **각자 순회하면 까다로운 순회 로직이 두 벌로
갈라진다.** 그래서 한가운데에 포맷 중립 모델을 둔다.

```
NSAttributedString (content, SSOT)
        │  DocumentModelBuilder  (블록·인라인 추출 — MarkdownSerializer.serialize() 순회 로직 재활용)
        ▼
DocumentModel = [Block]      ← 포맷 중립 IR
        ├─ DocxWriter  → zip(OOXML) → .docx
        └─ HwpxWriter  → zip(OWPML) → .hwpx
```

- 순회·해석은 **한 번만** 한다.
- 포맷별 차이는 "XML을 어떻게 쓰느냐"로만 격리된다.
- 테스트가 `IR → XML` 단위로 쪼개져 쉬워진다.

### 결정 2 — 구현은 순수 Swift Writer 직접 작성 (의존성 0)

`docx`·`hwpx`는 둘 다 결국 **zip + XML** 파일이다. 외부 도구 없이 Swift로 직접 쓴다.

- Pandoc 번들: `md→docx`는 품질이 좋지만 **hwpx 미지원**이라 반쪽이고, 외부 바이너리 번들로 앱이 무거워짐 → 제외.
- macOS 네이티브 `NSAttributedString` docx export: 거의 공짜지만 서식 통제가 약하고 hwpx와 코드를 공유 못 함 → 제외.
- **순수 Swift Writer**: 의존성 0, 두 포맷이 같은 IR을 공유, 배포 가벼움, 통제력 최고 → 채택.

### 결정 3 — 내보내기는 "다른 이름으로 저장(Save As)"이 아니라 별도 동작이다

읽기를 지원하지 않으므로, docx/hwpx를 `writableTypes`(Save As)에 넣으면 **그 파일이 문서의 새
경로(`fileURL`)가 되어** 다음 저장 때 깨진다. 따라서 내보내기는 NSDocument 저장 흐름 **바깥의
독립 동작**으로 둔다.

- File 메뉴 > **"내보내기…"** 서브메뉴 → `Word 문서 (.docx)` / `한글 문서 (.hwpx)`
- 저장 패널(`NSSavePanel`)을 띄우고, 기본 파일명은 원본 노트 이름 + 해당 확장자.
- 원본 md 문서 상태는 **건드리지 않는다**(dirty 만들지 않음, `fileURL` 유지).

### 결정 4 — 1차 범위는 풀 충실도 (표·이미지 포함)

NSAttributedString에 담긴 모든 요소를 내보낸다:

- 제목(h1~h3), 본문, 순서/비순서 목록, 인용, 코드블록, 구분선
- 인라인: 굵게, 기울임, 인라인코드, 링크, 색상
- **표** (셀·헤더 행)
- **이미지** (zip 패키지 안에 바이너리 임베드 + 관계(rels) 연결)

---

## 3. 컴포넌트

새 폴더 `Sources/JenaNoteKit/export/`:

| 파일 | 책임 | 의존 |
|---|---|---|
| `DocumentModel.swift` | 포맷 중립 IR 정의 (`Block`, `Inline`, `ImageRef`) | 없음 (순수 값 타입) |
| `DocumentModelBuilder.swift` | `NSAttributedString` → `[Block]` 변환 | AppKit, DocumentModel |
| `ZipArchive.swift` | 공용 zip 패킹 유틸 (파일 추가 → Data) | Foundation |
| `DocxWriter.swift` | `[Block]` → `.docx`(OOXML) Data | DocumentModel, ZipArchive |
| `HwpxWriter.swift` | `[Block]` → `.hwpx`(OWPML) Data | DocumentModel, ZipArchive |
| `ExportController.swift` | 메뉴 액션·저장 패널·에러 처리·파일 쓰기 | AppKit, 두 Writer |

### DocumentModel (IR) 개요

```swift
enum Block {
    case heading(level: Int, inlines: [Inline])
    case paragraph([Inline])
    case listItem(ordered: Bool, index: Int, inlines: [Inline])
    case blockquote([Inline])
    case codeBlock(String)                 // 언어 정보는 1차 미사용
    case table(rows: [[ [Inline] ]], headerRow: Int)
    case horizontalRule
    case image(ImageRef)
}

struct Inline {
    var text: String
    var bold = false
    var italic = false
    var code = false
    var color: String? = nil               // "#RRGGBB"
    var link: String? = nil
}

struct ImageRef {
    var data: Data                          // 원본 파일에서 로드한 바이너리
    var fileName: String                    // 패키지 내 이름 (image1.png ...)
    var width: Int?                         // 지정 폭(px), 없으면 원본
}
```

- 이미지 바이너리는 `MarkdownDocument.attachmentBaseURL` + 상대경로(`mdImageRelPath`)로 로드한다.

### 패키지 레이아웃

**docx (OOXML)**
```
[Content_Types].xml
_rels/.rels
word/document.xml          ← 본문
word/media/image1.png …    ← 이미지
word/_rels/document.xml.rels
```

**hwpx (OWPML)**
```
mimetype                   ← "application/hwp+zip" (무압축, 첫 엔트리)
META-INF/manifest.xml
Contents/content.hpf
Contents/header.xml
Contents/section0.xml      ← 본문
BinData/image1.png …       ← 이미지
```

---

## 4. 데이터 흐름 (내보내기 1회)

1. 사용자가 File > 내보내기 > `Word 문서 (.docx)` 선택.
2. `ExportController`가 `NSSavePanel`을 띄움(기본 파일명 = 노트명.docx).
3. 사용자가 위치·이름 확정.
4. `DocumentModelBuilder.build(content, baseURL:)` → `[Block]`.
5. `DocxWriter.write(blocks)` → `Data` (zip).
6. `Data`를 선택 경로에 기록. 성공/실패 알림.
7. 원본 문서 상태 불변.

---

## 5. 에러 처리

| 상황 | 처리 |
|---|---|
| 미저장 새 문서(이미지 baseURL 없음)에서 이미지 포함 export | 텍스트는 정상 내보내고, 로드 실패한 이미지는 건너뜀(자리 표시 없음). 경고 알림 1회. |
| 이미지 파일 로드 실패(경로 깨짐) | 해당 이미지만 건너뜀. 나머지 정상. |
| 파일 쓰기 실패(권한 등) | `NSAlert`로 사용자에게 명시. |
| 빈 문서 | 빈 본문 문서를 정상 생성(에러 아님). |

내보내기는 부분 실패를 조용히 삼키지 않는다 — 건너뛴 요소가 있으면 사용자에게 알린다.

---

## 6. 테스트 전략

읽기(import)가 없으므로 **round-trip 테스트는 하지 않는다.** 대신:

- **IR 빌더 단위 테스트**: 대표 Markdown들의 `NSAttributedString` → `[Block]` 정확성.
- **Writer 산출물 검증**: 생성된 zip을 풀어 핵심 XML 노드 존재 확인
  - docx: 제목 스타일, 표 셀, `document.xml.rels`의 이미지 관계.
  - hwpx: `section0.xml` 문단/표, `BinData` 이미지, `mimetype` 무압축 첫 엔트리.
- **수동 호환성 검증**: docx → Word/Pages에서 열기, hwpx → 한글에서 열기.

---

## 7. 단계·리스크

**hwpx(OWPML)는 docx보다 스펙이 까다롭고 한글 본가도 버전 호환이 깐깐**하다. 1차에 한글에서
안 열리는 케이스가 나올 수 있다. 권장 순서:

1. IR(`DocumentModel`) + `DocumentModelBuilder` + `ZipArchive` 공용 토대.
2. **DocxWriter 먼저 안착**(Word/Pages에서 검증) — 더 관대한 포맷.
3. ExportController + 메뉴/저장 패널로 docx 내보내기 완성.
4. **HwpxWriter 추가** — 한글에서 검증하며 다듬기.

docx를 먼저 끝까지 동작시키면, IR·zip·UX 토대가 검증된 상태에서 hwpx는 "XML 방언 추가"로만
남는다.

---

## 8. 인수 기준

- [ ] File > 내보내기 > Word/한글 메뉴가 보인다.
- [ ] 노트를 `.docx`로 내보내면 Word/Pages에서 제목·본문·목록·인용·코드·표·이미지·색상이 보인다.
- [ ] 노트를 `.hwpx`로 내보내면 한글에서 동일하게 열린다.
- [ ] 내보내기 후 원본 md 문서가 dirty 되지 않고 경로도 그대로다.
- [ ] 이미지 로드 실패 시 나머지는 정상 내보내고 사용자에게 알린다.
- [ ] 외부 바이너리 의존성이 없다(순수 Swift).
