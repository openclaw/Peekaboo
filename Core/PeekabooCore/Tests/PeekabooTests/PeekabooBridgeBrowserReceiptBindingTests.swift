import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

@Suite(.serialized)
struct PeekabooBridgeBrowserReceiptBindingTests {
    @Test
    func `binding a result aware mutation to status forbids reconnect and retarget`() {
        let requests = [
            PeekabooBridgeBrowserExecuteRequest(
                toolName: "click",
                arguments: ["uid": .string("7_1")],
                channel: "stable"),
            PeekabooBridgeBrowserExecuteRequest(
                calls: [
                    .init(toolName: "click", arguments: ["uid": .string("7_1")]),
                    .init(toolName: "type_text", arguments: ["text": .string("hello")]),
                ],
                channel: "stable"),
        ]

        for request in requests {
            #expect(request.connectionPolicy == nil)

            let bound = request.binding(to: Self.localReceipt)

            #expect(bound.expectedConnectionReceipt == Self.localReceipt)
            #expect(bound.connectionPolicy == .requireExistingLiveReceipt)
            #expect(bound.resolvedCalls == request.resolvedCalls)
            #expect(bound.channel == request.channel)
        }
    }

    @Test
    @MainActor
    func `browser target inspection preserves an existing typed refusal`() async throws {
        let services = StubServices()
        let expected = DesktopActionFailure.preDispatchRefusal(
            reason: .permissionDenied,
            message: "Browser status inspection requires permission.",
            hint: "Grant permission before retrying.",
            causeDescription: "typed fixture")
        services.browserStatusError = expected

        do {
            _ = try await Self.handleBrowserExecute(services: services)
            Issue.record("Expected the typed browser status refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure == expected)
        }
    }

    @Test
    @MainActor
    func `browser target inspection maps unsupported provider to canonical refusal`() async throws {
        let services = StubServices()
        services.browserStatusError = PeekabooBridgeErrorEnvelope(
            code: .operationNotSupported,
            message: "Browser provider cannot report an exact connection.",
            details: "unsupported fixture")

        do {
            _ = try await Self.handleBrowserExecute(services: services)
            Issue.record("Expected the unsupported browser provider refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .operationUnsupported)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(failure.causeDescription == "unsupported fixture")
        }
    }

    @Test
    @MainActor
    func `browser target inspection synthesizes unavailable only for untyped failure`() async throws {
        let services = StubServices()
        services.browserStatusError = BrowserStatusInspectionError()

        do {
            _ = try await Self.handleBrowserExecute(services: services)
            Issue.record("Expected the untyped browser status failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(failure.causeDescription == "untyped browser status fixture")
        }
    }

    @Test
    func `local browser dispatch requires exact binding while no dispatch may omit it`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-local-browser-receipt-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let localReceipt = PeekabooBridgeBrowserConnectionReceipt(
            channel: "stable",
            processIdentifier: 42,
            processStartIdentity: 10042,
            bundleIdentifier: "com.google.Chrome",
            browserVersion: "Chrome/151.0")
        let changedLocalReceipt = PeekabooBridgeBrowserConnectionReceipt(
            channel: "stable",
            processIdentifier: 42,
            processStartIdentity: 10043,
            bundleIdentifier: "com.google.Chrome",
            browserVersion: "Chrome/151.0")
        let calls = [
            PeekabooBridgeBrowserToolCall(toolName: "click", arguments: [:]),
            PeekabooBridgeBrowserToolCall(toolName: "type", arguments: [:]),
        ]
        let boundRequest = PeekabooBridgeRequest.projectedAction(.init(request: .browserExecute(.init(
            calls: calls,
            channel: "stable",
            expectedConnectionReceipt: localReceipt))))
        let unboundRequest = PeekabooBridgeRequest.projectedAction(.init(request: .browserExecute(.init(
            calls: calls,
            channel: "stable"))))
        let success = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2))

        func makeBundle(
            sequence: UInt64,
            request: PeekabooBridgeRequest,
            browserResponse: PeekabooBridgeBrowserToolResponse,
            outcome: DesktopActionOutcome,
            target: PeekabooBridgeOperationTargetReceipt?) async throws
            -> PeekabooBridgeOperationReceiptBundle
        {
            let response = PeekabooBridgeResponse.projectedAction(.init(
                response: .browserToolResponse(browserResponse),
                outcome: outcome.projection))
            let accepted = try await session.acceptedClaim(
                authority: authority,
                sequence: sequence,
                request: request)
            let payload = try OperationReceiptSessionFixture.receiptPayload(
                authority: authority,
                claim: accepted.claim,
                request: request,
                response: response,
                target: target,
                outcome: outcome.projection)
            let receipt = try await authority.signAndArchive(payload, claim: accepted.claim)
            let bundle = try OperationReceiptSessionFixture.bundle(
                authority: authority,
                sessionAttestation: session.attestation,
                receipt: receipt,
                request: request,
                response: response)
            authority.complete(accepted.claim)
            return bundle
        }

        let changedIdentity = ApplicationProcessIdentity(
            processIdentifier: 42,
            processStartIdentity: 10043)
        let substituted = try await makeBundle(
            sequence: 0,
            request: boundRequest,
            browserResponse: .init(
                content: [],
                isError: false,
                meta: nil,
                connectionReceipt: changedLocalReceipt,
                completedCallCount: 2,
                dispatchedCallCount: 2),
            outcome: success,
            target: .process(changedIdentity))
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try substituted.validate()
        }

        let localIdentity = ApplicationProcessIdentity(
            processIdentifier: 42,
            processStartIdentity: 10042)
        let missingBinding = try await makeBundle(
            sequence: 1,
            request: unboundRequest,
            browserResponse: .init(
                content: [],
                isError: false,
                meta: nil,
                connectionReceipt: localReceipt,
                completedCallCount: 2,
                dispatchedCallCount: 2),
            outcome: success,
            target: .process(localIdentity))
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try missingBinding.validate()
        }

        let refusal = DesktopActionFailure.preDispatchRefusal(
            route: .bridge,
            reason: .targetUnavailable,
            message: "Browser target disappeared before dispatch")
        let noDispatch = try await makeBundle(
            sequence: 2,
            request: unboundRequest,
            browserResponse: .init(
                content: [],
                isError: true,
                meta: nil,
                connectionReceipt: localReceipt,
                completedCallCount: 0,
                dispatchedCallCount: 0,
                actionFailure: refusal),
            outcome: refusal.outcome,
            target: nil)
        try noDispatch.validate()
        #expect(noDispatch.receipt.payload.outcome?.retrySafe == true)
    }

    @Test
    func `browser receipt progress is bounded by the requested batch`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-browser-batch-bounds-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)

        let threeCallRequest = PeekabooBridgeRequest.projectedAction(.init(request: .browserExecute(.init(
            calls: [
                .init(toolName: "click", arguments: [:]),
                .init(toolName: "type", arguments: [:]),
                .init(toolName: "hover", arguments: [:]),
            ],
            channel: "stable",
            expectedConnectionReceipt: Self.localReceipt))))
        let localIdentity = ApplicationProcessIdentity(
            processIdentifier: 42,
            processStartIdentity: 10042)

        func makeBundle(
            sequence: UInt64,
            completedCallCount: Int,
            dispatchedCallCount: Int,
            outcome: DesktopActionOutcome,
            request requestedRequest: PeekabooBridgeRequest? = nil) async throws -> PeekabooBridgeOperationReceiptBundle
        {
            let request = requestedRequest ?? threeCallRequest
            let response = PeekabooBridgeResponse.projectedAction(.init(
                response: .browserToolResponse(.init(
                    content: [],
                    isError: false,
                    meta: nil,
                    connectionReceipt: Self.localReceipt,
                    completedCallCount: completedCallCount,
                    dispatchedCallCount: dispatchedCallCount)),
                outcome: outcome.projection))
            let accepted = try await session.acceptedClaim(
                authority: authority,
                sequence: sequence,
                request: request)
            let payload = try OperationReceiptSessionFixture.receiptPayload(
                authority: authority,
                claim: accepted.claim,
                request: request,
                response: response,
                target: .process(localIdentity),
                outcome: outcome.projection)
            let receipt = try await authority.signAndArchive(payload, claim: accepted.claim)
            let bundle = try OperationReceiptSessionFixture.bundle(
                authority: authority,
                sessionAttestation: session.attestation,
                receipt: receipt,
                request: request,
                response: response)
            authority.complete(accepted.claim)
            return bundle
        }

        let oneCallSuccess = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let incompleteSuccess = try await makeBundle(
            sequence: 0,
            completedCallCount: 1,
            dispatchedCallCount: 1,
            outcome: oneCallSuccess)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try incompleteSuccess.validate()
        }

        let fourCallCount = DesktopActionOutcome.DispatchUnitCount(4)
        let inflatedOutcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: fourCallCount)
        let inflatedSuccess = try await makeBundle(
            sequence: 1,
            completedCallCount: 4,
            dispatchedCallCount: 4,
            outcome: inflatedOutcome)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try inflatedSuccess.validate()
        }

        let negativeProgress = try await makeBundle(
            sequence: 2,
            completedCallCount: -1,
            dispatchedCallCount: 1,
            outcome: oneCallSuccess)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try negativeProgress.validate()
        }

        let mixedRequest = PeekabooBridgeRequest.projectedAction(.init(request: .browserExecute(.init(
            calls: [
                .init(toolName: "take_snapshot", arguments: [:]),
                .init(toolName: "click", arguments: [:]),
                .init(toolName: "list_console_messages", arguments: [:]),
            ],
            channel: "stable",
            expectedConnectionReceipt: Self.localReceipt))))
        let mixedSuccess = try await makeBundle(
            sequence: 3,
            completedCallCount: 1,
            dispatchedCallCount: 1,
            outcome: oneCallSuccess,
            request: mixedRequest)
        try mixedSuccess.validate()
    }

    @MainActor
    private static func handleBrowserExecute(services: StubServices) async throws -> PeekabooBridgeHandledResponse {
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            permissionStatusEvaluator: { _ in Self.permissions })
        let request = PeekabooBridgeRequest.browserExecute(.init(
            toolName: "click",
            arguments: [:],
            channel: "stable",
            expectedConnectionReceipt: Self.localReceipt))
        return try await PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
            try await server.handleAuthorized(request, peer: nil, permissions: Self.permissions)
        }
    }

    private static let localReceipt = PeekabooBridgeBrowserConnectionReceipt(
        channel: "stable",
        processIdentifier: 42,
        processStartIdentity: 10042,
        bundleIdentifier: "com.google.Chrome",
        browserVersion: "Chrome/151.0")

    private static let permissions = PermissionsStatus(
        screenRecording: true,
        accessibility: true,
        postEvent: true)
}

private struct BrowserStatusInspectionError: LocalizedError {
    var errorDescription: String? {
        "untyped browser status fixture"
    }
}
