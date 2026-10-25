import Foundation
import Darwin

struct AIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct AIProcessOutput {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// Each request owns a process group, including CLI launcher children. All pipe reads are
/// nonblocking: a descendant retaining a pipe cannot prevent cancellation or completion.
final class AIProcess {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func run(executable: URL, arguments: [String], input: String = "", directory: URL? = nil,
             timeout: TimeInterval = 120, environmentOverrides: [String: String] = [:], exchange: AIProcessExchange? = nil, completion: @escaping (Result<AIProcessOutput, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try self.execute(executable: executable, arguments: arguments,
                                                   input: input, directory: directory, timeout: timeout, environmentOverrides: environmentOverrides, exchange: exchange) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func execute(executable: URL, arguments: [String], input: String, directory: URL?,
                         timeout: TimeInterval, environmentOverrides: [String: String], exchange: AIProcessExchange?) throws -> AIProcessOutput {
        guard !isCancelled else { throw AIError(message: L10n.tr("ai.cancelled")) }
        // A private, unlinked file gives stdin an EOF without a potentially blocked writer.
        var template = Array((NSTemporaryDirectory() + "jena-ai-stdin-XXXXXX").utf8CString)
        let inputFD = mkstemp(&template)
        guard inputFD >= 0 else { throw posixError() }
        unlink(template)
        let inputHandle = FileHandle(fileDescriptor: inputFD, closeOnDealloc: false)
        defer { close(inputFD) }
        try inputHandle.write(contentsOf: Data(input.utf8))
        lseek(inputFD, 0, SEEK_SET)

        // Metadata protocols need stdin to stay open until their response arrives.
        var interactive: [Int32] = [-1, -1]
        if exchange != nil {
            guard pipe(&interactive) == 0 else { throw posixError() }
            _ = fcntl(interactive[1], F_SETNOSIGPIPE, 1)
        }
        defer { for fd in interactive where fd >= 0 { close(fd) } }
        func writeInteractive(_ text: String) throws {
            let bytes = Data(text.utf8)
            // Control messages are deliberately small; never block on an unbounded prompt.
            guard bytes.count <= 4096 else { throw AIError(message: L10n.tr("ai.outputTooLarge")) }
            try FileHandle(fileDescriptor: interactive[1], closeOnDealloc: false).write(contentsOf: bytes)
        }
        var out: [Int32] = [0, 0], err: [Int32] = [0, 0]
        guard pipe(&out) == 0 else { throw posixError() }
        defer { close(out[0]); close(out[1]) }
        guard pipe(&err) == 0 else { throw posixError() }
        defer { close(err[0]); close(err[1]) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, exchange == nil ? inputFD : interactive[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, inputFD)
        for fd in out + err + interactive.filter({ $0 >= 0 }) { posix_spawn_file_actions_addclose(&actions, fd) }
        if let directory = directory {
            let code = posix_spawn_file_actions_addchdir_np(&actions, directory.path)
            guard code == 0 else { throw posixError(code) }
        }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ([executable.deletingLastPathComponent().path] + AISettings.searchDirectories).joined(separator: ":")
        environment["NO_COLOR"] = "1"
        environment["GEMINI_CLI_NO_RELAUNCH"] = "1"
        environment["GROK_DISABLE_AUTOUPDATER"] = "1"
        environment["GROK_MEMORY"] = "0"
        // Avoid importing unrelated Claude/Cursor automation into a writing request.
        for vendor in ["CLAUDE", "CURSOR", "CODEX"] {
            for kind in ["HOOKS", "MCPS", "AGENTS", "RULES", "SKILLS"] {
                environment["GROK_\(vendor)_\(kind)_ENABLED"] = "0"
            }
        }
        environment.removeValue(forKey: "CLAUDECODE")
        environment.merge(environmentOverrides) { _, override in override }
        var argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        var env = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var pid: pid_t = 0
        let code = posix_spawn(&pid, executable.path, &actions, &attributes, &argv, &env)
        guard code == 0 else { throw posixError(code) }
        _ = fcntl(out[0], F_SETFL, O_NONBLOCK)
        _ = fcntl(err[0], F_SETFL, O_NONBLOCK)
        let deadline = Date().addingTimeInterval(timeout)
        var terminationDate: Date?
        var timedOut = false, exceeded = false
        var stdout = Data(), stderr = Data()
        var status: Int32 = 0
        var reaped = false
        defer {
            // Never a user's existing CLI: the group was created by this spawn.
            kill(-pid, SIGKILL)
            if !reaped { while waitpid(pid, &status, 0) < 0 && errno == EINTR {} }
        }
        if exchange != nil { try writeInteractive(input) }
        var processedBytes = 0
        while true {
            drain(out[0], into: &stdout, exceeded: &exceeded)
            drain(err[0], into: &stderr, exceeded: &exceeded)
            if let exchange = exchange {
                while let newline = stdout[processedBytes...].firstIndex(of: 10) {
                    let line = String(decoding: stdout[processedBytes..<newline], as: UTF8.self)
                    processedBytes = newline + 1
                    if let reply = exchange.receive(line) { try writeInteractive(reply) }
                }
                if exchange.isComplete { break }
            }
            let wait = waitpid(pid, &status, WNOHANG)
            if wait == pid { reaped = true; break }
            if wait < 0 && errno != EINTR { throw posixError() }
            timedOut = Date() >= deadline
            if isCancelled || timedOut || exceeded {
                if terminationDate == nil { kill(-pid, SIGTERM); terminationDate = Date() }
                if Date().timeIntervalSince(terminationDate!) >= 1 { kill(-pid, SIGKILL) }
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        drain(out[0], into: &stdout, exceeded: &exceeded)
        drain(err[0], into: &stderr, exceeded: &exceeded)
        if isCancelled { throw AIError(message: L10n.tr("ai.cancelled")) }
        if timedOut { throw AIError(message: L10n.tr("ai.timeout")) }
        if exceeded { throw AIError(message: L10n.tr("ai.outputTooLarge")) }
        let exitCode = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return AIProcessOutput(status: exitCode, stdout: String(decoding: stdout, as: UTF8.self),
                               stderr: String(decoding: stderr, as: UTF8.self))
    }

    private func drain(_ descriptor: Int32, into data: inout Data, exceeded: inout Bool) {
        var bytes = [UInt8](repeating: 0, count: 8192)
        // Bound work per poll even if the child writes continuously.
        for _ in 0..<64 {
            let count = read(descriptor, &bytes, bytes.count)
            if count <= 0 { break }
            if data.count + count > 4 * 1024 * 1024 { exceeded = true }
            else { data.append(contentsOf: bytes.prefix(count)) }
        }
    }

    private func posixError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}

/// Used only by read-only metadata handshakes; receive runs on the process worker queue.
protocol AIProcessExchange: AnyObject {
    var isComplete: Bool { get }
    func receive(_ line: String) -> String?
}
