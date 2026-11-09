import XCTest
import AppKit
@testable import JenaNoteKit

final class AILocalServerTests: XCTestCase {
    private var directory: URL!
    private var previousPath = ""
    private var previousAddress = ""

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        previousPath = AISettings.customPath(for: .local)
        previousAddress = AISettings.localServerAddress
    }

    override func tearDown() {
        AISettings.setPath(previousPath, for: .local)
        AISettings.localServerAddress = previousAddress
        try? FileManager.default.removeItem(at: directory)
    }

    private func install(script: String) throws {
        let launcher = directory.appendingPathComponent("launcher")
        try script.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        AISettings.setPath(launcher.path, for: .local)
    }

    private func makeServer(healthy: @escaping () -> Bool, startupLimit: TimeInterval = 10) -> AILocalServer {
        AILocalServer(healthCheck: { $0(healthy()) }, startupLimit: startupLimit, pollInterval: 0.02,
                      logURL: directory.appendingPathComponent("server.log"))
    }

    private func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func isAlive(pidFile: URL) -> Bool {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return kill(pid, 0) == 0
    }

    func testLocalProviderHasNoSearchableExecutableUntilTheUserChoosesOne() {
        AISettings.setPath("", for: .local)
        XCTAssertNil(AISettings.executable(for: .local), "Any PATH program named `local` must not be launched")
        XCTAssertTrue(AISettings.canAttemptRequest(with: .local), "A server started elsewhere needs no launcher")
    }

    func testRunWaitsForHealthThenStopEndsTheWholeProcessGroup() throws {
        let pidFile = directory.appendingPathComponent("child.pid")
        // The child outlives a plain kill of the launcher, as with scripts that do not `exec`.
        try install(script: "#!/bin/sh\n/bin/sleep 60 &\necho $! > '\(pidFile.path)'\nwait\n")
        var healthy = false
        let server = makeServer(healthy: { healthy })
        server.start()
        guard case .starting = server.state else { return XCTFail("Must not claim readiness before health passes") }
        waitUntil { isAlive(pidFile: pidFile) }
        XCTAssertTrue(isAlive(pidFile: pidFile))
        healthy = true
        waitUntil { server.state == .running(owned: true) }
        XCTAssertEqual(server.state, .running(owned: true))
        server.stop()
        waitUntil { server.state == .stopped }
        XCTAssertEqual(server.state, .stopped)
        waitUntil { !isAlive(pidFile: pidFile) }
        XCTAssertFalse(isAlive(pidFile: pidFile), "A surviving child would keep gigabytes of model in memory")
    }

    func testFinderLaunchedAppStillFindsHomebrewAndPassesTheConfiguredPort() throws {
        let environment = directory.appendingPathComponent("environment")
        try install(script: "#!/bin/sh\necho \"$PORT $PATH\" > '\(environment.path)'\nexec /bin/sleep 60\n")
        AISettings.localServerAddress = "http://127.0.0.1:8123"
        let server = makeServer(healthy: { false })
        server.start()
        waitUntil { FileManager.default.fileExists(atPath: environment.path) }
        defer { server.stopForTermination() }
        let text = try String(contentsOf: environment, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("8123 "))
        XCTAssertTrue(text.contains("/opt/homebrew/bin"))
    }

    func testEarlyExitReportsTheServersOwnMessage() throws {
        try install(script: "#!/bin/sh\necho 'couldn not bind port' >&2\nexit 3\n")
        let server = makeServer(healthy: { false })
        server.start()
        waitUntil { if case .failed = server.state { return true } else { return false } }
        guard case .failed(let message) = server.state else { return XCTFail("Early exit must not look like loading") }
        XCTAssertTrue(message.contains("couldn not bind port"), message)
    }

    func testExistingServerIsUsedButNotOwned() throws {
        try install(script: "#!/bin/sh\nexit 9\n")
        let server = makeServer(healthy: { true })
        server.start()
        XCTAssertEqual(server.state, .running(owned: false), "A second server would double the model's memory")
    }

    func testMissingLaunchLocationIsReported() {
        AISettings.setPath("", for: .local)
        let server = makeServer(healthy: { false })
        server.start()
        XCTAssertEqual(server.state, .failed(L10n.tr("ai.local.noExecutable")))
    }

    func testServerThatNeverBecomesHealthyIsStoppedAtTheLimit() throws {
        try install(script: "#!/bin/sh\nexec /bin/sleep 60\n")
        let server = makeServer(healthy: { false }, startupLimit: 0.1)
        server.start()
        waitUntil { if case .failed = server.state { return true } else { return false } }
        XCTAssertEqual(server.state, .failed(L10n.tr("ai.local.startTimeout")))
    }

    func testRequestCarriesThePromptAndOmitsAnUnchosenModel() throws {
        let server = try XCTUnwrap(URL(string: "http://127.0.0.1:8080"))
        let request = try AIClient.localRequest(server: server, prompt: "질문", model: "", timeout: 600)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8080/v1/chat/completions")
        XCTAssertEqual(request.timeoutInterval, 600)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertNil(body["model"])
        XCTAssertEqual((body["messages"] as? [[String: String]])?.first?["content"], "질문")
    }

    func testReplyShowsTheAnswerNotTheModelsReasoning() throws {
        let json = #"{"choices":[{"message":{"content":"답","reasoning_content":"생각"}}],"usage":{"total_tokens":42}}"#
        let reply = try AIClient.localReply(from: Data(json.utf8), status: 200)
        XCTAssertEqual(reply.text, "답")
        XCTAssertEqual(reply.tokens, 42)
    }

    func testReasoningOnlyReplyIsAnErrorRatherThanAnEmptyAnswer() {
        let json = #"{"choices":[{"message":{"content":"","reasoning_content":"생각"}}]}"#
        XCTAssertThrowsError(try AIClient.localReply(from: Data(json.utf8), status: 200))
    }

    func testServerErrorMessageReachesTheWriter() {
        let json = #"{"error":{"message":"request exceeds the available context size"}}"#
        XCTAssertThrowsError(try AIClient.localReply(from: Data(json.utf8), status: 400)) { error in
            XCTAssertTrue(error.localizedDescription.contains("exceeds the available context size"))
        }
    }

    func testChoosingLocalShowsRunControlsAndHidesCLIOnes() throws {
        let previous = AISettings.provider
        defer { AISettings.provider = previous }
        AISettings.provider = .local
        let settings = AISettingsViewController()
        settings.loadView()
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let buttons = descendants(settings.view).compactMap { $0 as? NSButton }
        XCTAssertFalse(try XCTUnwrap(buttons.first { $0.title == L10n.tr("ai.local.run") }).isHidden)
        XCTAssertTrue(try XCTUnwrap(buttons.first { $0.title == L10n.tr("ai.install") }).isHidden)
        XCTAssertTrue(try XCTUnwrap(buttons.first { $0.title == L10n.tr("ai.recheck") }).isHidden)
    }
}
