import Commander
import Darwin
import Foundation
import PeekabooCore
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe), .serialized)
struct ConfigEditorLaunchTests {
    @Test
    func `EditCommand terminates env options before an option-like editor`() {
        let arguments = ConfigCommand.EditCommand.editorProcessArguments(
            editor: "-S/usr/bin/touch /tmp/pwned",
            configPath: "/tmp/config.json"
        )

        #expect(arguments == ["--", "-S/usr/bin/touch /tmp/pwned", "/tmp/config.json"])
    }

    @Test
    func `EditCommand preserves a normal editor after the env option terminator`() {
        let arguments = ConfigCommand.EditCommand.editorProcessArguments(
            editor: "/usr/bin/nano",
            configPath: "/tmp/config.json"
        )

        #expect(arguments == ["--", "/usr/bin/nano", "/tmp/config.json"])
    }

    @Test
    func `EditCommand leaves the editor wait unbounded unless timeout is set`() {
        let command = ConfigCommand.EditCommand()
        #expect(command.timeout == nil)
    }

    @Test
    func `CLI print-path does not create configuration or launch an editor`() async throws {
        try await self.withTempConfigDir { dir in
            let resolved = try CommanderRuntimeRouter.resolve(argv: [
                "peekaboo", "config", "edit", "--print-path",
                "--editor", dir.appendingPathComponent("missing-editor").path,
            ])
            var command = try CommanderCLIBinder.instantiateCommand(
                ofType: ConfigCommand.EditCommand.self,
                parsedValues: resolved.parsedValues
            )

            #expect(command.printPath)
            try await command.run(using: self.makeRuntime())
            #expect(!FileManager.default.fileExists(atPath: PeekabooCore.ConfigurationManager.configPath))
        }
    }

    @Test
    func `EditCommand bounds a non-exiting editor`() async throws {
        try await self.withTempConfigDir { dir in
            let fileManager = FileManager.default
            let editor = dir.appendingPathComponent("hanging-editor")
            let pidFile = dir.appendingPathComponent("editor.pid")
            let script = """
            #!/bin/sh
            printf '%s\\n' "$$" > "\(pidFile.path)"
            trap '' TERM
            exec /bin/sleep 8
            """
            try script.write(to: editor, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: editor.path)

            var command = ConfigCommand.EditCommand()
            command.editor = editor.path
            command.timeout = .seconds(1)

            let runtime = self.makeRuntime()
            let startedAt = ContinuousClock.now
            let exitCode = await #expect(throws: ExitCode.self) {
                try await command.run(using: runtime)
            }
            #expect(exitCode == ExitCode.failure)
            // The one-second timeout permits two more seconds of termination cleanup.
            // Leave scheduling headroom while staying below the editor's eight-second natural exit.
            #expect(startedAt.duration(to: .now) < .seconds(5))

            let pidText = try String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let pid = try #require(Int32(pidText))
            errno = 0
            #expect(kill(pid, 0) == -1)
            #expect(errno == ESRCH)
        }
    }

    private func makeRuntime() -> CommandRuntime {
        CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: false, logLevel: nil),
            services: PeekabooServices()
        )
    }

    private func withTempConfigDir(_ body: (URL) async throws -> Void) async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-cli-config-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let environmentKeys = [
            "PEEKABOO_CONFIG_DIR",
            "PEEKABOO_CONFIG_NONINTERACTIVE",
            "PEEKABOO_CONFIG_DISABLE_MIGRATION",
        ]
        let previous = Dictionary(uniqueKeysWithValues: environmentKeys.map { key in
            (key, getenv(key).map { String(cString: $0) })
        })

        setenv("PEEKABOO_CONFIG_DIR", tempDir.path, 1)
        setenv("PEEKABOO_CONFIG_NONINTERACTIVE", "1", 1)
        setenv("PEEKABOO_CONFIG_DISABLE_MIGRATION", "1", 1)
        PeekabooCore.ConfigurationManager.shared.resetForTesting()

        defer {
            for key in environmentKeys {
                if case let value?? = previous[key] {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
            PeekabooCore.ConfigurationManager.shared.resetForTesting()
            try? FileManager.default.removeItem(at: tempDir)
        }

        try await body(tempDir)
    }
}
