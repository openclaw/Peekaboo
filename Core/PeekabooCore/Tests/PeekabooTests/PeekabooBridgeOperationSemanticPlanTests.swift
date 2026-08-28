import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

// This exhaustive wire-operation matrix intentionally keeps its receipt plan and typed-response
// invariants together so new enum cases cannot be added without updating the same test surface.
// swiftlint:disable file_length
@Suite(.serialized)
// swiftlint:disable:next type_body_length
struct PeekabooBridgeOperationSemanticPlanTests {
    @Test
    func `Every operation has an explicit success response family`() {
        for operation in PeekabooBridgeOperation.allCases {
            let families = PeekabooBridgeOperationResultSemantics.responseFamilies(for: operation)
            #expect(
                !families.isEmpty || operation == ._appleScriptProbe,
                "Missing response family for \(operation)")
        }
    }

    @Test
    func `Every operation explicitly partitions every static semantic policy`() {
        typealias Semantics = PeekabooBridgeOperationResultSemantics
        let operations = PeekabooBridgeOperation.allCases
        let allOperations = Set(operations)

        // This count is intentionally reviewed whenever the wire enum grows. The exhaustive
        // policy switches also make a missing classification a compile error.
        #expect(operations.count == 116)

        func partition<Value: Equatable>(_ values: [Value], by keyPath: KeyPath<Semantics.OperationPolicy, Value>) {
            let groups = values.map { expected in
                Set(operations.filter { Semantics.operationPolicy(for: $0)[keyPath: keyPath] == expected })
            }
            #expect(groups.reduce(0) { $0 + $1.count } == operations.count)
            #expect(groups.reduce(into: Set<PeekabooBridgeOperation>()) { $0.formUnion($1) } == allOperations)
        }

        partition(
            [.bridge, .service],
            by: \Semantics.OperationPolicy.lane.nativeOwnership)
        partition(
            [.none, .globalExclusive, .exactTargetOrGlobalExclusive],
            by: \Semantics.OperationPolicy.lane.readPolicy)
        partition(
            [.unavailable, .legacyOptionalCurrentRequired, .required],
            by: \Semantics.OperationPolicy.pinnedWindow)
        partition(
            [
                .familyOnly,
                .agentExecutionTrace,
                .processGenerationObservation,
                .certificationProducerAttestation,
                .noSuccessResponse,
                .typeActions,
                .setValue,
                .performAction,
                .focusedElement,
                .applicationIdentifier,
                .applicationLaunch,
                .applicationRelaunch,
                .capture,
                .elementDetection,
                .desktopObservation,
                .postMutationWindow,
                .menuStructureApplication,
                .waitElementSelector,
                .dockItemSelector,
                .storedDetection,
                .detectionSnapshot,
                .snapshotMutationLease,
                .dialogResult,
                .preparedDialogAction,
                .targetedDialogElements,
            ],
            by: \Semantics.OperationPolicy.typedResponse)
        partition(
            [.none, .postMutationState],
            by: \Semantics.OperationPolicy.windowResponseProof)
        let permissionSets: [Set<PeekabooBridgePermissionKind>] = [
            [],
            [.screenRecording],
            [.accessibility],
            [.postEvent],
            [.accessibility, .postEvent],
        ]
        partition(
            permissionSets,
            by: \Semantics.OperationPolicy.requiredPermissions)

        let postWindow = Set(operations.filter {
            Semantics.operationPolicy(for: $0).windowResponseProof == .postMutationState
        })
        let pinnedWindowAvailable = Set(operations.filter {
            Semantics.operationPolicy(for: $0).pinnedWindow != .unavailable
        })
        #expect(postWindow == pinnedWindowAvailable)
        #expect(Set(operations.filter {
            Semantics.operationPolicy(for: $0).typedResponse == .noSuccessResponse
        }) == [._appleScriptProbe])
    }

    @Test
    func `Focus pin policy is legacy optional and current required`() {
        let focus = PeekabooBridgeRequest.focusWindow(.init(target: .windowId(71)))
        #expect(!focus.requiresPinnedWindowMutationReceipt)
        PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
            #expect(focus.requiresPinnedWindowMutationReceipt)
        }
    }

    @Test
    func `Read-only and permission response families are exact`() {
        let permissions = PeekabooBridgeResponse.permissionsStatus(.init(
            screenRecording: true,
            accessibility: true))
        #expect(PeekabooBridgeOperationResultSemantics.responseMatchesContract(
            permissions,
            request: .permissionsStatus))
        #expect(!PeekabooBridgeOperationResultSemantics.responseMatchesContract(
            .ok,
            request: .permissionsStatus))
        #expect(PeekabooBridgeOperationResultSemantics.responseMatchesContract(
            .bool(true),
            request: .requestPostEventPermission))
    }

    @Test
    func `Delivery and unit rules admit bounded production alternatives`() throws {
        let maximize = PeekabooBridgeRequest.maximizeWindow(.init(
            target: .windowId(71),
            expectedIdentity: .init(
                windowID: 71,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 1001,
                capturedBounds: CGRect(x: 10, y: 20, width: 300, height: 200))))
        let two = try #require(DesktopActionOutcome.DispatchUnitCount(2))
        let maximizeOutcome = DesktopActionOutcome.confirmedChange(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            unitCount: two)
        #expect(PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            maximizeOutcome,
            request: maximize))

        let scroll = PeekabooBridgeRequest.targetedScroll(.init(request: .init(
            direction: .down,
            amount: 2,
            target: "S1")))
        let scrollOutcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: two)
        #expect(PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            scrollOutcome,
            request: scroll))
        #expect(!PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            .dispatchedUnverified(
                route: .bridge,
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .one),
            request: scroll))
    }

    @Test
    func `Pixel focus AX delivery treats empty text as a zero emission action`() {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let identity = WindowMutationIdentity(
            windowID: 71,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 1001,
            capturedBounds: bounds)
        func request(_ actions: [TypeAction]) -> PeekabooBridgeRequest {
            .exactWindowPixelFocusType(.init(request: .init(
                point: CGPoint(x: 40, y: 50),
                actions: actions,
                cadence: .fixed(milliseconds: 0),
                snapshotID: "snapshot",
                windowIdentity: identity,
                windowBounds: bounds)))
        }

        let axOnlyOutcome = DesktopActionOutcome.confirmedChange(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            unitCount: .init(2))
        #expect(PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            axOnlyOutcome,
            request: request([.clear, .text("")])))
        #expect(!PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            axOnlyOutcome,
            request: request([.clear, .text(""), .key(.return)])))
        #expect(!PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            axOnlyOutcome,
            request: request([.text("")])))
    }

    @Test
    // swiftlint:disable:next function_body_length
    func `composed input parity binds response family delivery units and exact target`() async throws {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let identity = WindowMutationIdentity(
            windowID: 71,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 1001,
            capturedBounds: bounds)
        let target = PeekabooBridgeOperationTargetReceipt.window(identity)

        let pixelRequest = PeekabooBridgeRequest.exactWindowPixelFocusType(.init(request: .init(
            point: CGPoint(x: 40, y: 50),
            actions: [.text("ab"), .key(.return)],
            cadence: .fixed(milliseconds: 0),
            snapshotID: "snapshot",
            windowIdentity: identity,
            windowBounds: bounds)))
        let pixelResult = TypeResult(totalCharacters: 2, keyPresses: 3)
        let pixelOutcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .composite, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .init(4))
        #expect(PeekabooBridgeOperationResultSemantics.responseMatchesContract(
            .typeResult(pixelResult),
            request: pixelRequest))
        #expect(PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            pixelOutcome,
            request: pixelRequest))

        let projectedPixelRequest = PeekabooBridgeRequest.projectedAction(.init(request: pixelRequest))
        let projectedPixelResponse = PeekabooBridgeResponse.projectedAction(.init(
            response: .typeResult(pixelResult),
            outcome: pixelOutcome.projection))
        let validPixel = try await Self.makeBundle(
            request: projectedPixelRequest,
            response: projectedPixelResponse,
            target: target,
            outcome: pixelOutcome.projection)
        try validPixel.bundle.validateIntegrity()

        let forgedFocusConfirmed = DesktopActionOutcome.confirmedChange(
            route: .bridge,
            delivery: .init(mechanism: .composite, mode: .background),
            unitCount: .init(4))
        #expect(!PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            forgedFocusConfirmed,
            request: pixelRequest))
        let signedForgedFocusConfirmed = try await Self.makeBundle(
            request: projectedPixelRequest,
            response: .projectedAction(.init(
                response: .typeResult(pixelResult),
                outcome: forgedFocusConfirmed.projection)),
            target: target,
            outcome: forgedFocusConfirmed.projection)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try signedForgedFocusConfirmed.bundle.validateIntegrity()
        }

        let confirmedLiteralRequest = PeekabooBridgeRequest.exactWindowPixelFocusType(.init(request: .init(
            point: CGPoint(x: 40, y: 50),
            actions: [.clear, .text("ok")],
            cadence: .fixed(milliseconds: 0),
            snapshotID: "snapshot",
            windowIdentity: identity,
            windowBounds: bounds)))
        let projectedConfirmedLiteralRequest = PeekabooBridgeRequest.projectedAction(.init(
            request: confirmedLiteralRequest))
        let confirmedLiteralResult = TypeResult(
            totalCharacters: 2,
            keyPresses: 0,
            specialKeyPresses: 0)
        let confirmedLiteralOutcome = DesktopActionOutcome.confirmedChange(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            unitCount: .init(4))
        #expect(PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            confirmedLiteralOutcome,
            request: confirmedLiteralRequest))
        let signedConfirmedLiteral = try await Self.makeBundle(
            request: projectedConfirmedLiteralRequest,
            response: .projectedAction(.init(
                response: .typeResult(confirmedLiteralResult),
                outcome: confirmedLiteralOutcome.projection)),
            target: target,
            outcome: confirmedLiteralOutcome.projection)
        try signedConfirmedLiteral.bundle.validateIntegrity()

        let pixelFocusFailure = DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one,
            message: "Pixel-focus typing stopped after its focus write.")
        #expect(PeekabooBridgeOperationResultSemantics.failureOutcomeMatchesContract(
            pixelFocusFailure.outcome,
            request: pixelRequest))
        let signedPixelFocusFailure = try await Self.makeBundle(
            request: projectedPixelRequest,
            response: .projectedAction(.init(
                response: .error(.init(code: .internalError, actionFailure: pixelFocusFailure)),
                outcome: pixelFocusFailure.outcome.projection)),
            target: target,
            outcome: pixelFocusFailure.outcome.projection)
        try signedPixelFocusFailure.bundle.validateIntegrity()

        let pixelFocusOnlySuccess = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        #expect(!PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            pixelFocusOnlySuccess,
            request: pixelRequest))
        let signedPixelFocusOnlySuccess = try await Self.makeBundle(
            request: projectedPixelRequest,
            response: .projectedAction(.init(
                response: .typeResult(pixelResult),
                outcome: pixelFocusOnlySuccess.projection)),
            target: target,
            outcome: pixelFocusOnlySuccess.projection)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try signedPixelFocusOnlySuccess.bundle.validateIntegrity()
        }

        let missingClickOutcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .composite, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .init(3))
        let missingClick = try await Self.makeBundle(
            request: projectedPixelRequest,
            response: .projectedAction(.init(
                response: .typeResult(pixelResult),
                outcome: missingClickOutcome.projection)),
            target: target,
            outcome: missingClickOutcome.projection)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try missingClick.bundle.validateIntegrity()
        }

        let modifierRequest = PeekabooBridgeRequest.foregroundModifierClick(.init(request: .init(
            point: CGPoint(x: 40, y: 50),
            clickType: .single,
            modifiers: [.command, .shift],
            snapshotID: "snapshot",
            windowIdentity: identity,
            windowBounds: bounds)))
        let modifierResult = ForegroundModifierClickResult(
            cursorRestoration: .restored,
            focusRestoration: .preservedNewerState)
        let modifierOutcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .composite, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .init(6))
        #expect(PeekabooBridgeOperationResultSemantics.responseMatchesContract(
            .foregroundModifierClickResult(modifierResult),
            request: modifierRequest))
        #expect(!PeekabooBridgeOperationResultSemantics.responseMatchesContract(
            .typeResult(pixelResult),
            request: modifierRequest))
        #expect(PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            modifierOutcome,
            request: modifierRequest))

        let alreadyFocusedResult = ForegroundModifierClickResult(
            cursorRestoration: .notNeeded,
            focusRestoration: .notNeeded)
        let alreadyFocusedOutcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one)
        #expect(PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            alreadyFocusedOutcome,
            request: modifierRequest))
        let alreadyFocusedBundle = try await Self.makeBundle(
            request: .projectedAction(.init(request: modifierRequest)),
            response: .projectedAction(.init(
                response: .foregroundModifierClickResult(alreadyFocusedResult),
                outcome: alreadyFocusedOutcome.projection)),
            target: target,
            outcome: alreadyFocusedOutcome.projection)
        try alreadyFocusedBundle.bundle.validateIntegrity()

        let projectedModifierRequest = PeekabooBridgeRequest.projectedAction(.init(request: modifierRequest))
        let projectedModifierResponse = PeekabooBridgeResponse.projectedAction(.init(
            response: .foregroundModifierClickResult(modifierResult),
            outcome: modifierOutcome.projection))
        let validModifier = try await Self.makeBundle(
            request: projectedModifierRequest,
            response: projectedModifierResponse,
            target: target,
            outcome: modifierOutcome.projection)
        try validModifier.bundle.validateIntegrity()

        let focusPrefixDeliveries = [
            DesktopActionOutcome.Delivery(mechanism: .nativeFramework, mode: .foreground),
            DesktopActionOutcome.Delivery(mechanism: .accessibilityValue, mode: .foreground),
            DesktopActionOutcome.Delivery(mechanism: .accessibilityAction, mode: .foreground),
        ]
        for delivery in focusPrefixDeliveries {
            let focusFailure = DesktopActionFailure.indeterminate(
                route: .bridge,
                delivery: delivery,
                evidence: .completionUnknown,
                unitCount: .one,
                message: "Modifier-click focus stopped after an accepted foreground dispatch.")
            #expect(PeekabooBridgeOperationResultSemantics.failureOutcomeMatchesContract(
                focusFailure.outcome,
                request: modifierRequest))
            let projectedFocusFailure = PeekabooBridgeResponse.projectedAction(.init(
                response: .error(.init(code: .internalError, actionFailure: focusFailure)),
                outcome: focusFailure.outcome.projection))
            let signedFocusFailure = try await Self.makeBundle(
                request: projectedModifierRequest,
                response: projectedFocusFailure,
                target: target,
                outcome: focusFailure.outcome.projection)
            try signedFocusFailure.bundle.validateIntegrity()

            let focusOnlySuccess = DesktopActionOutcome.dispatchedUnverified(
                route: .bridge,
                delivery: delivery,
                evidence: .deliveryAccepted,
                unitCount: .one)
            #expect(!PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
                focusOnlySuccess,
                request: modifierRequest))
            let signedFocusOnlySuccess = try await Self.makeBundle(
                request: projectedModifierRequest,
                response: .projectedAction(.init(
                    response: .foregroundModifierClickResult(alreadyFocusedResult),
                    outcome: focusOnlySuccess.projection)),
                target: target,
                outcome: focusOnlySuccess.projection)
            #expect(throws: PeekabooBridgeOperationReceiptError.self) {
                try signedFocusOnlySuccess.bundle.validateIntegrity()
            }
        }

        for (request, response, outcome) in [
            (projectedPixelRequest, projectedPixelResponse, pixelOutcome.projection),
            (projectedModifierRequest, projectedModifierResponse, modifierOutcome.projection),
        ] {
            let conflicting = try await Self.makeBundle(
                request: request,
                response: response,
                target: .global,
                outcome: outcome)
            #expect(throws: PeekabooBridgeOperationReceiptError.self) {
                try conflicting.bundle.validateIntegrity()
            }
        }
    }

    @Test
    func `focus and close plans admit exact native composite counts`() throws {
        let identity = WindowMutationIdentity(
            windowID: 71,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 1001,
            capturedBounds: CGRect(x: 10, y: 20, width: 300, height: 200))
        let three = try #require(DesktopActionOutcome.DispatchUnitCount(3))
        let five = try #require(DesktopActionOutcome.DispatchUnitCount(5))

        let focus = PeekabooBridgeRequest.focusWindow(.init(
            target: .windowId(identity.windowID),
            expectedIdentity: identity))
        #expect(PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            .dispatchedUnverified(
                route: .bridge,
                delivery: .init(mechanism: .composite, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: three),
            request: focus))

        let foregroundClose = PeekabooBridgeRequest.closeWindow(.init(
            target: .windowId(identity.windowID),
            expectedIdentity: identity))
        #expect(PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            .confirmedChange(
                route: .bridge,
                delivery: .init(mechanism: .composite, mode: .foreground),
                unitCount: five),
            request: foregroundClose))

        let backgroundClose = PeekabooBridgeRequest.backgroundCloseWindow(.init(
            target: .windowId(identity.windowID),
            expectedIdentity: identity))
        let two = try #require(DesktopActionOutcome.DispatchUnitCount(2))
        #expect(PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            .confirmedChange(
                route: .bridge,
                delivery: .init(mechanism: .accessibilityAction, mode: .background),
                unitCount: two),
            request: backgroundClose))
        #expect(!PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            .confirmedChange(
                route: .bridge,
                delivery: .init(mechanism: .accessibilityAction, mode: .background),
                unitCount: three),
            request: backgroundClose))
    }

    @Test
    func `Exact window click admits only AX and window-routed production delivery`() throws {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let identity = WindowMutationIdentity(
            windowID: 71,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 1001,
            capturedBounds: bounds)
        let request = PeekabooBridgeRequest.targetedClick(.init(
            target: .elementId("B1"),
            clickType: .single,
            snapshotId: "snapshot",
            targetProcessIdentifier: identity.ownerProcessIdentifier,
            targetWindowID: identity.windowID,
            expectedWindowIdentity: identity,
            expectedWindowBounds: bounds))
        #expect(request.operation == .exactWindowTargetedClick)
        let two = try #require(DesktopActionOutcome.DispatchUnitCount(2))
        let three = try #require(DesktopActionOutcome.DispatchUnitCount(3))
        let valid = [
            DesktopActionOutcome.dispatchedUnverified(
                route: .bridge,
                delivery: .init(mechanism: .accessibilityAction, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .one),
            DesktopActionOutcome.dispatchedUnverified(
                route: .bridge,
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: three),
        ]
        for outcome in valid {
            #expect(PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
                outcome,
                request: request))
        }

        let invalid = [
            DesktopActionOutcome.dispatchedUnverified(
                route: .bridge,
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one),
            DesktopActionOutcome.dispatchedUnverified(
                route: .bridge,
                delivery: .init(mechanism: .processTargetedEvents, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: three),
            DesktopActionOutcome.dispatchedUnverified(
                route: .bridge,
                delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one),
            DesktopActionOutcome.dispatchedUnverified(
                route: .bridge,
                delivery: .init(mechanism: .windowTargetedEvents, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: three),
            DesktopActionOutcome.dispatchedUnverified(
                route: .bridge,
                delivery: .init(mechanism: .accessibilityAction, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: two),
        ]
        for outcome in invalid {
            #expect(!PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
                outcome,
                request: request))
        }

        let coordinateRequest = PeekabooBridgeRequest.targetedClick(.init(
            target: .coordinates(CGPoint(x: 30, y: 40)),
            clickType: .single,
            snapshotId: "snapshot",
            targetProcessIdentifier: identity.ownerProcessIdentifier,
            targetWindowID: identity.windowID,
            expectedWindowIdentity: identity,
            expectedWindowBounds: bounds))
        #expect(PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            valid[1],
            request: coordinateRequest))
        #expect(!PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            valid[0],
            request: coordinateRequest))
    }

    @Test
    func `Exact window hotkey rejects process-only delivery in plans and signed receipts`() async throws {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let identity = WindowMutationIdentity(
            windowID: 71,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 1001,
            capturedBounds: bounds)
        let processIdentity = identity.processIdentity
        let targetedRequest = PeekabooBridgeRequest.targetedHotkey(.init(
            keys: "cmd,a",
            holdDuration: 0,
            targetProcessIdentifier: processIdentity.processIdentifier,
            expectedProcessIdentity: processIdentity))
        let exactRequest = PeekabooBridgeRequest.exactWindowTargetedHotkey(.init(
            keys: "cmd,a",
            holdDuration: 0,
            expectedWindowIdentity: identity,
            expectedWindowBounds: bounds))
        let processOutcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .processTargetedEvents, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let axOutcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let windowOutcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)

        #expect(PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            processOutcome,
            request: targetedRequest))
        #expect(!PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            processOutcome,
            request: exactRequest))
        let processFailure = DesktopActionOutcome.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .processTargetedEvents, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one)
        #expect(PeekabooBridgeOperationResultSemantics.failureOutcomeMatchesContract(
            processFailure,
            request: targetedRequest))
        #expect(!PeekabooBridgeOperationResultSemantics.failureOutcomeMatchesContract(
            processFailure,
            request: exactRequest))
        for outcome in [axOutcome, windowOutcome] {
            #expect(PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
                outcome,
                request: exactRequest))
        }

        let request = PeekabooBridgeRequest.projectedAction(.init(request: exactRequest))
        let invalidResponse = PeekabooBridgeResponse.projectedAction(.init(
            response: .ok,
            outcome: processOutcome.projection))
        let invalid = try await Self.makeBundle(
            request: request,
            response: invalidResponse,
            target: .window(identity),
            outcome: processOutcome.projection)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try invalid.bundle.validateIntegrity()
        }

        let validResponse = PeekabooBridgeResponse.projectedAction(.init(
            response: .ok,
            outcome: windowOutcome.projection))
        let valid = try await Self.makeBundle(
            request: request,
            response: validResponse,
            target: .window(identity),
            outcome: windowOutcome.projection)
        try valid.bundle.validateIntegrity()
    }

    @Test
    func `Wrong failure delivery is rejected while quit false refusal is admitted`() {
        let move = PeekabooBridgeRequest.moveMouse(.init(
            to: .zero,
            duration: 0,
            steps: 1,
            profile: .linear))
        let wrongFailure = DesktopActionOutcome.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one)
        #expect(!PeekabooBridgeOperationResultSemantics.failureOutcomeMatchesContract(
            wrongFailure,
            request: move))

        let quit = PeekabooBridgeRequest.quitApplication(.init(
            identifier: "PID:42",
            force: false,
            expectedIdentity: .init(processIdentifier: 42, processStartIdentity: 1001)))
        let refusal = DesktopActionOutcome.refused(route: .bridge, reason: .targetUnavailable)
        #expect(PeekabooBridgeOperationResultSemantics.nonErrorResponseAllowsFailureOutcome(
            .bool(false),
            outcome: refusal,
            request: quit))
    }

    @Test
    func `Dock launch ambiguity admits only one foreground AXPress unit`() {
        let request = PeekabooBridgeRequest.launchDockItem(.init(appName: "Safari"))
        let foreground = DesktopActionOutcome.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            evidence: .completionUnknown,
            unitCount: .one)
        let background = DesktopActionOutcome.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one)

        #expect(PeekabooBridgeOperationResultSemantics.failureOutcomeMatchesContract(
            foreground,
            request: request))
        #expect(!PeekabooBridgeOperationResultSemantics.failureOutcomeMatchesContract(
            background,
            request: request))
    }

    @Test
    func `Mixed application fallback keeps a known count and derives only a global target`() async throws {
        let three = try #require(DesktopActionOutcome.DispatchUnitCount(3))
        let mixed = DesktopActionOutcome.indeterminate(
            route: .bridge,
            delivery: nil,
            evidence: .completionUnknown,
            unitCount: three)
        let hideOthers = PeekabooBridgeRequest.hideOtherApplications(.init(identifier: "Fixture"))
        #expect(PeekabooBridgeOperationResultSemantics.failureOutcomeMatchesContract(
            mixed,
            request: hideOthers))

        let pointer = PeekabooBridgeRequest.moveMouse(.init(
            to: .zero,
            duration: 0,
            steps: 1,
            profile: .linear))
        #expect(!PeekabooBridgeOperationResultSemantics.failureOutcomeMatchesContract(
            mixed,
            request: pointer))

        let possibleAX = DesktopActionOutcome.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one)
        #expect(PeekabooBridgeOperationResultSemantics.failureOutcomeMatchesContract(
            possibleAX,
            request: hideOthers))

        let failure = DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: nil,
            evidence: .completionUnknown,
            unitCount: three,
            message: "mixed AX and native fallback")
        let envelope = PeekabooBridgeErrorEnvelope(code: .internalError, actionFailure: failure)
        let request = PeekabooBridgeRequest.projectedAction(.init(request: hideOthers))
        let response = PeekabooBridgeResponse.projectedAction(.init(
            response: .error(envelope),
            outcome: mixed.projection))
        let handled = PeekabooBridgeHandledResponse(response: response)
        try PeekabooBridgeOperationResultSemantics.validateSuccessfulTargetDisposition(
            request: request,
            handled: handled)
        #expect(try PeekabooBridgeOperationTargetAttribution.resolve(
            request: request,
            response: response,
            handledTarget: nil) == nil)

        let signed = try await Self.makeBundle(
            request: request,
            response: response,
            target: .global,
            outcome: mixed.projection)
        try signed.bundle.validateIntegrity()
        #expect(signed.bundle.receipt.payload.target == .global)
        #expect(signed.bundle.receipt.payload.targetAttributionFailure == nil)
        #expect(signed.bundle.receipt.payload.outcome?.dispatchedUnitCount == three)

        let targeted = PeekabooBridgeRequest.projectedAction(.init(request: .hideApplication(.init(
            identifier: "Fixture"))))
        #expect(throws: DesktopTargetIdentityError.self) {
            try PeekabooBridgeOperationResultSemantics.validateSuccessfulTargetDisposition(
                request: targeted,
                handled: handled)
        }
    }

    @Test
    func `Success states and result values are operation exact`() throws {
        let move = PeekabooBridgeRequest.moveMouse(.init(
            to: .zero,
            duration: 0,
            steps: 1,
            profile: .linear))
        #expect(!PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            .confirmedNoChange(route: .bridge),
            response: .ok,
            request: move))
        #expect(PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            .dispatchedUnverified(
                route: .bridge,
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one),
            response: .ok,
            request: move))

        let quit = PeekabooBridgeRequest.quitApplication(.init(
            identifier: "PID:42",
            force: false,
            expectedIdentity: .init(processIdentifier: 42, processStartIdentity: 1001)))
        let suspected = DesktopActionOutcome.suspectedNoop(
            route: .bridge,
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            unitCount: .one)
        #expect(!PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            suspected,
            response: .bool(true),
            request: quit))
        #expect(PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            suspected,
            response: .bool(false),
            request: quit))

        let forceDismiss = try PeekabooBridgeRequest.exactDialogForceDismiss(.init(
            target: DialogTargetSelector(processIdentifier: 42, windowID: 71)))
        #expect(!PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            .confirmedChange(
                route: .bridge,
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                unitCount: .one),
            response: .dialogResult(Self.dialogResult(
                action: .dismiss,
                outcome: .confirmedChange(
                    delivery: .init(mechanism: .globalEvents, mode: .foreground),
                    unitCount: .one))),
            request: forceDismiss))
    }

    @Test
    func `Protocol 1 29 error-only operations reject signed success`() {
        let unhide = PeekabooBridgeRequest.unhideApplication(.init(identifier: "Fixture"))
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        #expect(!PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            outcome,
            response: .ok,
            request: unhide))
    }

    @Test
    func `Bundle validation requires an independent trust anchor for provenance`() async throws {
        let request = PeekabooBridgeRequest.permissionsStatus
        let response = PeekabooBridgeResponse.permissionsStatus(.init(
            screenRecording: true,
            accessibility: true))
        let signed = try await Self.makeBundle(request: request, response: response)

        try signed.bundle.validateIntegrity()
        try signed.bundle.validate(trustAnchor: .listenerAttestation(signed.attestation))
        try signed.bundle.validate(trustAnchor: .listenerPublicKey(signed.attestation.publicKey))
        try signed.bundle.validate(trustAnchor: .listenerPublicKeySHA256(
            PeekabooBridgeOperationReceiptCoding.sha256(signed.attestation.publicKey)))
        try signed.bundle.validate(trustAnchor: .listenerAttestationSHA256(
            PeekabooBridgeOperationReceiptCoding.sha256(signed.attestation)))
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try signed.bundle.validate(trustAnchor: .listenerPublicKey(Data(repeating: 7, count: 32)))
        }
    }

    @Test
    func `Standalone receipt binds the supplied listener key digest before signature acceptance`() async throws {
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: "/tmp/receipt-key-digest-\(UUID().uuidString)/bridge.sock")
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let request = PeekabooBridgeRequest.permissionsStatus
        let response = PeekabooBridgeResponse.permissionsStatus(.init(
            screenRecording: true,
            accessibility: true))
        let accepted = try await session.acceptedClaim(
            authority: authority,
            sequence: 0,
            request: request)
        let original = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: accepted.claim,
            request: request,
            response: response)
        let forgedPayload = PeekabooBridgeOperationReceiptPayload(
            requestID: original.requestID,
            sessionID: original.sessionID,
            sessionSequence: original.sessionSequence,
            sessionAttestationSHA256: original.sessionAttestationSHA256,
            listenerInstanceID: original.listenerInstanceID,
            listenerPublicKeySHA256: String(repeating: "0", count: 64),
            host: original.host,
            clientInstanceID: original.clientInstanceID,
            client: original.client,
            operation: original.operation,
            requestSHA256: original.requestSHA256,
            responseSHA256: original.responseSHA256,
            target: original.target,
            focusedElement: original.focusedElement,
            targetAttributionFailure: original.targetAttributionFailure,
            targetAttributionEvidence: original.targetAttributionEvidence,
            outcome: original.outcome,
            remainingClaimCount: original.remainingClaimCount,
            startedAtUnixMilliseconds: original.startedAtUnixMilliseconds,
            completedAtUnixMilliseconds: original.completedAtUnixMilliseconds)
        let forgedReceipt = try await authority.signAndArchive(forgedPayload, claim: accepted.claim)
        authority.complete(accepted.claim)

        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try forgedReceipt.validateSignature(publicKey: authority.attestation.publicKey)
        }
    }

    @Test
    func `Signed read-only response-family drift is rejected`() async throws {
        let signed = try await Self.makeBundle(request: .permissionsStatus, response: .ok)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try signed.bundle.validateIntegrity()
        }

        let projected = try await Self.makeBundle(
            request: .permissionsStatus,
            response: .projectedAction(.init(
                response: .permissionsStatus(.init(screenRecording: true, accessibility: true)),
                outcome: nil)))
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try projected.bundle.validateIntegrity()
        }
    }
}

extension PeekabooBridgeOperationSemanticPlanTests {
    @Test
    func `Signed captures bind their exact request selectors and targets`() async throws {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let identity = WindowMutationIdentity(
            windowID: 73,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 1001,
            capturedBounds: bounds)
        let application = Self.applicationWithSelectorProof(ServiceApplicationInfo(
            processIdentifier: identity.ownerProcessIdentifier,
            processStartIdentity: identity.ownerProcessStartIdentity,
            bundleIdentifier: "dev.peekaboo.fixture",
            name: "Fixture"), selector: "dev.peekaboo.fixture")
        let window = ServiceWindowInfo(
            windowID: identity.windowID,
            title: "Fixture",
            bounds: bounds,
            index: 2,
            mutationIdentity: identity)
        let indexedSelectorProofs = (application.selectorResolutionProofs ?? []).map {
            $0.selecting(windowIdentity: identity)
        } + [Self.windowSelectorProof(
            selection: .index(2),
            processIdentity: identity.processIdentity,
            window: window)]
        let windowResponse = PeekabooBridgeResponse.capture(.init(
            imageData: Data(),
            metadata: .init(
                size: bounds.size,
                mode: .window,
                applicationInfo: application,
                windowInfo: window,
                diagnostics: Self.captureDiagnostics(size: bounds.size),
                selectorResolutionProofs: indexedSelectorProofs)))
        let windowRequest = PeekabooBridgeRequest.captureWindow(.init(
            appIdentifier: "",
            windowIndex: nil,
            windowId: identity.windowID,
            visualizerMode: .none,
            scale: .logical1x))
        let frontmostRequest = PeekabooBridgeRequest.captureFrontmost(.init(
            visualizerMode: .none,
            scale: .logical1x))
        let frontmostResponse = PeekabooBridgeResponse.capture(.init(
            imageData: Data(),
            metadata: .init(
                size: bounds.size,
                mode: .frontmost,
                applicationInfo: application,
                windowInfo: window,
                diagnostics: Self.captureDiagnostics(size: bounds.size))))

        #expect(PeekabooBridgeOperationResultSemantics.contract(for: windowRequest).targetPolicy == .responseResolved)
        #expect(PeekabooBridgeOperationResultSemantics.contract(for: frontmostRequest)
            .targetPolicy == .responseResolved)
        for (request, response) in [(windowRequest, windowResponse), (frontmostRequest, frontmostResponse)] {
            let signed = try await Self.makeBundle(request: request, response: response, target: .window(identity))
            try signed.bundle.validateIntegrity()
        }

        let wrongFrontmostMode = try await Self.makeBundle(
            request: frontmostRequest,
            response: windowResponse,
            target: .window(identity))
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try wrongFrontmostMode.bundle.validateIntegrity()
        }

        let targetless = try await Self.makeBundle(
            request: frontmostRequest,
            response: .capture(.init(
                imageData: Data(),
                metadata: .init(
                    size: bounds.size,
                    mode: .frontmost,
                    diagnostics: Self.captureDiagnostics(size: bounds.size)))))
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try targetless.bundle.validateIntegrity()
        }

        let indexedWindowRequest = PeekabooBridgeRequest.captureWindow(.init(
            appIdentifier: "dev.peekaboo.fixture",
            windowIndex: 2,
            visualizerMode: .none,
            scale: .logical1x))
        let indexedWindow = try await Self.makeBundle(
            request: indexedWindowRequest,
            response: windowResponse,
            target: .window(identity))
        try indexedWindow.bundle.validateIntegrity()

        let wrongWindowIndexRequest = PeekabooBridgeRequest.captureWindow(.init(
            appIdentifier: "dev.peekaboo.fixture",
            windowIndex: 1,
            visualizerMode: .none,
            scale: .logical1x))
        let wrongWindowIndex = try await Self.makeBundle(
            request: wrongWindowIndexRequest,
            response: windowResponse,
            target: .window(identity))
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try wrongWindowIndex.bundle.validateIntegrity()
        }

        let differentIdentity = WindowMutationIdentity(
            windowID: identity.windowID + 1,
            ownerProcessIdentifier: identity.ownerProcessIdentifier,
            ownerProcessStartIdentity: identity.ownerProcessStartIdentity,
            capturedBounds: bounds)
        let differentResponse = PeekabooBridgeResponse.capture(.init(
            imageData: Data(),
            metadata: .init(
                size: bounds.size,
                mode: .window,
                applicationInfo: application,
                windowInfo: .init(
                    windowID: differentIdentity.windowID,
                    title: "Other",
                    bounds: bounds,
                    mutationIdentity: differentIdentity),
                diagnostics: Self.captureDiagnostics(size: bounds.size))))
        let drifted = try await Self.makeBundle(
            request: windowRequest,
            response: differentResponse,
            target: .window(differentIdentity))
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try drifted.bundle.validateIntegrity()
        }
    }

    @Test
    func `Signed window captures bind executable selector evidence`() async throws {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let identity = WindowMutationIdentity(
            windowID: 73,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 1001,
            capturedBounds: bounds)
        let executablePath = "/Applications/OpenClaw Desktop Test.app/Contents/MacOS/openclaw-desktop"

        func response(executablePath: String?, selector: String) -> PeekabooBridgeResponse {
            let application = Self.applicationWithSelectorProof(
                .init(
                    processIdentifier: identity.ownerProcessIdentifier,
                    processStartIdentity: identity.ownerProcessStartIdentity,
                    bundleIdentifier: "org.openclaw.desktop-test",
                    name: "OpenClaw Desktop Test",
                    bundlePath: "/Applications/OpenClaw Desktop Test.app",
                    executablePath: executablePath),
                selector: selector)
            let window = ServiceWindowInfo(
                windowID: identity.windowID,
                title: "Fixture",
                bounds: bounds,
                index: 0,
                mutationIdentity: identity)
            let selectorProofs = (application.selectorResolutionProofs ?? []).map {
                $0.selecting(windowIdentity: identity)
            } + [Self.windowSelectorProof(
                selection: .automatic,
                processIdentity: identity.processIdentity,
                window: window)]
            return .capture(.init(
                imageData: Data(),
                metadata: .init(
                    size: bounds.size,
                    mode: .window,
                    applicationInfo: application,
                    windowInfo: window,
                    diagnostics: Self.captureDiagnostics(size: bounds.size),
                    selectorResolutionProofs: selectorProofs)))
        }

        for selector in [executablePath, "openclaw-desktop", "claw-desk"] {
            let request = PeekabooBridgeRequest.captureWindow(.init(
                appIdentifier: selector,
                windowIndex: nil,
                visualizerMode: .none,
                scale: .logical1x))
            let signed = try await Self.makeBundle(
                request: request,
                response: response(executablePath: executablePath, selector: selector),
                target: .window(identity))
            try signed.bundle.validateIntegrity()
        }

        let request = PeekabooBridgeRequest.captureWindow(.init(
            appIdentifier: "openclaw-desktop",
            windowIndex: nil,
            visualizerMode: .none,
            scale: .logical1x))
        let forged = try await Self.makeBundle(
            request: request,
            response: response(
                executablePath: "/Applications/Other.app/Contents/MacOS/other",
                selector: "other"),
            target: .window(identity))
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try forged.bundle.validateIntegrity()
        }
    }

    @Test
    func `Signed application responses share discovery selector semantics`() async throws {
        let processIdentity = ApplicationProcessIdentity(
            processIdentifier: 42,
            processStartIdentity: 1001)
        let application = ServiceApplicationInfo(
            processIdentifier: processIdentity.processIdentifier,
            processStartIdentity: processIdentity.processStartIdentity,
            bundleIdentifier: "org.openclaw.desktop-test",
            name: "OpenClaw Desktop Test",
            bundlePath: "/Applications/OpenClaw Desktop Test.app",
            executablePath: "/Applications/OpenClaw Desktop Test.app/Contents/MacOS/openclaw-desktop")

        for selector in [
            "openclaw desktop test",
            "claw desk",
            "openclaw-desktop",
            "claw-desk",
        ] {
            let request = PeekabooBridgeRequest.findApplication(.init(identifier: selector))
            let resolvedApplication = Self.applicationWithSelectorProof(application, selector: selector)
            let signed = try await Self.makeBundle(
                request: request,
                response: .application(resolvedApplication),
                target: .process(processIdentity))
            try signed.bundle.validateIntegrity()
        }

        let forged = try await Self.makeBundle(
            request: .findApplication(.init(identifier: "openclaw-desktop")),
            response: .application(.init(
                processIdentifier: processIdentity.processIdentifier,
                processStartIdentity: processIdentity.processStartIdentity,
                bundleIdentifier: "org.example.other",
                name: "Other App",
                bundlePath: "/Applications/Other.app",
                executablePath: "/Applications/Other.app/Contents/MacOS/other")),
            target: .process(processIdentity))
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try forged.bundle.validateIntegrity()
        }
    }

    @Test
    func `Signed desktop observations carry executable selector evidence`() async throws {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let identity = WindowMutationIdentity(
            windowID: 73,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 1001,
            capturedBounds: bounds)
        let baseApplication = ServiceApplicationInfo(
            processIdentifier: identity.ownerProcessIdentifier,
            processStartIdentity: identity.ownerProcessStartIdentity,
            bundleIdentifier: "org.openclaw.desktop-test",
            name: "OpenClaw Desktop Test",
            bundlePath: "/Applications/OpenClaw Desktop Test.app",
            executablePath: "/Applications/OpenClaw Desktop Test.app/Contents/MacOS/openclaw-desktop")
        let application = Self.applicationWithSelectorProof(baseApplication, selector: "openclaw-desktop")
        let app = ApplicationIdentity(
            processIdentifier: application.processIdentifier,
            processStartIdentity: application.processStartIdentity,
            bundleIdentifier: application.bundleIdentifier,
            name: application.name,
            bundlePath: application.bundlePath,
            executablePath: application.executablePath,
            selectorResolutionProofs: application.selectorResolutionProofs)
        let window = WindowIdentity(windowID: identity.windowID, title: "Fixture", bounds: bounds, index: 0)
        let serviceWindow = ServiceWindowInfo(
            windowID: identity.windowID,
            title: window.title,
            bounds: bounds,
            index: window.index,
            mutationIdentity: identity)
        let selectorProofs = (application.selectorResolutionProofs ?? []).map {
            $0.selecting(windowIdentity: identity)
        } + [Self.windowSelectorProof(
            selection: .automatic,
            processIdentity: identity.processIdentity,
            window: serviceWindow)]
        let observationRequest = DesktopObservationRequest(
            target: .app(identifier: "openclaw-desktop", window: .automatic),
            detection: .init(mode: .none))
        let request = PeekabooBridgeRequest.desktopObservation(observationRequest)
        let observationResult = DesktopObservationResult(
            target: .init(
                kind: .appWindow,
                app: app,
                window: window,
                bounds: bounds,
                detectionContext: .init(
                    applicationName: application.name,
                    applicationBundleId: application.bundleIdentifier,
                    applicationProcessId: application.processIdentifier,
                    windowTitle: window.title,
                    windowID: window.windowID,
                    windowBounds: window.bounds,
                    windowMutationIdentity: identity),
                selectorResolutionProofs: selectorProofs),
            capture: .init(
                imageData: Data(),
                metadata: .init(
                    size: bounds.size,
                    mode: .window,
                    applicationInfo: application,
                    windowInfo: serviceWindow,
                    diagnostics: .init(
                        requestedScale: observationRequest.capture.scale,
                        nativeScale: 1,
                        outputScale: 1,
                        scaleSource: "test",
                        finalPixelSize: bounds.size,
                        engine: "ScreenCaptureKit"))),
            elements: nil)
            .withCaptureContentDigest(rawScreenshotData: nil, annotatedScreenshotData: nil)
        let response = PeekabooBridgeResponse.desktopObservation(observationResult)
        let signed = try await Self.makeBundle(
            request: request,
            response: response,
            target: .window(identity))
        try signed.bundle.validateIntegrity()
    }

    @Test
    // swiftlint:disable:next function_body_length
    func `Signed menu bar popover observations bind background setup target and leaf`() async throws {
        let statusBounds = CGRect(x: 1500, y: 0, width: 24, height: 24)
        let popoverBounds = CGRect(x: 1180, y: 24, width: 360, height: 300)
        let statusIdentity = WindowMutationIdentity(
            windowID: 700,
            ownerProcessIdentifier: 321,
            ownerProcessStartIdentity: 654,
            capturedBounds: statusBounds)
        let mutationTarget = try DesktopTargetIdentity(exactWindow: .init(
            identity: statusIdentity,
            bounds: statusBounds))
        let rawRequest = PeekabooBridgeRequest.desktopObservation(.init(
            target: .menubarPopover(
                hints: ["Control Center", "Wi-Fi"],
                openIfNeeded: .init(clickHint: "Control Center", settleDelayNanoseconds: 0)),
            capture: .init(focus: .background),
            detection: .init(mode: .none)))
        let request = PeekabooBridgeRequest.projectedAction(.init(request: rawRequest))
        let result = DesktopObservationResult(
            target: .init(
                kind: .menubarPopover,
                bounds: popoverBounds,
                mutationTargetIdentity: .init(mutationTarget)),
            capture: .init(
                imageData: Data([1, 2, 3]),
                metadata: .init(
                    size: popoverBounds.size,
                    mode: .area,
                    displayInfo: .init(
                        index: 0,
                        name: "Main",
                        bounds: popoverBounds,
                        scaleFactor: 1),
                    diagnostics: Self.captureDiagnostics(size: popoverBounds.size))),
            elements: nil,
            diagnostics: .init(target: .init(
                requestedKind: "menubar-popover",
                resolvedKind: "menubar-popover",
                source: "click-location-area-fallback",
                hints: ["Control Center", "Wi-Fi"],
                openIfNeeded: true,
                clickHint: "Control Center",
                bounds: popoverBounds)))
            .withCaptureContentDigest(rawScreenshotData: nil, annotatedScreenshotData: nil)
        let targetReceipt = DesktopActionTargetReceipt(
            processIdentifier: statusIdentity.ownerProcessIdentifier,
            processStartIdentity: statusIdentity.ownerProcessStartIdentity,
            windowID: statusIdentity.windowID)
        let selectedLeaf = try DesktopSelectedLeafEvidence(
            kind: .menuBarItem,
            normalizedSelector: "control center",
            matchKind: .exact,
            selectedTargetReceipt: targetReceipt,
            selectedIndex: 0,
            selectedTitle: "Control Center",
            selectedIdentifier: "fixture.control-center",
            selectedRole: "AXStatusItem",
            selectedFrame: statusBounds,
            candidateSetSHA256: String(repeating: "a", count: 64),
            candidateCount: 1)
        let three = try #require(DesktopActionOutcome.DispatchUnitCount(3))
        let setupOutcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: three)
        let response = PeekabooBridgeResponse.projectedAction(.init(
            response: .desktopObservation(result),
            outcome: setupOutcome.projection))
        let valid = try await Self.makeBundle(
            request: request,
            response: response,
            target: .window(statusIdentity),
            outcome: setupOutcome.projection,
            selectedLeafEvidence: [selectedLeaf])
        try PeekabooBridgeOperationReceiptSemantics.validateReceiptCarriage(
            valid.bundle.receipt.payload,
            request: request,
            response: response)
        try valid.bundle.validateIntegrity()

        let popoverIdentity = WindowMutationIdentity(
            windowID: 701,
            ownerProcessIdentifier: 500,
            ownerProcessStartIdentity: 900,
            capturedBounds: popoverBounds)
        let popoverApplication = ServiceApplicationInfo(
            processIdentifier: popoverIdentity.ownerProcessIdentifier,
            processStartIdentity: popoverIdentity.ownerProcessStartIdentity,
            bundleIdentifier: "com.apple.controlcenter",
            name: "Control Center")
        let popoverAppIdentity = ApplicationIdentity(
            processIdentifier: popoverApplication.processIdentifier,
            processStartIdentity: popoverApplication.processStartIdentity,
            bundleIdentifier: popoverApplication.bundleIdentifier,
            name: popoverApplication.name)
        let popoverWindowIdentity = WindowIdentity(
            windowID: popoverIdentity.windowID,
            title: "Control Center",
            bounds: popoverBounds,
            index: 0)
        let popoverWindow = ServiceWindowInfo(
            windowID: popoverIdentity.windowID,
            title: popoverWindowIdentity.title,
            bounds: popoverBounds,
            index: popoverWindowIdentity.index,
            mutationIdentity: popoverIdentity)
        let alreadyOpenResult = DesktopObservationResult(
            target: .init(
                kind: .menubarPopover,
                app: popoverAppIdentity,
                window: popoverWindowIdentity,
                bounds: popoverBounds,
                detectionContext: .init(
                    applicationName: popoverApplication.name,
                    applicationBundleId: popoverApplication.bundleIdentifier,
                    applicationProcessId: popoverApplication.processIdentifier,
                    windowTitle: popoverWindowIdentity.title,
                    windowID: popoverWindowIdentity.windowID,
                    windowBounds: popoverBounds,
                    windowMutationIdentity: popoverIdentity)),
            capture: .init(
                imageData: Data([4, 5, 6]),
                metadata: .init(
                    size: popoverBounds.size,
                    mode: .window,
                    applicationInfo: popoverApplication,
                    windowInfo: popoverWindow,
                    displayInfo: .init(
                        index: 0,
                        name: "Main",
                        bounds: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                        scaleFactor: 2),
                    diagnostics: Self.captureDiagnostics(size: popoverBounds.size))),
            elements: nil,
            diagnostics: .init(target: .init(
                requestedKind: "menubar-popover",
                resolvedKind: "menubar-popover",
                source: "window-catalog",
                hints: ["Control Center", "Wi-Fi"],
                openIfNeeded: true,
                clickHint: "Control Center",
                windowID: popoverIdentity.windowID,
                bounds: popoverBounds)))
            .withCaptureContentDigest(rawScreenshotData: nil, annotatedScreenshotData: nil)
        let noOpOutcome = DesktopActionOutcome.confirmedNoChange(route: .bridge)
        let alreadyOpenResponse = PeekabooBridgeResponse.projectedAction(.init(
            response: .desktopObservation(alreadyOpenResult),
            outcome: noOpOutcome.projection))
        let alreadyOpen = try await Self.makeBundle(
            request: request,
            response: alreadyOpenResponse,
            target: .window(popoverIdentity),
            outcome: noOpOutcome.projection)
        try alreadyOpen.bundle.validateIntegrity()

        let foregroundRequestDetails = DesktopObservationRequest(
            target: .menubarPopover(
                hints: ["Control Center", "Wi-Fi"],
                openIfNeeded: .init(clickHint: "Control Center", settleDelayNanoseconds: 0)),
            capture: .init(focus: .foreground),
            detection: .init(mode: .none))
        let foregroundRequest = PeekabooBridgeRequest.projectedAction(.init(
            request: .desktopObservation(foregroundRequestDetails)))
        let foregroundPipeline = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .capturePipeline, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let foregroundResponse = PeekabooBridgeResponse.projectedAction(.init(
            response: .desktopObservation(alreadyOpenResult),
            outcome: foregroundPipeline.projection))
        let foreground = try await Self.makeBundle(
            request: foregroundRequest,
            response: foregroundResponse,
            target: .window(popoverIdentity),
            outcome: foregroundPipeline.projection)
        try foreground.bundle.validateIntegrity()

        let forgedForegroundNoOpResponse = PeekabooBridgeResponse.projectedAction(.init(
            response: .desktopObservation(alreadyOpenResult),
            outcome: noOpOutcome.projection))
        let forgedForegroundNoOp = try await Self.makeBundle(
            request: foregroundRequest,
            response: forgedForegroundNoOpResponse,
            target: .window(popoverIdentity),
            outcome: noOpOutcome.projection)
        #expect(throws: PeekabooBridgeOperationReceiptError.receiptMismatch(
            "menu-bar observation conditional pipeline outcome"))
        {
            try forgedForegroundNoOp.bundle.validateIntegrity()
        }

        let webDetection = DesktopDetectionOptions(
            mode: .accessibility,
            allowWebFocusFallback: true)
        let webContext = WindowContext(
            applicationName: popoverApplication.name,
            applicationBundleId: popoverApplication.bundleIdentifier,
            applicationProcessId: popoverApplication.processIdentifier,
            windowTitle: popoverWindowIdentity.title,
            windowID: popoverWindowIdentity.windowID,
            windowBounds: popoverBounds,
            windowMutationIdentity: popoverIdentity,
            shouldFocusWebContent: true,
            includeMenuBarElements: webDetection.includeMenuBarElements,
            traversalBudget: webDetection.traversalBudget)
        let webResult = DesktopObservationResult(
            target: .init(
                kind: .menubarPopover,
                app: popoverAppIdentity,
                window: popoverWindowIdentity,
                bounds: popoverBounds,
                detectionContext: webContext),
            capture: alreadyOpenResult.capture,
            elements: .init(
                snapshotId: "web-focus",
                screenshotPath: "",
                elements: .init(),
                metadata: .init(
                    detectionTime: 0,
                    elementCount: 0,
                    method: "fixture",
                    windowContext: webContext)),
            diagnostics: alreadyOpenResult.diagnostics)
            .withCaptureContentDigest(rawScreenshotData: nil, annotatedScreenshotData: nil)
        let webRequestDetails = DesktopObservationRequest(
            target: .menubarPopover(
                hints: ["Control Center", "Wi-Fi"],
                openIfNeeded: .init(clickHint: "Control Center", settleDelayNanoseconds: 0)),
            capture: .init(focus: .background),
            detection: webDetection)
        let webRequest = PeekabooBridgeRequest.projectedAction(.init(
            request: .desktopObservation(webRequestDetails)))
        let webPipeline = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .capturePipeline, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let webResponse = PeekabooBridgeResponse.projectedAction(.init(
            response: .desktopObservation(webResult),
            outcome: webPipeline.projection))
        let web = try await Self.makeBundle(
            request: webRequest,
            response: webResponse,
            target: .window(popoverIdentity),
            outcome: webPipeline.projection)
        try web.bundle.validateIntegrity()

        let combinedRequestDetails = DesktopObservationRequest(
            target: webRequestDetails.target,
            capture: .init(focus: .foreground),
            detection: webDetection)
        let combinedRequest = PeekabooBridgeRequest.projectedAction(.init(
            request: .desktopObservation(combinedRequestDetails)))
        let two = try #require(DesktopActionOutcome.DispatchUnitCount(2))
        let combinedPipeline = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .capturePipeline, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: two)
        let combinedResponse = PeekabooBridgeResponse.projectedAction(.init(
            response: .desktopObservation(webResult),
            outcome: combinedPipeline.projection))
        let combined = try await Self.makeBundle(
            request: combinedRequest,
            response: combinedResponse,
            target: .window(popoverIdentity),
            outcome: combinedPipeline.projection)
        try combined.bundle.validateIntegrity()

        let clickedNoOpResponse = PeekabooBridgeResponse.projectedAction(.init(
            response: .desktopObservation(result),
            outcome: noOpOutcome.projection))
        let clickedNoOp = try await Self.makeBundle(
            request: request,
            response: clickedNoOpResponse,
            target: .window(statusIdentity),
            outcome: noOpOutcome.projection)
        #expect(throws: PeekabooBridgeOperationReceiptError.receiptMismatch(
            "menu-bar observation setup outcome"))
        {
            try clickedNoOp.bundle.validateIntegrity()
        }

        let noOpWithSetupLeaf = try await Self.makeBundle(
            request: request,
            response: alreadyOpenResponse,
            target: .window(popoverIdentity),
            outcome: noOpOutcome.projection,
            selectedLeafEvidence: [selectedLeaf])
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try noOpWithSetupLeaf.bundle.validateIntegrity()
        }

        let laterFailure = DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: setupOutcome.delivery,
            evidence: .completionUnknown,
            unitCount: three,
            message: "Capture failed after the menu-bar click")
            .attributed(to: targetReceipt)
            .selectingLeaves([selectedLeaf])
        let failureResponse = PeekabooBridgeResponse.projectedAction(.init(
            response: .error(.init(code: .internalError, actionFailure: laterFailure)),
            outcome: laterFailure.outcome.projection))
        let preservedFailure = try await Self.makeBundle(
            request: request,
            response: failureResponse,
            target: .window(statusIdentity),
            outcome: laterFailure.outcome.projection,
            selectedLeafEvidence: [selectedLeaf])
        try preservedFailure.bundle.validateIntegrity()

        let four = try #require(DesktopActionOutcome.DispatchUnitCount(4))
        let incompatibleTargetFailure = DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .composite, mode: .foreground),
            evidence: .completionUnknown,
            unitCount: four,
            message: "Menu setup and foreground capture completed on incompatible exact targets")
        let targetFailure = PeekabooBridgeTargetAttributionFailure(
            .incompleteExactWindow,
            stage: .postExecution)
        let incompatibleResponse = PeekabooBridgeResponse.projectedAction(.init(
            response: .error(.init(
                code: .internalError,
                actionFailure: incompatibleTargetFailure,
                context: "bridge_target_attribution:\(targetFailure.code.rawValue)")),
            outcome: incompatibleTargetFailure.outcome.projection))
        let incompatible = try await Self.makeBundle(
            request: foregroundRequest,
            response: incompatibleResponse,
            target: nil,
            outcome: incompatibleTargetFailure.outcome.projection,
            targetAttributionFailure: targetFailure,
            targetAttributionEvidence: [])
        try incompatible.bundle.validateIntegrity()

        let compositeSuccess = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .composite, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: four)
        let compositeSuccessResponse = PeekabooBridgeResponse.projectedAction(.init(
            response: .desktopObservation(alreadyOpenResult),
            outcome: compositeSuccess.projection))
        let forgedCompositeSuccess = try await Self.makeBundle(
            request: foregroundRequest,
            response: compositeSuccessResponse,
            target: .window(popoverIdentity),
            outcome: compositeSuccess.projection)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try forgedCompositeSuccess.bundle.validateIntegrity()
        }

        let wrongDelivery = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .capturePipeline, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: three)
        let wrongDeliveryResponse = PeekabooBridgeResponse.projectedAction(.init(
            response: .desktopObservation(result),
            outcome: wrongDelivery.projection))
        let wrongDeliveryBundle = try await Self.makeBundle(
            request: request,
            response: wrongDeliveryResponse,
            target: .window(statusIdentity),
            outcome: wrongDelivery.projection,
            selectedLeafEvidence: [selectedLeaf])
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try wrongDeliveryBundle.bundle.validateIntegrity()
        }

        let missingLeaf = try await Self.makeBundle(
            request: request,
            response: response,
            target: .window(statusIdentity),
            outcome: setupOutcome.projection)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try missingLeaf.bundle.validateIntegrity()
        }

        let setupWithoutMutationTargetResponse = PeekabooBridgeResponse.projectedAction(.init(
            response: .desktopObservation(alreadyOpenResult),
            outcome: setupOutcome.projection))
        let setupWithoutMutationTarget = try await Self.makeBundle(
            request: request,
            response: setupWithoutMutationTargetResponse,
            target: .window(popoverIdentity),
            outcome: setupOutcome.projection,
            selectedLeafEvidence: [selectedLeaf])
        #expect(throws: PeekabooBridgeOperationReceiptError.receiptMismatch(
            "menu-bar observation conditional pipeline outcome"))
        {
            try setupWithoutMutationTarget.bundle.validateIntegrity()
        }
    }

    @Test
    func `Normal mutating observations retain capture-pipeline semantics`() async throws {
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let rawRequest = PeekabooBridgeRequest.desktopObservation(.init(
            target: .screen(index: 0),
            capture: .init(focus: .foreground),
            detection: .init(mode: .none)))
        let request = PeekabooBridgeRequest.projectedAction(.init(request: rawRequest))
        let result = DesktopObservationResult(
            target: .init(kind: .screen(index: 0)),
            capture: .init(
                imageData: Data([1, 2, 3]),
                metadata: .init(
                    size: bounds.size,
                    mode: .screen,
                    displayInfo: .init(index: 0, name: "Main", bounds: bounds, scaleFactor: 1),
                    diagnostics: Self.captureDiagnostics(size: bounds.size))),
            elements: nil,
            diagnostics: .init(target: .init(
                requestedKind: "screen",
                resolvedKind: "screen",
                source: "screen")))
            .withCaptureContentDigest(rawScreenshotData: nil, annotatedScreenshotData: nil)
        let captureOutcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .capturePipeline, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let response = PeekabooBridgeResponse.projectedAction(.init(
            response: .desktopObservation(result),
            outcome: captureOutcome.projection))
        let valid = try await Self.makeBundle(
            request: request,
            response: response,
            outcome: captureOutcome.projection)
        try valid.bundle.validateIntegrity()

        let wrongOutcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let wrongResponse = PeekabooBridgeResponse.projectedAction(.init(
            response: .desktopObservation(result),
            outcome: wrongOutcome.projection))
        let wrong = try await Self.makeBundle(
            request: request,
            response: wrongResponse,
            outcome: wrongOutcome.projection)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try wrong.bundle.validateIntegrity()
        }
    }

    @Test
    func `Signed screen and area captures bind display index and bounds`() async throws {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let screenRequest = PeekabooBridgeRequest.captureScreen(.init(
            displayIndex: 1,
            visualizerMode: .none,
            scale: .logical1x))
        let areaRequest = PeekabooBridgeRequest.captureArea(.init(
            rect: bounds,
            visualizerMode: .none,
            scale: .logical1x))
        #expect(PeekabooBridgeOperationResultSemantics.contract(for: screenRequest).targetPolicy == .notApplicable)
        #expect(PeekabooBridgeOperationResultSemantics.contract(for: areaRequest).targetPolicy == .notApplicable)
        let screenResponse = PeekabooBridgeResponse.capture(.init(
            imageData: Data(),
            metadata: .init(
                size: bounds.size,
                mode: .screen,
                displayInfo: .init(index: 1, name: "Fixture", bounds: bounds, scaleFactor: 1),
                diagnostics: Self.captureDiagnostics(size: bounds.size))))
        let areaResponse = PeekabooBridgeResponse.capture(.init(
            imageData: Data(),
            metadata: .init(
                size: bounds.size,
                mode: .area,
                displayInfo: .init(index: 1, name: "Fixture", bounds: bounds, scaleFactor: 1),
                diagnostics: Self.captureDiagnostics(size: bounds.size))))
        for (request, response) in [(screenRequest, screenResponse), (areaRequest, areaResponse)] {
            let signed = try await Self.makeBundle(request: request, response: response)
            try signed.bundle.validateIntegrity()
        }

        let wrongScreenIndex = try await Self.makeBundle(
            request: screenRequest,
            response: .capture(.init(
                imageData: Data(),
                metadata: .init(
                    size: bounds.size,
                    mode: .screen,
                    displayInfo: .init(index: 0, name: "Other", bounds: bounds, scaleFactor: 1),
                    diagnostics: Self.captureDiagnostics(size: bounds.size)))))
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try wrongScreenIndex.bundle.validateIntegrity()
        }

        let wrongArea = try await Self.makeBundle(
            request: areaRequest,
            response: .capture(.init(
                imageData: Data(),
                metadata: .init(
                    size: bounds.size,
                    mode: .area,
                    displayInfo: .init(
                        index: 1,
                        name: "Fixture",
                        bounds: bounds.offsetBy(dx: 1, dy: 0),
                        scaleFactor: 1),
                    diagnostics: Self.captureDiagnostics(size: bounds.size)))))
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try wrongArea.bundle.validateIntegrity()
        }
    }
}

extension PeekabooBridgeOperationSemanticPlanTests {
    @Test
    func `Unique exact fallback synthesizes one signed Bridge mutation`() async throws {
        let rawRequest = PeekabooBridgeRequest.moveMouse(.init(
            to: CGPoint(x: 10, y: 20),
            duration: 0,
            steps: 1,
            profile: .linear))
        let handled = try PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
            try PeekabooBridgeOperationResultSemantics.finalizeSuccessful(
                request: rawRequest,
                handled: .init(response: .ok))
        }
        let outcome = try #require(handled.outcome)
        #expect(outcome.route == .bridge)
        #expect(outcome.delivery == .init(mechanism: .globalEvents, mode: .foreground))
        #expect(outcome.dispatchState.unitCount == .one)

        let request = PeekabooBridgeRequest.projectedAction(.init(request: rawRequest))
        let response = PeekabooBridgeResponse.projectedAction(.init(
            response: .ok,
            outcome: outcome.projection))
        let signed = try await Self.makeBundle(
            request: request,
            response: response,
            target: .global,
            outcome: outcome.projection)
        try signed.bundle.validateIntegrity()
    }

    @Test
    func `Signed permission request accepts its Boolean response`() async throws {
        let rawRequest = PeekabooBridgeRequest.requestPostEventPermission
        let request = PeekabooBridgeRequest.projectedAction(.init(request: rawRequest))
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let response = PeekabooBridgeResponse.projectedAction(.init(
            response: .bool(true),
            outcome: outcome.projection))
        let signed = try await Self.makeBundle(
            request: request,
            response: response,
            outcome: outcome.projection)
        try signed.bundle.validateIntegrity()
    }

    @Test
    func `Read-only error cannot claim a desktop mutation outcome`() async throws {
        let actionFailure = DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one,
            message: "forged read-only mutation")
        let response = PeekabooBridgeResponse.error(.init(
            code: .internalError,
            actionFailure: actionFailure))
        let signed = try await Self.makeBundle(
            request: .permissionsStatus,
            response: response,
            outcome: actionFailure.outcome.projection)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try signed.bundle.validateIntegrity()
        }
    }

    @Test
    func `Projected browser attribution error does not require a tool progress response`() async throws {
        let request = PeekabooBridgeRequest.projectedAction(.init(request: .browserExecute(.init(
            toolName: "click",
            arguments: [:],
            channel: "stable"))))
        let failure = PeekabooBridgeTargetAttributionFailure(
            .incompleteExactWindow,
            stage: .postExecution)
        let actionFailure = DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one,
            message: "Browser completion target is unknown")
        let envelope = PeekabooBridgeErrorEnvelope(
            code: .internalError,
            actionFailure: actionFailure,
            context: "bridge_target_attribution:\(failure.code.rawValue)")
        let response = PeekabooBridgeResponse.projectedAction(.init(
            response: .error(envelope),
            outcome: actionFailure.outcome.projection))
        let signed = try await Self.makeBundle(
            request: request,
            response: response,
            target: nil,
            outcome: actionFailure.outcome.projection,
            targetAttributionFailure: failure,
            targetAttributionEvidence: [])
        try signed.bundle.validateIntegrity()
    }

    @Test
    func `Focused response cannot drift from its generation-pinned request`() async throws {
        let generation = try #require(SystemIdentityResolver.processStartIdentity(getpid()))
        let identity = ApplicationProcessIdentity(
            processIdentifier: getpid(),
            processStartIdentity: generation)
        let request = PeekabooBridgeRequest.getFocusedElement(.init(
            targetProcessIdentifier: identity.processIdentifier,
            expectedProcessIdentity: identity))
        let response = PeekabooBridgeResponse.focusedElement(.init(
            role: "AXTextField",
            title: nil,
            value: nil,
            frame: CGRect(x: 10, y: 20, width: 100, height: 30),
            applicationName: "Other",
            bundleIdentifier: "dev.peekaboo.other",
            processId: Int(identity.processIdentifier + 1),
            windowID: 71))
        let signed = try await Self.makeBundle(
            request: request,
            response: response,
            target: .process(identity))
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try signed.bundle.validateIntegrity()
        }
    }

    @Test
    func `Post-mutation window response cannot name another stable window`() async throws {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let expected = WindowMutationIdentity(
            windowID: 71,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 1001,
            capturedBounds: bounds)
        let other = WindowMutationIdentity(
            windowID: 72,
            ownerProcessIdentifier: 43,
            ownerProcessStartIdentity: 2002,
            capturedBounds: bounds)
        let rawRequest = PeekabooBridgeRequest.moveWindow(.init(
            target: .windowId(expected.windowID),
            expectedIdentity: expected,
            position: CGPoint(x: 50, y: 60)))
        let request = PeekabooBridgeRequest.projectedAction(.init(request: rawRequest))
        let outcome = DesktopActionOutcome.confirmedChange(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            unitCount: .one)
        let movedBounds = CGRect(x: 50, y: 60, width: 300, height: 200)
        let movedIdentity = WindowMutationIdentity(
            windowID: expected.windowID,
            ownerProcessIdentifier: expected.ownerProcessIdentifier,
            ownerProcessStartIdentity: expected.ownerProcessStartIdentity,
            capturedBounds: movedBounds)
        let validResponse = PeekabooBridgeResponse.projectedAction(.init(
            response: .window(.init(
                windowID: expected.windowID,
                title: "Moved",
                bounds: movedBounds,
                mutationIdentity: movedIdentity)),
            outcome: outcome.projection))
        let valid = try await Self.makeBundle(
            request: request,
            response: validResponse,
            target: .window(expected),
            outcome: outcome.projection)
        try valid.bundle.validateIntegrity()

        let contradictoryBoundsResponse = PeekabooBridgeResponse.projectedAction(.init(
            response: .window(.init(
                windowID: expected.windowID,
                title: "Contradictory",
                bounds: CGRect(x: 70, y: 80, width: 300, height: 200),
                mutationIdentity: movedIdentity)),
            outcome: outcome.projection))
        let contradictoryBounds = try await Self.makeBundle(
            request: request,
            response: contradictoryBoundsResponse,
            target: .window(expected),
            outcome: outcome.projection)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try contradictoryBounds.bundle.validateIntegrity()
        }

        let response = PeekabooBridgeResponse.projectedAction(.init(
            response: .window(.init(
                windowID: other.windowID,
                title: "Other",
                bounds: bounds,
                mutationIdentity: other)),
            outcome: outcome.projection))
        let signed = try await Self.makeBundle(
            request: request,
            response: response,
            target: .window(expected),
            outcome: outcome.projection)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try signed.bundle.validateIntegrity()
        }
    }

    @Test
    // swiftlint:disable:next function_body_length
    func `Signed confirmed window responses prove their requested postcondition`() async throws {
        let originalBounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let expected = WindowMutationIdentity(
            windowID: 71,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 1001,
            capturedBounds: originalBounds)
        let valueDelivery = DesktopActionOutcome.Delivery(
            mechanism: .accessibilityValue,
            mode: .background)

        func window(
            bounds: CGRect,
            isMinimized: Bool = false,
            isKeyWindow: Bool? = nil,
            mutationPostconditionEvidence: WindowMutationPostconditionEvidence? = nil) -> ServiceWindowInfo
        {
            ServiceWindowInfo(
                windowID: expected.windowID,
                title: "Fixture",
                bounds: bounds,
                isMinimized: isMinimized,
                isKeyWindow: isKeyWindow,
                mutationIdentity: WindowMutationIdentity(
                    windowID: expected.windowID,
                    ownerProcessIdentifier: expected.ownerProcessIdentifier,
                    ownerProcessStartIdentity: expected.ownerProcessStartIdentity,
                    capturedBounds: bounds,
                    isMinimized: isMinimized),
                mutationPostconditionEvidence: mutationPostconditionEvidence)
        }

        func verify(
            rawRequest: PeekabooBridgeRequest,
            correct: ServiceWindowInfo?,
            forged: ServiceWindowInfo?,
            additionalForgeries: [ServiceWindowInfo?] = [],
            delivery: DesktopActionOutcome.Delivery) async throws
        {
            let requestIdentity = try #require(rawRequest.pinnedWindowMutation?.identity)
            let request = PeekabooBridgeRequest.projectedAction(.init(request: rawRequest))
            let confirmedOutcomes: [DesktopActionOutcome] = [
                .confirmedChange(route: .bridge, delivery: delivery, unitCount: .one),
                .confirmedNoChange(route: .bridge),
            ]
            for outcome in confirmedOutcomes {
                let validResponse = PeekabooBridgeResponse.projectedAction(.init(
                    response: .window(correct),
                    outcome: outcome.projection))
                let valid = try await Self.makeBundle(
                    request: request,
                    response: validResponse,
                    target: .window(requestIdentity),
                    outcome: outcome.projection)
                try valid.bundle.validateIntegrity()

                for forgedResponseWindow in [forged] + additionalForgeries {
                    let forgedResponse = PeekabooBridgeResponse.projectedAction(.init(
                        response: .window(forgedResponseWindow),
                        outcome: outcome.projection))
                    let forgedBundle = try await Self.makeBundle(
                        request: request,
                        response: forgedResponse,
                        target: .window(requestIdentity),
                        outcome: outcome.projection)
                    #expect(throws: PeekabooBridgeOperationReceiptError.self) {
                        try forgedBundle.bundle.validateIntegrity()
                    }
                }

                let unprovenResponse = PeekabooBridgeResponse.projectedAction(.init(
                    response: .ok,
                    outcome: outcome.projection))
                let unproven = try await Self.makeBundle(
                    request: request,
                    response: unprovenResponse,
                    target: .window(requestIdentity),
                    outcome: outcome.projection)
                #expect(throws: PeekabooBridgeOperationReceiptError.self) {
                    try unproven.bundle.validateIntegrity()
                }
            }

            let dispatched = DesktopActionOutcome.dispatchedUnverified(
                route: .bridge,
                delivery: delivery,
                evidence: .deliveryAccepted,
                unitCount: .one)
            let unverifiedResponse = PeekabooBridgeResponse.projectedAction(.init(
                response: .window(forged),
                outcome: dispatched.projection))
            let unverified = try await Self.makeBundle(
                request: request,
                response: unverifiedResponse,
                target: .window(requestIdentity),
                outcome: dispatched.projection)
            try unverified.bundle.validateIntegrity()
            for substitutedWindow in additionalForgeries {
                let substitutedResponse = PeekabooBridgeResponse.projectedAction(.init(
                    response: .window(substitutedWindow),
                    outcome: dispatched.projection))
                let substituted = try await Self.makeBundle(
                    request: request,
                    response: substitutedResponse,
                    target: .window(requestIdentity),
                    outcome: dispatched.projection)
                #expect(throws: PeekabooBridgeOperationReceiptError.self) {
                    try substituted.bundle.validateIntegrity()
                }
            }

            let unverifiedOKResponse = PeekabooBridgeResponse.projectedAction(.init(
                response: .ok,
                outcome: dispatched.projection))
            let unverifiedOK = try await Self.makeBundle(
                request: request,
                response: unverifiedOKResponse,
                target: .window(requestIdentity),
                outcome: dispatched.projection)
            try unverifiedOK.bundle.validateIntegrity()
        }

        let movedBounds = CGRect(origin: CGPoint(x: 50, y: 60), size: originalBounds.size)
        let providerConfirmedMovedBounds = CGRect(
            origin: CGPoint(x: movedBounds.minX + 0.5, y: movedBounds.minY - 0.5),
            size: movedBounds.size)
        try await verify(
            rawRequest: .moveWindow(.init(
                target: .windowId(expected.windowID),
                expectedIdentity: expected,
                position: movedBounds.origin)),
            correct: window(bounds: providerConfirmedMovedBounds),
            forged: window(bounds: originalBounds),
            delivery: valueDelivery)

        let resizedBounds = CGRect(origin: originalBounds.origin, size: CGSize(width: 450, height: 275))
        let providerConfirmedResizedBounds = CGRect(
            origin: resizedBounds.origin,
            size: CGSize(width: resizedBounds.width - 0.5, height: resizedBounds.height + 0.5))
        try await verify(
            rawRequest: .resizeWindow(.init(
                target: .windowId(expected.windowID),
                expectedIdentity: expected,
                size: resizedBounds.size)),
            correct: window(bounds: providerConfirmedResizedBounds),
            forged: window(bounds: originalBounds),
            delivery: valueDelivery)

        let requestedBounds = CGRect(x: 90, y: 100, width: 500, height: 350)
        let providerConfirmedBounds = CGRect(
            x: requestedBounds.minX + 0.5,
            y: requestedBounds.minY - 0.5,
            width: requestedBounds.width - 0.5,
            height: requestedBounds.height + 0.5)
        try await verify(
            rawRequest: .setWindowBounds(.init(
                target: .windowId(expected.windowID),
                expectedIdentity: expected,
                bounds: requestedBounds)),
            correct: window(bounds: providerConfirmedBounds),
            forged: window(bounds: originalBounds),
            delivery: valueDelivery)

        let substitutedBounds = CGRect(x: 35, y: 45, width: 360, height: 240)
        try await verify(
            rawRequest: .minimizeWindow(.init(
                target: .windowId(expected.windowID),
                expectedIdentity: expected)),
            correct: window(bounds: originalBounds, isMinimized: true),
            forged: window(bounds: originalBounds),
            additionalForgeries: [window(bounds: substitutedBounds, isMinimized: true)],
            delivery: valueDelivery)

        let minimizedExpected = expected.withMinimizedState(true)
        try await verify(
            rawRequest: .restoreWindow(.init(
                target: .windowId(expected.windowID),
                expectedIdentity: minimizedExpected)),
            correct: window(bounds: originalBounds),
            forged: window(bounds: originalBounds, isMinimized: true),
            additionalForgeries: [window(bounds: substitutedBounds)],
            delivery: valueDelivery)

        try await verify(
            rawRequest: .focusWindow(.init(
                target: .windowId(expected.windowID),
                expectedIdentity: expected)),
            correct: window(bounds: originalBounds, isKeyWindow: true),
            forged: window(bounds: originalBounds, isKeyWindow: false),
            additionalForgeries: [window(bounds: substitutedBounds, isKeyWindow: true)],
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground))

        try await verify(
            rawRequest: .closeWindow(.init(
                target: .windowId(expected.windowID),
                expectedIdentity: expected)),
            correct: nil,
            forged: window(bounds: originalBounds),
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground))

        try await verify(
            rawRequest: .backgroundCloseWindow(.init(
                target: .windowId(expected.windowID),
                expectedIdentity: expected)),
            correct: nil,
            forged: window(bounds: originalBounds),
            delivery: .init(mechanism: .accessibilityAction, mode: .background))

        let maximizeRequest = PeekabooBridgeRequest.projectedAction(.init(request: .maximizeWindow(.init(
            target: .windowId(expected.windowID),
            expectedIdentity: expected))))
        let maximizeOutcomes: [DesktopActionOutcome] = [
            .confirmedChange(
                route: .bridge,
                delivery: valueDelivery,
                unitCount: .one),
            .confirmedNoChange(route: .bridge),
        ]
        let visibleWorkArea = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let providerConfirmedMaximizedBounds = CGRect(x: 0.5, y: -0.5, width: 1439.5, height: 900.5)
        for maximizeOutcome in maximizeOutcomes {
            let provenMaximizeResponse = PeekabooBridgeResponse.projectedAction(.init(
                response: .window(window(
                    bounds: providerConfirmedMaximizedBounds,
                    mutationPostconditionEvidence: .init(
                        isMaximized: true,
                        verifiedVisibleWorkArea: visibleWorkArea))),
                outcome: maximizeOutcome.projection))
            let provenMaximize = try await Self.makeBundle(
                request: maximizeRequest,
                response: provenMaximizeResponse,
                target: .window(expected),
                outcome: maximizeOutcome.projection)
            try provenMaximize.bundle.validateIntegrity()

            let forgedEvidence: [WindowMutationPostconditionEvidence?] = [
                nil,
                .init(isMaximized: false, verifiedVisibleWorkArea: visibleWorkArea),
                .init(
                    isMaximized: true,
                    verifiedVisibleWorkArea: CGRect(x: 0, y: 0, width: 1280, height: 720)),
            ]
            for evidence in forgedEvidence {
                let arbitraryMaximizeResponse = PeekabooBridgeResponse.projectedAction(.init(
                    response: .window(window(
                        bounds: providerConfirmedMaximizedBounds,
                        mutationPostconditionEvidence: evidence)),
                    outcome: maximizeOutcome.projection))
                let maximize = try await Self.makeBundle(
                    request: maximizeRequest,
                    response: arbitraryMaximizeResponse,
                    target: .window(expected),
                    outcome: maximizeOutcome.projection)
                #expect(throws: PeekabooBridgeOperationReceiptError.self) {
                    try maximize.bundle.validateIntegrity()
                }
            }
        }

        let maximizeOutcome = maximizeOutcomes[0]
        let unprovenMaximizeResponse = PeekabooBridgeResponse.projectedAction(.init(
            response: .ok,
            outcome: maximizeOutcome.projection))
        let unprovenMaximize = try await Self.makeBundle(
            request: maximizeRequest,
            response: unprovenMaximizeResponse,
            target: .window(expected),
            outcome: maximizeOutcome.projection)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try unprovenMaximize.bundle.validateIntegrity()
        }
    }

    @Test
    func `Signed browser connect binds its exact normalized loopback endpoint and channel`() async throws {
        let request = PeekabooBridgeRequest.projectedAction(.init(request: .browserConnect(.init(
            channel: "stable",
            browserURL: "HTTP://LOCALHOST:9222"))))
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let validReceipt = PeekabooBridgeBrowserConnectionReceipt(
            channel: "stable",
            browserURL: "http://localhost:9222/",
            webSocketDebuggerURL: "ws://localhost:9222/devtools/browser/browser-a",
            devToolsBrowserID: "browser-a",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")

        func signed(
            receipt: PeekabooBridgeBrowserConnectionReceipt,
            target: PeekabooBridgeOperationTargetReceipt) async throws
            -> PeekabooBridgeOperationReceiptBundle
        {
            let response = PeekabooBridgeResponse.projectedAction(.init(
                response: .browserStatus(.init(
                    isConnected: true,
                    toolCount: 1,
                    detectedBrowsers: [],
                    connectionReceipt: receipt)),
                outcome: outcome.projection))
            return try await Self.makeBundle(
                request: request,
                response: response,
                target: target,
                outcome: outcome.projection).bundle
        }

        try await signed(receipt: validReceipt, target: .browser(validReceipt)).validateIntegrity()

        let wrongPort = PeekabooBridgeBrowserConnectionReceipt(
            channel: "stable",
            browserURL: "http://localhost:9333/",
            webSocketDebuggerURL: "ws://localhost:9333/devtools/browser/browser-a",
            devToolsBrowserID: "browser-a",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
        let wrongChannel = PeekabooBridgeBrowserConnectionReceipt(
            channel: "canary",
            browserURL: "http://localhost:9222/",
            webSocketDebuggerURL: "ws://localhost:9222/devtools/browser/browser-a",
            devToolsBrowserID: "browser-a",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
        let inconsistentWebSocket = PeekabooBridgeBrowserConnectionReceipt(
            channel: "stable",
            browserURL: "http://localhost:9222/",
            webSocketDebuggerURL: "ws://localhost:9333/devtools/browser/browser-b",
            devToolsBrowserID: "browser-a",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
        let localProcess = PeekabooBridgeBrowserConnectionReceipt(
            channel: "stable",
            processIdentifier: 42,
            processStartIdentity: 10042,
            bundleIdentifier: "com.google.Chrome",
            browserVersion: "Chrome/151.0")
        let localIdentity = ApplicationProcessIdentity(
            processIdentifier: 42,
            processStartIdentity: 10042)

        for (receipt, target) in [
            (wrongPort, PeekabooBridgeOperationTargetReceipt.browser(wrongPort)),
            (wrongChannel, .browser(wrongChannel)),
            (inconsistentWebSocket, .global),
            (localProcess, .process(localIdentity)),
        ] {
            let forged = try await signed(receipt: receipt, target: target)
            #expect(throws: PeekabooBridgeOperationReceiptError.self) {
                try forged.validateIntegrity()
            }
        }
    }

    @Test
    func `external operation failure retains its exact action target`() async throws {
        let process = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 1001)
        let request = PeekabooBridgeRequest.projectedAction(.init(request: .clickMenuExtra(.init(name: "Clock"))))
        let targetReceipt = DesktopActionTargetReceipt(
            processIdentifier: process.processIdentifier,
            processStartIdentity: process.processStartIdentity)
        let selectedLeaf = try DesktopSelectedLeafEvidence(
            kind: .menuBarItem,
            normalizedSelector: "clock",
            matchKind: .exact,
            selectedTargetReceipt: targetReceipt,
            selectedIndex: 0,
            selectedTitle: "Clock",
            selectedIdentifier: "fixture.clock",
            selectedRole: "AXStatusItem",
            selectedFrame: CGRect(x: 10, y: 0, width: 20, height: 20),
            candidateSetSHA256: String(repeating: "a", count: 64),
            candidateCount: 1)
        let failure = DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            evidence: .completionUnknown,
            unitCount: .one,
            message: "The status item dispatch completed without a terminal response")
            .attributed(to: targetReceipt)
            .selectingLeaves([selectedLeaf])
        let response = PeekabooBridgeResponse.projectedAction(.init(
            response: .error(.init(code: .internalError, actionFailure: failure)),
            outcome: failure.outcome.projection))
        let handled = PeekabooBridgeHandledResponse(response: response)

        try PeekabooBridgeOperationResultSemantics.validateSuccessfulTargetDisposition(
            request: request,
            handled: handled)
        let signed = try await Self.makeBundle(
            request: request,
            response: response,
            target: .process(process),
            outcome: failure.outcome.projection,
            selectedLeafEvidence: [selectedLeaf])
        try signed.bundle.validateIntegrity()

        let missingTarget = PeekabooBridgeResponse.projectedAction(.init(
            response: .error(.init(code: .internalError, actionFailure: .indeterminate(
                route: .bridge,
                delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                evidence: .completionUnknown,
                unitCount: .one,
                message: "Missing external target"))),
            outcome: failure.outcome.projection))
        #expect(throws: DesktopTargetIdentityError.self) {
            try PeekabooBridgeOperationResultSemantics.validateSuccessfulTargetDisposition(
                request: request,
                handled: .init(response: missingTarget))
        }
    }

    @Test
    func `Response-resolved application target cannot self-fill a missing generation`() async throws {
        let oldIdentity = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 1001)
        let claimedNewIdentity = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 1002)
        let rawRequest = PeekabooBridgeRequest.relaunchApplicationWithOptions(.init(
            targetIdentifier: "PID:42",
            expectedTargetIdentity: oldIdentity,
            launchRequest: .init(applicationBundleIdentifier: "dev.peekaboo.fixture", activates: true)))
        let request = PeekabooBridgeRequest.projectedAction(.init(request: rawRequest))
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let response = PeekabooBridgeResponse.projectedAction(.init(
            response: .application(.init(
                processIdentifier: claimedNewIdentity.processIdentifier,
                bundleIdentifier: "dev.peekaboo.fixture",
                name: "Fixture")),
            outcome: outcome.projection))
        let signed = try await Self.makeBundle(
            request: request,
            response: response,
            target: .process(claimedNewIdentity),
            outcome: outcome.projection)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try signed.bundle.validateIntegrity()
        }

        let validResponse = PeekabooBridgeResponse.projectedAction(.init(
            response: .application(.init(
                processIdentifier: claimedNewIdentity.processIdentifier,
                processStartIdentity: claimedNewIdentity.processStartIdentity,
                bundleIdentifier: "dev.peekaboo.fixture",
                name: "Fixture")),
            outcome: outcome.projection))
        let valid = try await Self.makeBundle(
            request: request,
            response: validResponse,
            target: .process(claimedNewIdentity),
            outcome: outcome.projection)
        try valid.bundle.validateIntegrity()

        let substitutedResponse = PeekabooBridgeResponse.projectedAction(.init(
            response: .application(.init(
                processIdentifier: claimedNewIdentity.processIdentifier,
                processStartIdentity: claimedNewIdentity.processStartIdentity,
                bundleIdentifier: "dev.peekaboo.other",
                name: "Other")),
            outcome: outcome.projection))
        let substituted = try await Self.makeBundle(
            request: request,
            response: substitutedResponse,
            target: .process(claimedNewIdentity),
            outcome: outcome.projection)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try substituted.bundle.validateIntegrity()
        }
    }

    @Test
    func `Dialog response action and inner outcome must match the projected result`() async throws {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let identity = WindowMutationIdentity(
            windowID: 71,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 1001,
            capturedBounds: bounds)
        let selector = try DialogTargetSelector(processIdentifier: 42, windowID: 71)
        let rawRequest = try PeekabooBridgeRequest.exactDialogEnterText(.init(
            target: selector,
            text: "hello"))
        let request = PeekabooBridgeRequest.projectedAction(.init(request: rawRequest))
        let localOutcome = DesktopActionOutcome.confirmedChange(
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            unitCount: .one)
        let outerOutcome = localOutcome.routed(to: .bridge)
        let result = DialogActionResult(
            success: true,
            action: .dismiss,
            details: [:],
            outcome: localOutcome,
            targetReceipt: .init(
                processIdentifier: 42,
                processStartIdentity: 1001,
                windowID: 71),
            targetWindowIdentity: identity,
            targetWindowBounds: bounds,
            focusedElement: nil)
        let response = PeekabooBridgeResponse.projectedAction(.init(
            response: .dialogResult(result),
            outcome: outerOutcome.projection))
        let signed = try await Self.makeBundle(
            request: request,
            response: response,
            target: .window(identity),
            outcome: outerOutcome.projection)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try signed.bundle.validateIntegrity()
        }
    }

    @Test
    func `Signed exact dialog result binds broad selector evidence`() async throws {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let identity = WindowMutationIdentity(
            windowID: 71,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 1001,
            capturedBounds: bounds)
        let exactTarget = try UIAutomationTarget.ExactWindow(identity: identity, bounds: bounds)
        let selector = try DialogTargetSelector(
            applicationIdentifier: "Safari",
            windowTitle: "Save")
        let rawRequest = try PeekabooBridgeRequest.exactDialogEnterText(.init(
            target: selector,
            text: "hello"))
        let request = PeekabooBridgeRequest.projectedAction(.init(request: rawRequest))
        let localOutcome = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let outerOutcome = localOutcome.routed(to: .bridge)

        func resolvedTarget(
            name: String,
            bundleIdentifier: String,
            executablePath: String) throws -> ResolvedDialogTargetEvidence
        {
            let unboundApplication = ServiceApplicationInfo(
                processIdentifier: identity.ownerProcessIdentifier,
                processStartIdentity: identity.ownerProcessStartIdentity,
                bundleIdentifier: bundleIdentifier,
                name: name,
                bundlePath: "/Applications/\(name).app",
                executablePath: executablePath)
            let application = name == "Safari"
                ? Self.applicationWithSelectorProof(unboundApplication, selector: "Safari")
                : unboundApplication
            let window = ServiceWindowInfo(
                windowID: identity.windowID,
                title: "Save Document",
                bounds: bounds,
                index: 2,
                mutationIdentity: identity)
            return try .init(
                target: exactTarget,
                application: application,
                window: window,
                windowResolutionProof: Self.windowSelectorProof(
                    selection: .title("Save"),
                    processIdentity: identity.processIdentity,
                    window: window))
        }

        func response(_ resolvedTarget: ResolvedDialogTargetEvidence) -> PeekabooBridgeResponse {
            .projectedAction(.init(
                response: .dialogResult(.init(
                    success: true,
                    action: .enterText,
                    details: [:],
                    outcome: localOutcome,
                    targetReceipt: .init(
                        processIdentifier: identity.ownerProcessIdentifier,
                        processStartIdentity: identity.ownerProcessStartIdentity,
                        windowID: identity.windowID),
                    targetWindowIdentity: identity,
                    targetWindowBounds: bounds,
                    focusedElement: nil,
                    resolvedTarget: resolvedTarget)),
                outcome: outerOutcome.projection))
        }

        let validResponse = try response(resolvedTarget(
            name: "Safari",
            bundleIdentifier: "com.apple.Safari",
            executablePath: "/Applications/Safari.app/Contents/MacOS/Safari"))
        let valid = try await Self.makeBundle(
            request: request,
            response: validResponse,
            target: .window(identity),
            outcome: outerOutcome.projection)
        try valid.bundle.validateIntegrity()

        let forgedResponse = try response(resolvedTarget(
            name: "TextEdit",
            bundleIdentifier: "com.apple.TextEdit",
            executablePath: "/System/Applications/TextEdit.app/Contents/MacOS/TextEdit"))
        let forged = try await Self.makeBundle(
            request: request,
            response: forgedResponse,
            target: .window(identity),
            outcome: outerOutcome.projection)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try forged.bundle.validateIntegrity()
        }
    }

    @Test
    func `Reserved attribution context requires a matching failure receipt`() async throws {
        let rawRequest = PeekabooBridgeRequest.moveMouse(.init(
            to: .zero,
            duration: 0,
            steps: 1,
            profile: .linear))
        let request = PeekabooBridgeRequest.projectedAction(.init(request: rawRequest))
        let refusal = DesktopActionFailure.preDispatchRefusal(
            route: .bridge,
            reason: .invalidRequest,
            message: "refused")
        let response = PeekabooBridgeResponse.projectedAction(.init(
            response: .error(.init(
                code: .invalidRequest,
                actionFailure: refusal,
                context: "bridge_target_attribution:incomplete_exact_window")),
            outcome: refusal.outcome.projection))
        let signed = try await Self.makeBundle(
            request: request,
            response: response,
            outcome: refusal.outcome.projection)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try signed.bundle.validateIntegrity()
        }
    }

    @Test
    func `Prepared dialog response binds request kind and explicit target`() async throws {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let expectedTarget = try DialogTargetSelector(processIdentifier: 42, windowID: 71)
        let request = try PeekabooBridgeRequest.prepareDialogAction(.init(
            target: expectedTarget,
            kind: .clickButton,
            buttonText: "OK"))

        let wrongKindIdentity = WindowMutationIdentity(
            windowID: 71,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 1001,
            capturedBounds: bounds)
        let wrongKind = try PeekabooBridgeResponse.preparedDialogAction(.init(
            token: UUID(),
            kind: .dismiss,
            target: .init(identity: wrongKindIdentity, bounds: bounds)))
        let wrongKindBundle = try await Self.makeBundle(
            request: request,
            response: wrongKind,
            target: .window(wrongKindIdentity))
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try wrongKindBundle.bundle.validateIntegrity()
        }

        let wrongTargetIdentity = WindowMutationIdentity(
            windowID: 72,
            ownerProcessIdentifier: 43,
            ownerProcessStartIdentity: 2002,
            capturedBounds: bounds)
        let wrongTarget = try PeekabooBridgeResponse.preparedDialogAction(.init(
            token: UUID(),
            kind: .clickButton,
            target: .init(identity: wrongTargetIdentity, bounds: bounds)))
        let wrongTargetBundle = try await Self.makeBundle(
            request: request,
            response: wrongTarget,
            target: .window(wrongTargetIdentity))
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try wrongTargetBundle.bundle.validateIntegrity()
        }

        let broadSelector = try DialogTargetSelector(
            applicationIdentifier: "Safari",
            windowTitle: "Save")
        let broadRequest = try PeekabooBridgeRequest.prepareDialogAction(.init(
            target: broadSelector,
            kind: .clickButton,
            buttonText: "OK"))
        let exactTarget = try UIAutomationTarget.ExactWindow(identity: wrongKindIdentity, bounds: bounds)
        let application = Self.applicationWithSelectorProof(
            .init(
                processIdentifier: wrongKindIdentity.ownerProcessIdentifier,
                processStartIdentity: wrongKindIdentity.ownerProcessStartIdentity,
                bundleIdentifier: "com.apple.Safari",
                name: "Safari"),
            selector: "Safari")
        let window = ServiceWindowInfo(
            windowID: wrongKindIdentity.windowID,
            title: "Save Document",
            bounds: bounds,
            index: 0,
            mutationIdentity: wrongKindIdentity)
        let resolvedTarget = try ResolvedDialogTargetEvidence(
            target: exactTarget,
            application: application,
            window: window,
            windowResolutionProof: Self.windowSelectorProof(
                selection: .title("Save"),
                processIdentity: wrongKindIdentity.processIdentity,
                window: window))
        let broadResponse = PeekabooBridgeResponse.preparedDialogAction(.init(
            token: UUID(),
            kind: .clickButton,
            target: exactTarget,
            resolvedTarget: resolvedTarget))
        let broad = try await Self.makeBundle(
            request: broadRequest,
            response: broadResponse,
            target: .window(wrongKindIdentity))
        try broad.bundle.validateIntegrity()

        let missingEvidenceResponse = PeekabooBridgeResponse.preparedDialogAction(.init(
            token: UUID(),
            kind: .clickButton,
            target: exactTarget))
        let missingEvidence = try await Self.makeBundle(
            request: broadRequest,
            response: missingEvidenceResponse,
            target: .window(wrongKindIdentity))
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try missingEvidence.bundle.validateIntegrity()
        }
    }

    private static func makeBundle(
        request: PeekabooBridgeRequest,
        response: PeekabooBridgeResponse,
        target: PeekabooBridgeOperationTargetReceipt? = .global,
        focusedElement: FocusedElementIdentity? = nil,
        outcome: DesktopActionOutcome.Projection? = nil,
        selectedLeafEvidence: [DesktopSelectedLeafEvidence]? = nil,
        targetAttributionFailure: PeekabooBridgeTargetAttributionFailure? = nil,
        targetAttributionEvidence: [PeekabooBridgeOperationTargetEvidence]? = nil) async throws
        -> (bundle: PeekabooBridgeOperationReceiptBundle, attestation: PeekabooBridgeListenerAttestation)
    {
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: "/tmp/semantic-plan-\(UUID().uuidString)/bridge.sock")
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let accepted = try await session.acceptedClaim(
            authority: authority,
            sequence: 0,
            request: request)
        let payload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: accepted.claim,
            request: request,
            response: response,
            target: target,
            focusedElement: focusedElement,
            targetAttributionFailure: targetAttributionFailure,
            targetAttributionEvidence: targetAttributionEvidence,
            selectedLeafEvidence: selectedLeafEvidence,
            outcome: outcome)
        let receipt = try await authority.signAndArchive(payload, claim: accepted.claim)
        let bundle = try OperationReceiptSessionFixture.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: receipt,
            request: request,
            response: response)
        authority.complete(accepted.claim)
        return (bundle, authority.attestation)
    }

    private static func dialogResult(
        action: DialogActionType,
        outcome: DesktopActionOutcome) -> DialogActionResult
    {
        DialogActionResult(
            success: true,
            action: action,
            details: [:],
            outcome: outcome,
            targetReceipt: nil)
    }

    private static func applicationWithSelectorProof(
        _ application: ServiceApplicationInfo,
        selector: String) -> ServiceApplicationInfo
    {
        guard let processIdentity = application.processIdentity,
              let matchKind = ApplicationIdentifierMatcher.matchKind(
                  for: .init(application),
                  identifier: selector)
        else {
            preconditionFailure("Selector-proof fixture must match one stable application")
        }
        let proof = SelectorResolutionProof(
            scope: .application,
            normalizedSelector: ApplicationIdentifierMatcher.normalized(selector),
            matchKind: matchKind,
            matchPrecedence: matchKind.precedence,
            selectedProcessIdentity: processIdentity,
            candidateSetSHA256: String(repeating: "a", count: 64),
            candidateCount: 1,
            winningCandidateCount: 1,
            hasWinningTie: false)
        return application.withSelectorResolutionProofs([proof])
    }

    private static func windowSelectorProof(
        selection: WindowSelection,
        processIdentity: ApplicationProcessIdentity,
        window: ServiceWindowInfo) -> SelectorResolutionProof
    {
        let matchKind: SelectorResolutionProof.MatchKind = switch selection {
        case .automatic: .automaticWindowRank
        case .index: .windowIndex
        case .id: .windowID
        case let .title(title):
            window.title.compare(title, options: .caseInsensitive) == .orderedSame
                ? .exactWindowTitle
                : .partialWindowTitle
        }
        return SelectorResolutionProof(
            scope: .window,
            normalizedSelector: WindowSelectorResolutionProof.normalizedSelector(selection),
            matchKind: matchKind,
            matchPrecedence: matchKind.precedence,
            selectedProcessIdentity: processIdentity,
            selectedWindowIdentity: window.mutationIdentity,
            candidateSetSHA256: String(repeating: "b", count: 64),
            candidateCount: 1,
            winningCandidateCount: 1,
            hasWinningTie: false)
    }

    private static func captureDiagnostics(size: CGSize) -> CaptureDiagnostics {
        CaptureDiagnostics(
            requestedScale: .logical1x,
            nativeScale: 2,
            outputScale: 1,
            scaleSource: "fixture",
            finalPixelSize: size,
            engine: "ScreenCaptureKit")
    }
}
