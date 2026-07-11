import Foundation
import PeekabooCore
import Testing
@testable import PeekabooCLI

#if !PEEKABOO_SKIP_AUTOMATION
@Suite(
    .serialized,
    .tags(.safe),
    .enabled(if: CLITestEnvironment.runAutomationRead)
)
struct RunCommandCLIHarnessTests {
    @Test
    func `run command executes scripts via process service`() async throws {
        let scriptPath = "/tmp/test-script.peekaboo.json"
        let script = PeekabooScript(
            description: "Sample script",
            steps: [
                ScriptStep(stepId: "step1", comment: "Capture UI", command: "see", params: nil),
                ScriptStep(stepId: "step2", comment: "Click login", command: "click", params: nil),
            ]
        )

        let stepResults = [
            StepResult(
                stepId: "step1",
                stepNumber: 1,
                command: "see",
                success: true,
                output: .success("Captured"),
                error: nil,
                executionTime: 0.5
            ),
            StepResult(
                stepId: "step2",
                stepNumber: 2,
                command: "click",
                success: true,
                output: .success("Clicked"),
                error: nil,
                executionTime: 0.3
            ),
        ]

        let process = StubProcessService()
        process.scriptsByPath[scriptPath] = script
        process.nextExecuteScriptResults = stepResults

        let services = self.makeServices(process: process)
        let result = try await InProcessCommandRunner.run([
            "run",
            scriptPath,
            "--json",
        ], services: services)

        #expect(result.exitStatus == 0)
        let data = try #require(result.stdout.data(using: .utf8))
        let payload = try JSONDecoder().decode(CodableJSONResponse<ScriptExecutionResult>.self, from: data)
        #expect(payload.data.totalSteps == 2)
        #expect(payload.data.success)
        #expect(process.loadScriptCalls.count == 1)
        #expect(process.executeScriptCalls.count == 1)
    }

    @Test
    func `run command preserves terminal see at its actual boundary`() async throws {
        let scriptPath = "/tmp/boundary-script.peekaboo.json"
        let script = PeekabooScript(description: "Boundary script", steps: [
            ScriptStep(
                stepId: "sleep",
                comment: nil,
                command: "sleep",
                params: .sleep(.init(duration: 0.01))
            ),
            ScriptStep(stepId: "click", comment: nil, command: "click", params: nil),
            ScriptStep(stepId: "see", comment: nil, command: "see", params: nil),
            ScriptStep(
                stepId: "clipboard-get",
                comment: nil,
                command: "clipboard",
                params: .clipboard(.init(action: "get"))
            ),
            ScriptStep(
                stepId: "clipboard-save",
                comment: nil,
                command: "clipboard",
                params: .generic(["action": " SAVE "])
            ),
            ScriptStep(
                stepId: "dock-list",
                comment: nil,
                command: "dock",
                params: .generic(["action": " LIST "])
            ),
        ])
        let snapshots = StubSnapshotManager()
        let process = StubProcessService()
        process.scriptsByPath[scriptPath] = script
        var terminalStartedAt: Date?
        var freshSnapshotID: String?
        process.executeScriptProvider = { _, _, _ in
            _ = try await snapshots.createSnapshot()
            let observationStartedAt = Date()
            let snapshotID = try await snapshots.createSnapshot(pendingAt: observationStartedAt)
            terminalStartedAt = observationStartedAt
            freshSnapshotID = snapshotID
            return [
                StepResult(
                    stepId: "sleep",
                    stepNumber: 1,
                    command: "sleep",
                    success: true,
                    output: .success("Slept"),
                    error: nil,
                    executionTime: 0.01
                ),
                StepResult(
                    stepId: "click",
                    stepNumber: 2,
                    command: "click",
                    success: true,
                    output: .success("Clicked"),
                    error: nil,
                    executionTime: 0.01
                ),
                StepResult(
                    stepId: "see",
                    stepNumber: 3,
                    command: "see",
                    success: true,
                    output: .success("Captured"),
                    error: nil,
                    executionTime: 0.01,
                    startedAt: observationStartedAt,
                    snapshotId: snapshotID
                ),
                StepResult(
                    stepId: "clipboard-get",
                    stepNumber: 4,
                    command: "clipboard",
                    success: true,
                    output: .success("Read clipboard"),
                    error: nil,
                    executionTime: 0.01
                ),
                StepResult(
                    stepId: "clipboard-save",
                    stepNumber: 5,
                    command: "clipboard",
                    success: true,
                    output: .success("Saved clipboard"),
                    error: nil,
                    executionTime: 0.01
                ),
                StepResult(
                    stepId: "dock-list",
                    stepNumber: 6,
                    command: "dock",
                    success: true,
                    output: .success("Listed Dock"),
                    error: nil,
                    executionTime: 0.01
                ),
            ]
        }

        let services = TestServicesFactory.makePeekabooServices(
            snapshots: snapshots,
            process: process
        )
        let result = try await InProcessCommandRunner.run([
            "run",
            scriptPath,
            "--json",
        ], services: services)

        #expect(result.exitStatus == 0)
        #expect(snapshots.invalidationCutoffs == [terminalStartedAt])
        #expect(await snapshots.getMostRecentSnapshot() == freshSnapshotID)
    }

    @Test
    func `run command writes output file`() async throws {
        let scriptPath = "/tmp/output-script.peekaboo.json"
        let script = PeekabooScript(description: "Write output", steps: [])
        let process = StubProcessService()
        process.scriptsByPath[scriptPath] = script
        process.nextExecuteScriptResults = []

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-results-\(UUID().uuidString).json")

        defer { try? FileManager.default.removeItem(at: outputURL) }

        let services = self.makeServices(process: process)
        let result = try await InProcessCommandRunner.run([
            "run",
            scriptPath,
            "--output", outputURL.path,
        ], services: services)

        #expect(result.exitStatus == 0)
        #expect(FileManager.default.fileExists(atPath: outputURL.path))

        let data = try Data(contentsOf: outputURL)
        let payload = try JSONDecoder().decode(ScriptExecutionResult.self, from: data)
        #expect(payload.scriptPath == scriptPath)
    }

    @Test
    func `run command writes output file and emits JSON response`() async throws {
        let scriptPath = "/tmp/json-output-script.peekaboo.json"
        let script = PeekabooScript(description: "Write and emit output", steps: [])
        let process = StubProcessService()
        process.scriptsByPath[scriptPath] = script
        process.nextExecuteScriptResults = []

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-json-results-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let services = self.makeServices(process: process)
        let result = try await InProcessCommandRunner.run([
            "run",
            scriptPath,
            "--output", outputURL.path,
            "--json",
        ], services: services)

        #expect(result.exitStatus == 0)
        let stdoutData = try #require(result.stdout.data(using: .utf8))
        let response = try JSONDecoder().decode(CodableJSONResponse<ScriptExecutionResult>.self, from: stdoutData)
        #expect(response.data.scriptPath == scriptPath)

        let fileData = try Data(contentsOf: outputURL)
        let filePayload = try JSONDecoder().decode(ScriptExecutionResult.self, from: fileData)
        #expect(filePayload.scriptPath == scriptPath)
    }

    @Test
    func `run command expands home directory script and output paths`() async throws {
        let scriptRelativePath = "Library/Caches/peekaboo-script-\(UUID().uuidString).peekaboo.json"
        let outputRelativePath = "Library/Caches/peekaboo-run-results-\(UUID().uuidString).json"
        let scriptPath = "~/\(scriptRelativePath)"
        let outputPath = "~/\(outputRelativePath)"
        let resolvedScriptPath = NSString(string: scriptPath).expandingTildeInPath
        let resolvedOutputPath = NSString(string: outputPath).expandingTildeInPath
        let script = PeekabooScript(description: "Expanded paths", steps: [])
        let process = StubProcessService()
        process.scriptsByPath[resolvedScriptPath] = script
        process.nextExecuteScriptResults = []
        defer { try? FileManager.default.removeItem(atPath: resolvedOutputPath) }

        let services = self.makeServices(process: process)
        let result = try await InProcessCommandRunner.run([
            "run",
            scriptPath,
            "--output", outputPath,
        ], services: services)

        #expect(result.exitStatus == 0)
        #expect(process.loadScriptCalls.first?.path == resolvedScriptPath)
        #expect(FileManager.default.fileExists(atPath: resolvedOutputPath))

        let data = try Data(contentsOf: URL(fileURLWithPath: resolvedOutputPath))
        let payload = try JSONDecoder().decode(ScriptExecutionResult.self, from: data)
        #expect(payload.scriptPath == resolvedScriptPath)
    }

    @Test
    func `run command exits with failure when a step fails`() async throws {
        let scriptPath = "/tmp/failing-script.peekaboo.json"
        let script = PeekabooScript(description: "Failing script", steps: [
            ScriptStep(stepId: "fail", comment: nil, command: "click", params: nil),
        ])
        let failingStep = StepResult(
            stepId: "fail",
            stepNumber: 1,
            command: "click",
            success: false,
            output: nil,
            error: "Element not found",
            executionTime: 0.2
        )

        let process = StubProcessService()
        process.scriptsByPath[scriptPath] = script
        process.nextExecuteScriptResults = [failingStep]

        let services = self.makeServices(process: process)
        let result = try await InProcessCommandRunner.run(["run", scriptPath], services: services)

        #expect(result.exitStatus != 0)
        let output = result.stdout + result.stderr
        #expect(output.contains("❌ Script failed") || output.contains("❌ Error"))
    }

    @MainActor
    private func makeServices(process: StubProcessService) -> PeekabooServices {
        TestServicesFactory.makePeekabooServices(process: process)
    }
}
#endif

@Suite(.serialized, .tags(.unit))
struct RunCommandDataTests {
    @Test
    func `Run command parses script path`() throws {
        let command = try RunCommand.parse(["/path/to/script.peekaboo.json"])
        #expect(command.scriptPath == "/path/to/script.peekaboo.json")
        #expect(command.output == nil)
        #expect(command.noFailFast == false)
    }

    @Test
    func `Run command parses all options`() throws {
        let command = try RunCommand.parse([
            "/tmp/automation.peekaboo.json",
            "--output", "results.json",
            "--no-fail-fast",
        ])
        #expect(command.scriptPath == "/tmp/automation.peekaboo.json")
        #expect(command.output == "results.json")
        #expect(command.noFailFast == true)
    }

    @Test
    func `Run snapshot boundary follows final UI effect`() {
        let seeThenClick = PeekabooScript(description: nil, steps: [
            ScriptStep(stepId: "see", comment: nil, command: "see", params: nil),
            ScriptStep(stepId: "click", comment: nil, command: "click", params: nil),
        ])
        let clickThenSeeAndClipboardReads = PeekabooScript(description: nil, steps: [
            ScriptStep(stepId: "click", comment: nil, command: "click", params: nil),
            ScriptStep(stepId: "see", comment: nil, command: "see", params: nil),
            ScriptStep(
                stepId: "clipboard-get",
                comment: nil,
                command: "clipboard",
                params: .clipboard(.init(action: "get"))
            ),
            ScriptStep(
                stepId: "clipboard-save",
                comment: nil,
                command: "clipboard",
                params: .generic(["action": " SAVE "])
            ),
        ])
        let seeThenClipboardWrite = PeekabooScript(description: nil, steps: [
            ScriptStep(stepId: "see", comment: nil, command: "see", params: nil),
            ScriptStep(
                stepId: "clipboard-set",
                comment: nil,
                command: "clipboard",
                params: .clipboard(.init(action: "set", text: "updated"))
            ),
        ])
        let readOnly = PeekabooScript(description: nil, steps: [
            ScriptStep(
                stepId: "sleep",
                comment: nil,
                command: "sleep",
                params: .sleep(.init(duration: 0.1))
            ),
            ScriptStep(
                stepId: "dock",
                comment: nil,
                command: "dock",
                params: .generic(["action": " list "])
            ),
        ])
        let clickThenScreenshotOnly = PeekabooScript(description: nil, steps: [
            ScriptStep(stepId: "click", comment: nil, command: "click", params: nil),
            ScriptStep(
                stepId: "screenshot",
                comment: nil,
                command: "see",
                params: .screenshot(.init(path: "/tmp/screenshot.png", annotate: false))
            ),
        ])
        let screenshotOnly = PeekabooScript(description: nil, steps: [
            ScriptStep(
                stepId: "screenshot",
                comment: nil,
                command: "see",
                params: .generic(["path": "/tmp/screenshot.png", "annotate": "false"])
            ),
        ])
        let observationThenScreenshotOnly = PeekabooScript(description: nil, steps: [
            ScriptStep(stepId: "see", comment: nil, command: "see", params: nil),
            ScriptStep(
                stepId: "screenshot",
                comment: nil,
                command: "see",
                params: .screenshot(.init(path: "/tmp/screenshot.png", annotate: false))
            ),
        ])

        #expect(RunCommand.finalSnapshotEffect(in: seeThenClick) == .mutation)
        #expect(RunCommand.finalSnapshotEffect(in: clickThenSeeAndClipboardReads) == .freshObservation)
        #expect(RunCommand.finalSnapshotEffect(in: seeThenClipboardWrite) == .mutation)
        #expect(RunCommand.finalSnapshotEffect(in: readOnly) == .none)
        #expect(RunCommand.finalSnapshotEffect(in: clickThenScreenshotOnly) == .mutation)
        #expect(RunCommand.finalSnapshotEffect(in: screenshotOnly) == .mutation)
        #expect(RunCommand.finalSnapshotEffect(in: observationThenScreenshotOnly) == .mutation)
    }

    @Test
    func `Screenshot-only terminal see cannot preserve stale detection`() {
        let staleStartedAt = Date(timeIntervalSinceReferenceDate: 100)
        let screenshotStartedAt = Date(timeIntervalSinceReferenceDate: 200)
        let script = PeekabooScript(description: nil, steps: [
            ScriptStep(stepId: "click", comment: nil, command: "click", params: nil),
            ScriptStep(
                stepId: "screenshot",
                comment: nil,
                command: "see",
                params: .screenshot(.init(path: "/tmp/screenshot.png", annotate: false))
            ),
        ])
        let results = [
            StepResult(
                stepId: "click",
                stepNumber: 1,
                command: "click",
                success: true,
                output: .success("Clicked"),
                error: nil,
                executionTime: 0.01,
                startedAt: staleStartedAt,
                snapshotId: "stale-snapshot"
            ),
            StepResult(
                stepId: "screenshot",
                stepNumber: 2,
                command: "see",
                success: true,
                output: .success("Captured screenshot"),
                error: nil,
                executionTime: 0.01,
                startedAt: screenshotStartedAt,
                snapshotId: "stale-snapshot"
            ),
        ]

        #expect(RunCommand.terminalFreshObservation(in: script, results: results) == nil)
    }

    @Test
    func `Terminal see carries the remote host mutation certificate`() throws {
        let startedAt = Date(timeIntervalSinceReferenceDate: 100)
        let hostCompletedAt = Date(timeIntervalSinceReferenceDate: 200)
        let script = PeekabooScript(description: nil, steps: [
            ScriptStep(stepId: "see", comment: nil, command: "see", params: nil),
        ])
        let results = [
            StepResult(
                stepId: "see",
                stepNumber: 1,
                command: "see",
                success: true,
                output: .success("Captured"),
                error: nil,
                executionTime: 0.5,
                startedAt: startedAt,
                snapshotId: "fresh",
                desktopMutationCompletedAt: hostCompletedAt,
                desktopMutationPreservationAllowed: false
            ),
        ]

        let observation = try #require(RunCommand.terminalFreshObservation(in: script, results: results))
        #expect(observation.snapshotId == "fresh")
        #expect(observation.startedAt == startedAt)
        #expect(observation.confirmedMutationCompletedAt == hostCompletedAt)
        #expect(!observation.preservationAllowed)
    }

    @Test
    func `Run command requires script path`() {
        #expect(throws: (any Error).self) {
            try CLIOutputCapture.suppressStderr {
                _ = try RunCommand.parse([])
            }
        }
    }

    @Test
    func `Script structure validation`() {
        let steps = [
            TestScriptStep(
                stepId: "step1",
                comment: "Capture Safari UI",
                command: "see",
                params: ["app": "Safari"]
            ),
            TestScriptStep(
                stepId: "step2",
                comment: "Click login button",
                command: "click",
                params: ["query": "Login"]
            ),
            TestScriptStep(
                stepId: "step3",
                comment: nil,
                command: "type",
                params: ["text": "user@example.com", "on": "T1"]
            ),
        ]

        let script = TestPeekabooScript(
            description: "Automates the login flow",
            steps: steps
        )

        #expect(script.description == "Automates the login flow")
        #expect(script.steps.count == 3)
        #expect(script.steps[0].command == "see")
        #expect(script.steps[0].params?["app"] == "Safari")
        #expect(script.steps[2].comment == nil)
    }

    @Test
    func `Run result structure`() {
        let stepResults = [
            StepResult(
                stepId: "step1",
                stepNumber: 1,
                command: "see",
                success: true,
                output: .success("Step completed successfully"),
                error: nil,
                executionTime: 1.5
            ),
            StepResult(
                stepId: "step2",
                stepNumber: 2,
                command: "click",
                success: false,
                output: nil,
                error: "Element not found",
                executionTime: 2.0
            ),
        ]

        let result = ScriptExecutionResult(
            success: false,
            scriptPath: "/tmp/test.peekaboo.json",
            description: "Test script",
            totalSteps: 5,
            completedSteps: 1,
            failedSteps: 1,
            executionTime: 12.5,
            steps: stepResults
        )

        #expect(result.success == false)
        #expect(result.scriptPath == "/tmp/test.peekaboo.json")
        #expect(result.totalSteps == 5)
        #expect(result.completedSteps == 1)
        #expect(result.failedSteps == 1)
        #expect(result.executionTime == 12.5)
        #expect(result.steps.count == 2)
        #expect(result.steps[1].error == "Element not found")
    }

    @Test
    func `Script JSON parsing`() throws {
        let jsonString = """
        {
            "description": "A test automation script",
            "steps": [
                {
                    "stepId": "step1",
                    "command": "see",
                    "params": {
                        "app": "Finder"
                    }
                },
                {
                    "stepId": "step2",
                    "command": "sleep",
                    "params": {
                        "duration": "1000"
                    },
                    "comment": "Wait for UI to settle"
                }
            ]
        }
        """
        let jsonData = Data(jsonString.utf8)

        let script = try JSONDecoder().decode(TestPeekabooScript.self, from: jsonData)
        #expect(script.description == "A test automation script")
        #expect(script.steps.count == 2)
        #expect(script.steps[1].comment == "Wait for UI to settle")
    }
}

// MARK: - Test Helper Types

struct TestPeekabooScript: Codable {
    let description: String?
    let steps: [TestScriptStep]
}

struct TestScriptStep: Codable {
    let stepId: String
    let comment: String?
    let command: String
    let params: [String: String]?
}
