import Darwin
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
@Suite(.serialized)
struct ScreenCaptureKitExclusiveLockDeadlineTests {
    @Test
    func `default exclusive wait fits inside the standard Bridge request envelope`() {
        #expect(ScreenCaptureKitCaptureGate.defaultExclusiveWaitNanoseconds == 8_000_000_000)
        #expect(ScreenCaptureKitCaptureGate.defaultExclusiveWaitNanoseconds < 10_000_000_000)
    }

    @Test
    func `exclusive capture wait fails when another holder never unlocks`() async {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("boo.peekaboo.sckit-operation.lock")
        let holder = open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard holder >= 0 else {
            Issue.record("Could not create exclusive lock file")
            return
        }
        defer {
            flock(holder, LOCK_UN)
            close(holder)
        }
        guard flock(holder, LOCK_EX | LOCK_NB) == 0 else {
            Issue.record("Could not take exclusive lock for the fixture holder")
            return
        }

        var leafCalls = 0
        var settleCalls = 0
        let settle: @MainActor @Sendable () async -> Void = {
            settleCalls += 1
        }
        do {
            _ = try await ScreenCaptureKitCaptureGate.$postCaptureSettleOverride.withValue(settle) {
                try await ScreenCaptureKitCaptureGate.withExclusiveCaptureOperation(
                    operationName: "exclusiveLockDeadline",
                    exclusiveWaitNanoseconds: 80_000_000)
                {
                    leafCalls += 1
                    return 1
                }
            }
            Issue.record("A live exclusive holder should time out the waiter")
        } catch let error as PeekabooError {
            #expect(error.code == StandardErrorCode.captureFailed)
            #expect(error.localizedDescription.contains("exclusive ScreenCaptureKit operation lock"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(leafCalls == 0)
        #expect(settleCalls == 0)
    }

    @Test
    func `exec child cannot retain the operation lock after its parent descriptor closes`() {
        let holder = ScreenCaptureKitCaptureGate.openExclusiveOperationLockDescriptor()
        guard holder >= 0 else {
            Issue.record("Could not create the operation lock fixture")
            return
        }
        guard flock(holder, LOCK_EX | LOCK_NB) == 0 else {
            close(holder)
            Issue.record("Could not take the operation lock for the fixture holder")
            return
        }

        var arguments = [strdup("sleep"), strdup("30"), nil]
        defer {
            for argument in arguments where argument != nil {
                free(argument)
            }
        }
        var childProcessIdentifier: pid_t = 0
        let spawnResult = posix_spawn(
            &childProcessIdentifier,
            "/bin/sleep",
            nil,
            nil,
            &arguments,
            environ)
        guard spawnResult == 0 else {
            flock(holder, LOCK_UN)
            close(holder)
            Issue.record("Could not launch the exec inheritance fixture: \(spawnResult)")
            return
        }
        close(holder)
        defer {
            kill(childProcessIdentifier, SIGTERM)
            var childStatus: Int32 = 0
            while waitpid(childProcessIdentifier, &childStatus, 0) < 0, errno == EINTR {}
        }

        let contender = ScreenCaptureKitCaptureGate.openExclusiveOperationLockDescriptor()
        guard contender >= 0 else {
            Issue.record("Could not create the operation lock contender")
            return
        }
        defer { close(contender) }

        let acquisitionResult = flock(contender, LOCK_EX | LOCK_NB)
        #expect(acquisitionResult == 0)
        if acquisitionResult == 0 {
            flock(contender, LOCK_UN)
        }
    }
}
