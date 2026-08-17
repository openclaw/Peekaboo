import CoreGraphics
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooFoundation

enum CertificationTargetReceiptPolicy {
    static func matches(
        _ identity: WindowMutationIdentity,
        planned: WindowMutationIdentity
    ) -> Bool {
        identity.hasSameStableReceipt(as: planned) &&
            identity.isMinimized == planned.isMinimized
    }
}

enum CertificationCanonicalResponsePolicy {
    static func requireMatchingBridgeEncoding<T: Encodable>(
        signed: T,
        local: T
    ) throws {
        let signedData = try self.canonicalBridgeEncoding(signed)
        let localData = try self.canonicalBridgeEncoding(local)
        guard signedData == localData else {
            throw CertificationControllerError.runtimeRefusal(
                "Signed observation response differs from the locally returned payload."
            )
        }
    }

    private static func canonicalBridgeEncoding(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder.peekabooBridgeEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        return try encoder.encode(value)
    }
}

actor LiveCertificationBridge {
    private static let requiredProtocolVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 30)
    private static let requiredCapabilities: Set<String> = [
        "attestedOperationReceipts",
        "backgroundBridgeHost",
        "codeSignatureBuildIdentity",
        "desktopActionOutcomeProjection",
        "statelessClickVariants",
    ]
    private static let requiredOperations: Set<PeekabooBridgeOperation> = [
        .exactWindowTargetedTypeActions,
        .exactWindowTargetedClick,
        .desktopObservation,
    ]

    private let plan: CertificationControllerPlan
    private let client: PeekabooBridgeClient
    private let controllerIdentity: CertificationProcessReceipt
    private let controllerBuild: CertificationControllerBuildReceipt
    private var listenerAttestation: PeekabooBridgeListenerAttestation?
    private var sessionAttestation: PeekabooBridgeOperationSessionAttestation?
    private var exportedRequestIDs: [UUID] = []

    init(plan: CertificationControllerPlan) throws {
        guard let clientInstanceID = plan.clientUUID else {
            throw CertificationControllerError.invalidPlan("client_instance_id is invalid.")
        }
        let authenticatedBuild = try CertificationControllerBuildIdentityResolver.current(
            expectedTeamID: plan.expectedControllerBuild.teamID
        )
        try plan.expectedControllerBuild.requireMatches(authenticatedBuild.build)
        self.plan = plan
        self.controllerIdentity = authenticatedBuild.process
        self.controllerBuild = authenticatedBuild.build
        self.client = PeekabooBridgeClient(
            socketPath: plan.socketPath,
            operationReceiptExportDirectory: plan.bundleDirectoryURL,
            operationClientInstanceID: clientInstanceID,
            trustedHostTeamIDs: Set(plan.trustedBridgeHostTeamIDs)
        )
    }

    func connect() async throws -> CertificationHandshakeReceipt {
        guard self.listenerAttestation == nil, self.sessionAttestation == nil else {
            throw CertificationControllerError.runtimeRefusal("Controller handshake may run only once.")
        }
        let response = try await self.client.handshake(
            client: PeekabooBridgeClientIdentity(
                bundleIdentifier: Bundle.main.bundleIdentifier,
                teamIdentifier: self.controllerBuild.teamID,
                processIdentifier: self.controllerIdentity.pid,
                hostname: Host.current().name
            ),
            requestedHost: self.plan.expectedHost.hostKind,
            protocolVersion: Self.requiredProtocolVersion
        )
        guard response.negotiatedVersion == Self.requiredProtocolVersion else {
            throw CertificationControllerError.runtimeRefusal(
                "Bridge negotiated \(response.negotiatedVersion.major).\(response.negotiatedVersion.minor), not 1.30."
            )
        }
        guard response.hostKind == self.plan.expectedHost.hostKind else {
            throw CertificationControllerError.runtimeRefusal("Bridge host kind does not match the plan.")
        }
        let supported = Set(response.supportedOperations)
        let enabled = Set(response.enabledOperations ?? [])
        guard Self.requiredOperations.isSubset(of: supported),
              Self.requiredOperations.isSubset(of: enabled)
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Bridge does not enable all required exact-window certification operations."
            )
        }
        let capabilities = Set(response.hostCapabilities ?? [])
        guard Self.requiredCapabilities.isSubset(of: capabilities) else {
            throw CertificationControllerError.runtimeRefusal(
                "Bridge does not advertise the closed protocol-1.30 certification capabilities."
            )
        }
        guard let host = response.hostIdentity,
              let hostStartIdentity = host.processStartIdentity,
              host.processIdentifier == self.plan.expectedHost.processIdentifier,
              hostStartIdentity == self.plan.expectedHost.processStartIdentity,
              host.processStartIdentityDecimal == self.plan.expectedHost.processStartIdentityDecimal,
              host.codeSignatureHash == self.plan.expectedHost.codeSignatureHash,
              host.sourceCommit == self.plan.expectedHost.sourceCommit
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Bridge handshake host generation, CDHash, or source commit does not match the plan."
            )
        }
        // Listener attestations intentionally carry the exact executable CDHash instead of a source string.
        // Matching the handshake PID, generation, and CDHash binds its approved source commit to every receipt.
        guard let listener = response.operationAttestation,
              let session = response.operationSessionAttestation,
              listener.host.processIdentifier == host.processIdentifier,
              listener.host.processStartIdentity == hostStartIdentity,
              listener.host.codeSignatureHash == host.codeSignatureHash,
              session.listenerInstanceID == listener.listenerInstanceID,
              session.clientInstanceID.uuidString.lowercased() == self.plan.clientInstanceID,
              session.client.processIdentifier == self.controllerIdentity.pid,
              String(session.client.processStartIdentity) == self.controllerIdentity.startIdentity,
              session.client.codeSignatureHash == self.controllerIdentity.codeSignatureHash,
              session.remainingClaimCount > self.plan.slots.count,
              session.maximumRequestCount > self.plan.slots.count
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Bridge did not provide one usable listener-bound session for all four requests."
            )
        }
        try listener.validateSignature()
        try session.validateSignature(listenerAttestation: listener)
        self.listenerAttestation = listener
        self.sessionAttestation = session
        return CertificationHandshakeReceipt(
            socketPath: self.plan.socketPath,
            negotiatedVersion: .init(major: response.negotiatedVersion.major, minor: response.negotiatedVersion.minor),
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

    func execute(_ slot: CertificationSlot) async throws -> VerifiedCertificationSlot {
        guard let listener = self.listenerAttestation,
              let session = self.sessionAttestation
        else {
            throw CertificationControllerError.runtimeRefusal("Controller must authenticate before execution.")
        }
        let ordinal = self.exportedRequestIDs.count
        guard ordinal < self.plan.slots.count, self.plan.slots[ordinal] == slot else {
            throw CertificationControllerError.runtimeRefusal("Controller received an out-of-order slot.")
        }
        try self.preflightExactTarget()
        let marker = self.plan.marker(for: slot)
        let controllerStarted = Self.nowMilliseconds()
        let performed = try await self.perform(slot, marker: marker)
        let controllerCompleted = Self.nowMilliseconds()
        guard let bundle = await self.client.lastOperationReceiptBundle() else {
            throw CertificationControllerError.runtimeRefusal("Bridge operation returned without a signed bundle.")
        }
        if let exportFailure = await self.client.lastOperationReceiptExportFailure() {
            throw CertificationControllerError.runtimeRefusal(
                "Bridge bundle export failed for \(exportFailure.requestID.uuidString.lowercased())."
            )
        }
        try bundle.validate(trustAnchor: .listenerAttestation(listener))
        let payload = bundle.receipt.payload
        guard bundle.operationAttestation == listener,
              bundle.operationSessionAttestation == session,
              payload.listenerInstanceID == listener.listenerInstanceID,
              payload.sessionID == session.sessionID,
              payload.sessionSequence.value == UInt64(ordinal),
              payload.clientInstanceID.uuidString.lowercased() == self.plan.clientInstanceID,
              payload.client.processIdentifier == self.controllerIdentity.pid,
              String(payload.client.processStartIdentity) == self.controllerIdentity.startIdentity,
              payload.client.codeSignatureHash == self.controllerIdentity.codeSignatureHash,
              payload.host == listener.host,
              payload.operation == slot.operation,
              payload.outcome == performed.outcome
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Signed bundle session, process, operation, or outcome drifted at \(slot.id)."
            )
        }
        try self.validateBundleTarget(payload.target, slotID: slot.id)
        try self.validateCanonicalRequest(
            bundle.canonicalRequest,
            payload: payload,
            slot: slot,
            marker: marker
        )
        try self.validateCanonicalResponse(
            bundle.canonicalResponse,
            slot: slot,
            performed: performed
        )
        let bundleURL = self.plan.bundleDirectoryURL.appendingPathComponent(
            payload.requestID.uuidString.lowercased() + ".json"
        )
        try CertificationPrivateArtifacts.requireOwnerPrivateRegularFile(bundleURL)
        let bundleData = try Data(contentsOf: bundleURL)
        let exported = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeOperationReceiptBundle.self,
            from: bundleData
        )
        guard exported == bundle else {
            throw CertificationControllerError
                .runtimeRefusal("Exported bundle bytes do not decode to the returned bundle.")
        }
        let requestIDs = self.exportedRequestIDs + [payload.requestID]
        try CertificationPrivateArtifacts.requireExactBundleInventory(
            self.plan.bundleDirectoryURL,
            requestIDs: requestIDs
        )
        if slot.kind == .typeMutation {
            try self.writeMutationMarker(phase: "mutation-completed", to: self.plan.mutationCompletedURL)
        }
        self.exportedRequestIDs = requestIDs
        return VerifiedCertificationSlot(
            template: slot,
            marker: marker,
            requestID: payload.requestID,
            sessionID: payload.sessionID,
            sessionSequence: payload.sessionSequence.value,
            listenerInstanceID: payload.listenerInstanceID,
            target: CertificationWindowReceipt(target: self.plan.target),
            interval: .init(
                startedAtMilliseconds: payload.startedAtUnixMilliseconds,
                completedAtMilliseconds: payload.completedAtUnixMilliseconds
            ),
            controllerInterval: .init(
                startedAtMilliseconds: controllerStarted,
                completedAtMilliseconds: controllerCompleted
            ),
            outcome: payload.outcome,
            result: performed.result,
            bundle: .init(
                file: "bundles/\(payload.requestID.uuidString.lowercased()).json",
                sha256: CertificationPrivateArtifacts.sha256(bundleData),
                requestSHA256: payload.requestSHA256,
                responseSHA256: payload.responseSHA256
            )
        )
    }

    private func perform(
        _ slot: CertificationSlot,
        marker: String
    ) async throws -> PerformedCertificationSlot {
        let result: CertificationSlotResult
        let returnedOutcome: DesktopActionOutcome.Projection?
        let localObservation: DesktopObservationResult?
        switch slot.kind {
        case .typeMutation:
            try self.writeMutationMarker(phase: "mutation-started", to: self.plan.mutationStartedURL)
            let action = try await self.client.typeActionsWithOutcome(
                [.text(self.plan.typeText)],
                cadence: .fixed(milliseconds: self.plan.typingDelayMilliseconds),
                snapshotId: marker,
                expectedWindowIdentity: self.plannedWindowIdentity(),
                expectedWindowBounds: self.plan.target.bounds.cgRect
            )
            returnedOutcome = action.outcome?.projection
            localObservation = nil
            try CertificationMutationOutcomePolicy.requireSuccessfulBackgroundDispatch(
                returnedOutcome,
                operation: slot.operation.rawValue
            )
            result = CertificationSlotResult(
                status: "passed",
                totalCharacters: action.payload.totalCharacters,
                keyPresses: action.payload.keyPresses,
                observationFile: nil,
                observationSHA256: nil,
                observedBounds: nil
            )
        case .tripleClick:
            guard let tripleClick = ClickType(rawValue: "triple") else {
                throw CertificationControllerError.runtimeRefusal(
                    "This source does not contain the protocol-1.30 triple-click vocabulary."
                )
            }
            let action = try await self.client.clickWithOutcome(
                target: .coordinates(self.plan.target.clickPoint.cgPoint),
                clickType: tripleClick,
                snapshotId: marker,
                expectedWindowIdentity: self.plannedWindowIdentity(),
                expectedWindowBounds: self.plan.target.bounds.cgRect
            )
            returnedOutcome = action.outcome?.projection
            localObservation = nil
            try CertificationMutationOutcomePolicy.requireSuccessfulBackgroundDispatch(
                returnedOutcome,
                operation: slot.operation.rawValue
            )
            result = CertificationSlotResult(
                status: "passed",
                totalCharacters: nil,
                keyPresses: nil,
                observationFile: nil,
                observationSHA256: nil,
                observedBounds: nil
            )
        case .observation:
            let observationURL = self.plan.observationDirectoryURL.appendingPathComponent("\(slot.id).png")
            let action = try await self.client.desktopObservationWithOutcome(DesktopObservationRequest(
                target: .windowID(CGWindowID(self.plan.target.windowID)),
                capture: DesktopCaptureOptions(
                    engine: .auto,
                    scale: .logical1x,
                    focus: .background,
                    visualizerMode: .none,
                    includeMenuBar: false
                ),
                detection: DesktopDetectionOptions(mode: .none),
                output: DesktopObservationOutputOptions(
                    path: observationURL.path,
                    format: .png,
                    saveRawScreenshot: true,
                    saveAnnotatedScreenshot: false,
                    saveSnapshot: false,
                    snapshotID: marker
                ),
                timeout: DesktopObservationTimeouts(overall: 30, detection: nil, ocr: nil)
            ))
            returnedOutcome = action.outcome?.projection
            localObservation = action.payload
            try self.validateObservation(action.payload, expectedFile: observationURL)
            result = try CertificationSlotResult(
                status: "passed",
                totalCharacters: nil,
                keyPresses: nil,
                observationFile: "observations/\(slot.id).png",
                observationSHA256: CertificationPrivateArtifacts.sha256(file: observationURL),
                observedBounds: self.plan.target.bounds
            )
        }
        return PerformedCertificationSlot(
            outcome: returnedOutcome,
            result: result,
            localObservation: localObservation
        )
    }

    func controllerProcessReceipt() -> CertificationProcessReceipt {
        self.controllerIdentity
    }

    func controllerBuildReceipt() -> CertificationControllerBuildReceipt {
        self.controllerBuild
    }

    func preflightReady() throws {
        try self.preflightExactTarget()
    }

    func exportedIDs() -> [UUID] {
        self.exportedRequestIDs
    }

    private func plannedWindowIdentity() throws -> WindowMutationIdentity {
        guard let processStartIdentity = self.plan.target.processStartIdentity else {
            throw CertificationControllerError.invalidPlan("Target process generation is invalid.")
        }
        return WindowMutationIdentity(
            windowID: self.plan.target.windowID,
            ownerProcessIdentifier: self.plan.target.processIdentifier,
            ownerProcessStartIdentity: processStartIdentity,
            capturedBounds: self.plan.target.bounds.cgRect,
            isMinimized: self.plan.target.isMinimized
        )
    }

    private func preflightExactTarget() throws {
        // Stable identity deliberately excludes minimized state, so the certification policy checks it separately.
        guard let live = SystemIdentityResolver.windowMutationIdentity(
            windowID: CGWindowID(self.plan.target.windowID)
        ),
            try self.matchesPlannedReceipt(live)
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Exact target window, owner process generation, or bounds no longer matches the plan."
            )
        }
    }

    private func validateBundleTarget(
        _ target: PeekabooBridgeOperationTargetReceipt?,
        slotID: String
    ) throws {
        guard case let .window(identity) = target,
              try self.matchesPlannedReceipt(identity)
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Signed bundle target is not the planned exact window at \(slotID)."
            )
        }
    }

    private func validateCanonicalRequest(
        _ data: Data,
        payload: PeekabooBridgeOperationReceiptPayload,
        slot: CertificationSlot,
        marker: String
    ) throws {
        let outer = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeRequest.self, from: data)
        guard case let .attestedOperation(attested) = outer,
              attested.requestID == payload.requestID,
              attested.sessionID == payload.sessionID,
              attested.sessionSequence == payload.sessionSequence,
              attested.clientInstanceID == payload.clientInstanceID
        else {
            throw CertificationControllerError.runtimeRefusal("Canonical request lost its attested session carriage.")
        }
        let request: PeekabooBridgeRequest = if case let .projectedAction(projected) = attested.request {
            projected.request
        } else {
            attested.request
        }
        switch (slot.kind, request) {
        case let (.typeMutation, .exactWindowTargetedTypeActions(value)):
            guard value.snapshotId == marker,
                  try self.matchesPlannedReceipt(value.expectedWindowIdentity),
                  value.expectedWindowBounds == self.plan.target.bounds.cgRect,
                  value.actions.count == 1,
                  case let .text(text) = value.actions[0],
                  text == self.plan.typeText,
                  value.cadence == .fixed(milliseconds: self.plan.typingDelayMilliseconds)
            else {
                throw CertificationControllerError.runtimeRefusal("Type request does not match its closed slot plan.")
            }
        case let (.tripleClick, .targetedClick(value)):
            guard value.snapshotId == marker,
                  value.clickType.rawValue == "triple",
                  value.targetProcessIdentifier == self.plan.target.processIdentifier,
                  value.targetWindowID == self.plan.target.windowID,
                  try value.expectedWindowIdentity.map(self.matchesPlannedReceipt) == true,
                  value.expectedWindowBounds == self.plan.target.bounds.cgRect,
                  case let .coordinates(point) = value.target,
                  point == self.plan.target.clickPoint.cgPoint
            else {
                throw CertificationControllerError
                    .runtimeRefusal("Triple-click request does not match its closed slot plan.")
            }
        case let (.observation, .desktopObservation(value)):
            let expectedFile = self.plan.observationDirectoryURL.appendingPathComponent("\(slot.id).png").path
            guard value.output.snapshotID == marker,
                  value.output.path == expectedFile,
                  value.output.saveRawScreenshot,
                  !value.output.saveAnnotatedScreenshot,
                  !value.output.saveSnapshot,
                  value.capture.focus == .background,
                  value.capture.visualizerMode == .none,
                  value.detection.mode == .none,
                  case let .windowID(windowID) = value.target,
                  Int(windowID) == self.plan.target.windowID
            else {
                throw CertificationControllerError.runtimeRefusal(
                    "Desktop observation request does not match its closed slot plan."
                )
            }
        default:
            throw CertificationControllerError.runtimeRefusal(
                "Canonical request operation does not match slot \(slot.id)."
            )
        }
    }

    private func validateCanonicalResponse(
        _ data: Data,
        slot: CertificationSlot,
        performed: PerformedCertificationSlot
    ) throws {
        let response = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: data)
        switch (slot.kind, response) {
        case let (.typeMutation, .projectedAction(projected)):
            guard projected.outcome == performed.outcome,
                  case let .typeResult(signedResult) = projected.response,
                  signedResult.totalCharacters == performed.result.totalCharacters,
                  signedResult.keyPresses == performed.result.keyPresses
            else {
                throw CertificationControllerError.runtimeRefusal(
                    "Signed type response differs from the locally returned result."
                )
            }
        case let (.tripleClick, .projectedAction(projected)):
            guard projected.outcome == performed.outcome,
                  case .ok = projected.response
            else {
                throw CertificationControllerError.runtimeRefusal(
                    "Signed triple-click response differs from the locally returned result."
                )
            }
        case let (.observation, .desktopObservation(signedResult)):
            let expectedFile = self.plan.observationDirectoryURL.appendingPathComponent("\(slot.id).png")
            try self.validateObservation(signedResult, expectedFile: expectedFile)
            guard let localResult = performed.localObservation else {
                throw CertificationControllerError.runtimeRefusal(
                    "Local observation response is missing from its execution result."
                )
            }
            try CertificationCanonicalResponsePolicy.requireMatchingBridgeEncoding(
                signed: signedResult,
                local: localResult
            )
            let observationSHA256 = try CertificationPrivateArtifacts.sha256(file: expectedFile)
            guard performed.result.observationFile == "observations/\(slot.id).png",
                  performed.result.observationSHA256 == observationSHA256,
                  performed.result.observedBounds == self.plan.target.bounds
            else {
                throw CertificationControllerError.runtimeRefusal(
                    "Signed observation response differs from the locally returned result."
                )
            }
        default:
            throw CertificationControllerError.runtimeRefusal(
                "Signed response operation does not match slot \(slot.id)."
            )
        }
    }

    private func matchesPlannedReceipt(_ identity: WindowMutationIdentity) throws -> Bool {
        try CertificationTargetReceiptPolicy.matches(
            identity,
            planned: self.plannedWindowIdentity()
        )
    }

    private func validateObservation(
        _ result: DesktopObservationResult,
        expectedFile: URL
    ) throws {
        guard result.target.window?.windowID == self.plan.target.windowID,
              result.target.bounds == self.plan.target.bounds.cgRect,
              result.target.app?.processIdentifier == self.plan.target.processIdentifier,
              result.target.app?.processStartIdentity == self.plan.target.processStartIdentity,
              result.capture.metadata.windowInfo?.windowID == self.plan.target.windowID,
              try result.capture.metadata.windowInfo?.mutationIdentity.map(self.matchesPlannedReceipt) == true,
              result.files.rawScreenshotPath == expectedFile.path
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Desktop observation did not return the planned exact window and bounds."
            )
        }
        guard chmod(expectedFile.path, S_IRUSR | S_IWUSR) == 0 else {
            throw CertificationControllerError.unsafePrivatePath(
                "Cannot restrict observation artifact permissions."
            )
        }
        try CertificationPrivateArtifacts.requireOwnerPrivateRegularFile(expectedFile)
    }

    private func writeMutationMarker(phase: String, to url: URL) throws {
        let marker = CertificationMutationSynchronizationMarker(
            version: 1,
            phase: phase,
            executionNonce: self.plan.executionNonce,
            controllerID: self.plan.controllerID,
            targetID: self.plan.targetID,
            target: CertificationWindowReceipt(target: self.plan.target),
            timestampMilliseconds: Self.nowMilliseconds()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(marker)
        data.append(0x0A)
        try CertificationPrivateArtifacts.writeReceipt(data, to: url)
    }

    private static func nowMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
    }
}

private struct PerformedCertificationSlot: Sendable {
    let outcome: DesktopActionOutcome.Projection?
    let result: CertificationSlotResult
    let localObservation: DesktopObservationResult?
}
