import Foundation

/// Runs the shared evidence search with a CLI: one call per step, under one overall deadline.
final class AIWorkRetrieval {
    typealias Generate = (String, AIProvider, String?, @escaping (Result<String, Error>, Int) -> Void) -> (() -> Void)
    typealias Command = AIWorkRetrievalSession.Command
    static let maximumRounds = AIWorkRetrievalSession.maximumRounds
    static let evidenceBytes = AIWorkRetrievalSession.evidenceBytes
    static let pageSize = AIWorkRetrievalSession.pageSize
    static let directPassageLimit = AIWorkRetrievalSession.directPassageLimit
    private(set) var tokensUsed = 0
    private(set) var consulted: [String] = []
    private var cancelled = false
    private var cancelCall: (() -> Void)?
    private let generate: Generate
    private var deadline: DispatchWorkItem?
    private var completed = false

    init(generate: Generate? = nil) {
        self.generate = generate ?? { prompt, provider, model, completion in
            let client = AIClient()
            client.send(provider: provider, prompt: prompt, model: model) { result in
                completion(result, client.tokenUsage ?? 0)
            }
            return { client.cancel() }
        }
    }

    func cancel() { cancelled = true; deadline?.cancel(); deadline = nil; cancelCall?(); cancelCall = nil }

    static func decode(_ answer: String) throws -> Command { try AIWorkRetrievalSession.decode(answer) }

    static func page(_ number: Int, passages: [AIIndexedPassage]) -> [[String: Any]] {
        AIWorkRetrievalSession.page(number, passages: passages)
    }

    static func searchTerms(_ text: String) -> [String] { AIWorkRetrievalSession.searchTerms(text) }

    static func localCandidates(passages: [AIIndexedPassage], question: String,
                                document: String, history: [AIChatMessage] = []) -> [AIIndexedPassage] {
        AIWorkRetrievalSession.localCandidates(passages: passages, question: question, document: document, history: history)
    }

    func prepare(passages: [AIIndexedPassage], title: String, currentEpisode: String,
                 document: String, question: String, history: [AIChatMessage] = [], provider: AIProvider, model: String?,
                 prioritize: (([AIIndexedPassage]) -> Void)? = nil,
                 completion: @escaping (Result<AIWorkPayload, Error>) -> Void) {
        guard !cancelled else { return }
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let session = AIWorkRetrievalSession(passages: passages, title: title, currentEpisode: currentEpisode,
                                                 document: document, question: question, history: history, started: started)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.cancelled, !self.completed else { return }
                self.run(session, provider: provider, model: model, prioritize: prioritize, completion: completion)
            }
        }
    }

    private func run(_ session: AIWorkRetrievalSession, provider: AIProvider, model: String?,
                     prioritize: (([AIIndexedPassage]) -> Void)?,
                     completion: @escaping (Result<AIWorkPayload, Error>) -> Void) {
        let complete: (Result<AIWorkPayload, Error>) -> Void = { [weak self] result in
            guard let self, !self.cancelled, !self.completed else { return }
            self.completed = true
            self.deadline?.cancel()
            self.deadline = nil
            self.cancelCall = nil
            completion(result)
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !self.completed, !self.cancelled else { return }
            self.cancelCall?()
            complete(.failure(AIError(message: L10n.tr("ai.timeout"))))
        }
        deadline = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + AIWorkRetrievalSession.timeLimit, execute: timeout)
        prioritize?(session.candidates)

        func handle(_ step: AIWorkRetrievalSession.Step) {
            switch step {
            case .finished(let payload):
                prioritize?(session.selected)
                self.consulted = session.consulted
                complete(.success(payload))
            case .ask(let prompt):
                self.cancelCall = self.generate(prompt, provider, model) { result, tokens in
                    DispatchQueue.main.async {
                        guard !self.cancelled, !self.completed else { return }
                        self.tokensUsed += tokens
                        do {
                            handle(try session.receive(answer: result.get()))
                        } catch { complete(.failure(error)) }
                    }
                }
            }
        }
        do {
            handle(try session.start())
        } catch { complete(.failure(error)) }
    }
}
