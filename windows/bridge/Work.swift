import Foundation
import JenaNoteCore

// The work context for the Windows app: which folders make up a work, the index of their text, and
// the evidence search before a request. Windows has no on-device model, so passages are found by
// their own text. Summaries a Mac made for the same folder stay in the index and keep being used.

/// What the index records as how its summaries were made. It tells a Mac to redo the excerpts.
private let excerptSignature = "excerpt-v1:ai.index.localUnavailable"

/// The resolver reads open documents through one hook, so one request runs at a time.
private let requestLock = NSLock()
private var openTexts: [String: String] = [:]

private func pathKey(_ url: URL) -> String { url.standardizedFileURL.path.lowercased() }

private func useOpenTexts(_ json: Any?) {
    openTexts = [:]
    for (path, text) in json as? [String: String] ?? [:] {
        openTexts[pathKey(URL(fileURLWithPath: path))] = text
    }
    AIWorkContextResolver.openDocumentText = { openTexts[pathKey($0)] }
}

private func encode(_ object: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private func message(for failure: Error) -> String {
    if let failure = failure as? AIError { return failure.message }
    if let failure = failure as? AIWorkContextValidationError {
        switch failure {
        case .settingsOutsideRoot(let path): return L10n.tr("ai.work.errorOutsideRoot").replacingOccurrences(of: "%@", with: path)
        case .settingsIsRoot: return L10n.tr("ai.work.errorSourceIsRoot")
        case .noSettingsSources: return L10n.tr("ai.work.errorNoSettings")
        case .writingFolderOutsideRoot: return L10n.tr("ai.work.errorOutsideRoot").replacingOccurrences(of: "%@", with: "")
        }
    }
    return String(describing: failure)
}

private func respond(_ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                     _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, _ body: () throws -> String) -> Int32 {
    do {
        result.pointee = duplicate(try body())
        return 0
    } catch let failure {
        error.pointee = duplicate(message(for: failure))
        return -1
    }
}

private func fileURL(_ path: UnsafePointer<CChar>) -> URL { URL(fileURLWithPath: String(cString: path)) }

private func windowsPath(_ url: URL) -> String {
    url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path
}

// MARK: - Index

private func indexURL(_ root: URL) -> URL { root.appendingPathComponent(".jenanote/work-index.json") }

/// Reading a long work's index takes seconds, and the status row asks often. It is read again only
/// when the file changed.
private let indexCacheLock = NSLock()
private var indexCache: (path: String, stamp: String, index: AIWorkIndex?)?

private func fileStamp(_ url: URL) -> String? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
    return "\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0):\((attributes[.size] as? NSNumber)?.intValue ?? 0)"
}

private func savedIndex(_ root: URL) -> AIWorkIndex? {
    let url = indexURL(root)
    guard let stamp = fileStamp(url), AIWorkContext.isSafeInsideRoot(url, root: root) else { return nil }
    indexCacheLock.lock()
    let cached = indexCache
    indexCacheLock.unlock()
    if let cached, cached.path == url.path, cached.stamp == stamp { return cached.index }
    var saved: AIWorkIndex?
    if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(AIWorkIndex.self, from: data), decoded.version == AIWorkIndex.version {
        saved = decoded
    }
    indexCacheLock.lock()
    indexCache = (url.path, stamp, saved)
    indexCacheLock.unlock()
    return saved
}

/// Passages of files already read, which need no second read while they stay the same.
private let splitCacheLock = NSLock()
private var splitCache: [String: (stamp: String, passages: [AIIndexedPassage])] = [:]

private func splitReusing(_ file: AIWorkFile, _ path: String, _ isSetting: Bool) throws -> [AIIndexedPassage] {
    let key = "\(isSetting):\(pathKey(file.url))"
    let stamp = file.stamp ?? fileStamp(file.url)
    splitCacheLock.lock()
    let known = splitCache[key]
    splitCacheLock.unlock()
    if let known, let stamp, known.stamp == stamp, known.passages.first.map({ $0.path == path }) ?? true { return known.passages }
    let passages = AIWorkIndex.split(text: try AIWorkContextResolver.readText(file), path: path, isSetting: isSetting)
    if let stamp {
        splitCacheLock.lock()
        splitCache[key] = (stamp, passages)
        splitCacheLock.unlock()
    }
    return passages
}

/// A fresh scan with every summary this folder already has.
private func freshIndex(_ context: AIWorkContext) throws -> AIWorkIndex {
    var fresh = try AIWorkIndex.scan(context: context, split: splitReusing)
    if let saved = savedIndex(context.rootURL) { fresh.restoreSummaries(from: saved) }
    return fresh
}

private func statusText(_ index: AIWorkIndex) -> String {
    let excerpts = index.passages.filter { $0.summaryOrigin == .excerpt }.count
    if index.passages.isEmpty { return L10n.tr("ai.index.waiting") }
    if index.passages.contains(where: { $0.summary.isEmpty }) {
        return L10n.tr("ai.index.pending")
            .replacingOccurrences(of: "%d/%d", with: "\(index.passages.filter { !$0.summary.isEmpty }.count)/\(index.passages.count)")
    }
    if excerpts > 0 { return L10n.tr("ai.index.readyWithExcerpts").replacingOccurrences(of: "%d", with: "\(excerpts)") }
    return L10n.tr("ai.index.ready").replacingOccurrences(of: "%d", with: "\(Set(index.passages.map(\.path)).count)")
}

private func status(for url: URL) -> [String: Any] {
    switch AIWorkContext.locateResult(from: url) {
    case .failure:
        return ["kind": "corrupt"]
    case .success(nil):
        return ["kind": "notInWork"]
    case .success(let context?):
        var result: [String: Any] = ["root": windowsPath(context.rootURL), "title": context.config.title]
        if context.config.settingsSources.isEmpty { result["kind"] = "noSources" }
        else if !context.config.enabled { result["kind"] = "disabled" }
        else {
            result["kind"] = "indexed"
            result["text"] = statusText(savedIndex(context.rootURL) ?? AIWorkIndex())
        }
        return result
    }
}

@_cdecl("jena_work_status")
public func jena_work_status(_ path: UnsafePointer<CChar>, _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                             _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    respond(result, error) { try encode(status(for: fileURL(path))) }
}

/// Brings the index up to date. Takes time on a large work, so call it off the UI thread.
@_cdecl("jena_work_prepare")
public func jena_work_prepare(_ path: UnsafePointer<CChar>, _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                              _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    respond(result, error) {
        let url = fileURL(path)
        guard let context = AIWorkContext.locate(from: url), context.config.enabled else { return try encode(status(for: url)) }
        let saved = savedIndex(context.rootURL)
        var index = try AIWorkIndex.scan(context: context, split: splitReusing)
        if let saved { index.restoreSummaries(from: saved) }
        for i in index.passages.indices where index.passages[i].summary.isEmpty {
            let reason = index.passages[i].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "ai.index.blank" : "ai.index.localUnavailable"
            let excerpt = AIIndexSummary.excerpt(index.passages[i], reason: reason)
            index.passages[i].summary = String(excerpt.text.prefix(900))
            index.passages[i].summaryOrigin = excerpt.origin
            index.passages[i].summaryIssue = excerpt.issue
        }
        // Opening a file should not rewrite a shared folder's index when nothing changed. It would
        // sync the whole file again, and tell a Mac to redo its excerpts for nothing.
        if let saved, saved.passages == index.passages { return try encode(status(for: url)) }
        index.summaryAvailability = excerptSignature
        let target = indexURL(context.rootURL)
        guard AIWorkContext.isSafeInsideRoot(target, root: context.rootURL) else { throw AIWorkContextError.corrupt }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(index).write(to: target, options: .atomic)
        return try encode(status(for: url))
    }
}

// MARK: - Evidence search

private final class WorkSession {
    let session: AIWorkRetrievalSession
    let context: AIWorkContext
    let file: URL
    init(session: AIWorkRetrievalSession, context: AIWorkContext, file: URL) {
        self.session = session
        self.context = context
        self.file = file
    }
}

private func describe(_ step: AIWorkRetrievalSession.Step, _ payload: inout AIWorkPayload?) throws -> String {
    switch step {
    case .ask(let prompt):
        return try encode(["prompt": prompt])
    case .finished(let finished):
        payload = finished
        return try encode(["done": true])
    }
}

private var finishedPayloads: [UnsafeMutableRawPointer: AIWorkPayload] = [:]

/// Null without an error means the document is not in an enabled work, so a plain request is right.
/// `request` is `{"path", "document", "request", "history": [...], "open": {path: text}}`.
@_cdecl("jena_work_session_open")
public func jena_work_session_open(_ request: UnsafePointer<CChar>, _ handle: UnsafeMutablePointer<UnsafeMutableRawPointer?>,
                                   _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    requestLock.lock()
    defer { requestLock.unlock() }
    handle.pointee = nil
    do {
        let object = try JSONSerialization.jsonObject(with: Data(String(cString: request).utf8)) as? [String: Any] ?? [:]
        let url = URL(fileURLWithPath: object["path"] as? String ?? "")
        guard let context = AIWorkContext.locate(from: url), context.config.enabled, !context.config.settingsSources.isEmpty else { return 0 }
        useOpenTexts(object["open"])
        let resolved = AIWorkContextResolver.resolve(context, currentFile: url)
        let passages = try freshIndex(context).eligible(for: resolved)
        let history = (object["history"] as? [[String: Any]] ?? []).map {
            AIChatMessage(role: $0["role"] as? String ?? "", text: $0["text"] as? String ?? "")
        }
        let session = AIWorkRetrievalSession(passages: passages, title: context.config.title, currentEpisode: url.lastPathComponent,
                                             document: object["document"] as? String ?? "", question: object["request"] as? String ?? "",
                                             history: history)
        handle.pointee = Unmanaged.passRetained(WorkSession(session: session, context: context, file: url)).toOpaque()
        return 0
    } catch let failure {
        error.pointee = duplicate(message(for: failure))
        return -1
    }
}

private func workSession(_ handle: UnsafeMutableRawPointer) -> WorkSession {
    Unmanaged<WorkSession>.fromOpaque(handle).takeUnretainedValue()
}

/// The result is `{"prompt"}` for one more question to the CLI, or `{"done": true}`.
@_cdecl("jena_work_session_start")
public func jena_work_session_start(_ handle: UnsafeMutableRawPointer, _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                                    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    respond(result, error) {
        var payload: AIWorkPayload?
        let text = try describe(try workSession(handle).session.start(), &payload)
        requestLock.lock()
        finishedPayloads[handle] = payload
        requestLock.unlock()
        return text
    }
}

@_cdecl("jena_work_session_receive")
public func jena_work_session_receive(_ handle: UnsafeMutableRawPointer, _ answer: UnsafePointer<CChar>,
                                      _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                                      _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    respond(result, error) {
        var payload: AIWorkPayload?
        let text = try describe(try workSession(handle).session.receive(answer: String(cString: answer)), &payload)
        requestLock.lock()
        finishedPayloads[handle] = payload
        requestLock.unlock()
        return text
    }
}

/// The final request and the passages it read. Refused if the work's setup changed meanwhile.
@_cdecl("jena_work_session_prompt")
public func jena_work_session_prompt(_ handle: UnsafeMutableRawPointer, _ request: UnsafePointer<CChar>,
                                     _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                                     _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    respond(result, error) {
        let current = workSession(handle)
        requestLock.lock()
        let payload = finishedPayloads[handle]
        requestLock.unlock()
        guard let payload, AIWorkContext.locate(from: current.file) == current.context else {
            throw AIError(message: L10n.tr("ai.index.changed"))
        }
        let object = try JSONSerialization.jsonObject(with: Data(String(cString: request).utf8)) as? [String: Any] ?? [:]
        let history = (object["history"] as? [[String: Any]] ?? []).map {
            AIChatMessage(role: $0["role"] as? String ?? "", text: $0["text"] as? String ?? "")
        }
        let prompt = try AIWorkPrompt.make(document: object["document"] as? String ?? "", selectedText: object["selectedText"] as? String ?? "",
                                           messages: history, request: object["request"] as? String ?? "",
                                           mode: object["mode"] as? String == "edit" ? .edit : .guide, work: payload)
        return try encode(["prompt": prompt, "consulted": current.session.consulted])
    }
}

@_cdecl("jena_work_session_close")
public func jena_work_session_close(_ handle: UnsafeMutableRawPointer) {
    requestLock.lock()
    finishedPayloads[handle] = nil
    requestLock.unlock()
    Unmanaged<WorkSession>.fromOpaque(handle).release()
}

// MARK: - Setting up a work

private func configJSON(_ config: AIWorkContextConfig) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(config))
}

private func stateJSON(_ context: AIWorkContext, provisional: Bool, error: String? = nil) throws -> String {
    var object: [String: Any] = ["root": windowsPath(context.rootURL), "config": try configJSON(context.config), "provisional": provisional]
    if let error { object["error"] = error }
    return try encode(object)
}

/// A saved work for this file, or a suggested one that is not written until it is valid.
@_cdecl("jena_work_window_open")
public func jena_work_window_open(_ path: UnsafePointer<CChar>, _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                                  _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    respond(result, error) {
        let url = fileURL(path)
        if let context = AIWorkContext.locate(from: url) { return try stateJSON(context, provisional: false) }
        let suggestion = AIWorkContextSuggestion.make(for: url)
        let root = suggestion.rootURL
        if let saved = try? AIWorkContext.load(rootURL: root) { return try stateJSON(saved, provisional: false) }
        var config = AIWorkContextConfig(title: suggestion.title, settingsSources: [],
                                         writingFolder: AIWorkContext.relativePath(of: suggestion.writingFolderURL, to: root) ?? "", enabled: false)
        // The suggested settings folder is listed from the start, as on macOS.
        if let settings = suggestion.settingsSourceURL { try? AIWorkContextEdits.addingSource(settings, to: &config, root: root) }
        return try stateJSON(AIWorkContextEdits.withInvalidPaths(AIWorkContext(rootURL: root, config: config, invalidPaths: [])), provisional: true)
    }
}

private func decodeConfig(_ text: UnsafePointer<CChar>) throws -> AIWorkContextConfig {
    try JSONDecoder().decode(AIWorkContextConfig.self, from: Data(String(cString: text).utf8))
}

/// Rows for the window: what the sources yield, and what the index holds.
@_cdecl("jena_work_window_describe")
public func jena_work_window_describe(_ rootPath: UnsafePointer<CChar>, _ config: UnsafePointer<CChar>, _ current: UnsafePointer<CChar>,
                                      _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                                      _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    respond(result, error) {
        try AIWorkContext.withPathCache {
        let root = URL(fileURLWithPath: String(cString: rootPath), isDirectory: true)
        let context = AIWorkContextEdits.withInvalidPaths(AIWorkContext(rootURL: root, config: try decodeConfig(config), invalidPaths: []))
        let resolved = AIWorkContextResolver.resolve(context, currentFile: fileURL(current))
        let excluded = Set(context.config.excludedSettings)
        let unreadable = Set(resolved.unreadable.map(\.relativePath))
        let files = AIWorkContextResolver.naturalSort(resolved.settings + resolved.unreadable + resolved.excludedSettings)
        let sources: [[String: Any]] = context.config.settingsSources.map { path in
            let url = path.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return ["path": path, "exists": exists, "isDirectory": exists && isDirectory.boolValue,
                    "fileCount": exists && isDirectory.boolValue ? AIWorkContextResolver.files(under: url, recursive: true).count : 0]
        }
        let index = savedIndex(root) ?? AIWorkIndex()
        var chunksByPath: [String: (ready: Int, total: Int)] = [:]
        for passage in index.passages where !passage.isSetting {
            var counts = chunksByPath[passage.path] ?? (0, 0)
            counts.total += 1
            if !passage.summary.isEmpty { counts.ready += 1 }
            chunksByPath[passage.path] = counts
        }
        let previous: [[String: Any]] = resolved.previousEpisodes.compactMap { file in
            guard let path = AIWorkContext.relativePath(of: file.url, to: root) else { return nil }
            let counts = chunksByPath[path] ?? (0, 0)
            return ["path": path, "ready": counts.ready, "total": counts.total]
        }
        let reasons = Set(index.passages.compactMap(\.summaryIssue)).sorted().map { L10n.tr($0) }
        return try encode([
            "sources": sources,
            "files": files.map { ["path": $0.relativePath, "bytes": $0.byteCount, "included": !excluded.contains($0.relativePath),
                                  "unreadable": unreadable.contains($0.relativePath)] as [String: Any] },
            "included": resolved.settings.count,
            "invalidPaths": context.invalidPaths,
            "status": statusText(index),
            "counts": L10n.tr("ai.index.localCounts")
                .replacingOccurrences(of: "%d", with: "\(index.passages.filter { $0.summaryOrigin == .apple }.count)", range: L10n.tr("ai.index.localCounts").range(of: "%d"))
                .replacingOccurrences(of: "%d", with: "\(index.passages.filter { $0.summaryOrigin == .excerpt }.count)"),
            "reasons": reasons,
            "previous": previous,
        ] as [String: Any])
        }
    }
}

/// Applies one change, the way the macOS window does: on top of what is on disk now, and saved as
/// soon as the result is valid. A new work is written only once it has a source to read.
/// `edit` is `{"op": ..., "path"/"title"/"on": ...}`. The result is the new state, with `error` if refused.
@_cdecl("jena_work_window_edit")
public func jena_work_window_edit(_ rootPath: UnsafePointer<CChar>, _ config: UnsafePointer<CChar>, _ provisional: Int32, _ edit: UnsafePointer<CChar>,
                                  _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                                  _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    respond(result, error) {
        let root = URL(fileURLWithPath: String(cString: rootPath), isDirectory: true)
        let current = AIWorkContext(rootURL: root, config: try decodeConfig(config), invalidPaths: [])
        var isProvisional = provisional != 0
        let request = try JSONSerialization.jsonObject(with: Data(String(cString: edit).utf8)) as? [String: Any] ?? [:]
        let op = request["op"] as? String ?? ""
        let path = request["path"] as? String ?? ""
        let chosen = URL(fileURLWithPath: path)

        var base = current
        if !isProvisional, let disk = try? AIWorkContext.load(rootURL: root) { base = disk }
        var updated = base.config

        func refuse(_ text: String) throws -> String { try stateJSON(current, provisional: isProvisional, error: text) }

        if op == "setRoot" {
            let newRoot = URL(fileURLWithPath: path, isDirectory: true)
            let same = newRoot.standardizedFileURL.path.lowercased() == root.standardizedFileURL.path.lowercased()
            if !same, FileManager.default.fileExists(atPath: newRoot.appendingPathComponent(AIWorkContext.folderName).appendingPathComponent(AIWorkContext.fileName).path) {
                return try refuse(L10n.tr("ai.work.folders.errorRootHasContext"))
            }
            let writing = base.writingFolderURL ?? root
            guard let relative = AIWorkContext.relativePath(of: writing, to: newRoot) else {
                return try refuse(L10n.tr("ai.work.errorOutsideRoot").replacingOccurrences(of: "%@", with: windowsPath(newRoot)))
            }
            updated.settingsSources = updated.settingsSources.map { AIWorkContextEdits.rebase($0, from: root, to: newRoot) }
            updated.excludedSettings = updated.excludedSettings.map { AIWorkContextEdits.rebase($0, from: root, to: newRoot) }
            updated.summarizedSettings = updated.summarizedSettings.map { AIWorkContextEdits.rebase($0, from: root, to: newRoot) }
            updated.writingFolder = relative
            let moved = AIWorkContextEdits.withInvalidPaths(AIWorkContext(rootURL: newRoot, config: updated, invalidPaths: []))
            if !isProvisional {
                try moved.save()
                // The nearest context wins when looking for a work, so the old one must go.
                let old = root.appendingPathComponent(AIWorkContext.folderName).appendingPathComponent(AIWorkContext.fileName)
                if !same, AIWorkContext.isSafeInsideRoot(old, root: root) { try? FileManager.default.removeItem(at: old) }
            }
            return try stateJSON(moved, provisional: isProvisional)
        }

        do {
            switch op {
            case "addSource": try AIWorkContextEdits.addingSource(chosen, to: &updated, root: root)
            case "removeSource": AIWorkContextEdits.removingSource(path, from: &updated)
            case "toggleInclude": AIWorkContextEdits.toggleIncluded(&updated, path: path)
            case "setWriting":
                guard let relative = AIWorkContext.relativePath(of: chosen, to: root) else {
                    throw AIWorkContextValidationError.settingsOutsideRoot(windowsPath(chosen))
                }
                updated.writingFolder = relative
            case "setTitle":
                let title = (request["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { updated.title = title }
            case "setEnabled":
                let on = request["on"] as? Bool == true
                updated.disabledByUser = !on
                updated.enabled = on && !updated.settingsSources.isEmpty
            default:
                throw AIError(message: "unknown edit")
            }
        } catch let failure {
            return try refuse(message(for: failure))
        }

        let next = AIWorkContextEdits.withInvalidPaths(AIWorkContext(rootURL: root, config: updated, invalidPaths: []))
        let problems = AIWorkContext.validate(rootURL: root, settingsSources: next.settingsSourceURLs, writingFolder: next.writingFolderURL ?? root)
        let writingOK = next.writingFolderURL != nil && !problems.contains(.writingFolderOutsideRoot)
        if writingOK, !isProvisional || (problems.isEmpty && !next.config.settingsSources.isEmpty) {
            do {
                try next.save()
                isProvisional = false
            } catch let failure {
                return try stateJSON(next, provisional: isProvisional,
                                     error: L10n.tr("ai.work.saveFailed").replacingOccurrences(of: "%@", with: message(for: failure)))
            }
        }
        return try stateJSON(next, provisional: isProvisional)
    }
}

/// An unreadable context moves aside, so first setup can never overwrite it.
@_cdecl("jena_work_set_corrupt_aside")
public func jena_work_set_corrupt_aside(_ path: UnsafePointer<CChar>, _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    guard let root = AIWorkContext.locateRoot(from: fileURL(path)) else { return 0 }
    let folder = root.appendingPathComponent(AIWorkContext.folderName)
    let config = folder.appendingPathComponent(AIWorkContext.fileName)
    let backup = folder.appendingPathComponent(AIWorkContext.fileName + ".bak")
    do {
        guard AIWorkContext.isSafeInsideRoot(config, root: root), AIWorkContext.isSafeInsideRoot(backup, root: root) else {
            throw AIError(message: L10n.tr("ai.work.errorOutsideRoot").replacingOccurrences(of: "%@", with: config.path))
        }
        if FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.removeItem(at: backup) }
        try FileManager.default.moveItem(at: config, to: backup)
        return 0
    } catch let failure {
        error.pointee = duplicate(L10n.tr("ai.work.saveFailed").replacingOccurrences(of: "%@", with: message(for: failure)))
        return -1
    }
}
