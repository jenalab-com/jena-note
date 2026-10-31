import AppKit

final class PersonalDictionaryWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private static var windows: [PersonalDictionaryWindowController] = []
    private let store: PersonalDictionaryStore
    private let context: DictionaryWorkContext?
    private let initialTerm: String?
    private let table = NSTableView()
    private let search = NSSearchField()
    private let termField = NSTextField(string: "")
    private let allWorks = NSButton(checkboxWithTitle: L10n.tr("dictionary.all"), target: nil, action: nil)
    private let enabled = NSButton(checkboxWithTitle: L10n.tr("dictionary.enabled"), target: nil, action: nil)
    private let choices = NSStackView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var workOptions: [PersonalDictionaryStore.Work] = []
    private var workButtons: [UUID: NSButton] = [:]
    private var rows: [PersonalDictionaryStore.Entry] = []
    private var editingID: UUID?
    private var observer: NSObjectProtocol?

    static func present(context: DictionaryWorkContext?, term: String? = nil) {
        let controller = PersonalDictionaryWindowController(context: context, term: term)
        windows.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    init(context: DictionaryWorkContext?, term: String? = nil, store: PersonalDictionaryStore = .shared) {
        self.context = context; self.initialTerm = term; self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 620), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = L10n.tr("dictionary.title")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        build()
        observer = NotificationCenter.default.addObserver(forName: PersonalDictionaryStore.changed, object: store, queue: .main) { [weak self] _ in self?.reloadRows() }
        startNew(nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func windowWillClose(_ notification: Notification) { Self.windows.removeAll { $0 === self } }

    private func build() {
        let root = NSStackView()
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView?.addSubview(root)
        if let content = window?.contentView {
            NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), root.topAnchor.constraint(equalTo: content.topAnchor, constant: 18)])
        }
        root.addArrangedSubview(NSTextField(wrappingLabelWithString: L10n.tr("dictionary.description")))
        search.placeholderString = L10n.tr("dictionary.search"); search.delegate = self
        root.addArrangedSubview(search); search.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        for (id, title, width) in [("term", "dictionary.term", 230.0), ("scope", "dictionary.scope", 360.0), ("enabled", "dictionary.state", 80.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = L10n.tr(title); column.width = width; table.addTableColumn(column)
        }
        table.delegate = self; table.dataSource = self; table.rowHeight = 26
        let list = NSScrollView(); list.hasVerticalScroller = true; list.documentView = table
        root.addArrangedSubview(list)
        list.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        list.heightAnchor.constraint(equalToConstant: 190).isActive = true
        root.addArrangedSubview(NSTextField(labelWithString: L10n.tr("dictionary.term")))
        termField.placeholderString = L10n.tr("dictionary.termHint")
        root.addArrangedSubview(termField); termField.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        root.addArrangedSubview(allWorks); allWorks.target = self; allWorks.action = #selector(scopeChanged(_:))
        choices.orientation = .vertical; choices.alignment = .leading; choices.spacing = 5
        let workScroll = NSScrollView(); workScroll.hasVerticalScroller = true; workScroll.documentView = choices
        root.addArrangedSubview(workScroll)
        workScroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        workScroll.heightAnchor.constraint(equalToConstant: 100).isActive = true
        choices.translatesAutoresizingMaskIntoConstraints = false
        choices.widthAnchor.constraint(equalTo: workScroll.contentView.widthAnchor).isActive = true
        root.addArrangedSubview(enabled)
        let buttons = NSStackView(views: [NSButton(title: L10n.tr("dictionary.new"), target: self, action: #selector(startNew(_:))), NSButton(title: L10n.tr("dictionary.addWork"), target: self, action: #selector(addWork(_:))), NSButton(title: L10n.tr("dictionary.save"), target: self, action: #selector(saveEntry(_:)))])
        buttons.spacing = 10; root.addArrangedSubview(buttons)
        root.addArrangedSubview(status); status.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        workOptions = store.works
        if let context { include(store.work(for: context)) }
        rebuildChoices(selected: [])
        reloadRows()
        if store.loadError != nil { showError(AIError(message: L10n.tr("dictionary.corrupt"))) }
    }

    private func include(_ work: PersonalDictionaryStore.Work) {
        if let index = workOptions.firstIndex(where: { $0.id == work.id }) { workOptions[index] = work }
        else { workOptions.append(work) }
    }
    private func rebuildChoices(selected: Set<UUID>) {
        for view in choices.arrangedSubviews { choices.removeArrangedSubview(view); view.removeFromSuperview() }
        workButtons.removeAll()
        for work in workOptions {
            let button = NSButton(checkboxWithTitle: "\(work.title) — \(work.path)", target: nil, action: nil)
            button.state = selected.contains(work.id) ? .on : .off
            button.toolTip = work.path
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            button.cell?.lineBreakMode = .byTruncatingMiddle
            choices.addArrangedSubview(button); workButtons[work.id] = button
            button.widthAnchor.constraint(lessThanOrEqualTo: choices.widthAnchor).isActive = true
        }
        choices.layoutSubtreeIfNeeded(); choices.setFrameSize(choices.fittingSize)
        scopeChanged(nil)
    }
    private func scopeText(_ entry: PersonalDictionaryStore.Entry) -> String {
        guard let ids = entry.workIDs else { return L10n.tr("dictionary.all") }
        return ids.compactMap { id in store.works.first { $0.id == id }.map { "\($0.title) — \($0.path)" } }.sorted().joined(separator: "; ")
    }
    private func reloadRows() {
        let query = search.stringValue
        rows = store.entries.filter { query.isEmpty || $0.term.localizedCaseInsensitiveContains(query) || scopeText($0).localizedCaseInsensitiveContains(query) }.sorted { $0.term < $1.term }
        table.reloadData()
    }
    func controlTextDidChange(_ obj: Notification) { if obj.object as? NSSearchField === search { reloadRows() } }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let item = rows[row]
        let value = column?.identifier.rawValue == "term" ? item.term : column?.identifier.rawValue == "scope" ? scopeText(item) : L10n.tr(item.enabled ? "dictionary.on" : "dictionary.off")
        let label = NSTextField(labelWithString: value); label.lineBreakMode = .byTruncatingTail; label.toolTip = value
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard rows.indices.contains(table.selectedRow) else { return }
        loadEntry(rows[table.selectedRow])
    }
    private func loadEntry(_ item: PersonalDictionaryStore.Entry) {
        editingID = item.id; termField.stringValue = item.term
        enabled.state = item.enabled ? .on : .off; allWorks.state = item.workIDs == nil ? .on : .off
        for work in store.works { include(work) }
        rebuildChoices(selected: Set(item.workIDs ?? []))
        status.stringValue = L10n.tr("dictionary.editHint"); status.textColor = .secondaryLabelColor
    }
    @objc private func startNew(_ sender: Any?) {
        editingID = nil; table.deselectAll(nil); termField.stringValue = sender == nil ? initialTerm ?? "" : ""
        enabled.state = .on; allWorks.state = context == nil ? .on : .off
        let selected = context.flatMap { context in workOptions.first { $0.matches(context.root) }?.id }
        rebuildChoices(selected: selected.map { Set([$0]) } ?? [])
        status.stringValue = L10n.tr(context == nil ? "dictionary.noWork" : "dictionary.defaultCurrent"); status.textColor = .secondaryLabelColor
        if store.loadError != nil { showError(AIError(message: L10n.tr("dictionary.corrupt"))) }
    }
    @objc private func scopeChanged(_ sender: Any?) { for button in workButtons.values { button.isEnabled = allWorks.state != .on } }
    @objc private func saveEntry(_ sender: Any?) {
        do {
            let selected = allWorks.state == .on ? nil : workOptions.filter { workButtons[$0.id]?.state == .on }
            let item = try store.save(id: editingID, term: termField.stringValue, selectedWorks: selected, enabled: enabled.state == .on)
            loadEntry(item); reloadRows(); status.stringValue = L10n.tr("dictionary.saved")
        } catch { showError(error) }
    }
    @objc private func addWork(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = L10n.tr("dictionary.chooseWork")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let context = try AIWorkContext.load(rootURL: url)
                let work = self.store.work(for: DictionaryWorkContext(root: url, title: context.config.title))
                var selected = Set(self.workButtons.filter { $0.value.state == .on }.map(\.key)); selected.insert(work.id)
                self.include(work); self.allWorks.state = .off; self.rebuildChoices(selected: selected)
            } catch { self.showError(AIError(message: L10n.tr("dictionary.workMissing"))) }
        }
    }
    private func showError(_ error: Error) { status.stringValue = error.localizedDescription; status.textColor = .systemRed }
}
