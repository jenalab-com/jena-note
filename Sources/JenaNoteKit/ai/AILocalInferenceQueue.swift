import Foundation

/// Main-queue ownership. Interactive requests pass queued summaries, never active inference.
final class AILocalInferenceQueue {
    enum Priority: Int { case interactive, background }
    enum Failure: Error { case timedOut }
    static let shared = AILocalInferenceQueue()

    private final class Job {
        let id = UUID()
        let priority: Priority
        let timeout: Double
        let operation: () async throws -> String
        let completion: (Result<String, Error>) -> Void
        var deadline: DispatchWorkItem?
        var finished = false

        init(priority: Priority, timeout: Double, operation: @escaping () async throws -> String,
             completion: @escaping (Result<String, Error>) -> Void) {
            self.priority = priority
            self.timeout = timeout
            self.operation = operation
            self.completion = completion
        }
    }

    private var pending: [Job] = []
    private var active: Job?
    private var task: Task<Void, Never>?

    func enqueue(priority: Priority, timeout: Double, includesQueueTime: Bool = false,
                 operation: @escaping () async throws -> String,
                 completion: @escaping (Result<String, Error>) -> Void) -> () -> Void {
        dispatchPrecondition(condition: .onQueue(.main))
        let job = Job(priority: priority, timeout: timeout, operation: operation, completion: completion)
        pending.append(job)
        if includesQueueTime { armDeadline(job) }
        startNext()
        return { [weak self, weak job] in
            guard let self, let job else { return }
            self.cancel(job, error: CancellationError())
        }
    }

    private func armDeadline(_ job: Job) {
        guard job.deadline == nil else { return }
        let deadline = DispatchWorkItem { [weak self, weak job] in
            guard let self, let job else { return }
            self.cancel(job, error: Failure.timedOut)
        }
        job.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, job.timeout), execute: deadline)
    }

    private func complete(_ job: Job, _ result: Result<String, Error>) {
        guard !job.finished else { return }
        job.finished = true
        job.deadline?.cancel()
        job.deadline = nil
        job.completion(result)
    }

    private func cancel(_ job: Job, error: Error) {
        guard !job.finished else { return }
        pending.removeAll { $0.id == job.id }
        if active?.id == job.id { task?.cancel() }
        complete(job, .failure(error))
        // An active model may finish cancellation later. Keep its slot until it actually returns.
        if active == nil { startNext() }
    }

    private func startNext() {
        guard active == nil,
              let index = pending.indices.min(by: { pending[$0].priority.rawValue < pending[$1].priority.rawValue }) else { return }
        let job = pending.remove(at: index)
        active = job
        armDeadline(job)
        task = Task { @MainActor in
            do {
                try Task.checkCancellation()
                let text = try await job.operation()
                try Task.checkCancellation()
                self.complete(job, .success(text))
            } catch { self.complete(job, .failure(error)) }
            self.active = nil
            self.task = nil
            self.startNext()
        }
    }
}
