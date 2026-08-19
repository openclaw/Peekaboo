import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

@Suite(.serialized)
struct PeekabooBridgeDesktopObservationBindingTests: DesktopObservationBindingFixtureProviding {
    @Test
    @MainActor
    func `forged observation selectors fail live and offline validation`() async throws {
        for forgery in Self.forgeries() {
            #expect(
                PeekabooBridgeDesktopObservationBinding.mismatch(
                    request: forgery.request,
                    result: forgery.result) != nil,
                "Expected typed validator to reject \(forgery.name)")

            let provider = ObservationProvider(result: forgery.result)
            let server = Self.server(provider: provider)
            do {
                _ = try await PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
                    try await server.handleAuthorized(
                        .desktopObservation(forgery.request),
                        peer: nil,
                        permissions: Self.permissions)
                }
                Issue.record("Expected live validation to reject \(forgery.name)")
            } catch let envelope as PeekabooBridgeErrorEnvelope {
                #expect(
                    envelope.code == .internalError || envelope.code == .invalidRequest,
                    "Unexpected live error for \(forgery.name)")
            } catch {
                Issue.record("Unexpected live validation error for \(forgery.name): \(error)")
            }
            #expect(provider.observationCount == 1, "Expected provider response validation for \(forgery.name)")

            let signed = try await Self.makeBundle(
                request: .desktopObservation(forgery.request),
                response: .desktopObservation(forgery.result),
                target: forgery.receipt)
            #expect(throws: PeekabooBridgeOperationReceiptError.self) {
                try signed.validateIntegrity()
            }
        }
    }

    @Test
    func `application observations require result target application evidence`() throws {
        let forgery = Self.targetSelectorForgeries().first {
            $0.name == "missing requested application identity"
        }
        let missingRequestedApp = try #require(forgery)

        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: missingRequestedApp.request,
            result: missingRequestedApp.result) == "requested application identity")
        #expect(PeekabooBridgeSelectorResolutionBinding.observationMismatch(
            request: missingRequestedApp.request,
            result: missingRequestedApp.result,
            requireProof: true) == "missing application selector proof")
        #expect(PeekabooBridgeSelectorResolutionBinding.observationMismatch(
            request: .init(target: .pid(42, window: .automatic)),
            result: missingRequestedApp.result,
            requireProof: true) == "PID selector process")
        #expect(PeekabooBridgeSelectorResolutionBinding.observationMismatch(
            request: .init(target: .screen(index: 0), detection: .init(mode: .none)),
            result: Self.screenResult(index: 0),
            requireProof: true) == nil)
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: .init(target: .screen(index: 0), detection: .init(mode: .none)),
            result: Self.screenResult(index: 0)) == nil)
    }

    @Test
    @MainActor
    func `matching observation selector and evidence pass live and offline validation`() async throws {
        let fixture = Self.windowResult(.init(
            processIdentifier: 42,
            generation: 1001,
            bundleIdentifier: "dev.peekaboo.fixture",
            applicationName: "Fixture",
            windowID: 73,
            title: "Document - Fixture",
            index: 2,
            windowSelector: .title("Document")))
        let request = DesktopObservationRequest(target: .app(
            identifier: "dev.peekaboo.fixture",
            window: .title("Document")), detection: .init(mode: .none))

        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: request,
            result: fixture.result) == nil)
        let handled = try await PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
            try await Self.server(provider: ObservationProvider(result: fixture.result)).handleAuthorized(
                .desktopObservation(request),
                peer: nil,
                permissions: Self.permissions)
        }
        guard case .desktopObservation = handled.response else {
            Issue.record("Expected a live desktop observation response")
            return
        }

        let signed = try await Self.makeBundle(
            request: .desktopObservation(request),
            response: .desktopObservation(fixture.result),
            target: .window(fixture.identity))
        try signed.validateIntegrity()
    }

    @Test
    @MainActor
    func `PID window selector proof has live and offline parity with app window selection`() async throws {
        let fixture = Self.windowResult(.init(
            processIdentifier: 42,
            generation: 1001,
            bundleIdentifier: "dev.peekaboo.fixture",
            applicationName: "Fixture",
            windowID: 73,
            title: "Document - Fixture",
            index: 2,
            windowSelector: .title("Document")))
        let original = fixture.result.target
        let windowProof = try #require(original.selectorResolutionProofs?.last)
        let validTarget = ResolvedObservationTarget(
            kind: original.kind,
            app: original.app,
            window: original.window,
            bounds: original.bounds,
            detectionContext: original.detectionContext,
            captureScaleHint: original.captureScaleHint,
            selectorResolutionProofs: [windowProof],
            mutationTargetIdentity: original.mutationTargetIdentity)
        let valid = Self.replacingTarget(fixture.result, with: validTarget)
        let request = DesktopObservationRequest(
            target: .pid(42, window: .title("Document")),
            detection: .init(mode: .none))

        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: request,
            result: valid,
            requireSelectorResolutionProof: true) == nil)
        let handled = try await PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
            try await Self.server(provider: ObservationProvider(result: valid)).handleAuthorized(
                .desktopObservation(request),
                peer: nil,
                permissions: Self.permissions)
        }
        guard case .desktopObservation = handled.response else {
            Issue.record("Expected a PID-targeted observation response")
            return
        }
        let validBundle = try await Self.makeBundle(
            request: .desktopObservation(request),
            response: .desktopObservation(valid),
            target: .window(fixture.identity))
        try validBundle.validateIntegrity()

        let missingProof = Self.replacingTarget(
            fixture.result,
            with: ResolvedObservationTarget(
                kind: original.kind,
                app: original.app,
                window: original.window,
                bounds: original.bounds,
                detectionContext: original.detectionContext,
                captureScaleHint: original.captureScaleHint,
                selectorResolutionProofs: [],
                mutationTargetIdentity: original.mutationTargetIdentity))
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: request,
            result: missingProof,
            requireSelectorResolutionProof: true) == "selector proof PID window selector proof order")
        let forgedBundle = try await Self.makeBundle(
            request: .desktopObservation(request),
            response: .desktopObservation(missingProof),
            target: .window(fixture.identity))
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try PeekabooBridgeOperationReceiptSemantics.validateReceiptCarriage(
                forgedBundle.receipt.payload,
                request: .desktopObservation(request),
                response: .desktopObservation(missingProof))
        }
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try forgedBundle.validateIntegrity()
        }
    }

    @Test
    @MainActor
    func `exact window ID proof cardinality is strict without requiring redundant window proof`() async throws {
        let fixture = Self.windowResult(.init(
            processIdentifier: 42,
            generation: 1001,
            bundleIdentifier: "dev.peekaboo.fixture",
            applicationName: "Fixture",
            windowID: 73,
            title: "Document",
            index: 2,
            windowSelector: .id(73)))
        let proofs = try #require(fixture.result.target.selectorResolutionProofs)
        let applicationProof = try #require(proofs.first)
        let windowProof = try #require(proofs.last)
        let contradictoryWindowProof = SelectorResolutionProof(
            scope: .window,
            normalizedSelector: WindowSelectorResolutionProof.normalizedSelector(.id(74)),
            matchKind: windowProof.matchKind,
            matchPrecedence: windowProof.matchPrecedence,
            selectedProcessIdentity: windowProof.selectedProcessIdentity,
            selectedWindowIdentity: windowProof.selectedWindowIdentity,
            candidateSetSHA256: windowProof.candidateSetSHA256,
            candidateCount: windowProof.candidateCount,
            winningCandidateCount: windowProof.winningCandidateCount,
            hasWinningTie: windowProof.hasWinningTie)
        let wrongIdentity = WindowMutationIdentity(
            windowID: 74,
            ownerProcessIdentifier: fixture.identity.ownerProcessIdentifier,
            ownerProcessStartIdentity: fixture.identity.ownerProcessStartIdentity,
            capturedBounds: fixture.identity.capturedBounds)
        let wrongIdentityWindowProof = windowProof.selecting(windowIdentity: wrongIdentity)
        let pidRequest = DesktopObservationRequest(
            target: .pid(42, window: .id(73)),
            detection: .init(mode: .none))
        let appRequest = DesktopObservationRequest(
            target: .app(identifier: "dev.peekaboo.fixture", window: .id(73)),
            detection: .init(mode: .none))

        for (proofs, expected) in [
            ([], nil),
            ([windowProof], nil),
            ([applicationProof], "PID window selector proof order"),
            ([windowProof, windowProof], "PID window selector proof order"),
            ([windowProof, applicationProof], "PID window selector proof order"),
            ([contradictoryWindowProof], "window normalized selector"),
            ([wrongIdentityWindowProof], "window selected window identity"),
        ] as [([SelectorResolutionProof], String?)] {
            let result = Self.replacingSelectorResolutionProofs(fixture.result, with: proofs)
            #expect(PeekabooBridgeSelectorResolutionBinding.observationMismatch(
                request: pidRequest,
                result: result,
                requireProof: true) == expected)
        }

        for (proofs, expected) in [
            ([], "missing application selector proof"),
            ([applicationProof], nil),
            ([applicationProof, windowProof], nil),
            ([windowProof, applicationProof], "application selector proof order"),
            ([applicationProof, contradictoryWindowProof], "window normalized selector"),
            ([applicationProof, wrongIdentityWindowProof], "window selected window identity"),
        ] as [([SelectorResolutionProof], String?)] {
            let result = Self.replacingSelectorResolutionProofs(fixture.result, with: proofs)
            #expect(PeekabooBridgeSelectorResolutionBinding.observationMismatch(
                request: appRequest,
                result: result,
                requireProof: true) == expected)
        }

        let applicationOnly = Self.replacingSelectorResolutionProofs(
            fixture.result,
            with: [applicationProof])
        #expect(PeekabooBridgeSelectorResolutionBinding.observationMismatch(
            request: .init(
                target: .app(identifier: "dev.peekaboo.fixture", window: .title("Document")),
                detection: .init(mode: .none)),
            result: applicationOnly,
            requireProof: true) == "missing window selector proof")
        #expect(PeekabooBridgeSelectorResolutionBinding.observationMismatch(
            request: .init(target: .pid(42, window: .title("Document")), detection: .init(mode: .none)),
            result: Self.replacingSelectorResolutionProofs(fixture.result, with: []),
            requireProof: true) == "PID window selector proof order")

        let prooflessPIDResult = Self.replacingSelectorResolutionProofs(fixture.result, with: [])
        let prooflessPIDBundle = try await Self.makeBundle(
            request: .desktopObservation(pidRequest),
            response: .desktopObservation(prooflessPIDResult),
            target: .window(fixture.identity))
        try prooflessPIDBundle.validateIntegrity()
    }

    @Test
    @MainActor
    func `exact ID proofs tolerate mutable minimized state in live and offline validation`() async throws {
        let fixture = Self.windowResult(.init(
            processIdentifier: 42,
            generation: 1001,
            bundleIdentifier: "dev.peekaboo.fixture",
            applicationName: "Fixture",
            windowID: 73,
            title: "Document",
            index: 2,
            windowSelector: .id(73)))
        let proofIdentity = WindowMutationIdentity(
            windowID: fixture.identity.windowID,
            ownerProcessIdentifier: fixture.identity.ownerProcessIdentifier,
            ownerProcessStartIdentity: fixture.identity.ownerProcessStartIdentity,
            capturedBounds: fixture.identity.capturedBounds,
            isMinimized: false)
        let proofs = try #require(fixture.result.target.selectorResolutionProofs).map {
            $0.selecting(windowIdentity: proofIdentity)
        }
        let result = Self.replacingSelectorResolutionProofs(fixture.result, with: proofs)
        let applicationOnlyResult = try Self.replacingSelectorResolutionProofs(
            fixture.result,
            with: [#require(proofs.first)])
        let request = DesktopObservationRequest(
            target: .app(identifier: "dev.peekaboo.fixture", window: .id(73)),
            detection: .init(mode: .none))

        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: request,
            result: result,
            requireSelectorResolutionProof: true) == nil)
        let handled = try await PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
            try await Self.server(provider: ObservationProvider(result: result)).handleAuthorized(
                .desktopObservation(request),
                peer: nil,
                permissions: Self.permissions)
        }
        guard case .desktopObservation = handled.response else {
            Issue.record("Expected an exact app/window observation response")
            return
        }
        let bundle = try await Self.makeBundle(
            request: .desktopObservation(request),
            response: .desktopObservation(result),
            target: .window(fixture.identity))
        try bundle.validateIntegrity()

        let authorityRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-exact-observation-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: authorityRoot) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: authorityRoot.appendingPathComponent("bridge.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let wireRequest = PeekabooBridgeRequest.desktopObservation(request)
        let attributionEvidence = PeekabooBridgeOperationTargetAttribution.evidence(
            request: wireRequest,
            response: .desktopObservation(applicationOnlyResult),
            handledTarget: nil)
        let attributed = try PeekabooBridgeOperationTargetAttribution.resolveEvidence(
            request: wireRequest,
            evidence: attributionEvidence)
        #expect(attributed?.exactWindow?.identity.hasSameStableReceipt(as: fixture.identity) == true)
        let payload = session.request(authority: authority, sequence: 0, request: wireRequest)
        let strictServer = PeekabooBridgeServer(
            services: StubServices(desktopObservation: ObservationProvider(result: applicationOnlyResult)),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation],
            permissionStatusEvaluator: { _ in Self.permissions },
            windowOwnerProcessIdentifierProvider: { $0 == 73 ? 42 : nil },
            windowBoundsProvider: { $0 == 73 ? fixture.identity.capturedBounds : nil },
            processStartIdentityProvider: { $0 == 42 ? 1001 : nil })
        let data = try await PeekabooBridgeRequestContext.$operationReceiptAuthority.withValue(authority) {
            try await strictServer.handleAttestedOperation(
                payload,
                peer: session.peer)
        }
        guard case let .attestedOperation(attested) = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: data)
        else {
            Issue.record("Expected an attested exact app/window observation response")
            return
        }
        guard case .desktopObservation = attested.response else {
            Issue.record("Expected a signed exact app/window observation response: \(attested.response)")
            return
        }
        #expect(attested.receipt.payload.target == .window(fixture.identity))
        let strictBundle = try OperationReceiptSessionFixture.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: attested.receipt,
            request: wireRequest,
            response: attested.response)
        try strictBundle.validateIntegrity()

        let pidRequest = DesktopObservationRequest(
            target: .pid(42, window: .id(73)),
            detection: .init(mode: .none))
        let pidWireRequest = PeekabooBridgeRequest.desktopObservation(pidRequest)
        let prooflessPIDResult = Self.replacingSelectorResolutionProofs(fixture.result, with: [])
        let pidPayload = session.request(authority: authority, sequence: 1, request: pidWireRequest)
        let pidServer = PeekabooBridgeServer(
            services: StubServices(desktopObservation: ObservationProvider(result: prooflessPIDResult)),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation],
            permissionStatusEvaluator: { _ in Self.permissions },
            windowOwnerProcessIdentifierProvider: { $0 == 73 ? 42 : nil },
            windowBoundsProvider: { $0 == 73 ? fixture.identity.capturedBounds : nil },
            processStartIdentityProvider: { $0 == 42 ? 1001 : nil })
        let pidData = try await PeekabooBridgeRequestContext.$operationReceiptAuthority.withValue(authority) {
            try await pidServer.handleAttestedOperation(
                pidPayload,
                peer: session.peer)
        }
        guard case let .attestedOperation(pidAttested) = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: pidData),
            case .desktopObservation = pidAttested.response
        else {
            Issue.record("Expected a signed proofless PID/exact-window observation response")
            return
        }
        #expect(pidAttested.receipt.payload.target == .window(fixture.identity))
        let pidBundle = try OperationReceiptSessionFixture.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: pidAttested.receipt,
            request: pidWireRequest,
            response: pidAttested.response)
        try pidBundle.validateIntegrity()
    }

    @Test
    func `observation proof preserves prohibited helper fuzzy eligibility`() {
        let fixture = Self.windowResult(.init(
            processIdentifier: 42,
            generation: 1001,
            bundleIdentifier: "dev.peekaboo.fixture.helper",
            applicationName: "Fixture Helper",
            windowID: 73,
            title: "Helper",
            index: 0))
        let original = fixture.result.target
        let helper = ApplicationIdentity(
            processIdentifier: 42,
            processStartIdentity: 1001,
            bundleIdentifier: "dev.peekaboo.fixture.helper",
            name: "Fixture Helper",
            activationPolicy: .prohibited)
        let result = Self.replacingTarget(
            fixture.result,
            with: ResolvedObservationTarget(
                kind: original.kind,
                app: helper,
                window: original.window,
                bounds: original.bounds,
                detectionContext: original.detectionContext,
                captureScaleHint: original.captureScaleHint,
                mutationTargetIdentity: original.mutationTargetIdentity))

        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: .init(target: .app(identifier: "Fixture", window: nil), detection: .init(mode: .none)),
            result: result) == "application selector")
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: .init(
                target: .app(identifier: "dev.peekaboo.fixture.helper", window: nil),
                detection: .init(mode: .none)),
            result: result) == nil)
    }

    @Test
    func `signed observation selector proof rejects Safari winner substitution and ambiguity`() throws {
        let fixture = Self.windowResult(.init(
            processIdentifier: 42,
            generation: 1001,
            bundleIdentifier: nil,
            applicationName: "Safari",
            windowID: 73,
            title: "Safari",
            index: 0,
            windowSelector: .automatic))
        let request = DesktopObservationRequest(
            target: .app(identifier: "Safari", window: nil),
            detection: .init(mode: .none))
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: request,
            result: fixture.result,
            requireSelectorResolutionProof: true) == nil)

        let original = fixture.result.target
        let substitutedApp = ApplicationIdentity(
            processIdentifier: 42,
            processStartIdentity: 1001,
            bundleIdentifier: "com.apple.SafariTechnologyPreview",
            name: "Safari Technology Preview")
        let substituted = Self.replacingTarget(
            fixture.result,
            with: ResolvedObservationTarget(
                kind: original.kind,
                app: substitutedApp,
                window: original.window,
                bounds: original.bounds,
                detectionContext: original.detectionContext,
                captureScaleHint: original.captureScaleHint,
                selectorResolutionProofs: original.selectorResolutionProofs,
                mutationTargetIdentity: original.mutationTargetIdentity))
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: request,
            result: substituted,
            requireSelectorResolutionProof: true)?.contains("match kind or precedence") == true)

        let originalProof = try #require(original.selectorResolutionProofs?.first)
        let ambiguousProof = SelectorResolutionProof(
            scope: originalProof.scope,
            normalizedSelector: originalProof.normalizedSelector,
            matchKind: originalProof.matchKind,
            matchPrecedence: originalProof.matchPrecedence,
            selectedProcessIdentity: originalProof.selectedProcessIdentity,
            selectedWindowIdentity: originalProof.selectedWindowIdentity,
            candidateSetSHA256: originalProof.candidateSetSHA256,
            candidateCount: 2,
            winningCandidateCount: 2,
            hasWinningTie: true)
        let ambiguous = Self.replacingTarget(
            fixture.result,
            with: ResolvedObservationTarget(
                kind: original.kind,
                app: original.app,
                window: original.window,
                bounds: original.bounds,
                detectionContext: original.detectionContext,
                captureScaleHint: original.captureScaleHint,
                selectorResolutionProofs: [ambiguousProof],
                mutationTargetIdentity: original.mutationTargetIdentity))
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: request,
            result: ambiguous,
            requireSelectorResolutionProof: true)?.contains("ambiguous selector") == true)
    }

    @Test
    func `all screens cannot be represented as one primary screen result`() {
        let result = Self.screenResult(index: 0)
        let request = DesktopObservationRequest(target: .allScreens, detection: .init(mode: .none))

        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: request,
            result: result) == "all-screens composite target")
    }

    @Test
    func `frontmost result binds to emitted frontmost application`() throws {
        let fixture = Self.frontmostWindowResult()
        let app = try #require(fixture.result.target.app)
        let matching = Self.replacingDiagnostics(
            fixture.result,
            stateSnapshot: DesktopStateSnapshot(frontmostApplication: app))
        let request = DesktopObservationRequest(target: .frontmost, detection: .init(mode: .none))

        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: request,
            result: matching) == nil)
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: request,
            result: fixture.result) == "frontmost application snapshot")

        let other = ApplicationIdentity(
            processIdentifier: 43,
            processStartIdentity: 1002,
            bundleIdentifier: "dev.peekaboo.other",
            name: "Other")
        let forged = Self.replacingDiagnostics(
            fixture.result,
            stateSnapshot: DesktopStateSnapshot(frontmostApplication: other))
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: request,
            result: forged) == "frontmost application snapshot identity")
    }

    @Test
    func `menu bar popover result binds request hints and opening policy`() {
        let bounds = CGRect(x: 1200, y: 700, width: 360, height: 300)
        let request = DesktopObservationRequest(
            target: .menubarPopover(
                hints: ["Control Center", "Wi-Fi"],
                openIfNeeded: MenuBarPopoverOpenOptions(clickHint: "  Control Center  ")),
            detection: .init(mode: .none))
        let matching = Self.menuBarPopoverResult(
            bounds: bounds,
            hints: ["Control Center", "Wi-Fi"],
            openIfNeeded: true,
            clickHint: "Control Center")

        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: request,
            result: matching) == nil)
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: request,
            result: Self.replacingDiagnostics(
                matching,
                stateSnapshot: DesktopStateSnapshot())) == "menu-bar popover request diagnostics")
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: request,
            result: Self.menuBarPopoverResult(
                bounds: bounds,
                hints: ["Clock"],
                openIfNeeded: true,
                clickHint: "Control Center")) == "menu-bar popover hints")
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: request,
            result: Self.menuBarPopoverResult(
                bounds: bounds,
                hints: ["Control Center", "Wi-Fi"],
                openIfNeeded: false,
                clickHint: "Control Center")) == "menu-bar popover open-if-needed policy")
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: request,
            result: Self.menuBarPopoverResult(
                bounds: bounds,
                hints: ["Control Center", "Wi-Fi"],
                openIfNeeded: true,
                clickHint: "Clock")) == "menu-bar popover click hint")
    }

    @Test
    func `primary screen requires concrete primary display evidence`() {
        let request = DesktopObservationRequest(
            target: .screen(index: nil),
            detection: .init(mode: .none))
        let primary = Self.screenResult(targetIndex: nil, captureIndex: 0)
        let secondary = Self.screenResult(targetIndex: nil, captureIndex: 1)
        let missingDisplay = Self.replacingCaptureMetadata(primary) { metadata in
            CaptureMetadata(
                size: metadata.size,
                mode: metadata.mode,
                diagnostics: metadata.diagnostics)
        }

        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: request,
            result: primary) == nil)
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: request,
            result: secondary) == "captured screen index")
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: request,
            result: missingDisplay) == "captured screen identity")
    }

    @Test
    func `global observations reject exact application and window evidence`() {
        let fixture = Self.windowResult(.init(
            processIdentifier: 42,
            generation: 1001,
            bundleIdentifier: "dev.peekaboo.fixture",
            applicationName: "Fixture",
            windowID: 73,
            title: "Document",
            index: 0))
        let screen = Self.replacingTarget(
            Self.screenResult(index: 0),
            with: .init(
                kind: .screen(index: 0),
                app: fixture.result.target.app,
                window: fixture.result.target.window,
                detectionContext: fixture.result.target.detectionContext))
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let area = Self.replacingTarget(
            Self.areaResult(bounds),
            with: .init(
                kind: .area(bounds),
                app: fixture.result.target.app,
                window: fixture.result.target.window,
                bounds: bounds,
                detectionContext: fixture.result.target.detectionContext))

        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: .init(target: .screen(index: 0), detection: .init(mode: .none)),
            result: screen) == "screen target kind or index")
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: .init(target: .area(bounds), detection: .init(mode: .none)),
            result: area) == "area target bounds")
    }

    @Test
    func `capture engine scale and detection options are bound`() {
        let base = Self.screenResult(index: 0)
        let nativeRequest = DesktopObservationRequest(
            target: .screen(index: 0),
            capture: .init(engine: .modern, scale: .native),
            detection: .init(mode: .none))
        let native = Self.replacingCaptureMetadata(base) { metadata in
            CaptureMetadata(
                size: metadata.size,
                mode: metadata.mode,
                displayInfo: metadata.displayInfo,
                diagnostics: Self.captureDiagnostics(size: metadata.size, scale: .native))
        }
        let wrongScale = Self.replacingCaptureMetadata(native) { metadata in
            metadata.withDiagnostics(Self.captureDiagnostics(size: metadata.size))
        }
        let wrongEngine = Self.replacingCaptureMetadata(native) { metadata in
            metadata.withDiagnostics(Self.captureDiagnostics(
                size: metadata.size,
                scale: .native,
                engine: "CGWindowList"))
        }
        let accessibilityRequest = DesktopObservationRequest(
            target: .screen(index: 0),
            detection: .init(mode: .accessibility))

        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: nativeRequest,
            result: native) == nil)
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: nativeRequest,
            result: wrongScale) == "capture scale")
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: nativeRequest,
            result: wrongEngine) == "capture engine")
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: accessibilityRequest,
            result: base) == "accessibility detection result")
    }

    @Test
    func `raw capture scale is bound to signed diagnostics`() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let result = CaptureResult(
            imageData: Data(),
            metadata: .init(
                size: bounds.size,
                mode: .screen,
                displayInfo: .init(index: 0, name: "Fixture", bounds: bounds, scaleFactor: 1),
                diagnostics: Self.captureDiagnostics(size: bounds.size)))
        let request = PeekabooBridgeRequest.captureScreen(.init(
            displayIndex: 0,
            visualizerMode: .none,
            scale: .native))

        #expect(PeekabooBridgeCaptureBinding.mismatch(
            request: request,
            result: result) == "capture scale")
    }

    private static func forgeries() -> [Forgery] {
        self.targetSelectorForgeries() + self.globalTargetForgeries() + self.popoverForgeries()
    }

    private static func targetSelectorForgeries() -> [Forgery] {
        let base = Self.windowResult(.init(
            processIdentifier: 42,
            generation: 1001,
            bundleIdentifier: "dev.peekaboo.fixture",
            applicationName: "Fixture",
            windowID: 73,
            title: "Document",
            index: 0))
        let wrongPID = Self.windowResult(.init(
            processIdentifier: 43,
            generation: 1001,
            bundleIdentifier: "dev.peekaboo.fixture",
            applicationName: "Fixture",
            windowID: 73,
            title: "Document",
            index: 0))
        let wrongGeneration = Self.windowResult(.init(
            processIdentifier: 42,
            generation: 1001,
            bundleIdentifier: "dev.peekaboo.fixture",
            applicationName: "Fixture",
            windowID: 73,
            title: "Document",
            index: 0,
            captureGeneration: 1002))
        let wrongApp = Self.windowResult(.init(
            processIdentifier: 42,
            generation: 1001,
            bundleIdentifier: "dev.peekaboo.other",
            applicationName: "Other",
            windowID: 73,
            title: "Document",
            index: 0))
        let baseTarget = base.result.target
        let missingRequestedApp = Self.replacingTarget(
            base.result,
            with: .init(
                kind: baseTarget.kind,
                app: nil,
                window: baseTarget.window,
                bounds: baseTarget.bounds,
                detectionContext: baseTarget.detectionContext,
                captureScaleHint: baseTarget.captureScaleHint,
                selectorResolutionProofs: baseTarget.selectorResolutionProofs,
                mutationTargetIdentity: baseTarget.mutationTargetIdentity))
        let wrongWindow = Self.windowResult(.init(
            processIdentifier: 42,
            generation: 1001,
            bundleIdentifier: "dev.peekaboo.fixture",
            applicationName: "Fixture",
            windowID: 74,
            title: "Document",
            index: 0))
        let wrongTitle = Self.windowResult(.init(
            processIdentifier: 42,
            generation: 1001,
            bundleIdentifier: "dev.peekaboo.fixture",
            applicationName: "Fixture",
            windowID: 73,
            title: "Other",
            index: 0))
        let wrongIndex = Self.windowResult(.init(
            processIdentifier: 42,
            generation: 1001,
            bundleIdentifier: "dev.peekaboo.fixture",
            applicationName: "Fixture",
            windowID: 73,
            title: "Document",
            index: 1))
        let wrongFrontmost = Self.replacingDiagnostics(
            Self.frontmostWindowResult().result,
            stateSnapshot: DesktopStateSnapshot(frontmostApplication: ApplicationIdentity(
                processIdentifier: 43,
                processStartIdentity: 1002,
                bundleIdentifier: "dev.peekaboo.other",
                name: "Other")))

        return [
            Forgery(
                name: "PID",
                request: .init(target: .pid(42, window: .automatic)),
                result: wrongPID.result,
                receipt: .window(wrongPID.identity)),
            Forgery(
                name: "PID generation",
                request: .init(target: .pid(42, window: .automatic)),
                result: wrongGeneration.result,
                receipt: .window(wrongGeneration.identity)),
            Forgery(
                name: "application",
                request: .init(target: .app(identifier: "dev.peekaboo.fixture", window: .automatic)),
                result: wrongApp.result,
                receipt: .window(wrongApp.identity)),
            Forgery(
                name: "missing requested application identity",
                request: .init(target: .app(identifier: "dev.peekaboo.fixture", window: .automatic)),
                result: missingRequestedApp,
                receipt: .window(base.identity)),
            Forgery(
                name: "missing requested PID application identity",
                request: .init(target: .pid(42, window: .automatic)),
                result: missingRequestedApp,
                receipt: .window(base.identity)),
            Forgery(
                name: "window ID",
                request: .init(target: .app(identifier: "dev.peekaboo.fixture", window: .id(73))),
                result: wrongWindow.result,
                receipt: .window(wrongWindow.identity)),
            Forgery(
                name: "window title",
                request: .init(target: .app(identifier: "dev.peekaboo.fixture", window: .title("Document"))),
                result: wrongTitle.result,
                receipt: .window(wrongTitle.identity)),
            Forgery(
                name: "window index",
                request: .init(target: .app(identifier: "dev.peekaboo.fixture", window: .index(0))),
                result: wrongIndex.result,
                receipt: .window(wrongIndex.identity)),
            Forgery(
                name: "frontmost application snapshot",
                request: .init(target: .frontmost),
                result: wrongFrontmost,
                receipt: .window(base.identity)),
            Forgery(
                name: "captured window evidence",
                request: .init(target: .pid(42, window: .automatic)),
                result: Self.replacingCaptureWindowTitle(base.result, title: "Forged"),
                receipt: .window(base.identity)),
            Forgery(
                name: "missing captured application identity",
                request: .init(target: .pid(42, window: .automatic)),
                result: Self.removingCaptureApplicationIdentity(base.result),
                receipt: .window(base.identity)),
            Forgery(
                name: "missing captured window identity",
                request: .init(target: .pid(42, window: .automatic)),
                result: Self.removingCaptureWindowIdentity(base.result),
                receipt: .window(base.identity)),
        ]
    }

    private static func globalTargetForgeries() -> [Forgery] {
        let base = Self.windowResult(.init(
            processIdentifier: 42,
            generation: 1001,
            bundleIdentifier: "dev.peekaboo.fixture",
            applicationName: "Fixture",
            windowID: 73,
            title: "Document",
            index: 0))
        let requestedArea = CGRect(x: 10, y: 20, width: 300, height: 200)
        let wrongArea = CGRect(x: 11, y: 20, width: 300, height: 200)
        let menuBounds = CGRect(x: 0, y: 1050, width: 1920, height: 30)
        let screenWithWindow = Self.replacingTarget(
            Self.screenResult(index: 0),
            with: .init(
                kind: .screen(index: 0),
                app: base.result.target.app,
                window: base.result.target.window,
                detectionContext: base.result.target.detectionContext))
        let areaWithWindow = Self.replacingTarget(
            Self.areaResult(requestedArea),
            with: .init(
                kind: .area(requestedArea),
                app: base.result.target.app,
                window: base.result.target.window,
                bounds: requestedArea,
                detectionContext: base.result.target.detectionContext))
        let wrongEngine = Self.replacingCaptureMetadata(Self.screenResult(index: 0)) { metadata in
            metadata.withDiagnostics(Self.captureDiagnostics(
                size: metadata.size,
                engine: "CGWindowList"))
        }

        return [
            Forgery(
                name: "screen index",
                request: .init(target: .screen(index: 0)),
                result: Self.screenResult(index: 1),
                receipt: .global),
            Forgery(
                name: "primary screen concrete display",
                request: .init(target: .screen(index: nil)),
                result: Self.screenResult(targetIndex: nil, captureIndex: 1),
                receipt: .global),
            Forgery(
                name: "screen exact-target upgrade",
                request: .init(target: .screen(index: 0)),
                result: screenWithWindow,
                receipt: .window(base.identity)),
            Forgery(
                name: "area exact-target upgrade",
                request: .init(target: .area(requestedArea)),
                result: areaWithWindow,
                receipt: .window(base.identity)),
            Forgery(
                name: "capture scale",
                request: .init(
                    target: .screen(index: 0),
                    capture: .init(scale: .native)),
                result: Self.screenResult(index: 0),
                receipt: .global),
            Forgery(
                name: "capture engine",
                request: .init(
                    target: .screen(index: 0),
                    capture: .init(engine: .modern)),
                result: wrongEngine,
                receipt: .global),
            Forgery(
                name: "detection mode",
                request: .init(
                    target: .screen(index: 0),
                    detection: .init(mode: .accessibility)),
                result: Self.screenResult(index: 0),
                receipt: .global,
                preserveDetection: true),
            Forgery(
                name: "all-screens composite",
                request: .init(target: .allScreens),
                result: Self.screenResult(index: 0),
                receipt: .global),
            Forgery(
                name: "area bounds",
                request: .init(target: .area(requestedArea)),
                result: Self.areaResult(wrongArea),
                receipt: .global),
            Forgery(
                name: "menu-bar bounds",
                request: .init(target: .menubar),
                result: Self.menuBarResult(
                    targetBounds: menuBounds,
                    captureBounds: menuBounds.offsetBy(dx: 1, dy: 0)),
                receipt: .global),
            Forgery(
                name: "target kind",
                request: .init(target: .screen(index: 0)),
                result: Self.areaResult(requestedArea),
                receipt: .global),
        ]
    }

    private static func popoverForgeries() -> [Forgery] {
        let popoverBounds = CGRect(x: 1200, y: 700, width: 360, height: 300)
        let popoverRequest = DesktopObservationRequest(target: .menubarPopover(
            hints: ["Control Center", "Wi-Fi"],
            openIfNeeded: nil), detection: .init(mode: .none))
        return [
            Forgery(
                name: "menu-bar popover hints",
                request: popoverRequest,
                result: Self.menuBarPopoverResult(
                    bounds: popoverBounds,
                    hints: ["Clock"],
                    openIfNeeded: false,
                    clickHint: nil),
                receipt: .global),
            Forgery(
                name: "menu-bar popover open-if-needed",
                request: popoverRequest,
                result: Self.menuBarPopoverResult(
                    bounds: popoverBounds,
                    hints: ["Control Center", "Wi-Fi"],
                    openIfNeeded: true,
                    clickHint: nil),
                receipt: .global),
            Forgery(
                name: "menu-bar popover click hint",
                request: popoverRequest,
                result: Self.menuBarPopoverResult(
                    bounds: popoverBounds,
                    hints: ["Control Center", "Wi-Fi"],
                    openIfNeeded: false,
                    clickHint: "Clock"),
                receipt: .global),
        ]
    }

    private static func frontmostWindowResult()
        -> (result: DesktopObservationResult, identity: WindowMutationIdentity)
    {
        self.windowResult(.init(
            processIdentifier: 42,
            generation: 1001,
            bundleIdentifier: "dev.peekaboo.fixture",
            applicationName: "Fixture",
            windowID: 73,
            title: "Document",
            index: 0,
            captureMode: .frontmost))
    }

    private static func menuBarPopoverResult(
        bounds: CGRect,
        hints: [String],
        openIfNeeded: Bool,
        clickHint: String?) -> DesktopObservationResult
    {
        DesktopObservationResult(
            target: .init(kind: .menubarPopover, bounds: bounds),
            capture: .init(
                imageData: Data(),
                metadata: .init(
                    size: bounds.size,
                    mode: .area,
                    displayInfo: .init(index: 0, name: "Fixture", bounds: bounds, scaleFactor: 1),
                    diagnostics: self.captureDiagnostics(size: bounds.size))),
            elements: nil,
            diagnostics: .init(target: .init(
                requestedKind: "menubar-popover",
                resolvedKind: "menubar-popover",
                source: "window-list",
                hints: hints,
                openIfNeeded: openIfNeeded,
                clickHint: clickHint,
                bounds: bounds)))
            .withCaptureContentDigest(rawScreenshotData: nil, annotatedScreenshotData: nil)
    }

    private static func replacingDiagnostics(
        _ result: DesktopObservationResult,
        stateSnapshot: DesktopStateSnapshot) -> DesktopObservationResult
    {
        DesktopObservationResult(
            target: result.target,
            capture: result.capture,
            elements: result.elements,
            ocr: result.ocr,
            files: result.files,
            timings: result.timings,
            diagnostics: .init(stateSnapshot: DesktopStateSnapshotSummary(stateSnapshot)),
            captureContentDigest: result.captureContentDigest)
    }

    private static func areaResult(_ bounds: CGRect) -> DesktopObservationResult {
        DesktopObservationResult(
            target: .init(kind: .area(bounds), bounds: bounds),
            capture: .init(
                imageData: Data(),
                metadata: .init(
                    size: bounds.size,
                    mode: .area,
                    displayInfo: .init(index: 0, name: "Fixture", bounds: bounds, scaleFactor: 1),
                    diagnostics: self.captureDiagnostics(size: bounds.size))),
            elements: nil)
            .withCaptureContentDigest(rawScreenshotData: nil, annotatedScreenshotData: nil)
    }

    private static func menuBarResult(
        targetBounds: CGRect,
        captureBounds: CGRect) -> DesktopObservationResult
    {
        DesktopObservationResult(
            target: .init(kind: .menubar, bounds: targetBounds),
            capture: .init(
                imageData: Data(),
                metadata: .init(
                    size: targetBounds.size,
                    mode: .area,
                    displayInfo: .init(index: 0, name: "Fixture", bounds: captureBounds, scaleFactor: 1),
                    diagnostics: self.captureDiagnostics(size: targetBounds.size))),
            elements: nil)
            .withCaptureContentDigest(rawScreenshotData: nil, annotatedScreenshotData: nil)
    }

    private static func replacingCaptureWindowTitle(
        _ result: DesktopObservationResult,
        title: String) -> DesktopObservationResult
    {
        let metadata = result.capture.metadata
        let window = metadata.windowInfo.map {
            ServiceWindowInfo(
                windowID: $0.windowID,
                title: title,
                bounds: $0.bounds,
                isMinimized: $0.isMinimized,
                isMainWindow: $0.isMainWindow,
                isKeyWindow: $0.isKeyWindow,
                isFrontmost: $0.isFrontmost,
                subrole: $0.subrole,
                windowLevel: $0.windowLevel,
                alpha: $0.alpha,
                index: $0.index,
                spaceID: $0.spaceID,
                spaceName: $0.spaceName,
                screenIndex: $0.screenIndex,
                screenName: $0.screenName,
                isOffScreen: $0.isOffScreen,
                layer: $0.layer,
                isOnScreen: $0.isOnScreen,
                sharingState: $0.sharingState,
                isExcludedFromWindowsMenu: $0.isExcludedFromWindowsMenu,
                mutationIdentity: $0.mutationIdentity)
        }
        return DesktopObservationResult(
            target: result.target,
            capture: .init(
                imageData: result.capture.imageData,
                savedPath: result.capture.savedPath,
                metadata: .init(
                    size: metadata.size,
                    mode: metadata.mode,
                    videoTimestampMs: metadata.videoTimestampMs,
                    applicationInfo: metadata.applicationInfo,
                    windowInfo: window,
                    displayInfo: metadata.displayInfo,
                    timestamp: metadata.timestamp,
                    diagnostics: metadata.diagnostics,
                    viewport: metadata.viewport),
                warning: result.capture.warning),
            elements: result.elements,
            ocr: result.ocr,
            files: result.files,
            timings: result.timings,
            diagnostics: result.diagnostics,
            captureContentDigest: result.captureContentDigest)
    }

    private static func removingCaptureApplicationIdentity(
        _ result: DesktopObservationResult) -> DesktopObservationResult
    {
        self.replacingCaptureMetadata(result) { metadata in
            CaptureMetadata(
                size: metadata.size,
                mode: metadata.mode,
                videoTimestampMs: metadata.videoTimestampMs,
                windowInfo: metadata.windowInfo,
                displayInfo: metadata.displayInfo,
                timestamp: metadata.timestamp,
                diagnostics: metadata.diagnostics,
                viewport: metadata.viewport)
        }
    }

    private static func removingCaptureWindowIdentity(
        _ result: DesktopObservationResult) -> DesktopObservationResult
    {
        self.replacingCaptureMetadata(result) { metadata in
            CaptureMetadata(
                size: metadata.size,
                mode: metadata.mode,
                videoTimestampMs: metadata.videoTimestampMs,
                applicationInfo: metadata.applicationInfo,
                displayInfo: metadata.displayInfo,
                timestamp: metadata.timestamp,
                diagnostics: metadata.diagnostics,
                viewport: metadata.viewport)
        }
    }

    private static func replacingTarget(
        _ result: DesktopObservationResult,
        with target: ResolvedObservationTarget) -> DesktopObservationResult
    {
        DesktopObservationResult(
            target: target,
            capture: result.capture,
            elements: result.elements,
            ocr: result.ocr,
            files: result.files,
            timings: result.timings,
            diagnostics: result.diagnostics,
            captureContentDigest: result.captureContentDigest)
    }

    private static func replacingSelectorResolutionProofs(
        _ result: DesktopObservationResult,
        with proofs: [SelectorResolutionProof]) -> DesktopObservationResult
    {
        let target = result.target
        return self.replacingTarget(
            result,
            with: ResolvedObservationTarget(
                kind: target.kind,
                app: target.app,
                window: target.window,
                bounds: target.bounds,
                detectionContext: target.detectionContext,
                captureScaleHint: target.captureScaleHint,
                selectorResolutionProofs: proofs,
                mutationTargetIdentity: target.mutationTargetIdentity))
    }

    private static func replacingCaptureMetadata(
        _ result: DesktopObservationResult,
        transform: (CaptureMetadata) -> CaptureMetadata) -> DesktopObservationResult
    {
        DesktopObservationResult(
            target: result.target,
            capture: .init(
                imageData: result.capture.imageData,
                savedPath: result.capture.savedPath,
                metadata: transform(result.capture.metadata),
                warning: result.capture.warning),
            elements: result.elements,
            ocr: result.ocr,
            files: result.files,
            timings: result.timings,
            diagnostics: result.diagnostics,
            captureContentDigest: result.captureContentDigest)
    }
}

private struct Forgery {
    let name: String
    let request: DesktopObservationRequest
    let result: DesktopObservationResult
    let receipt: PeekabooBridgeOperationTargetReceipt

    init(
        name: String,
        request: DesktopObservationRequest,
        result: DesktopObservationResult,
        receipt: PeekabooBridgeOperationTargetReceipt,
        preserveDetection: Bool = false)
    {
        var request = request
        if !preserveDetection {
            request.detection = .init(mode: .none)
        }
        self.name = name
        self.request = request
        self.result = result
        self.receipt = receipt
    }
}
