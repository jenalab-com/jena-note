import Foundation
import Darwin

/// Owns the user's local model server for the life of the app. Unlike a CLI request this process
/// outlives any one prompt, so it logs to a file instead of AIProcess's bounded pipes.
final class AILocalServer {
    enum State: Equatable {
        case stopped
        case starting(since: Date)
        case running(owned: Bool)
        case failed(String)
    }

    typealias HealthCheck = (@escaping (Bool) -> Void) -> Void

    static let shared = AILocalServer()
    static let stateDidChange = Notification.Name("AILocalServerStateDidChange")
    /// A multi-gigabyte model on an external disk took about four minutes to load in practice.
    static let startupLimit: TimeInterval = 900
    private static let terminationGrace: TimeInterval = 3

    private(set) var state: State = .stopped {
        didSet { NotificationCenter.default.post(name: Self.stateDidChange, object: self) }
    }
    private var processID: pid_t?
    private var exitSource: DispatchSourceProcess?
    private var pollTimer: Timer?
    private var stopRequested = false
    private let healthCheck: HealthCheck
    private let startupLimit: TimeInterval
    private let pollInterval: TimeInterval
    private let logURL: URL

    init(healthCheck: HealthCheck? = nil, startupLimit: TimeInterval = AILocalServer.startupLimit,
         pollInterval: TimeInterval = 1, logURL: URL? = nil) {
        self.healthCheck = healthCheck ?? Self.checkConfiguredServer
        self.startupLimit = startupLimit
        self.pollInterval = pollInterval
        self.logURL = logURL ?? AISettings.applicationSupport.appendingPathComponent("local-server.log")
    }

    /// Finds a server left running by another tool without taking ownership of it.
    func refresh() {
        guard processID == nil else { return }
        healthCheck { [weak self] isHealthy in
            guard let self, self.processID == nil else { return }
            if isHealthy { self.state = .running(owned: false) }
            else if case .running = self.state { self.state = .stopped }
        }
    }

    func start() {
        guard processID == nil else { return }
        healthCheck { [weak self] isHealthy in
            guard let self, self.processID == nil else { return }
            if isHealthy { self.state = .running(owned: false); return }
            self.launch()
        }
    }

    func stop() {
        guard let processID else { return }
        stopRequested = true
        endPolling()
        // The group also reaches children of a launcher that did not `exec` its server.
        kill(-processID, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.terminationGrace) { [weak self] in
            guard self?.processID == processID else { return }
            kill(-processID, SIGKILL)
        }
    }

    /// The run loop ends with the app, so a delayed SIGKILL could never fire here.
    func stopForTermination() {
        guard let processID else { return }
        exitSource?.cancel()
        kill(-processID, SIGTERM)
        let deadline = Date().addingTimeInterval(Self.terminationGrace)
        var status: Int32 = 0
        while waitpid(processID, &status, WNOHANG) == 0 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        kill(-processID, SIGKILL)
    }

    private func launch() {
        guard let executable = AISettings.executable(for: .local) else {
            state = .failed(L10n.tr("ai.local.noExecutable")); return
        }
        do {
            let pid = try spawn(executable)
            processID = pid
            stopRequested = false
            watchExit(of: pid)
            let started = Date()
            state = .starting(since: started)
            poll(startedAt: started)
        } catch { state = .failed(error.localizedDescription) }
    }

    private func spawn(_ executable: URL) throws -> pid_t {
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, logURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        var environment = ProcessInfo.processInfo.environment
        // A Finder-launched app has no shell PATH, so `llama-server` would not resolve.
        environment["PATH"] = ([executable.deletingLastPathComponent().path] + AISettings.searchDirectories).joined(separator: ":")
        if let port = AISettings.localServerURL?.port { environment["PORT"] = String(port) }
        var argv = [strdup(executable.path), nil]
        var env = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var pid: pid_t = 0
        let code = posix_spawn(&pid, executable.path, &actions, &attributes, &argv, &env)
        guard code == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        return pid
    }

    private func watchExit(of pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in self?.processExited(pid) }
        exitSource = source
        source.resume()
    }

    private func processExited(_ pid: pid_t) {
        guard processID == pid else { return }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        exitSource?.cancel()
        exitSource = nil
        processID = nil
        endPolling()
        // Group members a launcher left behind must not keep the model in memory.
        kill(-pid, SIGKILL)
        state = stopRequested ? .stopped : .failed(L10n.tr("ai.local.exited") + "\n" + logTail())
    }

    private func poll(startedAt: Date) {
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            guard let self, case .starting = self.state else { return }
            if Date().timeIntervalSince(startedAt) >= self.startupLimit {
                self.endPolling()
                self.failAfterStartupLimit()
                return
            }
            self.healthCheck { [weak self] isHealthy in
                guard let self, isHealthy, !self.stopRequested, case .starting = self.state else {
                    // Ticks drive the elapsed-time label while the model loads.
                    NotificationCenter.default.post(name: Self.stateDidChange, object: self)
                    return
                }
                self.endPolling()
                self.state = .running(owned: true)
            }
        }
    }

    private func failAfterStartupLimit() {
        guard let processID else { return }
        exitSource?.cancel()
        exitSource = nil
        self.processID = nil
        kill(-processID, SIGKILL)
        var status: Int32 = 0
        while waitpid(processID, &status, 0) < 0 && errno == EINTR {}
        state = .failed(L10n.tr("ai.local.startTimeout"))
    }

    private func endPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func logTail() -> String {
        guard let data = try? Data(contentsOf: logURL) else { return "" }
        return String(decoding: data.suffix(600), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func checkConfiguredServer(_ completion: @escaping (Bool) -> Void) {
        guard let url = AISettings.localServerURL?.appendingPathComponent("health") else { completion(false); return }
        // llama-server answers 503 until the model has finished loading.
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 2)) { _, response, _ in
            let isHealthy = (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { completion(isHealthy) }
        }.resume()
    }
}
