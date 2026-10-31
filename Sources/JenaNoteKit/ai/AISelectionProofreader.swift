import Foundation

final class AISelectionProofreader {
    enum Availability { case available, unavailable(String) }
    private static let proofreadingQueue = AILocalInferenceQueue()
    static let maximumCharacters = 500
    static let maximumBytes = 1_500
    typealias Infer = (String) async throws -> String
    private let infer: Infer
    private let queue: AILocalInferenceQueue
    private let availability: () -> Availability
    private let timeout: Double

    init(queue: AILocalInferenceQueue = AISelectionProofreader.proofreadingQueue, timeout: Double = 10,
         availability: @escaping () -> Availability = { .available },
         infer: Infer? = nil) {
        self.queue = queue
        self.timeout = timeout
        self.availability = availability
        self.infer = infer ?? { try await KiwiProofreadingEngine.shared.check($0) }
        if infer == nil { KiwiProofreadingEngine.shared.prewarm() }
    }

    static func validate(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError(message: L10n.tr("proof.select"))
        }
        guard text.count <= maximumCharacters, text.utf8.count <= maximumBytes else {
            throw AIError(message: L10n.tr("proof.tooLong"))
        }
        guard !text.contains("\0") else { throw AIError(message: L10n.tr("proof.invalid")) }
        guard !text.contains("\u{fffc}") else { throw AIError(message: L10n.tr("proof.attachment")) }
    }

    func check(_ text: String, completion: @escaping (Result<String, Error>) -> Void) -> () -> Void {
        dispatchPrecondition(condition: .onQueue(.main))
        do {
            try Self.validate(text)
            if case .unavailable(let reason) = availability() {
                throw AIError(message: L10n.tr(reason))
            }
        } catch { completion(.failure(error)); return {} }
        let infer = self.infer
        return queue.enqueue(priority: .interactive, timeout: timeout, includesQueueTime: true,
                             operation: { try await infer(text) }) { result in
            switch result {
            case .success(let corrected):
                guard !corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      corrected.count <= Self.maximumCharacters * 2,
                      !corrected.contains("\u{fffc}") else {
                    completion(.failure(AIError(message: L10n.tr("proof.invalid"))))
                    return
                }
                completion(.success(corrected))
            case .failure(let error):
                if error is CancellationError { completion(.failure(error)) }
                else if error is AILocalInferenceQueue.Failure {
                    completion(.failure(AIError(message: L10n.tr("proof.timeout"))))
                } else { completion(.failure(error)) }
            }
        }
    }

}
