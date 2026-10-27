import AppKit
import CryptoKit
import Foundation

protocol AISummaryGenerating: AnyObject {
    var tokenUsage: Int? { get }
    func summarize(prompt: String, provider: AIProvider, model: String?,
                   completion: @escaping (Result<String, Error>) -> Void)
    func cancel()
}

extension AIClient: AISummaryGenerating {
    func summarize(prompt: String, provider: AIProvider, model: String?,
                   completion: @escaping (Result<String, Error>) -> Void) {
        send(provider: provider, prompt: prompt, model: model, timeout: Self.summaryTimeout, completion: completion)
    }
}

struct AISummaryRecord: Codable, Equatable {
    var sourceHash: String
    var summaryHash: String
    var generatedAt: Date
    var provider: String
}

struct AISummaryIndex: Codable, Equatable {
    var version = 1
    var entries: [String: AISummaryRecord] = [:]
    var settings: [String: AISummaryRecord] = [:]
}

enum AISummaryState: Equatable {
    case missing, stale, ready, manuallyEdited(sourceChanged: Bool)
}

/// Generation failure for one file; `file` names the episode/setting that failed.
struct AISummaryGenerationError: LocalizedError {
    let file: AIWorkFile
    let underlying: Error
    var errorDescription: String? { "\(file.relativePath): \(underlying.localizedDescription)" }
}

/// Handle for one `prepare`/`regenerate` caller. `cancel()` affects only this caller: a queued
/// request is dropped, the active one stops its generator; either way the queue moves on.
final class AISummaryRequest {
    fileprivate weak var store: AIEpisodeSummaryStore?
    fileprivate init(store: AIEpisodeSummaryStore) { self.store = store }
    func cancel() { store?.cancel(self) }
}

/// Cache of AI summaries for earlier episodes (and summarized settings files) under
/// `<root>/.jenanote/summaries/`. Main-thread only.
///
/// Concurrency policy (spec §6.3): one generation run at a time per store (= per work root).
/// A `prepare`/`regenerate` call made while another run is active waits in a FIFO queue; when it
/// reaches the front its pending list is recomputed, so summaries produced by earlier callers are
/// not generated twice. Each caller gets its own `AISummaryRequest` handle to cancel only itself.
final class AIEpisodeSummaryStore {
    private static var registry: [String: AIEpisodeSummaryStore] = [:]

    static func shared(for rootURL: URL) -> AIEpisodeSummaryStore {
        dispatchPrecondition(condition: .onQueue(.main))
        let key = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        if let store = registry[key] { return store }
        let store = AIEpisodeSummaryStore(rootURL: rootURL)
        registry[key] = store
        return store
    }

    /// Reuses the resolver's injectable hook; there is a single source of open documents.
    static var openDocuments: () -> [MarkdownDocument] {
        get { AIWorkContextResolver.openDocuments }
        set { AIWorkContextResolver.openDocuments = newValue }
    }

    let rootURL: URL
    private let makeGenerator: () -> AISummaryGenerating

    init(rootURL: URL, makeGenerator: @escaping () -> AISummaryGenerating = { AIClient() }) {
        self.rootURL = rootURL
        self.makeGenerator = makeGenerator
    }

    // MARK: - Hashing

    static func hash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(AIWorkContextResolver.normalize(text).utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func summaryHash(_ text: String) -> String {
        hash(AIWorkContextResolver.normalize(text).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Locations

    var summariesURL: URL {
        rootURL.appendingPathComponent(".jenanote", isDirectory: true)
            .appendingPathComponent("summaries", isDirectory: true)
    }

    var indexURL: URL { summariesURL.appendingPathComponent("index.json") }

    func summaryURL(for file: AIWorkFile, isSetting: Bool) -> URL {
        let base = isSetting ? summariesURL.appendingPathComponent("settings", isDirectory: true) : summariesURL
        return base.appendingPathComponent(file.relativePath + ".txt")
    }

    // MARK: - Index

    func loadIndex() -> AISummaryIndex {
        // Missing or corrupt index counts as empty: summaries are regenerable.
        guard let data = try? Data(contentsOf: indexURL) else { return AISummaryIndex() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(AISummaryIndex.self, from: data)) ?? AISummaryIndex()
    }

    private func saveIndex(_ index: AISummaryIndex) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: summariesURL, withIntermediateDirectories: true)
        try encoder.encode(index).write(to: indexURL, options: .atomic)
    }

    private func record(for file: AIWorkFile, isSetting: Bool, in index: AISummaryIndex) -> AISummaryRecord? {
        isSetting ? index.settings[file.relativePath] : index.entries[file.relativePath]
    }

    // MARK: - State

    func summaryText(for file: AIWorkFile, isSetting: Bool) -> String? {
        guard let data = try? Data(contentsOf: summaryURL(for: file, isSetting: isSetting)),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return AIWorkContextResolver.normalize(text)
    }

    func state(of file: AIWorkFile, isSetting: Bool) -> AISummaryState {
        guard let record = record(for: file, isSetting: isSetting, in: loadIndex()),
              let summary = summaryText(for: file, isSetting: isSetting) else { return .missing }
        let sourceHash = (try? AIWorkContextResolver.readText(file)).map(Self.hash)
        let sourceChanged = sourceHash != record.sourceHash
        if Self.summaryHash(summary) != record.summaryHash { return .manuallyEdited(sourceChanged: sourceChanged) }
        return sourceChanged ? .stale : .ready
    }

    func pending(_ files: [AIWorkFile], isSetting: Bool) -> [AIWorkFile] {
        files.filter {
            switch state(of: $0, isSetting: isSetting) {
            case .missing, .stale: return true
            case .ready, .manuallyEdited: return false
            }
        }
    }

    // MARK: - Generation queue

    private struct Job {
        let file: AIWorkFile
        let isSetting: Bool
    }

    private enum Work {
        case prepare(episodes: [AIWorkFile], settings: [AIWorkFile])
        case regenerate(AIWorkFile, isSetting: Bool)
    }

    private struct Caller {
        let request: AISummaryRequest
        let work: Work
        let provider: AIProvider
        let model: String?
        let progress: (Int, Int) -> Void
        let completion: (Result<Int, Error>) -> Void
    }

    private struct Run {
        let id: Int
        let caller: Caller
        let generator: AISummaryGenerating
        let jobs: [Job]
    }

    private var active: Run?
    private var queue: [Caller] = []
    private var runCounter = 0
    private var tokens = 0

    /// True while a run is active or any caller is waiting in the queue.
    var isGenerating: Bool { active != nil || !queue.isEmpty }

    /// Generates missing/stale summaries (episodes first, then settings), one file at a time.
    /// `progress(done, total)` fires after each file. On failure the run stops with an
    /// `AISummaryGenerationError`; earlier results stay on disk. With nothing pending and an idle
    /// store, `completion(.success(0))` is called synchronously. Int = summed token usage.
    @discardableResult
    func prepare(episodes: [AIWorkFile], settings: [AIWorkFile], provider: AIProvider, model: String?,
                 progress: @escaping (Int, Int) -> Void,
                 completion: @escaping (Result<Int, Error>) -> Void) -> AISummaryRequest {
        submit(.prepare(episodes: episodes, settings: settings), provider: provider, model: model,
               progress: progress, completion: completion)
    }

    /// Always regenerates (overwrites a manually edited summary). Fails with `ai.work.summaryOpenDirty`
    /// without writing if the summary document is open with unsaved changes.
    @discardableResult
    func regenerate(_ file: AIWorkFile, isSetting: Bool, provider: AIProvider, model: String?,
                    completion: @escaping (Result<Int, Error>) -> Void) -> AISummaryRequest {
        submit(.regenerate(file, isSetting: isSetting), provider: provider, model: model,
               progress: { _, _ in }, completion: completion)
    }

    /// Cancels every caller, active and queued (refresh-all / teardown). Generated summaries stay cached.
    func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        let waiting = queue
        queue.removeAll()
        if let run = active {
            run.generator.cancel()
            finish(run.id, Self.cancelled)
        }
        waiting.forEach { $0.completion(Self.cancelled) }
    }

    fileprivate func cancel(_ request: AISummaryRequest) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let index = queue.firstIndex(where: { $0.request === request }) {
            queue.remove(at: index).completion(Self.cancelled)
        } else if let run = active, run.caller.request === request {
            run.generator.cancel()
            finish(run.id, Self.cancelled)
        }
    }

    private static var cancelled: Result<Int, Error> { .failure(AIError(message: L10n.tr("ai.cancelled"))) }

    private func submit(_ work: Work, provider: AIProvider, model: String?,
                        progress: @escaping (Int, Int) -> Void,
                        completion: @escaping (Result<Int, Error>) -> Void) -> AISummaryRequest {
        dispatchPrecondition(condition: .onQueue(.main))
        let request = AISummaryRequest(store: self)
        queue.append(Caller(request: request, work: work, provider: provider, model: model,
                            progress: progress, completion: completion))
        advance()
        return request
    }

    /// Starts the next queued caller if idle. Pending files are recomputed now, so work finished by
    /// an earlier caller is skipped; callers with nothing left to do complete immediately.
    private func advance() {
        while active == nil, !queue.isEmpty {
            let caller = queue.removeFirst()
            let jobs: [Job]
            switch caller.work {
            case .prepare(let episodes, let settings):
                jobs = pending(episodes, isSetting: false).map { Job(file: $0, isSetting: false) }
                    + pending(settings, isSetting: true).map { Job(file: $0, isSetting: true) }
            case .regenerate(let file, let isSetting):
                if isSummaryOpenAndDirty(file, isSetting: isSetting) {
                    caller.completion(.failure(AIError(message: L10n.tr("ai.work.summaryOpenDirty"))))
                    continue
                }
                jobs = [Job(file: file, isSetting: isSetting)]
            }
            guard !jobs.isEmpty else {
                caller.completion(.success(0))
                continue
            }
            runCounter += 1
            tokens = 0
            active = Run(id: runCounter, caller: caller, generator: makeGenerator(), jobs: jobs)
            step(runCounter, at: 0)
        }
    }

    private func step(_ id: Int, at position: Int) {
        guard let run = active, run.id == id else { return }
        guard position < run.jobs.count else { return finish(id, .success(tokens)) }
        let job = run.jobs[position]
        let source: String
        let prompt: String
        do {
            source = try AIWorkContextResolver.readText(job.file)
            prompt = try AIPrompt.makeSummary(episodeName: job.file.relativePath, text: source)
        } catch {
            return finish(id, .failure(AISummaryGenerationError(file: job.file, underlying: error)))
        }
        run.generator.summarize(prompt: prompt, provider: run.caller.provider, model: run.caller.model) { [weak self] result in
            guard let self = self, let current = self.active, current.id == id else { return } // cancelled
            do {
                let summary = try result.get()
                try self.store(summary: summary, source: source, for: job, provider: current.caller.provider)
                self.tokens += current.generator.tokenUsage ?? 0
                current.caller.progress(position + 1, current.jobs.count)
                self.step(id, at: position + 1)
            } catch {
                self.finish(id, .failure(AISummaryGenerationError(file: job.file, underlying: error)))
            }
        }
    }

    private func store(summary: String, source: String, for job: Job, provider: AIProvider) throws {
        // Re-check at write time: the summary document may have been opened and edited meanwhile.
        if isSummaryOpenAndDirty(job.file, isSetting: job.isSetting) {
            throw AIError(message: L10n.tr("ai.work.summaryOpenDirty"))
        }
        let key = job.file.relativePath
        var index = loadIndex()
        // Drop the old record before replacing the text: an interruption between the writes then
        // reads as `missing` (regenerated next time), never as a false `manuallyEdited`.
        let removed = job.isSetting ? index.settings.removeValue(forKey: key) : index.entries.removeValue(forKey: key)
        if removed != nil { try saveIndex(index) }
        let url = summaryURL(for: job.file, isSetting: job.isSetting)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try summary.write(to: url, atomically: true, encoding: .utf8)
        let record = AISummaryRecord(sourceHash: Self.hash(source), summaryHash: Self.summaryHash(summary),
                                     generatedAt: Date(), provider: provider.rawValue)
        if job.isSetting { index.settings[key] = record } else { index.entries[key] = record }
        try saveIndex(index)
    }

    /// Completes the active caller (only while `id` is still the active run), then moves the queue on.
    private func finish(_ id: Int, _ result: Result<Int, Error>) {
        guard let run = active, run.id == id else { return }
        active = nil
        run.caller.completion(result)
        advance()
    }

    private func isSummaryOpenAndDirty(_ file: AIWorkFile, isSetting: Bool) -> Bool {
        let target = summaryURL(for: file, isSetting: isSetting).standardizedFileURL.resolvingSymlinksInPath()
        return Self.openDocuments().contains {
            $0.isDocumentEdited && $0.fileURL?.standardizedFileURL.resolvingSymlinksInPath() == target
        }
    }
}
