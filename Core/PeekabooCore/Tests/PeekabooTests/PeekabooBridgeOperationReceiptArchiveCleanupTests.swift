import Dispatch
import Foundation
import Testing
@testable import PeekabooBridge

@Suite(.serialized)
struct PeekabooBridgeOperationReceiptArchiveCleanupTests {
    @Test
    func `retention quarantine below capacity does not block a fresh session`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-operation-receipt-retention-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveGate = BlockingOperationReceiptArchiveMove()
        defer { archiveGate.release() }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path,
            maximumClaimCount: 2,
            maximumSessionCount: 6,
            retainedRetiredSessionCount: 1,
            archiveFileSystem: archiveGate.fileSystem)
        let first = try await OperationReceiptSessionFixture.make(authority: authority)
        let second = try await OperationReceiptSessionFixture.make(authority: authority)
        _ = try await OperationReceiptSessionFixture.make(authority: authority)

        try authority.retireSession(
            first.attestation.sessionID,
            clientInstanceID: first.clientInstanceID,
            peer: first.peer)
        try authority.retireSession(
            second.attestation.sessionID,
            clientInstanceID: second.clientInstanceID,
            peer: second.peer)
        #expect(await archiveGate.waitUntilMoveStarts())
        #expect(!archiveGate.isReleased)

        _ = try await OperationReceiptSessionFixture.make(authority: authority)
        #expect(!archiveGate.isReleased)
    }

    @Test
    func `blocked archive quarantine does not stall claims completion or the main actor`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-operation-receipt-quarantine-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveGate = BlockingOperationReceiptArchiveMove()
        defer { archiveGate.release() }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path,
            maximumClaimCount: 2,
            maximumSessionCount: 4,
            retainedRetiredSessionCount: 1,
            archiveFileSystem: archiveGate.fileSystem)
        var capacitySession = try await OperationReceiptSessionFixture.make(authority: authority)
        let oldestSessionID = capacitySession.attestation.sessionID

        for _ in 0..<3 {
            let rollover = try await capacitySession.rolloverRefusal(
                authority: authority,
                sequence: 2,
                request: .permissionsStatus)
            capacitySession = try OperationReceiptSessionFixture(
                clientInstanceID: capacitySession.clientInstanceID,
                peer: capacitySession.peer,
                attestation: #require(rollover.refusal.payload.successorSessionAttestation))
        }

        let saturatedSession = capacitySession
        let rolloverTask = Task {
            try await saturatedSession.rolloverRefusal(
                authority: authority,
                sequence: 2,
                request: .permissionsStatus)
        }
        #expect(await archiveGate.waitUntilMoveStarts())
        #expect(!archiveGate.isReleased)

        let concurrentClaim = try await saturatedSession.acceptedClaim(
            authority: authority,
            sequence: 0,
            request: .permissionsStatus)
        let mainActorAdvanced = await MainActor.run {
            authority.complete(concurrentClaim.claim)
            return true
        }
        #expect(mainActorAdvanced)
        #expect(!archiveGate.isReleased)

        archiveGate.release()
        let completedRollover = try await rolloverTask.value
        let successor = try #require(completedRollover.refusal.payload.successorSessionAttestation)
        #expect(successor.predecessorSessionID == saturatedSession.attestation.sessionID)
        let oldestArchive = URL(fileURLWithPath: authority.attestation.receiptArchiveDirectory)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(oldestSessionID.uuidString.lowercased(), isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: oldestArchive.path))
    }

    @Test
    func `failed trash deletion does not block later capacity rollover`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-operation-receipt-trash-retry-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = PeekabooBridgeOperationReceiptArchiveFileSystem(
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            moveItem: { try FileManager.default.moveItem(at: $0, to: $1) },
            removeItem: { _ in throw ArchiveRemovalFailure.injected })
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path,
            maximumClaimCount: 2,
            maximumSessionCount: 4,
            retainedRetiredSessionCount: 1,
            archiveFileSystem: fileSystem)
        var session = try await OperationReceiptSessionFixture.make(authority: authority)

        for _ in 0..<5 {
            let rollover = try await session.rolloverRefusal(
                authority: authority,
                sequence: 2,
                request: .permissionsStatus)
            #expect(rollover.refusal.payload.disposition == .sessionRolloverRequired)
            session = try OperationReceiptSessionFixture(
                clientInstanceID: session.clientInstanceID,
                peer: session.peer,
                attestation: #require(rollover.refusal.payload.successorSessionAttestation))
        }
    }

    @Test
    func `later quarantine failure refuses rollover while cleanup still blocks capacity`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-operation-receipt-progress-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveGate = FirstArchiveMoveGateThenFailure()
        defer { archiveGate.release() }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path,
            maximumClaimCount: 2,
            maximumSessionCount: 8,
            retainedRetiredSessionCount: 1,
            archiveFileSystem: archiveGate.fileSystem)
        var retiredSessions: [OperationReceiptSessionFixture] = []
        for _ in 0..<4 {
            try await retiredSessions.append(OperationReceiptSessionFixture.make(authority: authority))
        }
        for session in retiredSessions.prefix(2) {
            try authority.retireSession(
                session.attestation.sessionID,
                clientInstanceID: session.clientInstanceID,
                peer: session.peer)
        }
        #expect(await archiveGate.waitUntilMoveStarts())
        for session in retiredSessions.dropFirst(2) {
            try authority.retireSession(
                session.attestation.sessionID,
                clientInstanceID: session.clientInstanceID,
                peer: session.peer)
        }

        var activeSessions: [OperationReceiptSessionFixture] = []
        for _ in 0..<4 {
            try await activeSessions.append(OperationReceiptSessionFixture.make(authority: authority))
        }
        let saturatedSession = try #require(activeSessions.first)
        let rolloverTask = Task {
            try await saturatedSession.rolloverRefusal(
                authority: authority,
                sequence: 2,
                request: .permissionsStatus)
        }

        archiveGate.release()
        let rollover = try await rolloverTask.value
        #expect(rollover.refusal.payload.disposition == .sessionRolloverUnavailable)
        #expect(rollover.refusal.payload.successorSessionAttestation == nil)
        #expect(archiveGate.moveAttemptCount >= 2)
    }

    @Test
    func `registry progress cannot bypass a saturated quarantine backlog`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-operation-receipt-saturated-progress-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstSource = root.appendingPathComponent("first")
        let secondSource = root.appendingPathComponent("second")
        try Data().write(to: firstSource)
        try Data().write(to: secondSource)
        let maintenance = PeekabooBridgeOperationReceiptArchiveMaintenance(
            fileSystem: .init(
                fileExists: { FileManager.default.fileExists(atPath: $0.path) },
                moveItem: { try FileManager.default.moveItem(at: $0, to: $1) },
                removeItem: { _ in throw ArchiveRemovalFailure.injected }),
            capacityBacklogLimit: 2)

        #expect(maintenance.enqueue(
            owner: .retiredSession(UUID()),
            source: firstSource,
            quarantine: root.appendingPathComponent("first.quarantine")) != nil)
        #expect(maintenance.enqueue(
            owner: .orphan,
            source: secondSource,
            quarantine: root.appendingPathComponent("second.quarantine")) != nil)

        let maintained = await maintenance.performRequired { _ in true }

        #expect(!maintained)
        #expect(maintenance.requiresCapacityMaintenance)
        #expect(maintenance.backlogIsSaturated)
        #expect(!maintenance.hasUncommittedRetiredSession)
    }
}

private enum ArchiveRemovalFailure: Error {
    case injected
}

private final class FirstArchiveMoveGateThenFailure: @unchecked Sendable {
    private let lock = NSLock()
    private let moveStarted = DispatchSemaphore(value: 0)
    private let allowFirstMove = DispatchSemaphore(value: 0)
    private var didRelease = false
    private var moveAttempts = 0

    var fileSystem: PeekabooBridgeOperationReceiptArchiveFileSystem {
        PeekabooBridgeOperationReceiptArchiveFileSystem(
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            moveItem: { [self] source, destination in
                let attempt = self.lock.withLock {
                    self.moveAttempts += 1
                    return self.moveAttempts
                }
                guard attempt == 1 else { throw ArchiveRemovalFailure.injected }
                self.moveStarted.signal()
                guard self.allowFirstMove.wait(timeout: .now() + 5) == .success else {
                    throw ArchiveRemovalFailure.injected
                }
                try FileManager.default.moveItem(at: source, to: destination)
            },
            removeItem: { try FileManager.default.removeItem(at: $0) })
    }

    var moveAttemptCount: Int {
        self.lock.withLock { self.moveAttempts }
    }

    func waitUntilMoveStarts() async -> Bool {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread { [self] in
                continuation.resume(returning: self.moveStarted.wait(timeout: .now() + 2) == .success)
            }
        }
    }

    func release() {
        let shouldSignal = self.lock.withLock {
            guard !self.didRelease else { return false }
            self.didRelease = true
            return true
        }
        if shouldSignal {
            self.allowFirstMove.signal()
        }
    }
}

private final class BlockingOperationReceiptArchiveMove: @unchecked Sendable {
    private enum GateError: Error {
        case releaseTimedOut
    }

    private let lock = NSLock()
    private let moveStarted = DispatchSemaphore(value: 0)
    private let allowMove = DispatchSemaphore(value: 0)
    private var didRelease = false

    var fileSystem: PeekabooBridgeOperationReceiptArchiveFileSystem {
        PeekabooBridgeOperationReceiptArchiveFileSystem(
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            moveItem: { [self] source, destination in
                self.moveStarted.signal()
                guard self.allowMove.wait(timeout: .now() + 5) == .success else {
                    throw GateError.releaseTimedOut
                }
                try FileManager.default.moveItem(at: source, to: destination)
            },
            removeItem: { try FileManager.default.removeItem(at: $0) })
    }

    var isReleased: Bool {
        self.lock.withLock { self.didRelease }
    }

    func waitUntilMoveStarts() async -> Bool {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread { [self] in
                continuation.resume(returning: self.moveStarted.wait(timeout: .now() + 2) == .success)
            }
        }
    }

    func release() {
        let shouldSignal = self.lock.withLock {
            guard !self.didRelease else { return false }
            self.didRelease = true
            return true
        }
        if shouldSignal {
            self.allowMove.signal()
        }
    }
}
