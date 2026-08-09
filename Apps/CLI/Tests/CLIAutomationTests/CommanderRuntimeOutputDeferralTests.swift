import Darwin
import Foundation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@MainActor
@Suite(.serialized)
struct CommanderRuntimeOutputDeferralTests {
    private let clickArguments = [
        "click", "--coords", "100,200", "--foreground",
    ]

    @Test
    func `Process output gate serializes concurrent async regions`() async throws {
        let gate = InProcessRunGate()
        let probe = ConcurrentRegionProbe()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await gate.run {
                        await probe.enter()
                        try await Task.sleep(for: .milliseconds(5))
                        await probe.leave()
                    }
                }
            }
            try await group.waitForAll()
        }

        #expect(await probe.maximumActiveRegions == 1)
    }

    @Test
    func `Cancelled output gate waiter does not run or block its successor`() async throws {
        let gate = InProcessRunGate()
        let holderStarted = AsyncTestLatch()
        let releaseHolder = AsyncTestLatch()
        let probe = ConcurrentRegionProbe()

        let holder = Task {
            try await gate.run {
                await holderStarted.open()
                await releaseHolder.wait()
            }
        }
        await holderStarted.wait()

        let cancelledWaiter = Task {
            try await gate.run {
                await probe.markCancelledRegionRan()
            }
        }
        cancelledWaiter.cancel()
        let successor = Task {
            try await gate.run { 42 }
        }

        await releaseHolder.open()
        try await holder.value
        await #expect(throws: CancellationError.self) {
            try await cancelledWaiter.value
        }
        #expect(try await successor.value == 42)
        #expect(await probe.cancelledRegionRan == false)
    }

    @Test
    func `Deferred output preserves original terminal capabilities`() async throws {
        let result = try await InProcessCommandRunner.withExclusiveProcessOutput {
            var controllerFD: Int32 = -1
            var terminalFD: Int32 = -1
            var size = winsize()
            size.ws_col = 132
            size.ws_row = 43
            guard openpty(&controllerFD, &terminalFD, nil, nil, &size) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer {
                close(controllerFD)
                close(terminalFD)
            }

            let originalStdout = dup(STDOUT_FILENO)
            guard originalStdout != -1 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            _ = fflush(nil)
            guard dup2(terminalFD, STDOUT_FILENO) != -1 else {
                let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                close(originalStdout)
                throw POSIXError(code)
            }
            defer {
                _ = fflush(nil)
                _ = dup2(originalStdout, STDOUT_FILENO)
                close(originalStdout)
            }

            return try await DeferredCommandOutput.run(bufferingOutput: true) {
                let rawDescriptorIsInteractive = isatty(STDOUT_FILENO) != 0
                let capabilities = await MainActor.run {
                    let detected = TerminalDetector.detectCapabilities()
                    return (
                        detected.isInteractive,
                        detected.isPiped,
                        detected.width,
                        detected.height
                    )
                }
                return (
                    rawDescriptorIsInteractive,
                    capabilities.0,
                    capabilities.1,
                    capabilities.2,
                    capabilities.3
                )
            }
        }

        #expect(!result.0)
        #expect(result.1)
        #expect(!result.2)
        #expect(result.3 == 132)
        #expect(result.4 == 43)
    }

    @Test
    func `JSON success is replayed with one warning when snapshot cleanup fails`() async throws {
        let context = TestServicesFactory.makeAutomationTestContext()
        context.snapshots.invalidationError = PeekabooError.operationError(
            message: "invalidation unavailable"
        )

        let result = try await InProcessCommandRunner.run(
            self.clickArguments + ["--json"],
            services: context.services
        )

        #expect(result.exitStatus == 0)
        #expect(result.stderr == "\(CommanderRuntimeExecutorMessage.snapshotInvalidationWarning)\n")
        let output = try Self.parseJSONObject(result.stdout)
        #expect(output["success"] as? Bool == true)
        #expect(context.snapshots.invalidationCutoffs.count == 2)
        #expect(context.snapshots.invalidationCutoffs.first == context.snapshots.invalidationCutoffs.last)
    }

    @Test
    func `Text success is replayed with one warning when snapshot cleanup fails`() async throws {
        let context = TestServicesFactory.makeAutomationTestContext()
        context.snapshots.invalidationError = PeekabooError.operationError(
            message: "invalidation unavailable"
        )

        let result = try await InProcessCommandRunner.run(
            self.clickArguments,
            services: context.services
        )

        #expect(result.exitStatus == 0)
        #expect(result.stdout.contains("Click successful"))
        #expect(!result.stderr.contains("invalidation unavailable"))
        #expect(result.stderr == "\(CommanderRuntimeExecutorMessage.snapshotInvalidationWarning)\n")
        #expect(!result.stderr.contains("Error:"))
        #expect(context.snapshots.invalidationCutoffs.count == 2)
    }

    @Test
    func `Successful command output is replayed after snapshot cleanup`() async throws {
        let context = TestServicesFactory.makeAutomationTestContext()

        let result = try await InProcessCommandRunner.run(
            self.clickArguments + ["--json"],
            services: context.services
        )

        #expect(result.exitStatus == 0)
        #expect(result.stderr.isEmpty)
        let output = try Self.parseJSONObject(result.stdout)
        #expect(output["success"] as? Bool == true)
        #expect(context.snapshots.invalidationCutoffs.count >= 1)
    }

    @Test
    func `Failed selected-host catch-up blocks command before side effect`() async throws {
        let context = TestServicesFactory.makeAutomationTestContext()
        context.snapshots.effectiveImplicitLatestInvalidationWatermark = Date()
        context.snapshots.invalidationError = PeekabooError.operationError(
            message: "host watermark unavailable"
        )

        let result = try await InProcessCommandRunner.run(
            self.clickArguments,
            services: context.services
        )

        #expect(result.exitStatus == 1)
        #expect(context.automation.clickCalls.isEmpty)
        #expect(context.snapshots.invalidationCutoffs.count == 1)
        #expect(result.combinedOutput.contains("requested command was not executed"))
        #expect(result.combinedOutput.contains("retrying later is safe"))
    }

    @Test
    func `Selected-host catch-up preserves cancellation`() async {
        let context = TestServicesFactory.makeAutomationTestContext()
        context.snapshots.effectiveImplicitLatestInvalidationWatermark = Date()
        context.snapshots.invalidationError = CancellationError()
        let runtime = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: false, logLevel: nil),
            services: context.services
        )

        await #expect(throws: CancellationError.self) {
            try await CommanderRuntimeExecutor.catchUpSelectedHostIfNeeded(
                using: runtime,
                required: true
            )
        }
    }

    @Test
    func `Pre-cancelled selected-host catch-up cannot reach command execution`() async {
        let context = TestServicesFactory.makeAutomationTestContext()
        context.snapshots.effectiveImplicitLatestInvalidationWatermark = Date()
        let runtime = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: false, logLevel: nil),
            services: context.services
        )
        let ready = AsyncTestLatch()
        let release = AsyncTestLatch()

        let task = Task {
            await ready.open()
            await release.wait()
            try await CommanderRuntimeExecutor.catchUpSelectedHostIfNeeded(
                using: runtime,
                required: true
            )
        }
        await ready.wait()
        task.cancel()
        await release.open()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(context.snapshots.invalidationCutoffs.isEmpty)
    }

    @Test
    func `Command without snapshot dependency skips selected-host catch-up`() async throws {
        let context = TestServicesFactory.makeAutomationTestContext()
        context.snapshots.effectiveImplicitLatestInvalidationWatermark = Date()
        context.snapshots.invalidationError = PeekabooError.operationError(
            message: "must not be consulted"
        )
        let runtime = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: false, logLevel: nil),
            services: context.services
        )

        try await CommanderRuntimeExecutor.catchUpSelectedHostIfNeeded(
            using: runtime,
            required: false
        )

        #expect(context.snapshots.invalidationCutoffs.isEmpty)
    }

    @Test
    func `Operation error output remains primary when snapshot cleanup also fails`() async throws {
        let context = TestServicesFactory.makeAutomationTestContext()
        context.automation.clickError = PeekabooError.operationError(
            message: "synthetic click failure"
        )
        context.snapshots.invalidationError = PeekabooError.operationError(
            message: "invalidation unavailable"
        )

        let result = try await InProcessCommandRunner.run(
            self.clickArguments + ["--json"],
            services: context.services
        )

        #expect(result.exitStatus == 1)
        #expect(result.stderr.isEmpty)
        let output = try Self.parseJSONObject(result.stdout)
        #expect(output["success"] as? Bool == false)
        let error = try #require(output["error"] as? [String: Any])
        let message = try #require(error["message"] as? String)
        #expect(message.contains("synthetic click failure"))
        #expect(!message.contains("stale UI snapshots"))
        #expect(context.snapshots.invalidationCutoffs.count == 2)
    }

    private static func parseJSONObject(_ output: String) throws -> [String: Any] {
        let data = try #require(output.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private actor ConcurrentRegionProbe {
    private var activeRegions = 0
    private(set) var maximumActiveRegions = 0
    private(set) var cancelledRegionRan = false

    func enter() {
        self.activeRegions += 1
        self.maximumActiveRegions = max(self.maximumActiveRegions, self.activeRegions)
    }

    func leave() {
        self.activeRegions -= 1
    }

    func markCancelledRegionRan() {
        self.cancelledRegionRan = true
    }
}

private actor AsyncTestLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !self.isOpen else { return }
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    func open() {
        guard !self.isOpen else { return }
        self.isOpen = true
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
