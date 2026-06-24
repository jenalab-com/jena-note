import Foundation

// MARK: - DocumentModel (포맷 중립 중간표현, IR)
//
// `NSAttributedString`(SSOT)을 DocxWriter·HwpxWriter가 각자 순회하면 까다로운
// 순회 로직이 두 벌로 갈라진다. 그래서 한가운데에 포맷 중립 모델을 한 겹 둔다.
//
//   NSAttributedString  ──DocumentModelBuilder──▶  [Block]  ──▶ DocxWriter / HwpxWriter
//
// 순회·해석은 한 번만 하고, 포맷별 차이는 "XML을 어떻게 쓰느냐"로만 격리된다.

/// 문서의 블록 단위 요소. (제목·문단·목록·인용·코드·표·구분선·이미지)
enum Block {
    /// 제목. `level`은 1~3 (h1~h3).
    case heading(level: Int, inlines: [Inline])
    /// 본문 문단.
    case paragraph([Inline])
    /// 목록 항목. `ordered`면 순서 목록(번호 `index`), 아니면 글머리 기호.
    case listItem(ordered: Bool, index: Int, inlines: [Inline])
    /// 인용구.
    case blockquote([Inline])
    /// 코드 블록. 여러 줄을 하나의 문자열로 (언어 정보는 1차 미사용).
    case codeBlock(String)
    /// 표. `rows[행][열] = 셀의 인라인들`. `headerRow`는 헤더로 표시할 행 인덱스.
    case table(rows: [[[Inline]]], headerRow: Int)
    /// 구분선 (`---`).
    case horizontalRule
    /// 이미지. 바이너리는 패키지 안에 임베드된다.
    case image(ImageRef)
}

/// 인라인 텍스트 조각 — 텍스트 + 서식 플래그.
struct Inline {
    var text: String
    var bold = false
    var italic = false
    var code = false
    /// 사용자가 명시 지정한 글자색 "#RRGGBB" (구조적 기본색은 nil).
    var color: String? = nil
    /// 링크 URL 문자열 (없으면 nil).
    var link: String? = nil

    init(text: String, bold: Bool = false, italic: Bool = false,
         code: Bool = false, color: String? = nil, link: String? = nil) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.code = code
        self.color = color
        self.link = link
    }
}

/// 패키지에 임베드할 이미지 참조.
struct ImageRef {
    /// 원본 파일에서 로드한 바이너리.
    var data: Data
    /// 패키지 내 파일명 (`image1.png` …).
    var fileName: String
    /// 지정 폭(px). 없으면 원본 크기.
    var width: Int?
}
