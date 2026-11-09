import AppKit

/// File identity survives document-controller swaps. Unsaved notes use a per-document UUID.
final class AIConversation {
    var messages: [AIChatMessage] = []
    var tokenUsage: [AIProvider: Int] = [:]
    var draft = ""
    var mode: AIChatMode = .guide
}

final class AIConversationStore {
    static let shared = AIConversationStore()
    private var conversations: [String: AIConversation] = [:]
    private var keys: [UUID: String] = [:]

    func conversation(for document: MarkdownDocument) -> AIConversation {
        let key = document.fileURL?.standardizedFileURL.path ?? document.aiIdentity.uuidString
        if let oldKey = keys[document.aiIdentity], oldKey != key,
           let existing = conversations[oldKey] {
            if oldKey == document.aiIdentity.uuidString {
                conversations[key] = existing
            } else {
                let copy = AIConversation()
                copy.messages = existing.messages
                copy.tokenUsage = existing.tokenUsage
                copy.draft = existing.draft
                copy.mode = existing.mode
                conversations[key] = copy
            }
        }
        keys[document.aiIdentity] = key
        if let existing = conversations[key] { return existing }
        let conversation = AIConversation()
        conversations[key] = conversation
        return conversation
    }
}

struct AIEditSnapshot {
    let documentID: UUID
    let content: NSAttributedString
    let range: NSRange

    init(document: MarkdownDocument, selection: NSRange) {
        documentID = document.aiIdentity
        content = NSAttributedString(attributedString: document.content)
        range = selection.location != NSNotFound && selection.length > 0
            && NSMaxRange(selection) <= content.length
            ? selection : NSRange(location: 0, length: content.length)
    }

    func canApply(to document: MarkdownDocument) -> Bool {
        document.aiIdentity == documentID && document.content.isEqual(to: content)
    }

    /// Plain text replacement keeps surviving prefixes/suffixes and inherits the target style.
    /// Attachments in the changed region require a manual edit, since text cannot reproduce them.
    func replacement(_ text: String) throws -> (NSRange, NSAttributedString) {
        let original = content.attributedSubstring(from: range)
        let originalCharacters = Array(original.string), revisedCharacters = Array(text)
        var prefix = 0
        while prefix < min(originalCharacters.count, revisedCharacters.count), originalCharacters[prefix] == revisedCharacters[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(originalCharacters.count, revisedCharacters.count) - prefix,
              originalCharacters[originalCharacters.count - suffix - 1] == revisedCharacters[revisedCharacters.count - suffix - 1] { suffix += 1 }
        let prefixLength = String(originalCharacters.prefix(prefix)).utf16.count
        let oldMiddle = String(originalCharacters.dropFirst(prefix).dropLast(suffix))
        let newMiddle = String(revisedCharacters.dropFirst(prefix).dropLast(suffix))
        let changed = NSRange(location: range.location + prefixLength, length: oldMiddle.utf16.count)
        // Retain attributes of characters that survive between separate edits, too.
        // A single replacement string must not flatten bold/list/heading runs in its middle.
        let middle = original.attributedSubstring(from: NSRange(location: prefixLength, length: oldMiddle.utf16.count))
        let before = Array(oldMiddle), after = Array(newMiddle)
        // Myers diff can become quadratic on a rewrite. Keep the main-thread edit bounded.
        guard before.isEmpty || after.count <= 4_000_000 / before.count else {
            throw AIError(message: L10n.tr("ai.editTooLarge"))
        }
        let fallbackIndex = min(changed.location, max(0, min(NSMaxRange(range) - 1, content.length - 1)))
        var fallback = content.length > 0 ? content.attributes(at: fallbackIndex, effectiveRange: nil)
            : MarkdownSerializer.parsePlainText(" ").attributes(at: 0, effectiveRange: nil)
        fallback.removeValue(forKey: .attachment)
        if before.isEmpty { return (changed, NSAttributedString(string: newMiddle, attributes: fallback)) }
        if after.isEmpty {
            var attachment = false
            middle.enumerateAttribute(.attachment, in: NSRange(location: 0, length: middle.length)) { value, _, _ in
                if value != nil { attachment = true }
            }
            guard !attachment else { throw AIError(message: L10n.tr("ai.attachmentConflict")) }
            return (changed, NSAttributedString())
        }
        let revised = NSMutableAttributedString(attributedString: middle)
        var offsets = [0]
        for character in before { offsets.append(offsets.last! + String(character).utf16.count) }
        let difference = after.difference(from: before)
        let removals = difference.removals.compactMap { change -> Int? in
            if case .remove(let offset, _, _) = change { return offset }; return nil
        }.sorted(by: >)
        for offset in removals {
            let removed = NSRange(location: offsets[offset], length: offsets[offset + 1] - offsets[offset])
            var attachment = false
            middle.enumerateAttribute(.attachment, in: removed) { value, _, _ in
                if value != nil { attachment = true }
            }
            guard !attachment else { throw AIError(message: L10n.tr("ai.attachmentConflict")) }
            revised.deleteCharacters(in: removed)
        }
        var newOffsets = [0]
        for character in after { newOffsets.append(newOffsets.last! + String(character).utf16.count) }
        let insertions = difference.insertions.compactMap { change -> (Int, Character)? in
            if case .insert(let offset, let character, _) = change { return (offset, character) }; return nil
        }.sorted { $0.0 < $1.0 }
        for (offset, character) in insertions {
            let location = newOffsets[offset]
            let inherited = min(max(0, location - 1), max(0, revised.length - 1))
            var attributes = revised.length > 0 ? revised.attributes(at: inherited, effectiveRange: nil) : fallback
            attributes.removeValue(forKey: .attachment)
            revised.insert(NSAttributedString(string: String(character), attributes: attributes), at: location)
        }
        return (changed, revised)
    }
}

enum AIPrompt {
    static let maximumBytes = AIChatPrompt.maximumBytes

    static func make(snapshot: AIEditSnapshot, messages: [AIChatMessage], request: String,
                     mode: AIChatMode, hasSelection: Bool, work: AIWorkPayload? = nil) throws -> String {
        var context = AIChatPrompt.context(
            document: snapshot.content.string,
            selectedText: hasSelection ? snapshot.content.attributedSubstring(from: snapshot.range).string : "",
            messages: messages, request: request)
        var hasWork = false
        if let work {
            context["work"] = try fit(work, base: context, maximumBytes: work.retrievalNote == nil ? maximumBytes : maximumBytes - 4096).json()
            hasWork = true
        }
        return try AIChatPrompt.wrap(context: context, mode: mode, extraInstruction: hasWork ? workInstruction : nil)
    }

    static func parseEdit(_ answer: String) throws -> (explanation: String, replacement: String?) {
        try AIChatPrompt.parseEdit(answer)
    }
}
