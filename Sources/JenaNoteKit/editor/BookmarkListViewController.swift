import AppKit

/// 리더 툴바 책갈피 버튼에 딸린 팝오버 목록 (ADR-0008).
/// 현재 문서의 책갈피만 문서 순서로 보여준다. 행 클릭 → 그 자리로 점프, ⌫ → 삭제.
final class BookmarkListViewController: NSViewController {

    private var anchors: [ReadingAnchor]
    private let contentString: String

    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private weak var emptyLabel: NSTextField?

    /// 행이 선택됐을 때 — 해당 앵커로 점프하라는 뜻.
    var onSelect: ((ReadingAnchor) -> Void)?
    /// 행이 삭제됐을 때.
    var onDelete: ((ReadingAnchor) -> Void)?

    private let rowHeight: CGFloat = 26
    private let maxVisibleRows = 12

    init(anchors: [ReadingAnchor], contentString: String) {
        self.anchors = anchors
        self.contentString = contentString
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    override func loadView() {
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        tableView = BookmarkTableView()
        tableView.headerView = nil
        tableView.rowHeight = rowHeight
        tableView.style = .inset
        tableView.backgroundColor = .clear
        tableView.allowsMultipleSelection = false
        tableView.target = self
        tableView.action = #selector(rowClicked(_:))
        (tableView as? BookmarkTableView)?.onDeleteKey = { [weak self] in self?.deleteSelectedRow() }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bookmark"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        container.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])

        // 비어 있을 때 안내
        let label = NSTextField(labelWithString: L10n.tr("reader.bookmark.empty"))
        label.textColor = .secondaryLabelColor
        label.font = NSFont.systemFont(ofSize: 12)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        emptyLabel = label

        view = container
        updateEmptyState()
    }

    /// 팝오버가 뜰 크기 — 항목 수에 맞춰 줄이되 상한을 둔다.
    var preferredSize: NSSize {
        let rows = max(1, min(anchors.count, maxVisibleRows))
        return NSSize(width: 320, height: CGFloat(rows) * rowHeight + 16)
    }

    private func updateEmptyState() {
        emptyLabel?.isHidden = !anchors.isEmpty
        scrollView.isHidden = anchors.isEmpty
    }

    // MARK: - Actions

    @objc private func rowClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < anchors.count else { return }
        onSelect?(anchors[row])
    }

    private func deleteSelectedRow() {
        let row = tableView.selectedRow
        guard row >= 0, row < anchors.count else { return }
        let removed = anchors.remove(at: row)
        tableView.reloadData()
        updateEmptyState()
        preferredContentSize = preferredSize
        onDelete?(removed)
    }
}

// MARK: - Table Data

extension BookmarkListViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { anchors.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < anchors.count else { return nil }
        let anchor = anchors[row]

        let id = NSUserInterfaceItemIdentifier("BookmarkCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
            ?? BookmarkListViewController.makeCell(id: id)

        // 문서가 편집됐을 수 있으므로 저장된 스니펫이 아니라 현재 본문에서 다시 뜬다.
        let offset = anchor.resolve(in: contentString)
        let preview = ReadingAnchor.previewText(at: offset, in: contentString)
        cell.textField?.stringValue = preview.isEmpty ? L10n.tr("reader.bookmark.untitled") : preview
        cell.textField?.toolTip = preview
        return cell
    }

    private static func makeCell(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.font = NSFont.systemFont(ofSize: 12)
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}

/// ⌫ 로 선택 행을 지울 수 있게 한 테이블.
private final class BookmarkTableView: NSTableView {
    var onDeleteKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // 51 = delete, 117 = forward delete
        if event.keyCode == 51 || event.keyCode == 117 {
            onDeleteKey?()
            return
        }
        super.keyDown(with: event)
    }
}
