import AppKit

final class EndnoteEditorView: NSView, NSTextFieldDelegate {
    var onChange: (() -> Void)?
    let picker = NSPopUpButton()
    let field = NSTextField()
    private let notes: [DocumentEndnotes.Note]
    init(notes: [DocumentEndnotes.Note]) {
        self.notes = notes
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 90))
        picker.frame = NSRect(x: 0, y: 52, width: 380, height: 26)
        picker.addItem(withTitle: L10n.tr("note.new"))
        for note in notes { picker.addItem(withTitle: "[\(note.id)] " + String(note.text.prefix(40))) }
        picker.target = self; picker.action = #selector(selected)
        field.frame = NSRect(x: 0, y: 10, width: 380, height: 26)
        field.delegate = self
        field.placeholderString = L10n.tr("note.placeholder")
        field.setAccessibilityLabel(L10n.tr("note.placeholder"))
        addSubview(picker); addSubview(field)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func controlTextDidChange(_ notification: Notification) { onChange?() }
    @objc private func selected() {
        let index = picker.indexOfSelectedItem - 1
        field.stringValue = notes.indices.contains(index) ? notes[index].text : ""
        onChange?()
    }
}
