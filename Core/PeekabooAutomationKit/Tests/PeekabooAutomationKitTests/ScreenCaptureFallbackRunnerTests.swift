import Darwin
import Foundation
import PeekabooFoundation
import Testing
@testable @_spi(Testing) import PeekabooAutomationKit

@Suite(.serialized)
struct ScreenCaptureFallbackRunnerTests {
    @Test
    @MainActor
    func `auto capture falls back from quarantined or contended modern capture`() async throws {
        let failures: [PeekabooError] = [
            .captureFailed("ScreenCaptureKit is quarantined after an abandoned captureImage call"),
            .timeout(operation: "SCScreenshotManager waiting for ScreenCaptureKit gate", duration: 0.1),
        ]

        for modernFailure in failures {
            var attempts: [ScreenCaptureAPI] = []
            let runner = ScreenCaptureFallbackRunner(apis: [.modern, .legacy])
            let result = try await runner.runCapture(
                operationName: "captureWindow",
                logger: MockLoggingService().logger(category: "test"),
                correlationId: UUID().uuidString)
            { api in
                attempts.append(api)
                if api == .modern {
                    throw modernFailure
                }
                return Self.captureResult()
            }

            #expect(attempts == [.modern, .legacy])
            #expect(result.metadata.diagnostics?.engine == ScreenCaptureAPI.legacy.description)
            #expect(result.metadata.diagnostics?.fallbackReason?.contains("ScreenCaptureKit") == true)
        }
    }

    @Test
    @MainActor
    func `explicit modern capture fails honestly without legacy fallback`() async {
        var attempts: [ScreenCaptureAPI] = []
        let runner = ScreenCaptureFallbackRunner(apis: [.legacy, .modern])

        do {
            _ = try await runner.runCapture(
                operationName: "captureWindow",
                logger: MockLoggingService().logger(category: "test"),
                correlationId: UUID().uuidString,
                apis: runner.apis(for: .modern))
            { api in
                attempts.append(api)
                throw PeekabooError.captureFailed("ScreenCaptureKit is quarantined")
            }
            Issue.record("Expected explicit modern capture to fail")
        } catch {
            #expect(String(describing: error).contains("quarantined"))
        }
        #expect(attempts == [.modern])
    }

    @Test
    func `default resolver retains a safe legacy fallback`() {
        let apis = ScreenCaptureAPIResolver.resolve(environment: [:])
        #expect(apis.contains(.legacy))
        #expect(ScreenCaptureFallbackRunner(apis: apis).apis(for: .auto) == apis)
    }

    @Test
    @MainActor
    func `Bridge modern-first scope reorders only automatic capture and restores afterward`() async {
        let runner = ScreenCaptureFallbackRunner(apis: [.legacy, .modern])

        let scoped = await ScreenCaptureService.withModernFirstAutomaticCapture(true) {
            (
                auto: runner.apis(for: .auto),
                modern: runner.apis(for: .modern),
                legacy: runner.apis(for: .legacy))
        }

        #expect(scoped.auto == [.modern, .legacy])
        #expect(scoped.modern == [.modern])
        #expect(scoped.legacy == [.legacy])
        #expect(runner.apis(for: .auto) == [.legacy, .modern])
    }

    @Test
    @MainActor
    func `wedged system screencapture child is killed and reaped without blocking main actor`() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; exec /bin/sleep 30"]
        try process.run()
        let processIdentifier = process.processIdentifier
        let startedAt = ContinuousClock.now

        let heartbeat = ConfirmationRecorder()
        let waitTask = Task {
            try await LegacyScreenCaptureOperator.waitForSystemScreencaptureExit(
                process,
                timeoutSeconds: 0.05,
                operationName: "test screencapture")
        }
        Task { @MainActor in heartbeat.confirm() }
        try await Task.sleep(for: .milliseconds(10))
        #expect(heartbeat.wasConfirmed)
        await #expect(throws: PeekabooError.self) {
            try await waitTask.value
        }

        #expect(startedAt.duration(to: .now) < .seconds(2))
        #expect(!process.isRunning)
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGKILL)
        errno = 0
        #expect(kill(processIdentifier, 0) == -1)
        #expect(errno == ESRCH)
    }

    private static func captureResult() -> CaptureResult {
        let size = CGSize(width: 20, height: 10)
        return CaptureResult(
            imageData: Data([1]),
            metadata: CaptureMetadata(
                size: size,
                mode: .window,
                diagnostics: CaptureDiagnostics(
                    requestedScale: .logical1x,
                    nativeScale: 1,
                    outputScale: 1,
                    scaleSource: "test",
                    finalPixelSize: size)))
    }
}

@MainActor
private final class ConfirmationRecorder {
    private(set) var wasConfirmed = false

    func confirm() {
        self.wasConfirmed = true
    }
}
