import AppKit

/// 입력창의 `/스킬이름` 처리 — 화면과 떨어진 순수 로직이라 테스트할 수 있다.
enum AISlashCommand {
    /// 스킬 이름에 쓰이는 글자 (폴더 이름: 영문·숫자·`-` `_` `.` `:`)
    private static func isNameCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || "-_.:".contains(c))
    }

    /// 커서 바로 앞이 `/` 로 시작하는 단어면 그 범위(`/` 포함)와 검색어(`/` 뒤)를 돌려준다.
    /// `/` 는 줄 처음이거나 공백 뒤여야 한다 — 문장 속 "1/2" 같은 건 스킬 호출이 아니다.
    static func activeQuery(in text: String, cursor: Int) -> (range: NSRange, query: String)? {
        let ns = text as NSString
        guard cursor >= 1, cursor <= ns.length else { return nil }
        var start = cursor
        while start > 0 {
            let previous = ns.substring(with: NSRange(location: start - 1, length: 1))
            guard let char = previous.first, previous.count == 1 else { return nil }
            if char == "/" {
                let before = start - 1 > 0 ? ns.substring(with: NSRange(location: start - 2, length: 1)) : ""
                guard before.isEmpty || before.first?.isWhitespace == true else { return nil }
                let range = NSRange(location: start - 1, length: cursor - (start - 1))
                return (range, ns.substring(with: NSRange(location: start, length: cursor - start)))
            }
            guard isNameCharacter(char) else { return nil }
            start -= 1
        }
        return nil
    }

    /// 앞에서부터 맞는 것 먼저, 그다음 이름 어딘가에 들어 있는 것. 대소문자 무시.
    static func filter(_ skills: [AISkill], query: String) -> [AISkill] {
        let q = query.lowercased()
        guard !q.isEmpty else { return skills }
        let prefix = skills.filter { $0.name.lowercased().hasPrefix(q) }
        let contains = skills.filter { !$0.name.lowercased().hasPrefix(q) && $0.name.lowercased().contains(q) }
        return prefix + contains
    }

    /// 메시지에 적힌 `/이름` 중 실제로 있는 스킬만, 적힌 순서대로. 없는 이름은 그냥 글자로 둔다.
    static func referencedSkills(in text: String, available: [String]) -> [String] {
        let known = Set(available)
        var result: [String] = []
        let ns = text as NSString
        var index = 0
        while index < ns.length {
            let char = ns.character(at: index)
            let atWordStart = index == 0 || (Character(UnicodeScalar(ns.character(at: index - 1)) ?? " ").isWhitespace)
            if char == UInt16(UInt8(ascii: "/")), atWordStart {
                var end = index + 1
                while end < ns.length, let scalar = UnicodeScalar(ns.character(at: end)), isNameCharacter(Character(scalar)) {
                    end += 1
                }
                let name = ns.substring(with: NSRange(location: index + 1, length: end - index - 1))
                if known.contains(name), !result.contains(name) { result.append(name) }
                index = end
            } else {
                index += 1
            }
        }
        return result
    }
}

/// 입력창 위에 뜨는 스킬 목록. 고르는 건 키보드(↑↓·Enter)나 클릭.
final class AISkillSuggestionView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onChoose: ((AISkill) -> Void)?
    private(set) var skills: [AISkill] = []
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var heightConstraint: NSLayoutConstraint!
    static let rowHeight: CGFloat = 40
    static let maxVisibleRows = 6

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        shadow = NSShadow()
        layer?.shadowOpacity = 0.12
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.list)
        setAccessibilityLabel(L10n.tr("ai.skill.list"))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("skill"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.refusesFirstResponder = true

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        heightConstraint = heightAnchor.constraint(equalToConstant: Self.rowHeight)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            heightConstraint
        ])
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
    override var wantsUpdateLayer: Bool { true }

    func show(_ skills: [AISkill]) {
        self.skills = skills
        table.reloadData()
        heightConstraint.constant = CGFloat(min(skills.count, Self.maxVisibleRows)) * Self.rowHeight + 8
        isHidden = skills.isEmpty
        if !skills.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
    }

    func hide() { isHidden = true; skills = [] }

    var selected: AISkill? {
        let row = table.selectedRow
        return skills.indices.contains(row) ? skills[row] : nil
    }

    func move(by delta: Int) {
        guard !skills.isEmpty else { return }
        let row = max(0, min(skills.count - 1, (table.selectedRow < 0 ? 0 : table.selectedRow) + delta))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func clicked() {
        guard skills.indices.contains(table.clickedRow) else { return }
        onChoose?(skills[table.clickedRow])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { skills.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let skill = skills[row]
        let name = NSTextField(labelWithString: "/" + skill.name)
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        let summary = NSTextField(labelWithString: skill.summary)
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingTail
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [name, summary])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.toolTip = skill.summary
        return stack
    }
}
