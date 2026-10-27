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

/// Cache of AI summaries for earlier episodes (and summarized settings files) under
/// `<root>/.jenanote/summaries/`. Main-thread only.
///
/// Concurrency policy: one queue at a time per store. A `prepare`/`regenerate` call made while
/// `isGenerating` is true fails fast with `ai.work.generatingElsewhere` instead of queueing behind.
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

    private struct Run {
        let id: Int
        let generator: AISummaryGenerating
        let jobs: [Job]
        let provider: AIProvider
        let model: String?
        let progress: (Int, Int) -> Void
        let completion: (Result<Int, Error>) -> Void
    }

    private var run: Run?
    private var runCounter = 0
    private var tokens = 0
    private(set) var isGenerating = false

    func prepare(episodes: [AIWorkFile], settings: [AIWorkFile], provider: AIProvider, model: String?,
                 progress: @escaping (Int, Int) -> Void,
                 completion: @escaping (Result<Int, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isGenerating else { return completion(.failure(Self.busyError)) }
        let jobs = pending(episodes, isSetting: false).map { Job(file: $0, isSetting: false) }
            + pending(settings, isSetting: true).map { Job(file: $0, isSetting: true) }
        guard !jobs.isEmpty else { return completion(.success(0)) }
        start(jobs: jobs, provider: provider, model: model, progress: progress, completion: completion)
    }

    func regenerate(_ file: AIWorkFile, isSetting: Bool, provider: AIProvider, model: String?,
                    completion: @escaping (Result<Int, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isGenerating else { return completion(.failure(Self.busyError)) }
        if isSummaryOpenAndDirty(file, isSetting: isSetting) {
            return completion(.failure(AIError(message: L10n.tr("ai.work.summaryOpenDirty"))))
        }
        start(jobs: [Job(file: file, isSetting: isSetting)], provider: provider, model: model,
              progress: { _, _ in }, completion: completion)
    }

    func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let current = run else { return }
        current.generator.cancel()
        finish(current.id, .failure(AIError(message: L10n.tr("ai.cancelled"))))
    }

    private static var busyError: AIError { AIError(message: L10n.tr("ai.work.generatingElsewhere")) }

    private func start(jobs: [Job], provider: AIProvider, model: String?,
                       progress: @escaping (Int, Int) -> Void,
                       completion: @escaping (Result<Int, Error>) -> Void) {
        runCounter += 1
        tokens = 0
        isGenerating = true
        run = Run(id: runCounter, generator: makeGenerator(), jobs: jobs, provider: provider, model: model,
                  progress: progress, completion: completion)
        step(runCounter, at: 0)
    }

    private func step(_ id: Int, at position: Int) {
        guard let current = run, current.id == id else { return }
        guard position < current.jobs.count else { return finish(id, .success(tokens)) }
        let job = current.jobs[position]
        let source: String
        let prompt: String
        do {
            source = try AIWorkContextResolver.readText(job.file)
            prompt = try AIPrompt.makeSummary(episodeName: job.file.relativePath, text: source)
        } catch {
            return finish(id, .failure(error))
        }
        current.generator.summarize(prompt: prompt, provider: current.provider, model: current.model) { [weak self] result in
            guard let self = self, let active = self.run, active.id == id else { return } // cancelled or superseded
            do {
                let summary = try result.get()
                try self.store(summary: summary, source: source, for: job, provider: active.provider)
                self.tokens += active.generator.tokenUsage ?? 0
                active.progress(position + 1, active.jobs.count)
                self.step(id, at: position + 1)
            } catch {
                self.finish(id, .failure(error))
            }
        }
    }

    private func store(summary: String, source: String, for job: Job, provider: AIProvider) throws {
        // Re-check at write time: the summary document may have been opened and edited meanwhile.
        if isSummaryOpenAndDirty(job.file, isSetting: job.isSetting) {
            throw AIError(message: L10n.tr("ai.work.summaryOpenDirty"))
        }
        let url = summaryURL(for: job.file, isSetting: job.isSetting)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try summary.write(to: url, atomically: true, encoding: .utf8)
        var index = loadIndex()
        let record = AISummaryRecord(sourceHash: Self.hash(source), summaryHash: Self.summaryHash(summary),
                                     generatedAt: Date(), provider: provider.rawValue)
        if job.isSetting { index.settings[job.file.relativePath] = record } else { index.entries[job.file.relativePath] = record }
        try saveIndex(index)
    }

    private func finish(_ id: Int, _ result: Result<Int, Error>) {
        guard let current = run, current.id == id else { return }
        run = nil
        isGenerating = false
        current.completion(result)
    }

    private func isSummaryOpenAndDirty(_ file: AIWorkFile, isSetting: Bool) -> Bool {
        let target = summaryURL(for: file, isSetting: isSetting).standardizedFileURL.resolvingSymlinksInPath()
        return Self.openDocuments().contains {
            $0.isDocumentEdited && $0.fileURL?.standardizedFileURL.resolvingSymlinksInPath() == target
        }
    }
}
