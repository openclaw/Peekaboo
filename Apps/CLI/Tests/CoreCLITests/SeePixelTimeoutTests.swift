import Commander
import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@Suite(.serialized, .tags(.safe))
@MainActor
struct SeePixelTimeoutTests {
    @Test(arguments: [true, false])
    func `pixel deadline bounds noncooperative reservation and capture`(reservation: Bool) async throws {
        let fixture = try await Fixture()
        defer { fixture.removeFiles() }
        let entered = AsyncTestLatch()
        let release = AsyncTestLatch()
        let watchdog = Self.watchdog(release)
        defer { watchdog.cancel() }
        if reservation {
            fixture.snapshots.afterCreateExplicitSnapshot = { _ in
                await entered.open()
                await release.wait()
            }
        } else {
            fixture.observation.handler = { request in
                await entered.open()
                await release.wait()
                return try fixture.result(request)
            }
        }
        var command = fixture.command()
        let output = try await captureStandardOutputText {
            let operation = Task { @MainActor in try await command.run(using: fixture.runtime) }
            #expect(await entered.opensWithin(.seconds(1)))
            await #expect(throws: ExitCode.self) { try await operation.value }
            #expect(await !release.isOpen, "The deadline must finish while the operation is still held")
            #expect(fixture.observation.requests.count == (reservation ? 0 : 1))
            await release.open()
            #expect(await Self.waitForCleanup(fixture.snapshots))
        }
        let envelope = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(envelope["success"] as? Bool == false)
        #expect((envelope["error"] as? [String: Any])?["code"] as? String == "TIMEOUT")
        #expect(((envelope["error"] as? [String: Any])?["message"] as? String)?.contains("see pixel capture") == true)
        #expect(fixture.snapshots.cleanedSnapshotIDs.count == 1)
        #expect(await fixture.snapshots.getMostRecentSnapshot() == fixture.priorSnapshot)
        #expect(fixture.watermark.effectiveWatermark() == nil)
        #expect(!fixture.runtime.interactionMutationTracker.hasPendingDurableMutation)
    }

    @Test(arguments: [false, true])
    func `cleanup cannot add a second unbounded wait after a pixel failure`(publication: Bool) async throws {
        let fixture = try await Fixture()
        defer { fixture.removeFiles() }
        let entered = AsyncTestLatch()
        let release = AsyncTestLatch()
        let watchdog = Self.watchdog(release)
        defer { watchdog.cancel() }
        fixture.observation.handler = { request in
            if publication {
                return try fixture.result(request)
            }
            throw CaptureError.captureFailure("synthetic capture failure")
        }
        fixture.snapshots.beforeCleanSnapshot = { _ in
            await entered.open()
            await release.wait()
        }
        var command = fixture.command()
        let url = fixture.root.appendingPathComponent("capture.png")
        let changed = Data(repeating: 0x78, count: Data("synthetic pixel bytes".utf8).count)
        let afterPreparation: @Sendable () -> Void = {
            if publication {
                _ = try? changed.write(to: url)
            }
        }
        let output = try await captureStandardOutputText {
            let operation = Task { @MainActor in
                try await SeeCommandPreparationContext.$didCapture.withValue(afterPreparation) {
                    try await command.run(using: fixture.runtime)
                }
            }
            #expect(await entered.opensWithin(.seconds(1)))
            await #expect(throws: ExitCode.self) { try await operation.value }
            #expect(await !release.isOpen)
            await release.open()
            #expect(await Self.waitForCleanup(fixture.snapshots))
        }
        let envelope = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(envelope["success"] as? Bool == false)
        if publication {
            #expect(try Data(contentsOf: url) == changed)
        } else {
            #expect(((envelope["error"] as? [String: Any])?["message"] as? String)?
                .contains("synthetic capture failure") == true)
        }
        #expect(fixture.snapshots.cleanedSnapshotIDs.count == 1)
        #expect(await fixture.snapshots.getMostRecentSnapshot() == fixture.priorSnapshot)
    }

    @Test
    func `late noncooperative pixels cannot write raw stdout after timeout`() async throws {
        let fixture = try await Fixture(json: false)
        defer { fixture.removeFiles() }
        let entered = AsyncTestLatch()
        let release = AsyncTestLatch()
        let finished = AsyncTestLatch()
        let watchdog = Self.watchdog(release)
        defer { watchdog.cancel() }
        fixture.observation.handler = { request in
            await entered.open()
            await release.wait()
            let result = try fixture.result(request)
            await finished.open()
            return result
        }
        var command = fixture.command()
        command.path = "-"
        let output = try await captureStandardOutputBytes {
            let operation = Task { @MainActor in try await command.run(using: fixture.runtime) }
            #expect(await entered.opensWithin(.seconds(1)))
            await #expect(throws: ExitCode.self) { try await operation.value }
            #expect(await !release.isOpen)
            await release.open()
            #expect(await finished.opensWithin(.seconds(1)))
            // The noncooperative provider has returned; let the command continuation finish under capture.
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(output.isEmpty)
        #expect(fixture.snapshots.createExplicitCallCount == 0)
        let path = try #require(fixture.observation.requests.first?.output.path)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test(arguments: [false, true])
    func `post preparation cancellation and output corruption clean the reservation`(cancel: Bool) async throws {
        let fixture = try await Fixture()
        defer { fixture.removeFiles() }
        fixture.observation.handler = { try fixture.result($0) }
        var command = fixture.command()
        command.timeout = .seconds(1)
        let url = fixture.root.appendingPathComponent("capture.png")
        let changed = Data(repeating: 0x78, count: Data("synthetic pixel bytes".utf8).count)
        let afterPreparation: @Sendable () -> Void = {
            if cancel {
                withUnsafeCurrentTask { $0?.cancel() }
            } else {
                _ = try? changed.write(to: url)
            }
        }
        let output = try await captureStandardOutputText {
            let operation = Task { @MainActor in
                try await SeeCommandPreparationContext.$didCapture.withValue(afterPreparation) {
                    try await command.run(using: fixture.runtime)
                }
            }
            await #expect(throws: ExitCode.self) { try await operation.value }
            #expect(await Self.waitForCleanup(fixture.snapshots))
        }
        let envelope = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(envelope["success"] as? Bool == false)
        #expect(fixture.snapshots.cleanedSnapshotIDs.count == 1)
        #expect(await fixture.snapshots.getMostRecentSnapshot() == fixture.priorSnapshot)
        #expect(FileManager.default.fileExists(atPath: url.path), "Caller-requested output must not be deleted")
        if !cancel {
            #expect(try Data(contentsOf: url) == changed)
        }
    }

    @Test
    func `post preparation raw cancellation removes only its generated file`() async throws {
        let fixture = try await Fixture(json: false)
        defer { fixture.removeFiles() }
        fixture.observation.handler = { try fixture.result($0) }
        var command = fixture.command()
        command.path = "-"
        command.timeout = .seconds(1)
        let afterPreparation: @Sendable () -> Void = { withUnsafeCurrentTask { $0?.cancel() } }
        let output = try await captureStandardOutputBytes {
            let operation = Task { @MainActor in
                try await SeeCommandPreparationContext.$didCapture.withValue(afterPreparation) {
                    try await command.run(using: fixture.runtime)
                }
            }
            await #expect(throws: ExitCode.self) { try await operation.value }
        }
        #expect(output.isEmpty)
        #expect(fixture.snapshots.createExplicitCallCount == 0)
        let path = try #require(fixture.observation.requests.first?.output.path)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test(arguments: [false, true])
    func `abandoned attempt cleans once only after preparation settles`(abandonFirst: Bool) async throws {
        let fixture = try await Fixture()
        defer { fixture.removeFiles() }
        let attempt = SeePixelCaptureAttempt(
            deadline: .distantPast, snapshots: fixture.snapshots
        )
        let url = fixture.root.appendingPathComponent("generated.png")
        if abandonFirst {
            #expect(attempt.abandon() == nil)
        }
        attempt.snapshotID = try await fixture.snapshots.createExplicitSnapshot()
        attempt.temporaryOutputURLs.insert(url)
        try Data("pixels".utf8).write(to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(fixture.snapshots.cleanedSnapshotIDs.isEmpty)
        attempt.finishPreparation()
        _ = attempt.abandon()
        _ = attempt.abandon()
        attempt.finishPreparation()
        #expect(await Self.waitForCleanup(fixture.snapshots))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(fixture.snapshots.cleanedSnapshotIDs == [attempt.snapshotID])
        #expect(await fixture.snapshots.getMostRecentSnapshot() == fixture.priorSnapshot)
    }

    @Test
    func `multi window captures consume one shared budget`() async throws {
        let fixture = try await Fixture()
        defer { fixture.removeFiles() }
        fixture.observation.handler = { request in
            try await Task.sleep(for: .milliseconds(30))
            return try fixture.result(request)
        }
        var command = fixture.command()
        command.windowId = nil
        command.app = "Fixture"
        command.mode = .multi
        command.timeout = .seconds(1)
        let output = try await captureStandardOutputText {
            do { try await command.run(using: fixture.runtime) } catch {}
        }
        let envelope = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(envelope["success"] as? Bool == true, Comment(rawValue: output))
        #expect(fixture.observation.requests.count == 2)
        let first = try #require(fixture.observation.requests.first?.timeout.overall)
        let second = try #require(fixture.observation.requests.last?.timeout.overall)
        #expect(first <= 1 && first > second && second > 0)
        #expect(fixture.observation.requests.allSatisfy {
            $0.capture.focus == .background && $0.detection.mode == .none
        })
    }

    private static func watchdog(_ release: AsyncTestLatch) -> Task<Void, Never> {
        Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            await release.open()
        }
    }

    private static func waitForCleanup(_ snapshots: SnapshotMutationRecordingManager) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while snapshots.cleanedSnapshotIDs.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return snapshots.cleanedSnapshotIDs.count == 1
    }

    private final class Fixture {
        let root: URL
        let watermark: DesktopMutationWatermarkStore
        let snapshots: SnapshotMutationRecordingManager
        let priorSnapshot: String
        let observation = PixelTimeoutObservationService()
        let runtime: CommandRuntime
        private let targets: [LinkedDesktopTargetFixture]
        private var generatedPaths: [URL] = []

        init(json: Bool = true) async throws {
            self.root = FileManager.default.temporaryDirectory.appendingPathComponent("pixel-timeout-\(UUID())")
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: false)
            self.watermark = DesktopMutationWatermarkStore(directoryURL: self.root.appendingPathComponent("watermark"))
            self.snapshots = SnapshotMutationRecordingManager(wrapping: InMemorySnapshotManager(
                desktopMutationWatermarkStore: self.watermark
            ))
            self.priorSnapshot = try await self.snapshots.createSnapshot()
            self.targets = [77, 78].map {
                AutomationTestFixtures.linkedDesktopTarget(
                    windowID: $0, bounds: CGRect(x: 0, y: 0, width: 100, height: 100)
                )
            }
            let services = OwnerPolicyFixtureServices(
                ownerAware: true,
                observation: self.observation,
                snapshots: self.snapshots,
                windows: MockWindowService(result: self.targets.map(\.window))
            )
            self.runtime = CommandRuntime(
                configuration: .init(verbose: false, jsonOutput: json, logLevel: nil),
                services: services,
                interactionMutationTracker: InteractionMutationTracker(desktopMutationWatermarkStore: self.watermark)
            )
        }

        func command() -> SeeCommand {
            var command = SeeCommand()
            command.windowId = 77
            command.noElements = true
            command.path = self.root.appendingPathComponent("capture.png").path
            command.timeout = .milliseconds(50)
            return command
        }

        func result(_ request: DesktopObservationRequest) throws -> DesktopObservationResult {
            let path = try #require(request.output.path)
            let windowID = if case let .windowID(id) = request.target {
                Int(id)
            } else {
                77
            }
            let target = try #require(self.targets.first { $0.window.windowID == windowID })
            let bytes = Data("synthetic pixel bytes".utf8)
            let url = URL(fileURLWithPath: path)
            self.generatedPaths.append(url)
            try bytes.write(to: url)
            return DesktopObservationResult(
                target: ResolvedObservationTarget(
                    kind: .windowID(CGWindowID(windowID)),
                    app: ApplicationIdentity(
                        processIdentifier: target.application.processIdentifier,
                        processStartIdentity: target.application.processStartIdentity,
                        bundleIdentifier: target.application.bundleIdentifier,
                        name: target.application.name
                    ),
                    window: WindowIdentity(
                        windowID: windowID,
                        title: target.window.title,
                        bounds: target.window.bounds,
                        index: target.window.index
                    ),
                    bounds: target.window.bounds,
                    detectionContext: target.windowContext
                ),
                capture: CaptureResult(imageData: bytes, metadata: CaptureMetadata(
                    size: target.window.bounds.size,
                    mode: .window,
                    applicationInfo: target.application,
                    windowInfo: target.window
                )),
                elements: nil,
                files: DesktopObservationFiles(rawScreenshotPath: path, publishedSnapshotID: request.output.snapshotID)
            ).withCaptureContentDigest(rawScreenshotData: bytes, annotatedScreenshotData: nil)
        }

        func removeFiles() {
            for path in self.generatedPaths {
                try? FileManager.default.removeItem(at: path)
            }
            try? FileManager.default.removeItem(at: self.root)
        }
    }
}

@MainActor
private final class PixelTimeoutObservationService: DesktopObservationServiceProtocol {
    var requests: [DesktopObservationRequest] = []
    var handler: (@MainActor (DesktopObservationRequest) async throws -> DesktopObservationResult)?

    func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        self.requests.append(request)
        guard let handler = self.handler else { throw CaptureError.captureFailure("unexpected capture") }
        return try await handler(request)
    }
}
