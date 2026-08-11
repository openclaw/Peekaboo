import Darwin
import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct ScreenCaptureKitTimeoutRaceTests {
    @Test
    func `callback bridge returns success and failure without the SDK async overlay`() async throws {
        let value = try await ScreenCaptureKitCallbackBridge<Int>.wait { completion in
            completion(.success(42))
        }
        #expect(value == 42)

        struct ExpectedError: Error {}
        await #expect(throws: ExpectedError.self) {
            try await ScreenCaptureKitCallbackBridge<Int>.wait { completion in
                completion(.failure(ExpectedError()))
            }
        }
    }

    @Test
    func `cancellation before continuation installation still resumes the caller`() async {
        let race = ScreenCaptureKitTimeoutRace<Int>()
        race.cancel()

        await #expect(throws: CancellationError.self) {
            try await withCheckedThrowingContinuation { continuation in
                _ = race.setContinuation(continuation)
            }
        }
    }

    @Test
    func `completion before continuation installation preserves the result`() async throws {
        let race = ScreenCaptureKitTimeoutRace<Int>()
        race.resume(.success(42))

        let value = try await withCheckedThrowingContinuation { continuation in
            _ = race.setContinuation(continuation)
        }

        #expect(value == 42)
    }
}

@MainActor
struct ScreenCaptureKitOperationCoordinatorTests {
    @Test
    func `timed out framework work quarantines the gate until late completion`() async throws {
        let coordinator = ScreenCaptureKitOperationCoordinator(lockFilePath: nil)
        let started = AsyncTestLatch()
        let release = AsyncTestLatch()

        let firstCall = Task { @MainActor in
            try await coordinator.run(seconds: 0.05, operationName: "blocked capture") {
                await started.open()
                await release.wait()
                return 1
            }
        }

        await started.wait()
        let firstResult = await firstCall.result
        guard case .failure = firstResult else {
            Issue.record("The blocked capture should have timed out")
            await release.open()
            return
        }
        #expect(await self.eventually { coordinator.isQuarantined })

        var admittedSecondCall = false
        do {
            _ = try await coordinator.run(seconds: 0.05, operationName: "second capture") {
                admittedSecondCall = true
                return 2
            }
            Issue.record("A quarantined capture gate admitted another operation")
        } catch {
            #expect(String(describing: error).contains("quarantined"))
        }
        #expect(!admittedSecondCall)

        await release.open()
        #expect(await self.eventually { !coordinator.isQuarantined })

        let recoveredValue = try await coordinator.run(seconds: 0.2, operationName: "recovered capture") { 3 }
        #expect(recoveredValue == 3)
    }

    @Test
    func `caller cancellation quarantines noncooperative work but returns promptly`() async {
        let coordinator = ScreenCaptureKitOperationCoordinator(lockFilePath: nil)
        let started = AsyncTestLatch()
        let release = AsyncTestLatch()

        let firstCall = Task { @MainActor in
            try await coordinator.run(seconds: 60, operationName: "cancelled capture") {
                await started.open()
                await release.wait()
                return 1
            }
        }

        await started.wait()
        let cancellationStart = ContinuousClock.now
        firstCall.cancel()
        let firstResult = await firstCall.result
        let cancellationDuration = cancellationStart.duration(to: .now)

        guard case let .failure(error) = firstResult else {
            Issue.record("The cancelled capture should not have succeeded")
            await release.open()
            return
        }
        #expect(error is CancellationError)
        #expect(cancellationDuration < .seconds(1))
        #expect(await self.eventually { coordinator.isQuarantined })

        await release.open()
        #expect(await self.eventually { !coordinator.isQuarantined })
    }

    @Test
    func `concurrent calls stay serialized before any timeout`() async throws {
        let coordinator = ScreenCaptureKitOperationCoordinator(lockFilePath: nil)
        let firstStarted = AsyncTestLatch()
        let releaseFirst = AsyncTestLatch()
        let secondStarted = AsyncTestLatch()

        let firstCall = Task { @MainActor in
            try await coordinator.run(seconds: 2, operationName: "first capture") {
                await firstStarted.open()
                await releaseFirst.wait()
                return 1
            }
        }
        await firstStarted.wait()

        let secondCall = Task { @MainActor in
            try await coordinator.run(seconds: 2, operationName: "second capture") {
                await secondStarted.open()
                return 2
            }
        }

        try await Task.sleep(for: .milliseconds(50))
        #expect(await !secondStarted.isOpen)

        await releaseFirst.open()
        #expect(try await firstCall.value == 1)
        #expect(try await secondCall.value == 2)
        #expect(await secondStarted.isOpen)
    }

    @Test
    func `quarantine retains the cross process flock until late completion`() async {
        let lockPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("peekaboo-sck-gate-test-\(UUID().uuidString).lock")
        defer { try? FileManager.default.removeItem(atPath: lockPath) }

        let coordinator = ScreenCaptureKitOperationCoordinator(lockFilePath: lockPath)
        let started = AsyncTestLatch()
        let release = AsyncTestLatch()
        let firstCall = Task { @MainActor in
            try await coordinator.run(seconds: 0.05, operationName: "flock capture") {
                await started.open()
                await release.wait()
                return 1
            }
        }

        await started.wait()
        guard case .failure = await firstCall.result else {
            Issue.record("The blocked capture should have timed out")
            await release.open()
            return
        }
        #expect(await self.eventually { coordinator.isQuarantined })

        let probeFD = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        #expect(probeFD >= 0)
        guard probeFD >= 0 else {
            await release.open()
            return
        }
        defer { close(probeFD) }

        #expect(flock(probeFD, LOCK_EX | LOCK_NB) != 0)

        await release.open()
        #expect(await self.eventually { !coordinator.isQuarantined })
        #expect(flock(probeFD, LOCK_EX | LOCK_NB) == 0)
        flock(probeFD, LOCK_UN)
    }

    @Test
    func `another process retaining the flock cannot strand the caller past its deadline`() async throws {
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-sck-cross-process-\(UUID().uuidString)", isDirectory: true)
        let lockURL = testDirectory.appendingPathComponent("capture.lock")
        let readyURL = testDirectory.appendingPathComponent("holder.ready")
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDirectory) }

        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        holder.arguments = [
            "-c",
            """
            import fcntl, os, sys, time
            descriptor = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            with open(sys.argv[2], "w", encoding="utf-8") as ready:
                ready.write("ready")
            time.sleep(10)
            """,
            lockURL.path,
            readyURL.path,
        ]
        holder.standardOutput = FileHandle.nullDevice
        holder.standardError = FileHandle.nullDevice
        try holder.run()
        defer {
            if holder.isRunning {
                holder.terminate()
                holder.waitUntilExit()
            }
        }

        #expect(await self.eventually { FileManager.default.fileExists(atPath: readyURL.path) })
        guard FileManager.default.fileExists(atPath: readyURL.path) else {
            Issue.record("The cross-process flock holder did not become ready")
            return
        }

        let coordinator = ScreenCaptureKitOperationCoordinator(lockFilePath: lockURL.path)
        var admittedCapture = false
        let start = ContinuousClock.now
        do {
            _ = try await coordinator.run(seconds: 0.1, operationName: "contended capture") {
                admittedCapture = true
                return 1
            }
            Issue.record("The coordinator acquired a flock still owned by another process")
        } catch let error as PeekabooError {
            #expect(error.code == .timeout)
            #expect(error.userMessage.contains("another process may be quarantined"))
        } catch {
            Issue.record("Expected a structured Peekaboo timeout, got \(error)")
        }

        #expect(start.duration(to: .now) < .seconds(1))
        #expect(!admittedCapture)

        let cancelledCall = Task { @MainActor in
            try await coordinator.run(seconds: 60, operationName: "cancelled lock wait") {
                admittedCapture = true
                return 1
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        let cancellationStart = ContinuousClock.now
        cancelledCall.cancel()
        guard case let .failure(cancellationError) = await cancelledCall.result else {
            Issue.record("Cancelling a contended flock wait should not succeed")
            return
        }
        #expect(cancellationError is CancellationError)
        #expect(cancellationStart.duration(to: .now) < .seconds(1))
        #expect(!admittedCapture)

        holder.terminate()
        holder.waitUntilExit()
        let recoveredValue = try await coordinator.run(seconds: 0.5, operationName: "recovered capture") { 2 }
        #expect(recoveredValue == 2)
    }

    private func eventually(
        _ predicate: @MainActor () -> Bool,
        attempts: Int = 100) async -> Bool
    {
        for _ in 0..<attempts {
            if predicate() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
}
