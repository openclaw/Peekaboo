import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooBridge
@testable import PeekabooCore

extension PeekabooBridgeOperationReceiptTests {
    @Test
    func `successful projected response enforces the request result contract`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-operation-receipt-outcome-contradiction-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let request = PeekabooBridgeRequest.projectedAction(.init(request: .moveMouse(.init(
            to: CGPoint(x: 17, y: 29),
            duration: 0,
            steps: 1,
            profile: .linear))))
        func makeBundle(
            sequence: UInt64,
            outcome: DesktopActionOutcome) async throws -> PeekabooBridgeOperationReceiptBundle
        {
            let response = PeekabooBridgeResponse.projectedAction(.init(
                response: .ok,
                outcome: outcome.projection))
            return try await session.signedBundle(
                authority: authority,
                sequence: sequence,
                request: request,
                response: response,
                target: .global,
                outcome: outcome.projection)
        }

        let valid = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one)
        try await makeBundle(sequence: 0, outcome: valid).validate()

        let refusal = DesktopActionOutcome.refused(route: .bridge, reason: .invalidRequest)
        let wrongDelivery = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let wrongUnitCount = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2))
        let missingUnitCount = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted)
        for (sequence, outcome) in [refusal, wrongDelivery, wrongUnitCount, missingUnitCount].enumerated() {
            let bundle = try await makeBundle(sequence: UInt64(sequence + 1), outcome: outcome)
            #expect(throws: PeekabooBridgeOperationReceiptError.self) {
                try bundle.validate()
            }
        }
    }

    @Test
    func `mixed Dock selection failure validates as a signed retry-unsafe receipt`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-dock-mixed-delivery-receipt-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let request = PeekabooBridgeRequest.projectedAction(.init(request: .rightClickDockItem(.init(
            appName: "Safari",
            menuItem: "Options"))))
        let dock = ApplicationProcessIdentity(
            processIdentifier: 702,
            processStartIdentity: 9002)
        let targetReceipt = DesktopActionTargetReceipt(
            processIdentifier: dock.processIdentifier,
            processStartIdentity: dock.processStartIdentity)
        let selectedLeaves = try [
            DesktopSelectedLeafEvidence(
                kind: .dockItem,
                normalizedSelector: "safari",
                matchKind: .exact,
                selectedTargetReceipt: targetReceipt,
                selectedIndex: 0,
                selectedTitle: "Safari",
                selectedIdentifier: "com.apple.Safari",
                selectedRole: "AXDockItem",
                selectedFrame: CGRect(x: 10, y: 10, width: 20, height: 20),
                candidateSetSHA256: String(repeating: "a", count: 64),
                candidateCount: 1),
            DesktopSelectedLeafEvidence(
                kind: .dockContextMenuItem,
                normalizedSelector: "options",
                matchKind: .exact,
                selectedTargetReceipt: targetReceipt,
                selectedIndex: 0,
                selectedTitle: "Options",
                selectedIdentifier: "fixture.options",
                selectedRole: "AXMenuItem",
                selectedFrame: CGRect(x: 10, y: 40, width: 80, height: 20),
                candidateSetSHA256: String(repeating: "b", count: 64),
                candidateCount: 1),
        ]
        let failure = DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .composite, mode: .foreground),
            evidence: .completionUnknown,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2),
            message: "The Dock right-click and menu selection may both have been dispatched.")
            .attributed(to: targetReceipt)
            .selectingLeaves(selectedLeaves)
        let response = PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
            PeekabooBridgeResponse.projectedActionForCurrentRequestVocabulary(
                response: .error(.init(code: .internalError, actionFailure: failure)),
                outcome: failure.outcome.projection)
        }
        let accepted = try await session.acceptedClaim(
            authority: authority,
            sequence: 0,
            request: request)
        let payload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: accepted.claim,
            request: request,
            response: response,
            target: .process(dock),
            selectedLeafEvidence: selectedLeaves,
            outcome: failure.outcome.projection)
        let receipt = try await authority.signAndArchive(payload, claim: accepted.claim)
        let bundle = try OperationReceiptSessionFixture.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: receipt,
            request: request,
            response: response)

        try bundle.validate()
        #expect(receipt.payload.outcome == failure.outcome.projection)
        #expect(receipt.payload.outcome?.deliveryMechanism == .composite)
        #expect(receipt.payload.outcome?.dispatchedUnitCount == DesktopActionOutcome.DispatchUnitCount(2))
        #expect(receipt.payload.outcome?.retrySafe == false)
        authority.complete(accepted.claim)
    }

    @Test
    func `exact window click receipts admit only exact AX or window delivery and target`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-exact-window-click-receipt-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let identity = WindowMutationIdentity(
            windowID: 71,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 1001,
            capturedBounds: bounds)
        let request = PeekabooBridgeRequest.projectedAction(.init(request: .targetedClick(.init(
            target: .elementId("B1"),
            clickType: .single,
            snapshotId: "snapshot",
            targetProcessIdentifier: identity.ownerProcessIdentifier,
            targetWindowID: identity.windowID,
            expectedWindowIdentity: identity,
            expectedWindowBounds: bounds))))
        let three = try #require(DesktopActionOutcome.DispatchUnitCount(3))
        let ax = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let window = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: three)
        let global = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let process = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .processTargetedEvents, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: three)

        func makeBundle(
            sequence: UInt64,
            outcome: DesktopActionOutcome,
            target: PeekabooBridgeOperationTargetReceipt) async throws -> PeekabooBridgeOperationReceiptBundle
        {
            let response = PeekabooBridgeResponse.projectedAction(.init(
                response: .ok,
                outcome: outcome.projection))
            return try await session.signedBundle(
                authority: authority,
                sequence: sequence,
                request: request,
                response: response,
                target: target,
                outcome: outcome.projection)
        }

        try await makeBundle(sequence: 0, outcome: ax, target: .window(identity)).validate()
        try await makeBundle(sequence: 1, outcome: window, target: .window(identity)).validate()
        for (sequence, outcome) in [global, process].enumerated() {
            let bundle = try await makeBundle(
                sequence: UInt64(sequence + 2),
                outcome: outcome,
                target: .window(identity))
            #expect(throws: PeekabooBridgeOperationReceiptError.self) {
                try bundle.validate()
            }
        }

        let processTarget = ApplicationProcessIdentity(
            processIdentifier: identity.ownerProcessIdentifier,
            processStartIdentity: identity.ownerProcessStartIdentity)
        let widened = try await makeBundle(sequence: 4, outcome: ax, target: .process(processTarget))
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try widened.validate()
        }
        let contradictoryIdentity = WindowMutationIdentity(
            windowID: identity.windowID + 1,
            ownerProcessIdentifier: identity.ownerProcessIdentifier,
            ownerProcessStartIdentity: identity.ownerProcessStartIdentity,
            capturedBounds: bounds)
        let contradictory = try await makeBundle(
            sequence: 5,
            outcome: window,
            target: .window(contradictoryIdentity))
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try contradictory.validate()
        }
    }

    @Test
    func `tampering with signed receipt facts or exported bytes fails validation`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-operation-receipt-tamper-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path)
        let response = PeekabooBridgeResponse.permissionsStatus(.init(
            screenRecording: true,
            accessibility: true))
        let request = PeekabooBridgeRequest.permissionsStatus
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let validClaim = try await session.acceptedClaim(
            authority: authority,
            sequence: 0,
            request: request)
        let forgedClaim = try await session.acceptedClaim(
            authority: authority,
            sequence: 1,
            request: request)
        let largeIdentity = WindowMutationIdentity(
            windowID: 73,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 9_007_199_254_740_993,
            capturedBounds: CGRect(x: 10, y: 20, width: 300, height: 200))
        let payload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: validClaim.claim,
            request: request,
            response: response)
        let receipt = try await authority.signAndArchive(payload, claim: validClaim.claim)
        let bundle = try OperationReceiptSessionFixture.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: receipt,
            request: request,
            response: response)
        try bundle.validate()

        let forgedPayload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: forgedClaim.claim,
            request: request,
            response: response,
            target: .window(largeIdentity))
        let forgedReceipt = try await authority.signAndArchive(forgedPayload, claim: forgedClaim.claim)
        let forgedBundle = try PeekabooBridgeOperationReceiptBundle(
            operationAttestation: authority.attestation,
            operationSessionAttestation: session.attestation,
            receipt: forgedReceipt,
            canonicalListenerAttestationPayload: bundle.canonicalListenerAttestationPayload,
            canonicalSessionAttestationPayload: bundle.canonicalSessionAttestationPayload,
            canonicalReceiptPayload: PeekabooBridgeOperationReceiptCoding.canonicalData(forgedReceipt.payload),
            canonicalRequest: bundle.canonicalRequest,
            canonicalResponse: bundle.canonicalResponse)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try forgedBundle.validate()
        }

        let corrupted = PeekabooBridgeOperationReceiptBundle(
            operationAttestation: authority.attestation,
            operationSessionAttestation: session.attestation,
            receipt: receipt,
            canonicalListenerAttestationPayload: bundle.canonicalListenerAttestationPayload,
            canonicalSessionAttestationPayload: bundle.canonicalSessionAttestationPayload,
            canonicalReceiptPayload: bundle.canonicalReceiptPayload,
            canonicalRequest: Data("different request".utf8),
            canonicalResponse: bundle.canonicalResponse)
        #expect(throws: (any Error).self) {
            try corrupted.validate()
        }
        authority.complete(validClaim.claim)
        authority.complete(forgedClaim.claim)

        let encodedTarget = try PeekabooBridgeOperationReceiptCoding.canonicalData(forgedPayload.target)
        let targetObject = try #require(JSONSerialization.jsonObject(with: encodedTarget) as? [String: Any])
        #expect(targetObject["processStartIdentity"] as? String == "9007199254740993")
        #expect(try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeOperationTargetReceipt.self,
            from: encodedTarget) == .window(largeIdentity))

        let numericIdentity = Data(
            #"{"kind":"process","processIdentifier":42,"processStartIdentity":9007199254740993}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeOperationTargetReceipt.self,
                from: numericIdentity)
        }
        let noncanonicalIdentity = Data(
            #"{"kind":"process","processIdentifier":42,"processStartIdentity":"09007199254740993"}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeOperationTargetReceipt.self,
                from: noncanonicalIdentity)
        }
    }

    @Test
    func `external browser target round trips and rejects response target drift`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-browser-target-receipt-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path)
        let browserReceipt = PeekabooBridgeBrowserConnectionReceipt(
            channel: "stable",
            browserURL: "http://127.0.0.1:9222/",
            webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
            devToolsBrowserID: "browser-a",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
        let request = PeekabooBridgeRequest.projectedAction(.init(request: .browserExecute(.init(
            toolName: "click",
            arguments: [:],
            channel: "stable",
            expectedConnectionReceipt: browserReceipt))))
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let response = PeekabooBridgeResponse.projectedAction(.init(
            response: .browserToolResponse(.init(
                content: [],
                isError: false,
                meta: nil,
                connectionReceipt: browserReceipt,
                completedCallCount: 1,
                dispatchedCallCount: 1)),
            outcome: outcome.projection))
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let validClaim = try await session.acceptedClaim(
            authority: authority,
            sequence: 0,
            request: request)
        let payload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: validClaim.claim,
            request: request,
            response: response,
            target: .browser(browserReceipt),
            outcome: outcome.projection)
        let receipt = try await authority.signAndArchive(payload, claim: validClaim.claim)
        let bundle = try OperationReceiptSessionFixture.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: receipt,
            request: request,
            response: response)

        try bundle.validate()
        let targetData = try PeekabooBridgeOperationReceiptCoding.canonicalData(payload.target)
        #expect(try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeOperationTargetReceipt.self,
            from: targetData) == .browser(browserReceipt))

        let forgedClaim = try await session.acceptedClaim(
            authority: authority,
            sequence: 1,
            request: request)
        let changedReceipt = PeekabooBridgeBrowserConnectionReceipt(
            channel: "stable",
            browserURL: "http://127.0.0.1:9222/",
            webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-b",
            devToolsBrowserID: "browser-b",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
        let forgedPayload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: forgedClaim.claim,
            request: request,
            response: response,
            target: .browser(changedReceipt),
            outcome: outcome.projection)
        let forgedReceipt = try await authority.signAndArchive(forgedPayload, claim: forgedClaim.claim)
        let forgedBundle = try OperationReceiptSessionFixture.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: forgedReceipt,
            request: request,
            response: response)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try forgedBundle.validate()
        }
        let substitutionClaim = try await session.acceptedClaim(
            authority: authority,
            sequence: 2,
            request: request)
        let substitutedResponse = PeekabooBridgeResponse.projectedAction(.init(
            response: .browserToolResponse(.init(
                content: [],
                isError: false,
                meta: nil,
                connectionReceipt: changedReceipt,
                completedCallCount: 1,
                dispatchedCallCount: 1)),
            outcome: outcome.projection))
        let substitutionPayload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: substitutionClaim.claim,
            request: request,
            response: substitutedResponse,
            target: .browser(changedReceipt),
            outcome: outcome.projection)
        let substitutionReceipt = try await authority.signAndArchive(
            substitutionPayload,
            claim: substitutionClaim.claim)
        let substitutionBundle = try OperationReceiptSessionFixture.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: substitutionReceipt,
            request: request,
            response: substitutedResponse)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try substitutionBundle.validate()
        }
        let processClaim = try await session.acceptedClaim(
            authority: authority,
            sequence: 3,
            request: request)
        let fakeProcess = ApplicationProcessIdentity(
            processIdentifier: 42,
            processStartIdentity: 10042)
        let processPayload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: processClaim.claim,
            request: request,
            response: response,
            target: .process(fakeProcess),
            outcome: outcome.projection)
        let processReceipt = try await authority.signAndArchive(processPayload, claim: processClaim.claim)
        let processBundle = try OperationReceiptSessionFixture.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: processReceipt,
            request: request,
            response: response)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try processBundle.validate()
        }
        let refusalClaim = try await Self.validateBrowserTargetlessRefusal(
            authority: authority,
            session: session,
            request: request)
        authority.complete(validClaim.claim)
        authority.complete(forgedClaim.claim)
        authority.complete(substitutionClaim.claim)
        authority.complete(processClaim.claim)
        authority.complete(refusalClaim)
    }

    @Test
    func `external browser target binds the explicit requested channel`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-browser-channel-receipt-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let expectedReceipt = PeekabooBridgeBrowserConnectionReceipt(
            channel: "stable",
            browserURL: "http://127.0.0.1:9222/",
            webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
            devToolsBrowserID: "browser-a",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
        let request = PeekabooBridgeRequest.projectedAction(.init(request: .browserExecute(.init(
            toolName: "click",
            arguments: [:],
            channel: "stable",
            expectedConnectionReceipt: expectedReceipt))))
        let changedChannelReceipt = PeekabooBridgeBrowserConnectionReceipt(
            channel: "canary",
            browserURL: "http://127.0.0.1:9222/",
            webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
            devToolsBrowserID: "browser-a",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let response = PeekabooBridgeResponse.projectedAction(.init(
            response: .browserToolResponse(.init(
                content: [],
                isError: false,
                meta: nil,
                connectionReceipt: changedChannelReceipt,
                completedCallCount: 1,
                dispatchedCallCount: 1)),
            outcome: outcome.projection))
        let accepted = try await session.acceptedClaim(
            authority: authority,
            sequence: 0,
            request: request)
        let payload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: accepted.claim,
            request: request,
            response: response,
            target: .browser(changedChannelReceipt),
            outcome: outcome.projection)
        let receipt = try await authority.signAndArchive(payload, claim: accepted.claim)
        let bundle = try OperationReceiptSessionFixture.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: receipt,
            request: request,
            response: response)

        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try bundle.validate()
        }
        authority.complete(accepted.claim)
    }

    @Test
    func `projected browser receipts require typed failures exactly when marked as errors`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-browser-error-receipt-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let connectionReceipt = PeekabooBridgeBrowserConnectionReceipt(
            channel: "stable",
            browserURL: "http://127.0.0.1:9222/",
            webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
            devToolsBrowserID: "browser-a",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
        let request = PeekabooBridgeRequest.projectedAction(.init(request: .browserExecute(.init(
            calls: [
                .init(toolName: "click", arguments: [:]),
                .init(toolName: "type", arguments: [:]),
            ],
            channel: "stable",
            expectedConnectionReceipt: connectionReceipt))))
        let twoCalls = try #require(DesktopActionOutcome.DispatchUnitCount(2))
        let success = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: twoCalls)
        let partialFailure = DesktopActionFailure.partial(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            unitCount: twoCalls,
            message: "One browser call completed before the second failed")

        let fixture = BrowserReceiptFixture(
            authority: authority,
            session: session,
            request: request,
            connectionReceipt: connectionReceipt)

        let validSuccess = try await fixture.makeBundle(
            sequence: 0,
            browserResponse: .init(
                content: [],
                isError: false,
                meta: nil,
                connectionReceipt: connectionReceipt,
                completedCallCount: 2,
                dispatchedCallCount: 2),
            outcome: success)
        try validSuccess.validate()

        let validPartialError = try await fixture.makeBundle(
            sequence: 1,
            browserResponse: .init(
                content: [],
                isError: true,
                meta: nil,
                connectionReceipt: connectionReceipt,
                completedCallCount: 1,
                dispatchedCallCount: 2,
                actionFailure: partialFailure),
            outcome: partialFailure.outcome)
        try validPartialError.validate()

        let untypedError = try await fixture.makeBundle(
            sequence: 2,
            browserResponse: .init(
                content: [],
                isError: true,
                meta: nil,
                connectionReceipt: connectionReceipt,
                completedCallCount: 2,
                dispatchedCallCount: 2),
            outcome: success)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try untypedError.validate()
        }

        let unmarkedTypedFailure = try await fixture.makeBundle(
            sequence: 3,
            browserResponse: .init(
                content: [],
                isError: false,
                meta: nil,
                connectionReceipt: connectionReceipt,
                completedCallCount: 1,
                dispatchedCallCount: 2,
                actionFailure: partialFailure),
            outcome: partialFailure.outcome)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try unmarkedTypedFailure.validate()
        }

        let opaqueCancellation = DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .completionUnknown,
            message: "Browser provider cancellation left exact progress unknown")
        let validUnknownProgress = try await fixture.makeBundle(
            sequence: 4,
            browserResponse: .init(
                content: [],
                isError: true,
                meta: nil,
                connectionReceipt: connectionReceipt,
                actionFailure: opaqueCancellation),
            outcome: opaqueCancellation.outcome)
        try validUnknownProgress.validate()
        #expect(validUnknownProgress.receipt.payload.outcome?.dispatchedUnitCount == nil)
        #expect(validUnknownProgress.receipt.payload.outcome?.retrySafe == false)

        try await Self.validateBrowserZeroProgress(fixture: fixture, success: success)
    }

    @Test
    func `request target evidence delegates without changing selector constraints`() throws {
        let bounds = CGRect(x: 20, y: 30, width: 640, height: 480)
        let identity = WindowMutationIdentity(
            windowID: 73,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 1001,
            capturedBounds: bounds)
        let moveRequest = PeekabooBridgeRequest.moveWindow(.init(
            target: .windowId(identity.windowID),
            expectedIdentity: identity,
            position: .zero))
        #expect(moveRequest.operationTargetEvidence == [DesktopTargetEvidenceAdapter.evidence(
            windowTarget: .windowId(identity.windowID),
            windowIdentity: identity)])
        #expect(try PeekabooBridgeOperationTargetAttribution.resolveRequest(moveRequest)?.exactWindow?
            .identity == identity)

        let selectorContext = WindowContext(
            applicationProcessId: identity.ownerProcessIdentifier,
            applicationProcessStartIdentity: identity.ownerProcessStartIdentity,
            windowID: identity.windowID,
            windowBounds: bounds)
        let inspectRequest = PeekabooBridgeRequest.inspectAccessibilityTree(.init(windowContext: selectorContext))
        let selectorEvidence = try #require(inspectRequest.operationTargetEvidence.first)

        #expect(inspectRequest.operationTargetEvidence == [
            DesktopTargetEvidenceAdapter.evidence(selectorContext: selectorContext),
        ])
        #expect(selectorEvidence.processIdentifier == identity.ownerProcessIdentifier)
        #expect(selectorEvidence.processIdentity == nil)
        #expect(selectorEvidence.windowID == identity.windowID)
        #expect(selectorEvidence.windowBounds == bounds)
        #expect(try PeekabooBridgeOperationTargetAttribution.resolveRequest(inspectRequest) == nil)
    }

    @Test
    func `observation and capture receipts use resolved stable targets without widening`() throws {
        let bounds = CGRect(x: 20, y: 30, width: 640, height: 480)
        let identity = WindowMutationIdentity(
            windowID: 73,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 9_007_199_254_740_993,
            capturedBounds: bounds)
        let app = ApplicationIdentity(
            processIdentifier: 42,
            processStartIdentity: identity.ownerProcessStartIdentity,
            bundleIdentifier: "dev.peekaboo.fixture",
            name: "Fixture")
        let context = WindowContext(
            applicationName: "Fixture",
            applicationBundleId: "dev.peekaboo.fixture",
            applicationProcessId: 42,
            windowTitle: "Fixture",
            windowID: 73,
            windowBounds: bounds,
            windowMutationIdentity: identity)
        let resolved = ResolvedObservationTarget(
            kind: .windowID(73),
            app: app,
            window: .init(windowID: 73, title: "Fixture", bounds: bounds, index: 0),
            bounds: bounds,
            detectionContext: context)
        let capture = CaptureResult(
            imageData: Data(),
            metadata: .init(size: bounds.size, mode: .window))
        let observation = DesktopObservationResult(target: resolved, capture: capture, elements: nil)
        let observationRequest = PeekabooBridgeRequest.desktopObservation(.init(target: .windowID(73)))

        #expect(try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
            request: observationRequest,
            response: .desktopObservation(observation)).target == .window(identity))

        let windowInfo = ServiceWindowInfo(
            windowID: 73,
            title: "Fixture",
            bounds: bounds,
            mutationIdentity: identity)
        let applicationInfo = ServiceApplicationInfo(
            processIdentifier: 42,
            processStartIdentity: identity.ownerProcessStartIdentity,
            bundleIdentifier: "dev.peekaboo.fixture",
            name: "Fixture")
        let exactCapture = CaptureResult(
            imageData: Data(),
            metadata: .init(
                size: bounds.size,
                mode: .window,
                applicationInfo: applicationInfo,
                windowInfo: windowInfo))
        let captureRequest = PeekabooBridgeRequest.captureWindow(.init(
            appIdentifier: "",
            windowIndex: nil,
            windowId: identity.windowID,
            visualizerMode: .none,
            scale: .logical1x))
        #expect(try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
            request: captureRequest,
            response: .capture(exactCapture)).target == .window(identity))
        #expect(throws: DesktopTargetIdentityError.incompleteExactWindow) {
            _ = try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
                request: observationRequest,
                response: .capture(exactCapture))
        }

        let contradictoryCapture = CaptureResult(
            imageData: Data(),
            metadata: .init(
                size: bounds.size,
                mode: .window,
                applicationInfo: .init(
                    processIdentifier: 42,
                    processStartIdentity: identity.ownerProcessStartIdentity + 1,
                    bundleIdentifier: "dev.peekaboo.fixture",
                    name: "Fixture"),
                windowInfo: windowInfo))
        #expect(throws: DesktopTargetIdentityError.contradictoryProcessGeneration) {
            _ = try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
                request: captureRequest,
                response: .capture(contradictoryCapture))
        }

        let processOnly = DesktopObservationResult(
            target: .init(kind: .appWindow, app: app),
            capture: capture,
            elements: nil)
        #expect(throws: DesktopTargetIdentityError.incompleteExactWindow) {
            _ = try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
                request: observationRequest,
                response: .desktopObservation(processOnly))
        }
        let differentIdentity = WindowMutationIdentity(
            windowID: 74,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: identity.ownerProcessStartIdentity,
            capturedBounds: bounds)
        let differentTarget = try DesktopTargetIdentity(exactWindow: .init(
            identity: differentIdentity,
            bounds: bounds))
        #expect(throws: DesktopTargetIdentityError.contradictoryWindowIdentifier) {
            _ = try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
                request: observationRequest,
                response: .desktopObservation(processOnly),
                handledTarget: differentTarget)
        }

        let incompleteIdentity = WindowMutationIdentity(
            windowID: 73,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: identity.ownerProcessStartIdentity,
            capturedBounds: nil)
        let incompleteContext = WindowContext(
            applicationProcessId: 42,
            windowID: 73,
            windowBounds: bounds,
            windowMutationIdentity: incompleteIdentity)
        let unresolved = DesktopObservationResult(
            target: .init(
                kind: .windowID(73),
                app: .init(
                    processIdentifier: 42,
                    processStartIdentity: nil,
                    bundleIdentifier: nil,
                    name: "Fixture"),
                detectionContext: incompleteContext),
            capture: capture,
            elements: nil)
        #expect(throws: DesktopTargetIdentityError.incompleteExactWindow) {
            _ = try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
                request: observationRequest,
                response: .desktopObservation(unresolved))
        }

        try Self.expectDetectionAttribution(identity: identity, context: context, bounds: bounds)

        try Self.expectWindowMutationAttributionFailures(
            identity: identity,
            incompleteIdentity: incompleteIdentity,
            bounds: bounds)
    }

    @Test
    func `focused exact target is retained and contradictory focus is rejected`() throws {
        let bounds = CGRect(x: 10, y: 20, width: 600, height: 400)
        let identity = WindowMutationIdentity(
            windowID: 73,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 9_007_199_254_740_993,
            capturedBounds: bounds)
        let focused = FocusedElementIdentity(
            processIdentifier: 42,
            windowID: 73,
            role: "AXTextField",
            title: "Editor",
            identifier: "editor",
            frame: CGRect(x: 30, y: 40, width: 200, height: 30))
        let exact = try UIAutomationTarget.ExactWindow(
            identity: identity,
            bounds: bounds,
            focusedElement: focused)
        let request = PeekabooBridgeRequest.exactWindowTargetedTypeActions(.init(
            actions: [.text("x")],
            cadence: .fixed(milliseconds: 0),
            snapshotId: "snapshot",
            expectedWindowIdentity: identity,
            expectedWindowBounds: bounds,
            expectedFocusedElement: focused))

        let receipt = try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
            request: request,
            response: .ok,
            handledTarget: DesktopTargetIdentity(exactWindow: exact))
        #expect(receipt.target == .window(identity))
        #expect(receipt.focusedElement == focused)

        let contradictoryFocus = FocusedElementIdentity(
            processIdentifier: 42,
            windowID: 73,
            role: "AXTextField",
            title: "Other",
            identifier: "other",
            frame: CGRect(x: 30, y: 80, width: 200, height: 30))
        let contradictory = try UIAutomationTarget.ExactWindow(
            identity: identity,
            bounds: bounds,
            focusedElement: contradictoryFocus)
        #expect(throws: DesktopTargetIdentityError.contradictoryFocusedElement) {
            _ = try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
                request: request,
                response: .ok,
                handledTarget: DesktopTargetIdentity(exactWindow: contradictory))
        }
    }

    private static func expectWindowMutationAttributionFailures(
        identity: WindowMutationIdentity,
        incompleteIdentity: WindowMutationIdentity,
        bounds: CGRect) throws
    {
        let moveRequest = PeekabooBridgeRequest.moveWindow(.init(
            target: .windowId(identity.windowID),
            expectedIdentity: identity,
            position: .zero))
        let replacementIdentity = WindowMutationIdentity(
            windowID: identity.windowID,
            ownerProcessIdentifier: identity.ownerProcessIdentifier,
            ownerProcessStartIdentity: identity.ownerProcessStartIdentity + 1,
            capturedBounds: bounds)
        let replacementWindow = ServiceWindowInfo(
            windowID: identity.windowID,
            title: "Replacement",
            bounds: bounds,
            mutationIdentity: replacementIdentity)
        let moveTarget = try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
            request: moveRequest,
            response: .window(replacementWindow))
        #expect(moveTarget.target == .window(identity))

        let incompleteMove = PeekabooBridgeRequest.moveWindow(.init(
            target: .windowId(incompleteIdentity.windowID),
            expectedIdentity: incompleteIdentity,
            position: .zero))
        #expect(throws: DesktopTargetIdentityError.incompleteExactWindow) {
            _ = try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
                request: incompleteMove,
                response: .ok)
        }
    }

    private static func validateBrowserTargetlessRefusal(
        authority: PeekabooBridgeOperationReceiptAuthority,
        session: OperationReceiptSessionFixture,
        request: PeekabooBridgeRequest) async throws -> PeekabooBridgeOperationSessionClaim
    {
        let refusalClaim = try await session.acceptedClaim(
            authority: authority,
            sequence: 4,
            request: request)
        let refusal = DesktopActionFailure.preDispatchRefusal(
            route: .bridge,
            reason: .targetUnavailable,
            message: "browser target unavailable")
        let refusalResponse = PeekabooBridgeResponse.projectedAction(.init(
            response: .error(.init(code: .notFound, actionFailure: refusal)),
            outcome: refusal.outcome.projection))
        let refusalPayload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: refusalClaim.claim,
            request: request,
            response: refusalResponse,
            target: nil,
            outcome: refusal.outcome.projection)
        let refusalReceipt = try await authority.signAndArchive(refusalPayload, claim: refusalClaim.claim)
        let refusalBundle = try OperationReceiptSessionFixture.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: refusalReceipt,
            request: request,
            response: refusalResponse)
        try refusalBundle.validate()
        return refusalClaim.claim
    }

    private struct BrowserReceiptFixture {
        let authority: PeekabooBridgeOperationReceiptAuthority
        let session: OperationReceiptSessionFixture
        let request: PeekabooBridgeRequest
        let connectionReceipt: PeekabooBridgeBrowserConnectionReceipt

        func makeBundle(
            sequence: UInt64,
            browserResponse: PeekabooBridgeBrowserToolResponse,
            outcome: DesktopActionOutcome,
            target: PeekabooBridgeOperationTargetReceipt? = nil,
            targetless: Bool = false) async throws
            -> PeekabooBridgeOperationReceiptBundle
        {
            let response = PeekabooBridgeResponse.projectedAction(.init(
                response: .browserToolResponse(browserResponse),
                outcome: outcome.projection))
            return try await self.session.signedBundle(
                authority: self.authority,
                sequence: sequence,
                request: self.request,
                response: response,
                target: targetless ? nil : (target ?? .browser(self.connectionReceipt)),
                outcome: outcome.projection)
        }
    }

    private static func validateBrowserZeroProgress(
        fixture: BrowserReceiptFixture,
        success: DesktopActionOutcome) async throws
    {
        let connectionReceipt = fixture.connectionReceipt
        let zeroProgressRefusal = DesktopActionFailure.preDispatchRefusal(
            route: .bridge,
            reason: .targetUnavailable,
            message: "Browser target disappeared before dispatch")
        let validZeroProgress = try await fixture.makeBundle(
            sequence: 5,
            browserResponse: .init(
                content: [],
                isError: true,
                meta: nil,
                connectionReceipt: connectionReceipt,
                completedCallCount: 0,
                dispatchedCallCount: 0,
                actionFailure: zeroProgressRefusal),
            outcome: zeroProgressRefusal.outcome,
            targetless: true)
        try validZeroProgress.validate()
        #expect(validZeroProgress.receipt.payload.outcome?.dispatchedUnitCount == nil)
        #expect(validZeroProgress.receipt.payload.outcome?.retrySafe == true)

        let contradictoryZeroSuccess = try await fixture.makeBundle(
            sequence: 6,
            browserResponse: .init(
                content: [],
                isError: false,
                meta: nil,
                connectionReceipt: connectionReceipt,
                completedCallCount: 0,
                dispatchedCallCount: 0),
            outcome: success)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try contradictoryZeroSuccess.validate()
        }

        let contradictoryZeroFailure = DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .completionUnknown,
            message: "Contradictory unsafe zero-progress result")
        let invalidZeroFailure = try await fixture.makeBundle(
            sequence: 7,
            browserResponse: .init(
                content: [],
                isError: true,
                meta: nil,
                connectionReceipt: connectionReceipt,
                completedCallCount: 0,
                dispatchedCallCount: 0,
                actionFailure: contradictoryZeroFailure),
            outcome: contradictoryZeroFailure.outcome)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try invalidZeroFailure.validate()
        }
    }

    private static func expectDetectionAttribution(
        identity: WindowMutationIdentity,
        context: WindowContext,
        bounds: CGRect) throws
    {
        let detection = ElementDetectionResult(
            snapshotId: "snapshot",
            screenshotPath: "/tmp/fixture.png",
            elements: DetectedElements(),
            metadata: .init(
                detectionTime: 0,
                elementCount: 0,
                method: "fixture",
                windowContext: context))
        let detectRequest = PeekabooBridgeRequest.detectElements(.init(
            imageData: Data(),
            snapshotId: "snapshot",
            windowContext: context))
        #expect(try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
            request: detectRequest,
            response: .elementDetection(detection)).target == .global)
        let inspectRequest = PeekabooBridgeRequest.inspectAccessibilityTree(.init(windowContext: context))
        #expect(try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
            request: inspectRequest,
            response: .elementDetection(detection)).target == .window(identity))

        let processContext = WindowContext(
            applicationName: "Fixture",
            applicationProcessId: identity.ownerProcessIdentifier,
            applicationProcessStartIdentity: identity.ownerProcessStartIdentity,
            windowTitle: "AX-only description",
            windowID: identity.windowID,
            windowBounds: bounds)
        let processDetection = ElementDetectionResult(
            snapshotId: "process-snapshot",
            screenshotPath: "",
            elements: DetectedElements(),
            metadata: .init(
                detectionTime: 0,
                elementCount: 0,
                method: "fixture",
                windowContext: processContext))
        let processInspectRequest = PeekabooBridgeRequest.inspectAccessibilityTree(.init(
            windowContext: WindowContext(applicationName: "Fixture")))
        #expect(try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
            request: processInspectRequest,
            response: .elementDetection(processDetection)).target == .process(identity.processIdentity))

        let selectorOnlyContexts = [
            WindowContext(windowID: identity.windowID),
            WindowContext(
                applicationProcessId: identity.ownerProcessIdentifier,
                windowID: identity.windowID),
            WindowContext(
                applicationBundleId: "dev.peekaboo.fixture",
                windowID: identity.windowID),
        ]
        for selectorContext in selectorOnlyContexts {
            let selectorRequest = PeekabooBridgeRequest.inspectAccessibilityTree(.init(
                windowContext: selectorContext))
            #expect(try PeekabooBridgeOperationTargetAttribution.resolveRequest(selectorRequest) == nil)
            #expect(try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
                request: selectorRequest,
                response: .elementDetection(detection)).target == .window(identity))
        }

        let invalidProcessRequest = PeekabooBridgeRequest.inspectAccessibilityTree(.init(
            windowContext: WindowContext(
                applicationProcessId: 0,
                windowID: identity.windowID)))
        #expect(throws: DesktopTargetIdentityError.invalidProcessIdentifier) {
            _ = try PeekabooBridgeOperationTargetAttribution.resolveRequest(invalidProcessRequest)
        }

        let wrongProcessRequest = PeekabooBridgeRequest.inspectAccessibilityTree(.init(
            windowContext: WindowContext(
                applicationProcessId: identity.ownerProcessIdentifier + 1,
                windowID: identity.windowID)))
        #expect(throws: DesktopTargetIdentityError.contradictoryProcessIdentifier) {
            _ = try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
                request: wrongProcessRequest,
                response: .elementDetection(detection))
        }

        let wrongWindowRequest = PeekabooBridgeRequest.inspectAccessibilityTree(.init(
            windowContext: WindowContext(
                applicationProcessId: identity.ownerProcessIdentifier,
                windowID: identity.windowID + 1)))
        #expect(throws: DesktopTargetIdentityError.contradictoryWindowIdentifier) {
            _ = try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
                request: wrongWindowRequest,
                response: .elementDetection(detection))
        }
    }
}
