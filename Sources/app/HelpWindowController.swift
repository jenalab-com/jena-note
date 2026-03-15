import AppKit

class HelpWindowController: NSWindowController {

    static let shared = HelpWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Jena Note 도움말"
        window.center()
        window.minSize = NSSize(width: 480, height: 400)

        super.init(window: window)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 32, height: 24)
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        window.contentView = scrollView

        textView.textStorage?.setAttributedString(buildHelp())
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Content

    private func buildHelp() -> NSAttributedString {
        let result = NSMutableAttributedString()

        result.append(h1("Jena Note 도움말"))
        result.append(body("Jena Note는 macOS용 마크다운 편집기입니다. 마크다운 기호 없이 서식이 적용된 상태로 편집하며, 저장 시 표준 CommonMark 형식의 .md 파일로 내보냅니다."))
        result.append(spacer())

        result.append(h2("파일 관리"))
        result.append(item("새 문서", detail: "파일 > 새 문서 (⌘N) — 빈 문서를 새 창으로 엽니다."))
        result.append(item("파일 열기", detail: "파일 > 열기 (⌘O) — .md 파일을 선택해 엽니다."))
        result.append(item("저장", detail: "파일 > 저장 (⌘S) — 현재 문서를 저장합니다."))
        result.append(item("다른 이름으로 저장", detail: "파일 > 다른 이름으로 저장 (⇧⌘S) — 새 파일명으로 저장합니다."))
        result.append(item("최근 문서", detail: "파일 > 최근 열었던 항목 — 최근 열었던 파일 목록을 표시합니다. 앱 재시작 시 가장 최근 파일이 자동으로 열립니다."))
        result.append(spacer())

        result.append(h2("텍스트 서식"))
        result.append(body("텍스트를 선택한 뒤 툴바 버튼 또는 단축키로 서식을 적용합니다."))
        result.append(spacer(height: 6))

        result.append(h3("인라인 서식"))
        result.append(shortcut("굵게", key: "⌘B"))
        result.append(shortcut("기울임", key: "⌘I"))
        result.append(shortcut("인라인 코드", key: "툴바 버튼 사용 (텍스트 선택 필요)"))
        result.append(shortcut("링크 삽입", key: "⌘K (텍스트 선택 필요)"))
        result.append(spacer(height: 6))

        result.append(h3("단락 서식"))
        result.append(shortcut("본문", key: "서식 > 본문"))
        result.append(shortcut("제목 1", key: "서식 > 제목 1"))
        result.append(shortcut("제목 2", key: "서식 > 제목 2"))
        result.append(shortcut("제목 3", key: "서식 > 제목 3"))
        result.append(shortcut("글머리 기호 목록", key: "서식 > 목록"))
        result.append(shortcut("번호 목록", key: "서식 > 번호 목록"))
        result.append(shortcut("인용", key: "서식 > 인용"))
        result.append(shortcut("수평선", key: "서식 > 구분선 또는 툴바 ─ 버튼"))
        result.append(spacer())

        result.append(h2("줄 간격"))
        result.append(body("툴바 오른쪽의 1× · 1.5× · 2× 세그먼트 컨트롤로 전체 줄 간격을 조절합니다."))
        result.append(spacer())

        result.append(h2("편집"))
        result.append(shortcut("실행 취소", key: "⌘Z"))
        result.append(shortcut("다시 실행", key: "⇧⌘Z"))
        result.append(shortcut("오려두기", key: "⌘X"))
        result.append(shortcut("복사", key: "⌘C"))
        result.append(shortcut("붙여넣기", key: "⌘V"))
        result.append(shortcut("서식 없이 붙여넣기", key: "⇧⌘V"))
        result.append(shortcut("전체 선택", key: "⌘A"))
        result.append(shortcut("찾기", key: "⌘F"))
        result.append(spacer())

        result.append(h2("파일 형식"))
        result.append(body("Jena Note는 UTF-8 인코딩의 CommonMark 형식(.md)을 읽고 씁니다. 저장된 파일은 모든 표준 마크다운 편집기 및 뷰어와 호환됩니다."))
        result.append(spacer())

        return result
    }

    // MARK: - Style Helpers

    private func h1(_ text: String) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = 6
        return NSAttributedString(string: text + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .bold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para
        ])
    }

    private func h2(_ text: String) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacingBefore = 8
        para.paragraphSpacing = 4
        return NSAttributedString(string: text + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para
        ])
    }

    private func h3(_ text: String) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacingBefore = 4
        para.paragraphSpacing = 2
        return NSAttributedString(string: text + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: para
        ])
    }

    private func body(_ text: String) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = 2
        para.lineSpacing = 3
        return NSAttributedString(string: text + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para
        ])
    }

    private func item(_ title: String, detail: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let para = NSMutableParagraphStyle()
        para.headIndent = 16
        para.firstLineHeadIndent = 0
        para.paragraphSpacing = 3
        para.lineSpacing = 2
        result.append(NSAttributedString(string: "• ", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: para
        ]))
        result.append(NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para
        ]))
        result.append(NSAttributedString(string: " — " + detail + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para
        ]))
        return result
    }

    private func shortcut(_ label: String, key: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let para = NSMutableParagraphStyle()
        para.headIndent = 120
        para.firstLineHeadIndent = 16
        para.tabStops = [NSTextTab(type: .leftTabStopType, location: 120)]
        para.paragraphSpacing = 3

        result.append(NSAttributedString(string: "  " + label + "\t", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para
        ]))
        result.append(NSAttributedString(string: key + "\n", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: para
        ]))
        return result
    }

    private func spacer(height: CGFloat = 12) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = height
        para.maximumLineHeight = height
        return NSAttributedString(string: "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 1),
            .paragraphStyle: para
        ])
    }
}
