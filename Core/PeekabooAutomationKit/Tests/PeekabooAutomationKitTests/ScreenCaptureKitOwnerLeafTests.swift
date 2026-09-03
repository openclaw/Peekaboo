import Darwin
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@Suite(.serialized, CaptureTestIsolation())
@MainActor
struct ScreenCaptureKitOwnerLeafTests {
    @Test
    func `classic transaction skips ScreenCaptureKit settlement`() async throws {
        var steps: [String] = []
        let settle: @MainActor @Sendable () async -> Void = {
            steps.append("settle")
        }

        let value = try await ScreenCaptureKitCaptureGate.$postCaptureSettleOverride.withValue(settle) {
            try await ScreenCaptureKitCaptureGate.withExclusiveCaptureOperation(operationName: "classic") {
                steps.append("capture")
                return 42
            }
        }

        #expect(value == 42)
        #expect(steps == ["capture"])
    }

    @Test
    func `ScreenCaptureKit transaction settles before returning`() async throws {
        var steps: [String] = []
        let receipt = Self.receipt(processIdentifier: 100, processStartIdentity: 200)
        let claim: @MainActor @Sendable () throws -> ScreenCaptureKitOwnerLease.OwnerReceipt = { receipt }
        let settle: @MainActor @Sendable () async -> Void = {
            steps.append("settle")
        }

        let operation: () async throws -> Int = {
            try await ScreenCaptureKitCaptureGate.$postCaptureSettleOverride.withValue(settle) {
                try await ScreenCaptureKitCaptureGate.withExclusiveCaptureOperation(operationName: "modern") {
                    steps.append("transaction")
                    return try await ScreenCaptureKitCaptureGate.runOwnedOperation(
                        seconds: 1,
                        operationName: "leaf")
                    {
                        steps.append("leaf")
                        return 42
                    }
                }
            }
        }

        let value = try await ScreenCaptureKitCaptureGate.$processOwnerClaimOverride.withValue(
            claim,
            operation: operation)

        #expect(value == 42)
        #expect(steps == ["transaction", "leaf", "settle"])
    }

    @Test
    func `cancelled classic transaction skips settlement and preserves cancellation`() async {
        var settleCalls = 0
        let settle: @MainActor @Sendable () async -> Void = {
            settleCalls += 1
        }

        await #expect(throws: CancellationError.self) {
            try await ScreenCaptureKitCaptureGate.$postCaptureSettleOverride.withValue(settle) {
                try await ScreenCaptureKitCaptureGate.withExclusiveCaptureOperation(operationName: "classic") {
                    throw CancellationError()
                }
            }
        }
        #expect(settleCalls == 0)
    }

    @Test
    func `owner claim completes before the ScreenCaptureKit leaf`() async throws {
        var steps: [String] = []
        let receipt = Self.receipt(processIdentifier: 100, processStartIdentity: 200)
        let claim: @MainActor @Sendable () throws -> ScreenCaptureKitOwnerLease.OwnerReceipt = {
            steps.append("claim")
            return receipt
        }
        let operation: () async throws -> Int = {
            try await ScreenCaptureKitCaptureGate.withProcessOwner(operationName: "fixture") {
                steps.append("leaf")
                return 42
            }
        }

        let value = try await ScreenCaptureKitCaptureGate.$processOwnerClaimOverride.withValue(
            claim,
            operation: operation)

        #expect(value == 42)
        #expect(steps == ["claim", "leaf"])
    }

    @Test
    func `foreign owner refusal executes no ScreenCaptureKit leaf`() async {
        var leafCalls = 0
        let receipt = Self.receipt(processIdentifier: 4242, processStartIdentity: 9001)
        let claim: @MainActor @Sendable () throws -> ScreenCaptureKitOwnerLease.OwnerReceipt = {
            throw ScreenCaptureKitOwnerLease.LeaseError.ownedByAnotherProcess(
                path: "/tmp/fixture-owner.lock",
                receipt: receipt)
        }
        let operation: () async throws -> Int = {
            try await ScreenCaptureKitCaptureGate.withProcessOwner(operationName: "fixture") {
                leafCalls += 1
                return 42
            }
        }

        let error: ScreenCaptureKitOwnershipDiagnostic
        do {
            _ = try await ScreenCaptureKitCaptureGate.$processOwnerClaimOverride.withValue(
                claim,
                operation: operation)
            Issue.record("Foreign ownership should refuse before the leaf")
            return
        } catch let caught as ScreenCaptureKitOwnershipDiagnostic {
            error = caught
        } catch {
            Issue.record("Unexpected error: \(error)")
            return
        }

        #expect(error.code == StandardErrorCode.captureFailed)
        #expect(error.localizedDescription.contains("PID 4242, generation 9001"))
        #expect(error.blockers.first?.processIdentifier == 4242)
        #expect(error.blockers.first?.processStartIdentity == 9001)
        #expect(leafCalls == 0)
    }

    @Test
    func `owner is rechecked immediately before a delayed ScreenCaptureKit leaf`() async {
        var claimCalls = 0
        var leafCalls = 0
        let receipt = Self.receipt(processIdentifier: 100, processStartIdentity: 200)
        let blocker = ScreenCaptureKitOwnerLease.UncoordinatedHost(
            socketPath: "/tmp/old-bridge.sock",
            processIdentifier: nil,
            processStartIdentity: nil)
        let claim: @MainActor @Sendable () throws -> ScreenCaptureKitOwnerLease.OwnerReceipt = {
            claimCalls += 1
            if claimCalls == 1 {
                return receipt
            }
            throw ScreenCaptureKitOwnerLease.LeaseError.uncoordinatedHosts([blocker])
        }
        let operation: () async throws -> Int = {
            try await ScreenCaptureKitCaptureGate.runOwnedOperation(seconds: 1, operationName: "leaf") {
                leafCalls += 1
                return 42
            }
        }

        do {
            _ = try await ScreenCaptureKitCaptureGate.$processOwnerClaimOverride.withValue(
                claim,
                operation: operation)
            Issue.record("The second owner check should refuse before the delayed leaf")
        } catch let error as ScreenCaptureKitOwnershipDiagnostic {
            #expect(error.code == StandardErrorCode.captureFailed)
            #expect(error.localizedDescription.contains("old-bridge.sock"))
            #expect(error.kind == .uncoordinatedHosts)
            #expect(error.blockers.first?.socketPath == blocker.socketPath)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(claimCalls == 2)
        #expect(leafCalls == 0)
    }

    private static func receipt(
        processIdentifier: pid_t,
        processStartIdentity: UInt64) -> ScreenCaptureKitOwnerLease.OwnerReceipt
    {
        ScreenCaptureKitOwnerLease.OwnerReceipt(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity,
            codeSignatureHash: "fixture-build")
    }
}
