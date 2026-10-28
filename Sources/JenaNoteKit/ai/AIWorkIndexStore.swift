import Foundation

/// Main-queue ownership; disk scans run off the UI thread. One generation queue per work.
final class AIWorkIndexStore {
    static let changed = Notification.Name("JenaNoteWorkIndexChanged")
    static var automaticPreparationEnabled = !ProcessInfo.processInfo.arguments.contains { $0.contains(".xctest") }
    private static var stores: [String: AIWorkIndexStore] = [:]
    static func shared(for root: URL) -> AIWorkIndexStore {
        let key = root.standardizedFileURL.path
        if let store = stores[key] { return store }
        let store = AIWorkIndexStore(root: root)
        stores[key] = store
        return store
    }

    typealias Generate = (AIIndexedPassage, @escaping (Result<AIIndexSummary, Error>) -> Void) -> (() -> Void)
    let root: URL
    private(set) var index = AIWorkIndex()
    private(set) var isRunning = false
    private(set) var done = 0
    private(set) var total = 0
    private(set) var error: String?
    private var cancelGeneration: (() -> Void)?
    private var generation = UUID()
    private var waiters: [(Result<AIWorkIndex, Error>) -> Void] = []
    private var needsRescan = false
    private var activeContext: AIWorkContext?
    private var debounce: DispatchWorkItem?
    var generate: Generate
    var availability: () -> AIWorkLocalSummarizer.Availability
    private var activeAvailability = AIWorkLocalSummarizer.Availability.available
    private var retryExcerpts = false
    private var priorityKeys: [String] = []
    private var currentPath: String?
    private(set) var hasSearchSnapshot = false
    private var completedSinceSave = 0
    private var lastSavedAt = Date.distantPast
    private var pendingSave: DispatchWorkItem?
    private(set) var persistenceCount = 0

    var excerptCount: Int { index.passages.filter { $0.summaryOrigin == .excerpt }.count }
    var summaryCount: Int { index.passages.filter { $0.summaryOrigin == .apple }.count }

    var statusText: String {
        if isRunning && !hasSearchSnapshot { return L10n.tr("ai.index.waiting") }
        if isRunning { return String(format: L10n.tr("ai.index.preparing"), done, total) }
        if let error { return L10n.tr(hasSearchSnapshot ? "ai.index.summaryStopped" : "ai.index.failed") + " " + error }
        if index.passages.contains(where: { $0.summary.isEmpty }) {
            return String(format: L10n.tr("ai.index.pending"), index.passages.filter { !$0.summary.isEmpty }.count, index.passages.count)
        }
        if excerptCount > 0 { return String(format: L10n.tr("ai.index.readyWithExcerpts"), excerptCount) }
        return String(format: L10n.tr("ai.index.ready"), Set(index.passages.map(\.path)).count)
    }

    init(root: URL, generate: Generate? = nil,
         availability: (() -> AIWorkLocalSummarizer.Availability)? = nil) {
        self.root = root
        self.generate = generate ?? AIWorkLocalSummarizer.shared.generate
        self.availability = availability ?? (generate == nil ? AIWorkLocalSummarizer.availability : { .available })
        let url = root.appendingPathComponent(".jenanote/work-index.json")
        if AIWorkContext.isSafeInsideRoot(url, root: root),
           let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(AIWorkIndex.self, from: data),
           saved.version == AIWorkIndex.version { index = saved }
    }

    static func prepareDocument(_ url: URL?) {
        guard let url, let context = AIWorkContext.locate(from: url) else { return }
        let store = shared(for: context.rootURL)
        guard context.config.enabled else { store.cancel(); return }
        store.prioritizeDocument(url)
        store.schedule(context: context)
    }

    /// A fresh read snapshot is independent of the potentially hours-long summary queue.
    func prepareForSearch(context: AIWorkContext,
                          completion: @escaping (Result<AIWorkIndex, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard context.config.enabled else {
            completion(.failure(AIError(message: L10n.tr("ai.cancelled"))))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try AIWorkIndex.scan(context: context) }
            DispatchQueue.main.async {
                completion(result.map { fresh in
                    var snapshot = fresh
                    self.restoreSummaries(into: &snapshot)
                    if self.isRunning && self.activeContext == context && self.hasSearchSnapshot,
                       snapshot.passages.map(\.id) != self.index.passages.map(\.id) {
                        self.needsRescan = true
                    }
                    return snapshot
                })
            }
        }
    }

    func prioritizeDocument(_ url: URL) {
        currentPath = AIWorkContext.relativePath(of: url, to: root)
    }

    func prioritize(_ passages: [AIIndexedPassage]) {
        // Bound recent request state; repeated questions must not grow the queue indefinitely.
        var seen = Set<String>()
        priorityKeys = Array((passages.map(\.cacheKey) + priorityKeys).filter { seen.insert($0).inserted }.prefix(64))
    }

    private func nextPosition() -> Int? {
        for key in priorityKeys {
            if let position = index.passages.firstIndex(where: { $0.cacheKey == key && $0.summary.isEmpty }) { return position }
        }
        if let currentPath {
            var seen = Set<String>()
            let paths = index.passages.filter { !$0.isSetting }.map(\.path).filter { seen.insert($0).inserted }
            var preferred = [currentPath]
            if let current = paths.firstIndex(of: currentPath), current > 0 { preferred.append(paths[current - 1]) }
            for path in preferred {
                if let position = index.passages.firstIndex(where: { $0.path == path && $0.summary.isEmpty }) { return position }
            }
        }
        return index.passages.firstIndex { $0.summary.isEmpty }
    }

    private func restoreSummaries(into fresh: inout AIWorkIndex, retryExcerpts: Bool = false) {
        var cached: [String: AIIndexedPassage] = [:]
        for passage in index.passages where !passage.summary.isEmpty {
            if retryExcerpts && passage.summaryOrigin == .excerpt { continue }
            cached[passage.cacheKey] = passage
        }
        for i in fresh.passages.indices {
            if let saved = cached[fresh.passages[i].cacheKey] {
                fresh.passages[i].summary = saved.summary
                fresh.passages[i].summaryOrigin = saved.summaryOrigin
                fresh.passages[i].summaryIssue = saved.summaryIssue
            }
        }
    }

    func schedule(context: AIWorkContext) {
        // UI construction in unit tests must never start real model inference.
        guard Self.automaticPreparationEnabled else { return }
        if isRunning && activeContext != context { cancel() }
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.ensure(context: context) { _ in }
        }
        debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
    }

    func ensure(context: AIWorkContext, retryExcerpts: Bool = false,
                completion: @escaping (Result<AIWorkIndex, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        debounce?.cancel()
        guard context.config.enabled else {
            cancel()
            completion(.failure(AIError(message: L10n.tr("ai.cancelled"))))
            return
        }
        if isRunning {
            // A changed source list must never receive the old run's eligibility snapshot.
            if activeContext != context { cancel() }
            else {
                needsRescan = true
                self.retryExcerpts = self.retryExcerpts || retryExcerpts
                waiters.append(completion)
                return
            }
        }
        waiters.append(completion)
        activeContext = context
        self.retryExcerpts = retryExcerpts
        activeAvailability = availability()
        isRunning = true
        error = nil
        done = 0
        total = 0
        hasSearchSnapshot = false
        let token = UUID()
        generation = token
        needsRescan = false
        notify()
        scan(context: context, token: token)
    }

    private func scan(context: AIWorkContext, token: UUID) {
        DispatchQueue.global(qos: .utility).async {
            let scan = Result { try AIWorkIndex.scan(context: context) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                switch scan {
                case .failure(let error): self.finish(.failure(error))
                case .success(var fresh):
                    let availabilityChanged = self.index.summaryAvailability != self.activeAvailability.signature
                    self.restoreSummaries(into: &fresh, retryExcerpts: self.retryExcerpts || availabilityChanged)
                    fresh.summaryAvailability = self.activeAvailability.signature
                    self.retryExcerpts = false
                    self.index = fresh
                    self.total = fresh.passages.count
                    self.done = fresh.passages.filter { !$0.summary.isEmpty }.count
                    self.hasSearchSnapshot = true
                    do { try self.persist() } catch { self.finish(.failure(error)); return }
                    self.next(token: token)
                }
            }
        }
    }

    private func next(token: UUID) {
        guard generation == token else { return }
        if completedSinceSave >= 8 || (completedSinceSave > 0 && Date().timeIntervalSince(lastSavedAt) >= 5) {
            do { try persist() } catch { finish(.failure(error)); return }
        }
        notify()
        if needsRescan, let context = activeContext {
            needsRescan = false
            scan(context: context, token: token)
            return
        }
        guard let position = nextPosition() else {
            finish(.success(index))
            return
        }
        let passage = index.passages[position]
        let completion: (Result<AIIndexSummary, Error>) -> Void = { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.cancelGeneration = nil
                switch result {
                case .failure(let error): self.finish(.failure(error))
                case .success(let summary):
                    let cleaned = summary.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleaned.isEmpty else { self.finish(.failure(AIError(message: L10n.tr("ai.invalidResponse")))); return }
                    for i in self.index.passages.indices where self.index.passages[i].cacheKey == passage.cacheKey {
                        self.index.passages[i].summary = String(cleaned.prefix(900))
                        self.index.passages[i].summaryOrigin = summary.origin
                        self.index.passages[i].summaryIssue = summary.issue
                    }
                    self.done = self.index.passages.filter { !$0.summary.isEmpty }.count
                    self.completedSinceSave += 1
                    self.scheduleSave(token: token)
                    self.next(token: token)
                }
            }
        }
        if passage.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            completion(.success(.excerpt(passage, reason: "ai.index.blank")))
            return
        }
        switch activeAvailability {
        case .available: cancelGeneration = generate(passage, completion)
        case .unavailable(let reason): completion(.success(.excerpt(passage, reason: reason)))
        }
    }

    private func scheduleSave(token: UUID) {
        guard pendingSave == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, self.isRunning else { return }
            self.pendingSave = nil
            do { try self.persist() } catch {
                self.generation = UUID()
                self.cancelGeneration?()
                self.cancelGeneration = nil
                self.finish(.failure(error))
            }
        }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
    }

    private func persist() throws {
        pendingSave?.cancel()
        pendingSave = nil
        let folder = root.appendingPathComponent(".jenanote")
        let url = folder.appendingPathComponent("work-index.json")
        guard AIWorkContext.isSafeInsideRoot(url, root: root) else { throw AIWorkContextError.corrupt }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        index.updatedAt = Date()
        try JSONEncoder().encode(index).write(to: url, options: .atomic)
        persistenceCount += 1
        completedSinceSave = 0
        lastSavedAt = Date()
    }

    func cancel() {
        debounce?.cancel()
        pendingSave?.cancel()
        pendingSave = nil
        generation = UUID()
        cancelGeneration?()
        cancelGeneration = nil
        if isRunning { finish(.failure(AIError(message: L10n.tr("ai.cancelled")))) }
    }

    private func finish(_ result: Result<AIWorkIndex, Error>) {
        isRunning = false
        var finalResult = result
        if hasSearchSnapshot {
            do { try persist() } catch { finalResult = .failure(error) }
        }
        if case .failure(let failure) = finalResult { error = failure.localizedDescription }
        let completions = waiters
        waiters.removeAll()
        notify()
        completions.forEach { $0(finalResult) }
    }

    private func notify() { NotificationCenter.default.post(name: Self.changed, object: self) }
}
