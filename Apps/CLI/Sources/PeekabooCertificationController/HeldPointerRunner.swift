import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooFoundation

struct HeldPointerCertificationOperationReceipt: Codable, Equatable, Sendable {
    let operation: String
    let requestID: String
    let sessionSequence: String
    let listenerInstanceID: String
    let interval: CertificationIntervalReceipt
    let outcome: DesktopActionOutcome.Projection?
    let bundle: CertificationBundleReceipt

    private enum CodingKeys: String, CodingKey {
        case operation
        case requestID = "request_id"
        case sessionSequence = "session_sequence"
        case listenerInstanceID = "listener_instance_id"
        case interval
        case outcome
        case bundle
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.operation, forKey: .operation)
        try container.encode(self.requestID, forKey: .requestID)
        try container.encode(self.sessionSequence, forKey: .sessionSequence)
        try container.encode(self.listenerInstanceID, forKey: .listenerInstanceID)
        try container.encode(self.interval, forKey: .interval)
        try container.encode(self.outcome, forKey: .outcome)
        try container.encode(self.bundle, forKey: .bundle)
    }
}

struct HeldPointerCertificationReceipt: Codable, Equatable, Sendable {
    let version: Int
    let result: String
    let executionNonce: String
    let controller: CertificationProcessReceipt
    let build: CertificationControllerBuildReceipt
    let handshake: CertificationHandshakeReceipt
    let target: CertificationWindowReceipt
    let point: CertificationPoint
    let button: String
    let holdMilliseconds: Int
    let interval: CertificationIntervalReceipt
    let beginDispatchedUnits: Int
    let releaseDispatchedUnits: Int
    let lifecycleDispatchedUnits: Int
    let terminalReason: String
    let cleanupState: String
    let operations: [HeldPointerCertificationOperationReceipt]

    private enum CodingKeys: String, CodingKey {
        case version
        case result
        case executionNonce = "execution_nonce"
        case controller
        case build
        case handshake
        case target
        case point
        case button
        case holdMilliseconds = "hold_milliseconds"
        case interval
        case beginDispatchedUnits = "begin_dispatched_units"
        case releaseDispatchedUnits = "release_dispatched_units"
        case lifecycleDispatchedUnits = "lifecycle_dispatched_units"
        case terminalReason = "terminal_reason"
        case cleanupState = "cleanup_state"
        case operations
    }
}

enum HeldPointerReceiptTargetExpectation {
    case unchecked
    case absent
    case exact(WindowMutationIdentity)
}

enum HeldPointerCertificationSemantics {
    struct ExpectedTarget: Sendable {
        let identity: WindowMutationIdentity
        let bounds: CGRect
        let point: CGPoint
    }

    struct ReleaseEvidence {
        let outcome: DesktopActionOutcome?
        let targetIdentity: DesktopTargetIdentity?
        let reason: ExactWindowHeldPointerTerminalReason
        let receiptIdentity: WindowMutationIdentity
        let receiptBounds: CGRect
        let receiptPoint: CGPoint
        let receiptButton: ExactWindowHeldPointerButton
        let lifecycleDispatchedUnits: Int
    }

    struct FailureDisconnectEvidence: Sendable {
        let outcome: DesktopActionOutcome?
        let targetIdentity: DesktopTargetIdentity?
        let terminalReason: ExactWindowHeldPointerTerminalReason?
        let lifecycleDispatchedUnits: Int?
        let hasPayload: Bool
    }

    static func requireBegin(
        outcome: DesktopActionOutcome?,
        targetIdentity: DesktopTargetIdentity?,
        plannedIdentity: WindowMutationIdentity,
        plannedBounds: CGRect
    ) throws {
        guard outcome?.route == .bridge,
              outcome?.delivery?.mode == .background,
              outcome?.delivery?.mechanism == .windowTargetedEvents,
              outcome?.dispatchState.mutationDispatched == true,
              outcome?.dispatchState.unitCount?.rawValue == 2,
              targetIdentity?.exactWindow?.identity == plannedIdentity,
              targetIdentity?.exactWindow?.bounds == plannedBounds
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Held-pointer begin did not prove two exact-window background units."
            )
        }
    }

    static func requireRelease(_ observed: ReleaseEvidence, expected: ExpectedTarget) throws {
        guard observed.reason == .released,
              observed.receiptIdentity == expected.identity,
              observed.receiptBounds == expected.bounds,
              observed.receiptPoint == expected.point,
              observed.receiptButton == .left,
              observed.outcome?.route == .bridge,
              observed.outcome?.delivery?.mode == .background,
              observed.outcome?.delivery?.mechanism == .windowTargetedEvents,
              observed.outcome?.dispatchState.mutationDispatched == true,
              observed.outcome?.dispatchState.unitCount?.rawValue == 1,
              observed.targetIdentity?.exactWindow?.identity == expected.identity,
              observed.targetIdentity?.exactWindow?.bounds == expected.bounds,
              observed.lifecycleDispatchedUnits == 3
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Held-pointer release did not prove the exact three-unit released lifecycle."
            )
        }
    }

    static func requireDisconnect(
        outcome: DesktopActionOutcome?,
        hasPayload: Bool,
        targetIdentity: DesktopTargetIdentity?
    ) throws {
        guard !hasPayload,
              outcome == .confirmedNoChange(route: .bridge),
              targetIdentity == nil
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Released held-pointer owner did not disconnect with a signed zero-dispatch result."
            )
        }
    }

    static func requireFailureDisconnect(
        _ observed: FailureDisconnectEvidence,
        expected: ExpectedTarget
    ) throws {
        if !observed.hasPayload {
            try self.requireDisconnect(
                outcome: observed.outcome,
                hasPayload: false,
                targetIdentity: observed.targetIdentity
            )
            return
        }
        guard observed.terminalReason == .ownerDisconnected,
              observed.lifecycleDispatchedUnits == 3,
              observed.outcome?.route == .bridge,
              observed.outcome?.delivery?.mode == .background,
              observed.outcome?.delivery?.mechanism == .windowTargetedEvents,
              observed.outcome?.dispatchState.mutationDispatched == true,
              observed.outcome?.dispatchState.unitCount?.rawValue == 1,
              observed.targetIdentity?.exactWindow?.identity == expected.identity,
              observed.targetIdentity?.exactWindow?.bounds == expected.bounds
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Failure-path held-pointer disconnect did not prove exact owner cleanup."
            )
        }
    }

    static func performFailureCleanup(
        originalError: any Error,
        expected: ExpectedTarget,
        disconnect: @escaping @Sendable () async throws -> FailureDisconnectEvidence
    ) async throws -> Never {
        // The detached task does not inherit caller cancellation. Production cleanup remains
        // bounded by the exact Bridge client's configured transport timeout.
        let cleanupTask = Task.detached { try await disconnect() }
        do {
            let evidence = try await cleanupTask.value
            try self.requireFailureDisconnect(evidence, expected: expected)
        } catch let cleanupError {
            throw CertificationControllerError.runtimeRefusal(
                "Held-pointer lifecycle failed: \(originalError.localizedDescription); " +
                    "explicit owner cleanup failed: \(cleanupError.localizedDescription)"
            )
        }
        throw originalError
    }

    static func requireReceiptTarget(
        _ actual: PeekabooBridgeOperationTargetReceipt?,
        expected: HeldPointerReceiptTargetExpectation
    ) throws {
        let matches = switch expected {
        case .unchecked: true
        case .absent: actual == nil
        case let .exact(identity): actual == .window(identity)
        }
        guard matches else {
            throw CertificationControllerError.runtimeRefusal(
                "Held-pointer signed receipt target differs from the expected target policy."
            )
        }
    }
}

private struct HeldPointerLifecycleResult {
    let operations: [HeldPointerCertificationOperationReceipt]
    let terminalReason: ExactWindowHeldPointerTerminalReason
    let lifecycleDispatchedUnits: Int
}

private struct HeldPointerReceiptTracker {
    let directory: URL
    let listener: PeekabooBridgeListenerAttestation
    let session: PeekabooBridgeOperationSessionAttestation
    let controller: CertificationProcessReceipt
    private(set) var requestIDs: [UUID] = []

    mutating func record(
        client: PeekabooBridgeClient,
        expectedOperation: PeekabooBridgeOperation,
        expectedTarget: HeldPointerReceiptTargetExpectation = .unchecked,
        expectedOutcome: DesktopActionOutcome.Projection? = nil
    ) async throws -> HeldPointerCertificationOperationReceipt {
        guard await client.lastOperationReceiptExportFailure() == nil,
              let bundle = await client.lastOperationReceiptBundle()
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Bridge did not export the expected held-pointer signed receipt."
            )
        }
        try bundle.validate(trustAnchor: .listenerAttestation(self.listener))
        let payload = bundle.receipt.payload
        let ordinal = self.requestIDs.count
        guard bundle.operationAttestation == self.listener,
              bundle.operationSessionAttestation == self.session,
              payload.listenerInstanceID == self.listener.listenerInstanceID,
              payload.sessionID == self.session.sessionID,
              payload.clientInstanceID == self.session.clientInstanceID,
              payload.sessionSequence.value == UInt64(ordinal),
              payload.client.processIdentifier == self.controller.pid,
              String(payload.client.processStartIdentity) == self.controller.startIdentity,
              payload.client.codeSignatureHash == self.controller.codeSignatureHash,
              payload.host == self.listener.host,
              payload.operation == expectedOperation,
              payload.outcome == expectedOutcome
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Held-pointer bundle session, client generation, operation, or outcome drifted."
            )
        }
        try HeldPointerCertificationSemantics.requireReceiptTarget(
            payload.target,
            expected: expectedTarget
        )
        guard !self.requestIDs.contains(payload.requestID) else {
            throw CertificationControllerError.runtimeRefusal(
                "Held-pointer signed receipt reused a request ID."
            )
        }
        let bundleURL = self.directory.appendingPathComponent(
            payload.requestID.uuidString.lowercased() + ".json",
            isDirectory: false
        )
        try CertificationPrivateArtifacts.requireOwnerPrivateRegularFile(bundleURL)
        let bundleData = try Data(contentsOf: bundleURL)
        let exported = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeOperationReceiptBundle.self,
            from: bundleData
        )
        guard exported == bundle else {
            throw CertificationControllerError.runtimeRefusal(
                "Held-pointer exported bundle differs from the returned signed bundle."
            )
        }
        self.requestIDs.append(payload.requestID)
        try CertificationPrivateArtifacts.requireExactBundleInventory(
            self.directory,
            requestIDs: self.requestIDs
        )
        return HeldPointerCertificationOperationReceipt(
            operation: payload.operation.rawValue,
            requestID: payload.requestID.uuidString.lowercased(),
            sessionSequence: String(payload.sessionSequence.value),
            listenerInstanceID: payload.listenerInstanceID.uuidString.lowercased(),
            interval: .init(
                startedAtMilliseconds: payload.startedAtUnixMilliseconds,
                completedAtMilliseconds: payload.completedAtUnixMilliseconds
            ),
            outcome: payload.outcome,
            bundle: .init(
                file: "bundles/\(payload.requestID.uuidString.lowercased()).json",
                sha256: CertificationPrivateArtifacts.sha256(bundleData),
                requestSHA256: payload.requestSHA256,
                responseSHA256: payload.responseSHA256
            )
        )
    }
}

enum HeldPointerCertificationRunner {
    private static let protocolVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 30)
    private static let requiredCapabilities: Set<String> = [
        PeekabooBridgeHostCapability.attestedOperationReceipts,
        PeekabooBridgeHostCapability.backgroundBridgeHost,
        PeekabooBridgeHostCapability.codeSignatureBuildIdentity,
        PeekabooBridgeHostCapability.desktopActionOutcomeProjection,
        PeekabooBridgeHostCapability.exactWindowHeldPointerLifecycle,
        PeekabooBridgeHostCapability.plannerInventoryTransport,
    ]
    private static let requiredOperations: Set<PeekabooBridgeOperation> = [
        .listWindows,
        .createExactWindowHeldPointerOwner,
        .beginExactWindowHeldPointer,
        .releaseExactWindowHeldPointer,
        .disconnectExactWindowHeldPointerOwner,
    ]

    static func run(planURL: URL) async throws -> URL {
        let planData = try CertificationPrivateArtifacts.readPlan(at: planURL)
        let plan = try HeldPointerCertificationPlan.decode(planData)
        try CertificationPrivateArtifacts.prepareHeldPointer(for: plan)
        let startedAt = Self.nowMilliseconds()
        let authenticatedBuild = try CertificationControllerBuildIdentityResolver.current(
            expectedTeamID: plan.expectedControllerBuild.teamID
        )
        try plan.expectedControllerBuild.requireMatches(authenticatedBuild.build)
        guard authenticatedBuild.process.pid != plan.target.processIdentifier else {
            throw CertificationControllerError.runtimeRefusal(
                "Held-pointer controller and target must be distinct process generations."
            )
        }
        guard let clientInstanceID = plan.clientUUID else {
            throw CertificationControllerError.invalidPlan("client_instance_id is invalid.")
        }
        let client = PeekabooBridgeClient(
            socketPath: plan.socketPath,
            requestTimeoutSec: 10,
            operationReceiptExportDirectory: plan.bundleDirectoryURL,
            operationClientInstanceID: clientInstanceID,
            trustedHostTeamIDs: Set(plan.trustedBridgeHostTeamIDs)
        )
        let handshake = try await client.handshake(
            client: PeekabooBridgeClientIdentity(
                bundleIdentifier: Bundle.main.bundleIdentifier,
                teamIdentifier: authenticatedBuild.build.teamID,
                processIdentifier: authenticatedBuild.process.pid,
                hostname: Host.current().name
            ),
            requestedHost: plan.expectedHost.hostKind,
            protocolVersion: Self.protocolVersion,
            overallTimeoutSec: 10
        )
        let handshakeReceipt = try self.validateHandshake(
            handshake,
            plan: plan,
            controller: authenticatedBuild.process
        )
        guard let listener = handshake.operationAttestation,
              let session = handshake.operationSessionAttestation
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Held-pointer handshake omitted its signed listener or session."
            )
        }
        var tracker = HeldPointerReceiptTracker(
            directory: plan.bundleDirectoryURL,
            listener: listener,
            session: session,
            controller: authenticatedBuild.process
        )
        let lifecycle = try await self.performLifecycle(plan: plan, client: client, tracker: &tracker)
        let receipt = HeldPointerCertificationReceipt(
            version: 1,
            result: "passed",
            executionNonce: plan.executionNonce,
            controller: authenticatedBuild.process,
            build: authenticatedBuild.build,
            handshake: handshakeReceipt,
            target: CertificationWindowReceipt(target: plan.target),
            point: plan.target.clickPoint,
            button: ExactWindowHeldPointerButton.left.rawValue,
            holdMilliseconds: plan.holdMilliseconds,
            interval: .init(
                startedAtMilliseconds: startedAt,
                completedAtMilliseconds: Self.nowMilliseconds()
            ),
            beginDispatchedUnits: 2,
            releaseDispatchedUnits: 1,
            lifecycleDispatchedUnits: lifecycle.lifecycleDispatchedUnits,
            terminalReason: lifecycle.terminalReason.rawValue,
            cleanupState: "owner_disconnected",
            operations: lifecycle.operations
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var receiptData = try encoder.encode(receipt)
        receiptData.append(0x0A)
        try CertificationPrivateArtifacts.writeReceipt(receiptData, to: plan.receiptURL)
        return plan.receiptURL
    }

    private static func performLifecycle(
        plan: HeldPointerCertificationPlan,
        client: PeekabooBridgeClient,
        tracker: inout HeldPointerReceiptTracker
    ) async throws -> HeldPointerLifecycleResult {
        var operations: [HeldPointerCertificationOperationReceipt] = []
        var owner: ExactWindowHeldPointerOwner?
        var ownedTarget: HeldPointerCertificationSemantics.ExpectedTarget?
        do {
            let firstInventory = try await client.listWindowMutationInventory(
                target: .windowId(plan.target.windowID)
            )
            try await operations.append(tracker.record(client: client, expectedOperation: .listWindows))
            let firstWindow = try self.exactWindow(from: firstInventory, plan: plan)
            let secondInventory = try await client.listWindowMutationInventory(
                target: .windowId(plan.target.windowID)
            )
            try await operations.append(tracker.record(client: client, expectedOperation: .listWindows))
            let secondWindow = try self.exactWindow(from: secondInventory, plan: plan)
            guard firstWindow == secondWindow, let identity = secondWindow.mutationIdentity else {
                throw CertificationControllerError.runtimeRefusal(
                    "Exact held-pointer target changed between complete inventories."
                )
            }

            let createdOwner = try await client.createExactWindowHeldPointerOwner()
            owner = createdOwner
            ownedTarget = .init(
                identity: identity,
                bounds: plan.target.bounds.cgRect,
                point: plan.target.clickPoint.cgPoint
            )
            try await operations.append(tracker.record(
                client: client,
                expectedOperation: .createExactWindowHeldPointerOwner
            ))
            let begin = try await client.beginExactWindowPointerHold(
                owner: createdOwner,
                request: ExactWindowHeldPointerRequest(
                    point: plan.target.clickPoint.cgPoint,
                    windowIdentity: identity,
                    windowBounds: plan.target.bounds.cgRect,
                    button: .left,
                    expiresAfterSeconds: 5
                )
            )
            try HeldPointerCertificationSemantics.requireBegin(
                outcome: begin.outcome,
                targetIdentity: begin.targetIdentity,
                plannedIdentity: identity,
                plannedBounds: plan.target.bounds.cgRect
            )
            try await operations.append(tracker.record(
                client: client,
                expectedOperation: .beginExactWindowHeldPointer,
                expectedTarget: .exact(identity),
                expectedOutcome: begin.outcome?.projection
            ))

            try await Task.sleep(for: .milliseconds(plan.holdMilliseconds))
            let release = try await client.releaseExactWindowPointerHold(
                owner: createdOwner,
                receipt: begin.payload
            )
            try HeldPointerCertificationSemantics.requireRelease(
                .init(
                    outcome: release.outcome,
                    targetIdentity: release.targetIdentity,
                    reason: release.payload.reason,
                    receiptIdentity: release.payload.receipt.windowIdentity,
                    receiptBounds: release.payload.receipt.windowBounds,
                    receiptPoint: release.payload.receipt.point,
                    receiptButton: release.payload.receipt.button,
                    lifecycleDispatchedUnits: release.payload.lifecycleDispatchedUnitCount
                ),
                expected: .init(
                    identity: identity,
                    bounds: plan.target.bounds.cgRect,
                    point: plan.target.clickPoint.cgPoint
                )
            )
            try await operations.append(tracker.record(
                client: client,
                expectedOperation: .releaseExactWindowHeldPointer,
                expectedTarget: .exact(identity),
                expectedOutcome: release.outcome?.projection
            ))

            let disconnect = try await client.disconnectExactWindowHeldPointerOwner(createdOwner)
            try HeldPointerCertificationSemantics.requireDisconnect(
                outcome: disconnect.outcome,
                hasPayload: disconnect.payload != nil,
                targetIdentity: disconnect.targetIdentity
            )
            try await operations.append(tracker.record(
                client: client,
                expectedOperation: .disconnectExactWindowHeldPointerOwner,
                expectedTarget: .absent,
                expectedOutcome: disconnect.outcome?.projection
            ))
            owner = nil
            guard operations.map(\.operation) == self.expectedOperationOrder,
                  tracker.requestIDs.count == self.expectedOperationOrder.count
            else {
                throw CertificationControllerError.runtimeRefusal(
                    "Held-pointer lifecycle did not produce the closed ordered six-receipt corpus."
                )
            }
            return HeldPointerLifecycleResult(
                operations: operations,
                terminalReason: release.payload.reason,
                lifecycleDispatchedUnits: release.payload.lifecycleDispatchedUnitCount
            )
        } catch {
            if let owner, let ownedTarget {
                try await HeldPointerCertificationSemantics.performFailureCleanup(
                    originalError: error,
                    expected: ownedTarget
                ) {
                    let disconnect = try await client.disconnectExactWindowHeldPointerOwner(owner)
                    return .init(
                        outcome: disconnect.outcome,
                        targetIdentity: disconnect.targetIdentity,
                        terminalReason: disconnect.payload?.reason,
                        lifecycleDispatchedUnits: disconnect.payload?.lifecycleDispatchedUnitCount,
                        hasPayload: disconnect.payload != nil
                    )
                }
            }
            throw error
        }
    }

    private static let expectedOperationOrder = [
        PeekabooBridgeOperation.listWindows.rawValue,
        PeekabooBridgeOperation.listWindows.rawValue,
        PeekabooBridgeOperation.createExactWindowHeldPointerOwner.rawValue,
        PeekabooBridgeOperation.beginExactWindowHeldPointer.rawValue,
        PeekabooBridgeOperation.releaseExactWindowHeldPointer.rawValue,
        PeekabooBridgeOperation.disconnectExactWindowHeldPointerOwner.rawValue,
    ]

    private static func validateHandshake(
        _ response: PeekabooBridgeHandshakeResponse,
        plan: HeldPointerCertificationPlan,
        controller: CertificationProcessReceipt
    ) throws -> CertificationHandshakeReceipt {
        guard response.negotiatedVersion == self.protocolVersion,
              response.hostKind == plan.expectedHost.hostKind,
              self.requiredOperations.isSubset(of: Set(response.supportedOperations)),
              self.requiredOperations.isSubset(of: Set(response.enabledOperations ?? [])),
              self.requiredCapabilities.isSubset(of: Set(response.hostCapabilities ?? [])),
              let host = response.hostIdentity,
              let hostStartIdentity = host.processStartIdentity,
              host.processIdentifier == plan.expectedHost.processIdentifier,
              hostStartIdentity == plan.expectedHost.processStartIdentity,
              host.processStartIdentityDecimal == plan.expectedHost.processStartIdentityDecimal,
              host.codeSignatureHash == plan.expectedHost.codeSignatureHash,
              host.sourceCommit == plan.expectedHost.sourceCommit,
              let listener = response.operationAttestation,
              let session = response.operationSessionAttestation,
              listener.host.processIdentifier == host.processIdentifier,
              listener.host.processStartIdentity == hostStartIdentity,
              listener.host.codeSignatureHash == host.codeSignatureHash,
              session.listenerInstanceID == listener.listenerInstanceID,
              session.clientInstanceID == plan.clientUUID,
              session.client.processIdentifier == controller.pid,
              String(session.client.processStartIdentity) == controller.startIdentity,
              session.client.codeSignatureHash == controller.codeSignatureHash,
              session.remainingClaimCount > 6,
              session.maximumRequestCount > 6
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Bridge did not provide the exact protocol-1.30 held-pointer host and session."
            )
        }
        try listener.validateSignature()
        try session.validateSignature(listenerAttestation: listener)
        return CertificationHandshakeReceipt(
            socketPath: plan.socketPath,
            negotiatedVersion: .init(
                major: response.negotiatedVersion.major,
                minor: response.negotiatedVersion.minor
            ),
            hostKind: response.hostKind.rawValue,
            build: response.build,
            listenerInstanceID: listener.listenerInstanceID.uuidString.lowercased(),
            host: CertificationHostReceipt(
                process: .init(
                    pid: host.processIdentifier,
                    startIdentity: String(hostStartIdentity),
                    codeSignatureHash: host.codeSignatureHash ?? ""
                ),
                bundleIdentifier: host.bundleIdentifier,
                bundleShortVersion: host.bundleShortVersion,
                bundleVersion: host.bundleVersion,
                sourceCommit: host.sourceCommit ?? ""
            ),
            session: .init(
                id: session.sessionID.uuidString.lowercased(),
                clientInstanceID: session.clientInstanceID.uuidString.lowercased(),
                maximumRequestCount: session.maximumRequestCount,
                initialRemainingClaimCount: session.remainingClaimCount
            )
        )
    }

    private static func exactWindow(
        from inventory: DesktopTargetPlanning.Inventory<ServiceWindowInfo>,
        plan: HeldPointerCertificationPlan
    ) throws -> ServiceWindowInfo {
        guard inventory.isComplete,
              inventory.items.count == 1,
              let window = inventory.items.first,
              window.windowID == plan.target.windowID,
              window.bounds == plan.target.bounds.cgRect,
              window.isMinimized == false,
              window.bounds.contains(plan.target.clickPoint.cgPoint),
              let identity = window.mutationIdentity,
              identity == self.plannedWindowIdentity(plan)
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Held-pointer inventory is incomplete, ambiguous, stale, minimized, or off-target."
            )
        }
        return window
    }

    private static func plannedWindowIdentity(
        _ plan: HeldPointerCertificationPlan
    ) -> WindowMutationIdentity? {
        guard let startIdentity = plan.target.processStartIdentity else { return nil }
        return WindowMutationIdentity(
            windowID: plan.target.windowID,
            ownerProcessIdentifier: plan.target.processIdentifier,
            ownerProcessStartIdentity: startIdentity,
            capturedBounds: plan.target.bounds.cgRect,
            isMinimized: plan.target.isMinimized
        )
    }

    private static func nowMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
    }
}
