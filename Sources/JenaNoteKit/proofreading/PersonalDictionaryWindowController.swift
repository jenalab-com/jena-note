import AppKit

final class PersonalDictionaryWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private static var windows: [PersonalDictionaryWindowController] = []
    private let store: PersonalDictionaryStore
    private let context: DictionaryWorkContext?
    private let initialTerm: String?
    private let table = NSTableView()
    private let search = NSSearchField()
    private let deleteButton = SettingsButton(title: "", target: nil, action: nil, primary: false)
    private let selectAll = NSButton(checkboxWithTitle: L10n.tr("dictionary.selectAll"), target: nil, action: nil)
    private var checkedIDs = Set<UUID>()
    private let termField = NSTextField(string: "")
    private let scopePopup = JenaPopUpButton(frame: .zero, pullsDown: false)
    private let saveButton = SettingsButton(title: "", target: nil, action: nil, primary: true)
    private let newButton = SettingsButton(title: "", target: nil, action: nil, primary: false)
    private let heading = NSTextField(labelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let emptyState = NSTextField(labelWithString: "")
    private var workOptions: [PersonalDictionaryStore.Work] = []
    private var rows: [PersonalDictionaryStore.Entry] = []
    private var editingID: UUID?
    private var reloadingRows = false
    private var observer: NSObjectProtocol?

    static func present(context: DictionaryWorkContext?, term: String? = nil) {
        let controller = PersonalDictionaryWindowController(context: context, term: term)
        windows.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
    init(context: DictionaryWorkContext?, term: String? = nil, store: PersonalDictionaryStore = .shared) {
        self.context = context; self.initialTerm = term; self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = L10n.tr("dictionary.title")
        SettingsText.applyToolWindowChrome(window)
        window.isReleasedWhenClosed = false; window.delegate = self; window.center()
        workOptions = store.works
        if let context { include(store.work(for: context)) }
        build()
        observer = NotificationCenter.default.addObserver(forName: PersonalDictionaryStore.changed, object: store, queue: .main) { [weak self] _ in self?.reloadRows() }
        startNew(nil)
        reloadRows()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func windowWillClose(_ notification: Notification) { Self.windows.removeAll { $0 === self } }

    private func build() {
        guard let content = window?.contentView else { return }
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: SettingsStyle.contentInset),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -SettingsStyle.contentInset),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 44),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -SettingsStyle.contentInset)
        ])
        let title = SettingsText.heading(L10n.tr("dictionary.title"))
        root.addArrangedSubview(title)
        root.setCustomSpacing(18, after: title)

        // 등록 — "단어 추가 / 수정" 머리말과 새로 쓰기
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        newButton.title = L10n.tr("dictionary.newAction")
        newButton.target = self; newButton.action = #selector(startNew(_:))
        let formHeader = NSStackView(views: [heading, newButton]); formHeader.spacing = 10; formHeader.alignment = .centerY
        root.addArrangedSubview(formHeader)
        termField.placeholderString = L10n.tr("dictionary.input")
        termField.identifier = .init("dictionary.term"); termField.delegate = self
        termField.setAccessibilityLabel(L10n.tr("dictionary.term"))
        scopePopup.identifier = .init("dictionary.scope")
        scopePopup.setAccessibilityLabel(L10n.tr("dictionary.scope"))
        scopePopup.target = self; scopePopup.action = #selector(scopeChanged(_:))
        scopePopup.isFilled = true
        scopePopup.font = .systemFont(ofSize: 13)
        scopePopup.widthAnchor.constraint(equalToConstant: 210).isActive = true
        scopePopup.cell?.lineBreakMode = .byTruncatingTail
        saveButton.identifier = .init("dictionary.save")
        saveButton.target = self; saveButton.action = #selector(saveEntry(_:))
        saveButton.keyEquivalent = "\r"
        let termBox = SettingsFieldContainer(termField)
        termBox.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let input = NSStackView(views: [termBox, scopePopup, saveButton]); input.spacing = 8; input.alignment = .centerY
        input.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        let form = SettingsPanelView(content: input)
        root.addArrangedSubview(form)
        form.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        termBox.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        status.textColor = .systemRed; status.font = .systemFont(ofSize: 12); status.isHidden = true
        root.addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        root.setCustomSpacing(20, after: status)
        root.setCustomSpacing(20, after: form)

        // 목록 — 검색, 고른 항목 지우기, 표
        search.placeholderString = L10n.tr("dictionary.search"); search.delegate = self
        search.setAccessibilityLabel(L10n.tr("dictionary.search"))
        let searchBox = HeaderFieldContainer(search)
        selectAll.target = self; selectAll.action = #selector(toggleAll(_:))
        selectAll.allowsMixedState = true
        deleteButton.target = self; deleteButton.action = #selector(deleteChecked(_:))
        deleteButton.identifier = .init("dictionary.delete")
        let listHeader = NSStackView(views: [searchBox, selectAll, deleteButton]); listHeader.spacing = 12; listHeader.alignment = .centerY
        searchBox.setContentHuggingPriority(.defaultLow, for: .horizontal)
        root.addArrangedSubview(listHeader)
        listHeader.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let checkColumn = NSTableColumn(identifier: .init("checked"))
        checkColumn.title = ""; checkColumn.width = 30; checkColumn.minWidth = 30; checkColumn.maxWidth = 30
        table.addTableColumn(checkColumn)
        for (id, title, width) in [("term", "dictionary.term", 260.0), ("scope", "dictionary.scope", 280.0), ("enabled", "dictionary.state", 90.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = L10n.tr(title); column.width = width
            table.addTableColumn(column)
        }
        table.delegate = self; table.dataSource = self; table.rowHeight = 30
        table.backgroundColor = .clear
        table.style = .plain
        table.gridStyleMask = []
        let list = NSScrollView(); list.hasVerticalScroller = true; list.documentView = table
        list.drawsBackground = false
        let listPanel = SettingsPanelView(content: list)
        root.addArrangedSubview(listPanel)
        listPanel.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        listPanel.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        emptyState.textColor = .secondaryLabelColor
        root.addArrangedSubview(emptyState)
    }
    private func include(_ work: PersonalDictionaryStore.Work) {
        if let index = workOptions.firstIndex(where: { $0.id == work.id }) { workOptions[index] = work }
        else { workOptions.append(work) }
    }
    private func rebuildScopes(selected: [UUID]?) {
        for work in store.works { include(work) }
        scopePopup.removeAllItems()
        scopePopup.addItem(withTitle: L10n.tr("dictionary.allShort"))
        // Empty IDs represent all works. Existing multi-work entries keep their scope when edited.
        scopePopup.lastItem?.representedObject = [UUID]()
        let sorted = workOptions.sorted { lhs, rhs in
            let leftCurrent = context.map { lhs.matches($0.root) } ?? false
            let rightCurrent = context.map { rhs.matches($0.root) } ?? false
            return leftCurrent != rightCurrent ? leftCurrent : lhs.title < rhs.title
        }
        for work in sorted {
            let current = context.map { work.matches($0.root) } ?? false
            scopePopup.addItem(withTitle: work.title + (current ? " (" + L10n.tr("dictionary.currentWork") + ")" : ""))
            scopePopup.lastItem?.representedObject = [work.id]
            scopePopup.lastItem?.toolTip = work.path
        }
        if let selected, selected.count > 1 {
            let title = workOptions.filter { selected.contains($0.id) }.map(\.title).joined(separator: ", ")
            scopePopup.addItem(withTitle: title); scopePopup.lastItem?.representedObject = selected
        }
        let ids = Set(selected ?? [])
        scopePopup.selectItem(at: scopePopup.itemArray.firstIndex { Set($0.representedObject as? [UUID] ?? []) == ids } ?? 0)
    }
    private func scopeText(_ entry: PersonalDictionaryStore.Entry) -> String {
        guard let ids = entry.workIDs else { return L10n.tr("dictionary.allShort") }
        return ids.compactMap { id in store.works.first { $0.id == id }?.title }.sorted().joined(separator: ", ")
    }
    private func reloadRows() {
        reloadingRows = true; defer { reloadingRows = false }
        let query = search.stringValue
        rows = store.entries.filter { query.isEmpty || $0.term.localizedCaseInsensitiveContains(query) || scopeText($0).localizedCaseInsensitiveContains(query) }.sorted { $0.term < $1.term }
        checkedIDs.formIntersection(Set(rows.map(\.id)))
        table.reloadData()
        updateDeleteState()
        emptyState.stringValue = L10n.tr(query.isEmpty ? "dictionary.emptyShort" : "dictionary.noResultsShort")
        emptyState.isHidden = !rows.isEmpty
        if let editingID, let index = rows.firstIndex(where: { $0.id == editingID }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }
    private func updateSaveState() {
        let term = termField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        saveButton.isEnabled = store.loadError == nil && !term.isEmpty && term.count <= 100 && !term.contains(where: { $0.isNewline })
        saveButton.title = L10n.tr(editingID == nil ? "dictionary.registerAction" : "dictionary.updateAction")
        heading.stringValue = L10n.tr(editingID == nil ? "dictionary.addHeading" : "dictionary.editAction")
        newButton.isHidden = editingID == nil
    }
    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSSearchField === search { reloadRows() }
        else { status.isHidden = true; updateSaveState() }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let item = rows[row]
        if column?.identifier.rawValue == "checked" {
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleChecked(_:)))
            checkbox.identifier = .init(item.id.uuidString)
            checkbox.state = checkedIDs.contains(item.id) ? .on : .off
            checkbox.setAccessibilityLabel(item.term)
            return checkbox
        }
        let value = column?.identifier.rawValue == "term" ? item.term : column?.identifier.rawValue == "scope" ? scopeText(item) : L10n.tr(item.enabled ? "dictionary.on" : "dictionary.off")
        let label = NSTextField(labelWithString: value); label.lineBreakMode = .byTruncatingTail; label.toolTip = value
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloadingRows, rows.indices.contains(table.selectedRow) else { return }
        let item = rows[table.selectedRow]
        editingID = item.id; termField.stringValue = item.term
        rebuildScopes(selected: item.workIDs); status.isHidden = true; updateSaveState()
    }
    @objc private func startNew(_ sender: Any?) {
        editingID = nil; table.deselectAll(nil)
        termField.stringValue = sender == nil ? initialTerm ?? "" : ""
        let selected = context.flatMap { context in workOptions.first { $0.matches(context.root) }?.id }
        rebuildScopes(selected: selected.map { [$0] })
        status.isHidden = true; updateSaveState(); window?.makeFirstResponder(termField)
        if store.loadError != nil { showError(AIError(message: L10n.tr("dictionary.corrupt"))) }
    }
    @objc private func scopeChanged(_ sender: Any?) { status.isHidden = true; updateSaveState() }
    @objc private func saveEntry(_ sender: Any?) {
        do {
            let ids = scopePopup.selectedItem?.representedObject as? [UUID] ?? []
            let works = ids.isEmpty ? nil : workOptions.filter { ids.contains($0.id) }
            try store.save(id: editingID, term: termField.stringValue, selectedWorks: works, enabled: true)
            search.stringValue = ""
            startNew(self)
            rebuildScopes(selected: ids.isEmpty ? nil : ids)
            reloadRows()
        } catch { showError(error) }
    }
    private func updateDeleteState() {
        deleteButton.title = checkedIDs.isEmpty ? L10n.tr("dictionary.deleteSelected") : String(format: L10n.tr("dictionary.deleteCount"), checkedIDs.count)
        deleteButton.isEnabled = !checkedIDs.isEmpty && store.loadError == nil
        selectAll.isEnabled = !rows.isEmpty
        selectAll.state = checkedIDs.isEmpty ? .off : checkedIDs.count == rows.count ? .on : .mixed
    }
    @objc private func toggleChecked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        if sender.state == .on { checkedIDs.insert(id) } else { checkedIDs.remove(id) }
        updateDeleteState()
    }
    @objc private func toggleAll(_ sender: NSButton) {
        checkedIDs = checkedIDs.count == rows.count ? [] : Set(rows.map(\.id))
        table.reloadData(); updateDeleteState()
    }
    @objc private func deleteChecked(_ sender: Any?) {
        let ids = checkedIDs
        guard !ids.isEmpty else { return }
        do {
            try store.remove(ids: ids)
            if let editingID, ids.contains(editingID) { startNew(self) }
            checkedIDs.removeAll(); status.isHidden = true; reloadRows()
        } catch { showError(error) }
    }
    private func showError(_ error: Error) { status.stringValue = error.localizedDescription; status.isHidden = false }
}
