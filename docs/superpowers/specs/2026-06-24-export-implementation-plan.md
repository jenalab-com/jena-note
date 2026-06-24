# 구현 계획 — docx / hwpx 내보내기

- 날짜: 2026-06-24
- 설계 근거: [2026-06-24-export-docx-hwpx-design.md](./2026-06-24-export-docx-hwpx-design.md)
- 원칙: **DocxWriter 먼저 끝까지 동작 → hwpx는 "XML 방언 추가"로.** 각 단계는 독립 빌드·테스트 가능 단위.

---

## 코드 토대 (확인된 사실)

구현이 얹힐 기존 코드:

- **SSOT** = `MarkdownDocument.content` (`NSMutableAttributedString`).
- **순회 본보기** = `MarkdownSerializer.serialize()` — 단락 단위(`\n` 경계) 순회 + `mdBlockType`으로 블록 판별 + `serializeTable()` 테이블 grid 재구성 + `serializeInline()` run 순회. IR 빌더는 이 구조를 **그대로 본뜬다**(출력만 String→Block).
- **블록 판별 키**: `.mdBlockType`("h1/h2/h3/body/ul/ol/blockquote/codeblock/hr/table-cell"), `.mdListIndex`, `.mdTableHeader`.
- **인라인 판별**: 폰트 traits로 bold/italic(기준폰트 trait은 제외), `.mdInlineCode`, `.mdCustomColor`+`.foregroundColor`, `.link`.
- **이미지**: `.attachment` + `.mdImageRelPath`/`.mdImageAlt`/`.mdImageWidth`. 바이너리는 `attachmentBaseURL`(= `fileURL` 폴더) + relPath로 로드.
- **메뉴**: `AppDelegate.setupMenu()`의 `fileMenu`. L10n은 `L10n.tr()` — 7개 언어 키 추가 필요.
- **문서 접근**: 메뉴 액션은 `NSDocumentController.shared.currentDocument as? MarkdownDocument`로 현재 문서·content 획득.

---

## 단계 0 — IR 정의 (`export/DocumentModel.swift`)

순수 값 타입. 의존성 0. 설계문서 §3 그대로.

```swift
enum Block { case heading/paragraph/listItem/blockquote/codeBlock/table/horizontalRule/image }
struct Inline { text; bold; italic; code; color:String?; link:String? }
struct ImageRef { data:Data; fileName:String; width:Int? }
```

- ✅ 검증: 컴파일만. 테스트 없음.

---

## 단계 1 — IR 빌더 (`export/DocumentModelBuilder.swift`)

`NSAttributedString → [Block]`. `serialize()` 순회를 본떠 출력을 Block으로 교체.

- 단락 경계 순회 → blockType 분기 → heading/paragraph/list/blockquote/codeBlock/hr 매핑.
- 테이블: `serializeTable()` grid 재구성 로직 이식 → `Block.table(rows, headerRow)`.
- codeBlock: 연속 codeblock 단락 묶기(`serialize`의 prevIsCB 로직).
- 인라인: `serializeInline()` run 순회 본떠 `[Inline]` 생성. 이미지 run은 별도 `Block.image`로.
- **이미지 로드**: builder에 `baseURL` 주입 → relPath로 `Data` 로드. 실패 시 `loadFailures` 카운트(에러 알림용). 폭은 `mdImageWidth`.
- fileName 부여: `image1.png` … (확장자는 원본 relPath 따름).

- ✅ 검증: **단위 테스트** — 대표 md를 `parse()`→`build()` 돌려 Block 트리 정확성(제목 레벨·목록 ordered/index·표 행렬·인라인 bold/색상·이미지 ref).

---

## 단계 2 — Zip 유틸 (`export/ZipArchive.swift`)  ⚠️ 리스크 지점

의존성 0 zip 패커. **1차는 무압축(stored)** 으로 간다 — Word·한글 둘 다 stored 엔트리를 연다. deflate는 나중에 Compression.framework로 선택 추가.

- 엔트리: local file header + 데이터 + central directory + EOCD.
- **CRC32 직접 구현**(테이블 방식) — stored여도 CRC는 필수.
- `addEntry(path, data, compressed:Bool=false)`, `addStored(path, data)` (mimetype 무압축 전용), `finalize() -> Data`.
- hwpx 요구: `mimetype`이 **첫 엔트리 + 무압축**.

- ✅ 검증: 생성 Data를 `/usr/bin/unzip -l`로 풀어 엔트리 목록·CRC 무결성 확인(테스트에서 임시파일 unzip, 또는 `Process`).

---

## 단계 3 — DocxWriter (`export/DocxWriter.swift`)

`[Block] → .docx Data`. OOXML 최소 골격.

- 패키지: `[Content_Types].xml`, `_rels/.rels`, `word/document.xml`, `word/_rels/document.xml.rels`, `word/media/imageN.*`.
- 블록 매핑: heading→`pStyle Heading1~3`, paragraph→`w:p`, list→`numPr`(또는 1차는 글머리 텍스트), blockquote→들여쓰기 스타일, codeBlock→고정폭+음영, table→`w:tbl`, hr→하단 테두리 문단, image→`w:drawing`+rels.
- 인라인: `w:r`+`w:rPr`(b/i, `w:rFonts` 코드, `w:color`, hyperlink는 rels).
- XML escape 유틸 공용.

- ✅ 검증: zip 풀어 핵심 노드 존재(제목 스타일·표 셀·이미지 rels) 단위 테스트 + **수동: Word/Pages에서 열기**.

---

## 단계 4 — ExportController + 메뉴 (`export/ExportController.swift`)

- File > **"내보내기…"** 서브메뉴 → `Word 문서 (.docx)` / `한글 문서 (.hwpx)` (단계 4는 docx만 활성, hwpx는 단계 6에서).
- 액션: currentDocument 획득 → `NSSavePanel`(기본명 = 노트명.docx) → `Builder.build` → `DocxWriter.write` → 경로 기록.
- 에러: 이미지 로드 실패 시 1회 경고 `NSAlert`, 쓰기 실패 시 `NSAlert`. 원본 문서 **dirty/`fileURL` 불변**.
- `AppDelegate.setupMenu()`에 서브메뉴 + L10n 키 7개 언어(`menu.file.export`, `.export.docx`, `.export.hwpx`).

- ✅ 검증: 앱 빌드·실행 → 실제 노트 .docx 내보내 Word/Pages에서 열기. **docx 경로 end-to-end 완성.**

---

## 단계 5 — (게이트) docx 인수 기준 통과 확인

설계문서 §8 중 docx 항목 전부 ✅ 된 뒤에만 hwpx 착수. 토대(IR·zip·UX) 검증 완료 지점.

---

## 단계 6 — HwpxWriter (`export/HwpxWriter.swift`)

`[Block] → .hwpx Data`. OWPML.

- 패키지: `mimetype`(stored 첫 엔트리), `META-INF/manifest.xml`, `Contents/content.hpf`, `Contents/header.xml`, `Contents/section0.xml`, `BinData/imageN.*`.
- 같은 `[Block]` 순회, XML 방언만 교체. header.xml에 문단/글자 모양 정의 최소셋.
- ⚠️ **리스크**: 한글 버전 호환 깐깐. section0 문단/표 구조·BinData 참조가 핵심.

- ✅ 검증: zip 구조(mimetype 무압축 첫 엔트리)·section0 노드 단위 테스트 + **수동: 한글에서 열기**. 안 열리면 실제 hwpx 샘플과 XML 대조.

---

## 단계 7 — ExportController hwpx 활성 + 마무리

- hwpx 메뉴 활성, 동일 흐름.
- 회귀: docx·hwpx 둘 다 내보낸 뒤 원본 md 무변경 확인.

---

## 작업 순서 한눈에

```
0 IR  →  1 Builder(+테스트)  →  2 Zip(+테스트)  →  3 DocxWriter(+테스트)
     →  4 ExportController+메뉴(수동검증)  →  [5 게이트]  →  6 HwpxWriter  →  7 마무리
```

핵심 리스크 둘: **단계 2(zip 직접 구현)**, **단계 6(hwpx 한글 호환)**. 나머지는 기존 순회 로직 재활용이라 위험 낮음.
