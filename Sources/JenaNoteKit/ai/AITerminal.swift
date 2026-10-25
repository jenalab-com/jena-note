import AppKit

enum AITerminal {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func open(provider: AIProvider, install: Bool, completion: @escaping (Error?) -> Void) {
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("JenaNote-CLI-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let script = directory.appendingPathComponent("\(install ? "Install" : "Login")-\(provider.rawValue).command")
            let command: String
            if install { command = provider.installCommand }
            else {
                guard let executable = AISettings.executable(for: provider) else {
                    throw AIError(message: L10n.tr("ai.notInstalled"))
                }
                command = ([executable.path] + provider.loginArguments).map(quote).joined(separator: " ")
            }
            let profileCommand: String
            if provider == .grok && !install {
                try FileManager.default.createDirectory(at: AISettings.grokProfile, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                profileCommand = "export GROK_HOME=" + quote(AISettings.grokProfile.path)
            } else { profileCommand = "" }
            let scriptText = """
            #!/bin/zsh -l
            set -o pipefail
            export PATH=\(quote(AISettings.searchDirectories.joined(separator: ":"))):"$PATH"
            \(profileCommand)
            cd \(quote(directory.path))
            echo \(quote("JenaNote — " + provider.title))
            \(command)
            jena_cli_status=$?
            if [ "$jena_cli_status" -eq 0 ]; then
                echo \(quote(L10n.tr("ai.terminalDone")))
            else
                echo \(quote(L10n.tr("ai.terminalFailed")))
            fi
            echo \(quote(L10n.tr("ai.terminalReturn")))
            exit "$jena_cli_status"
            """
            try scriptText.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: .init()) { _, error in
                DispatchQueue.main.async { completion(error) }
            }
        } catch { completion(error) }
    }
}
