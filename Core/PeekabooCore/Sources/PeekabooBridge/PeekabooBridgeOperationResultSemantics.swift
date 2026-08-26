import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

/// Bridge-owned terminal semantics for one operation.
///
/// This is deliberately exhaustive over `PeekabooBridgeOperation`. Adding a wire operation must
/// classify both its successful delivery and its target attribution before the Bridge can build a
/// canonical action outcome for a legacy handler that returned none.
enum PeekabooBridgeOperationResultSemantics {
    enum Completion: Equatable, Sendable {
        case readOnly
        case requestDependent(mutatesDesktop: Bool)
        case dispatchedUnverified(DesktopActionOutcome.Delivery)
        /// A child process may dispatch several nested target mutations, but the outer request
        /// owns no desktop lane or watermark. Its release is still retry-unsafe process dispatch.
        case externalProcessDispatch(DesktopActionOutcome.Delivery)

        var mutatesDesktop: Bool {
            switch self {
            case .readOnly: false
            case let .requestDependent(mutatesDesktop): mutatesDesktop
            case .dispatchedUnverified: true
            case .externalProcessDispatch: true
            }
        }

        var fixedDelivery: DesktopActionOutcome.Delivery? {
            switch self {
            case let .dispatchedUnverified(delivery), let .externalProcessDispatch(delivery): delivery
            case .readOnly, .requestDependent: nil
            }
        }
    }

    /// The target fact a receipt must establish before a successful result can be trusted.
    enum TargetPolicy: Equatable, Sendable {
        case notApplicable
        case requestDependent
        case global
        case requestPinned
        case handlerRequired
        /// The handler may resolve one exact target or prove that no desktop target was active.
        case handlerResolvedOrGlobal
        case responseResolved
        /// The affected object needs a richer receipt than a desktop process/window identity.
        case external
    }

    struct Contract: Equatable, Sendable {
        let completion: Completion
        let targetPolicy: TargetPolicy
    }

    enum ResponseFamily: Hashable, Sendable {
        case agentExecutionTrace
        case application
        case applicationMutationInventory
        case applications
        case bool
        case browserStatus
        case browserToolResponse
        case capture
        case clickResult
        case daemonStatus
        case detection
        case desktopObservation
        case dialogElements
        case dialogInfo
        case dialogResult
        case dockItem
        case dockItems
        case elementActionResult
        case elementDetection
        case focusedElement
        case heldPointerOwner
        case heldPointerReceipt
        case heldPointerTermination
        case int
        case menuBarItems
        case menuExtras
        case menuStructure
        case modifierClickResult
        case ok
        case permissionsStatus
        case processGenerationObservation
        case certificationProducerAttestation
        case preparedDialogAction
        case rect
        case snapshotID
        case snapshotMutationLease
        case snapshots
        case typeResult
        case waitResult
        case window
        case windowMutationInventory
        case windows
    }

    enum UnitPolicy: Equatable, Sendable {
        case exact(Int)
        case oneOf([Int])
        case positive
        /// The concrete service owns the count and may omit it when multiple native mechanisms ran.
        case variable

        func acceptsSuccessful(_ count: DesktopActionOutcome.DispatchUnitCount?) -> Bool {
            switch self {
            case let .exact(expected):
                count?.rawValue == expected
            case let .oneOf(expected):
                count.map { expected.contains($0.rawValue) } ?? false
            case .positive:
                count != nil
            case .variable:
                true
            }
        }

        func acceptsFailureProgress(_ count: DesktopActionOutcome.DispatchUnitCount?) -> Bool {
            guard let count else { return true }
            return switch self {
            case let .exact(maximum):
                count.rawValue <= maximum
            case let .oneOf(expected):
                expected.max().map { count.rawValue <= $0 } ?? false
            case .positive:
                true
            case .variable:
                true
            }
        }

        var defaultSuccessfulCount: DesktopActionOutcome.DispatchUnitCount? {
            switch self {
            case let .exact(value):
                DesktopActionOutcome.DispatchUnitCount(value)
            case let .oneOf(values):
                values.count == 1
                    ? values.first.flatMap { DesktopActionOutcome.DispatchUnitCount($0) }
                    : nil
            case .positive, .variable:
                nil
            }
        }
    }

    struct DeliveryRule: Equatable, Sendable {
        let delivery: DesktopActionOutcome.Delivery
        let units: UnitPolicy
        let failureUnits: UnitPolicy?
        let allowsSuccessfulOutcome: Bool

        init(
            delivery: DesktopActionOutcome.Delivery,
            units: UnitPolicy,
            failureUnits: UnitPolicy? = nil,
            allowsSuccessfulOutcome: Bool = true)
        {
            self.delivery = delivery
            self.units = units
            self.failureUnits = failureUnits
            self.allowsSuccessfulOutcome = allowsSuccessfulOutcome
        }

        func acceptsFailureProgress(_ count: DesktopActionOutcome.DispatchUnitCount?) -> Bool {
            self.failureUnits?.acceptsSuccessful(count) ?? self.units.acceptsFailureProgress(count)
        }
    }

    enum SuccessResponsePolicy: Equatable, Sendable {
        case ordinary
        /// Protocol 1.29 deliberately refuses this legacy operation before provider dispatch.
        case errorOnly
        /// The Boolean payload and canonical action state must describe the same quit result.
        case quitBoolean
        /// A terminal replay may be no-dispatch only when it proves a pre-dispatch owner disconnect.
        case heldPointerTerminalReplay
    }

    struct TypeActionResultRule: Equatable, Sendable {
        let totalCharacters: Int
        let keyPresses: Int

        let additionalDispatchUnits: Int

        init(actions: [TypeAction], additionalDispatchUnits: Int = 0) {
            var totalCharacters = 0
            var keyPresses = 0
            for action in actions {
                switch action {
                case let .text(text):
                    totalCharacters += text.count
                    keyPresses += text.count
                case .key:
                    keyPresses += 1
                case .clear:
                    keyPresses += 2
                }
            }
            self.totalCharacters = totalCharacters
            self.keyPresses = keyPresses
            self.additionalDispatchUnits = additionalDispatchUnits
        }

        var dispatchUnits: UnitPolicy {
            .exact(self.keyPresses + self.additionalDispatchUnits)
        }

        var expectedDispatchUnitCount: DesktopActionOutcome.DispatchUnitCount? {
            DesktopActionOutcome.DispatchUnitCount(self.keyPresses + self.additionalDispatchUnits)
        }
    }

    enum TypedResponseRule: Equatable, Sendable {
        case none
        case agentExecutionTrace(PeekabooBridgeAgentExecutionTraceRequest)
        case processGenerationObservation(PeekabooBridgeProcessGenerationObservationRequest)
        case certificationProducerAttestation(PeekabooBridgeCertificationProducerAttestationRequest)
        case typeActions(TypeActionResultRule)
        case setValue(target: String, value: String)
        case performAction(target: String, actionName: String)

        var typeActionDispatchUnits: UnitPolicy? {
            guard case let .typeActions(rule) = self else { return nil }
            return rule.dispatchUnits
        }

        func isConsistent(with binding: TypedResponseBinding) -> Bool {
            switch binding {
            case .agentExecutionTrace:
                if case .agentExecutionTrace = self {
                    true
                } else {
                    false
                }
            case .processGenerationObservation:
                if case .processGenerationObservation = self {
                    true
                } else {
                    false
                }
            case .certificationProducerAttestation:
                if case .certificationProducerAttestation = self {
                    true
                } else {
                    false
                }
            case .typeActions:
                if case .typeActions = self {
                    true
                } else {
                    false
                }
            case .setValue:
                if case .setValue = self {
                    true
                } else {
                    false
                }
            case .performAction:
                if case .performAction = self {
                    true
                } else {
                    false
                }
            case .familyOnly,
                 .noSuccessResponse,
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
                 .targetedDialogElements:
                self == .none
            }
        }
    }

    /// Which layer owns the desktop-operation lease for this wire operation.
    enum NativeLaneOwnership: Equatable, Sendable {
        case bridge
        case service
    }

    /// Bridge coordination required before a read reaches its concrete service.
    enum ReadLanePolicy: Equatable, Sendable {
        case none
        case globalExclusive
        /// The Bridge proposes an exclusive global lane, then narrows to a shared exact-target
        /// lane only after it resolves and revalidates the target under the current host identity.
        case exactTargetOrGlobalExclusive
    }

    struct LanePolicy: Equatable, Sendable {
        let nativeOwnership: NativeLaneOwnership
        let readPolicy: ReadLanePolicy
    }

    /// Whether a window mutation may or must carry an immutable request-side target receipt.
    enum PinnedWindowPolicy: Equatable, Sendable {
        case unavailable
        case legacyOptionalCurrentRequired
        case required
    }

    /// Typed response binding applied by receipt validation after the response-family check.
    enum TypedResponseBinding: Equatable, Sendable {
        /// The response family is the complete typed contract; no request field is echoed by the result.
        case familyOnly
        case agentExecutionTrace
        case processGenerationObservation
        case certificationProducerAttestation
        /// This operation intentionally has no successful response family.
        case noSuccessResponse
        case typeActions
        case setValue
        case performAction
        case focusedElement
        case applicationIdentifier
        case applicationLaunch
        case applicationRelaunch
        case capture
        case elementDetection
        case desktopObservation
        case postMutationWindow
        case menuStructureApplication
        case waitElementSelector
        case dockItemSelector
        case storedDetection
        case detectionSnapshot
        case snapshotMutationLease
        case dialogResult
        case preparedDialogAction
        case targetedDialogElements
    }

    /// Whether a `.window` response is postcondition proof rather than target-attribution evidence.
    enum WindowResponseProofPolicy: Equatable, Sendable {
        case none
        case postMutationState
    }

    /// Where a successful response can contribute target-attribution evidence.
    enum ResponseTargetEvidenceSource: Equatable, Sendable {
        case none
        case agentProcess
        case application
        case browserConnection
        case capture
        case desktopObservation
        case dialog
        case heldPointerTermination
        case inspectWindowContext
        case preparedDialog
        case targetedDialog
        case window
    }

    /// Static policy that every wire operation must classify in one descriptor.
    struct OperationDescriptor: Equatable, Sendable {
        let operation: PeekabooBridgeOperation
        let requiredPermissions: Set<PeekabooBridgePermissionKind>
        let lane: LanePolicy
        let pinnedWindow: PinnedWindowPolicy
        let typedResponse: TypedResponseBinding
        let windowResponseProof: WindowResponseProofPolicy
        let contract: Contract
        let responseFamilies: Set<ResponseFamily>
        let responseTargetEvidence: ResponseTargetEvidenceSource
    }

    typealias OperationPolicy = OperationDescriptor

    enum ExactReadTarget: Equatable, Sendable {
        case process(pid_t)
        case window(windowID: Int, expectedOwner: pid_t?)
        case validatedWindow(WindowMutationIdentity)
    }

    struct PinnedWindowMutation: Sendable {
        let target: WindowTarget
        let identity: WindowMutationIdentity
    }

    struct TargetPlan: Sendable {
        let policy: TargetPolicy
        let responseEvidenceSource: ResponseTargetEvidenceSource
        let requestEvidence: [DesktopTargetIdentity.Evidence]
        let desktopOperationScope: DesktopOperationScope
        let desktopReadOperationLane: (scope: DesktopOperationScope, access: DesktopOperationAccess)?
        let exactReadTarget: ExactReadTarget?
        let pinnedWindowMutation: PinnedWindowMutation?
        let requiresPinnedWindowMutation: Bool

        var requiresStableIdentity: Bool {
            self.policy == .requestPinned
        }

        var requiresResolvedIdentity: Bool {
            switch self.policy {
            case .requestPinned, .handlerRequired, .responseResolved, .external:
                true
            case .handlerResolvedOrGlobal, .notApplicable, .requestDependent, .global:
                false
            }
        }
    }

    struct ResultPlan: Sendable {
        let completion: Completion
        let responseFamilies: Set<ResponseFamily>
        let deliveryRules: [DeliveryRule]
        let allowedSuccessStates: [DesktopActionOutcome.State]
        let successResponsePolicy: SuccessResponsePolicy
        let deliveryAgnosticFailureUnits: UnitPolicy?
        let typedResponseRule: TypedResponseRule
    }

    struct PeekabooBridgeRequestPlan: Sendable {
        enum Vocabulary: Equatable, Sendable {
            case legacy
            case current

            init(usesCurrentResultSemantics: Bool) {
                self = usesCurrentResultSemantics ? .current : .legacy
            }

            var usesCurrentResultSemantics: Bool {
                self == .current
            }
        }

        let request: PeekabooBridgeRequest
        let carriageRequest: PeekabooBridgeRequest
        let descriptor: OperationDescriptor
        let vocabulary: Vocabulary
        let target: TargetPlan
        let result: ResultPlan

        var operation: PeekabooBridgeOperation {
            self.descriptor.operation
        }

        var operationPolicy: OperationPolicy {
            self.descriptor
        }

        var contract: Contract {
            .init(completion: self.result.completion, targetPolicy: self.target.policy)
        }

        var responseFamilies: Set<ResponseFamily> {
            self.result.responseFamilies
        }

        var deliveryRules: [DeliveryRule] {
            self.result.deliveryRules
        }

        var allowedSuccessStates: [DesktopActionOutcome.State] {
            self.result.allowedSuccessStates
        }

        var successResponsePolicy: SuccessResponsePolicy {
            self.result.successResponsePolicy
        }

        var deliveryAgnosticFailureUnits: UnitPolicy? {
            self.result.deliveryAgnosticFailureUnits
        }

        var typedResponseRule: TypedResponseRule {
            self.result.typedResponseRule
        }

        var desktopOperationScope: DesktopOperationScope {
            self.target.desktopOperationScope
        }

        var desktopReadOperationLane: (scope: DesktopOperationScope, access: DesktopOperationAccess)? {
            self.target.desktopReadOperationLane
        }

        var exactReadTarget: ExactReadTarget? {
            self.target.exactReadTarget
        }

        var pinnedWindowMutation: PinnedWindowMutation? {
            self.target.pinnedWindowMutation
        }

        func responseMatches(_ response: PeekabooBridgeResponse) -> Bool {
            if case .error = response {
                return true
            }
            return self.responseFamilies.contains { $0.matches(response) }
        }

        func validateBoundTypedResponse(
            _ response: PeekabooBridgeResponse,
            outcome: DesktopActionOutcome?) throws
        {
            switch (self.typedResponseRule, response) {
            case (.none, _):
                return
            case (.agentExecutionTrace, .error):
                return
            case let (.agentExecutionTrace(request), .agentExecutionTrace(result)):
                try result.validate(request: request)
            case (.processGenerationObservation, .error):
                return
            case let (.processGenerationObservation(request), .processGenerationObservation(result)):
                try result.validate(request: request)
            case (.certificationProducerAttestation, .error):
                return
            case let (.certificationProducerAttestation(request), .certificationProducerAttestation(result)):
                try result.validateEnvelope(request: request)
            case (.typeActions, .error), (.setValue, .error):
                // A canonical failure has no success payload to bind. Its outcome, target receipt,
                // and dispatch count are validated by the failure and receipt contracts instead.
                return
            case let (.typeActions(expected), .typeResult(result)):
                guard expected.keyPresses > 0 else {
                    throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                        "type response zero-emission success")
                }
                guard result.totalCharacters == expected.totalCharacters,
                      result.keyPresses == expected.keyPresses
                else {
                    throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                        "type response request counts")
                }
                guard let expectedUnits = expected.expectedDispatchUnitCount,
                      let outcome,
                      case let .dispatched(actualUnits) = outcome.dispatchState,
                      actualUnits == expectedUnits
                else {
                    throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                        "type response dispatch units")
                }
            case let (.setValue(expectedTarget, expectedValue), .elementActionResult(result)):
                guard result.target == expectedTarget,
                      result.actionName == "AXSetValue",
                      result.anchorPoint == nil,
                      result.newValue == expectedValue
                else {
                    throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                        "set-value response request semantics")
                }
            case let (.performAction(expectedTarget, expectedAction), .elementActionResult(result)):
                guard result.target == expectedTarget,
                      result.actionName == expectedAction,
                      result.oldValue == nil,
                      result.newValue == nil
                else {
                    throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                        "perform-action response request semantics")
                }
            case (.agentExecutionTrace, _), (.processGenerationObservation, _),
                 (.certificationProducerAttestation, _),
                 (.typeActions, _), (.setValue, _), (.performAction, _):
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("bound typed response family")
            }
        }

        func deliveryRule(for delivery: DesktopActionOutcome.Delivery?) -> DeliveryRule? {
            guard let delivery else { return nil }
            return self.deliveryRules.first { $0.delivery == delivery }
        }

        func allowsSuccessState(_ state: DesktopActionOutcome.State) -> Bool {
            self.allowedSuccessStates.contains(state)
        }

        var successfulDeliveryRules: [DeliveryRule] {
            self.deliveryRules.filter(\.allowsSuccessfulOutcome)
        }

        var nativeServiceOwnsDesktopOperationLane: Bool {
            self.descriptor.lane.nativeOwnership == .service
        }

        var requiresPinnedWindowMutation: Bool {
            self.target.requiresPinnedWindowMutation
        }

        var responseCarriesPostMutationWindowState: Bool {
            self.descriptor.windowResponseProof == .postMutationState
        }

        func defaultSuccessfulDispatchUnitCount(
            for delivery: DesktopActionOutcome.Delivery) -> DesktopActionOutcome.DispatchUnitCount?
        {
            self.typedResponseRule.typeActionDispatchUnits?.defaultSuccessfulCount ??
                self.deliveryRule(for: delivery)?.units.defaultSuccessfulCount
        }
    }

    enum FailureStage: Equatable, Sendable {
        case preDispatch(DesktopActionOutcome.RefusalReason)
        case executionMayHaveStarted
    }
}

typealias PeekabooBridgeRequestPlan =
    PeekabooBridgeOperationResultSemantics.PeekabooBridgeRequestPlan

extension PeekabooBridgeOperationResultSemantics {
    static func operationPolicy(for operation: PeekabooBridgeOperation) -> OperationPolicy {
        self.operationDescriptor(for: operation)
    }

    static func contract(for operation: PeekabooBridgeOperation) -> Contract {
        self.operationDescriptor(for: operation).contract
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func contract(for request: PeekabooBridgeRequest) -> Contract {
        let request = request.unwrappedOperationRequest
        switch request {
        case .attestedOperation, .projectedAction:
            // Only invalid carriage remains wrapped after canonical unwrapping. It must not be
            // granted the inner operation's mutation semantics.
            return .init(completion: .readOnly, targetPolicy: .notApplicable)
        case let .browserExecute(payload):
            guard payload.isReadOnly else { return self.contract(for: request.operation) }
            return .init(completion: .readOnly, targetPolicy: .notApplicable)
        case let .click(payload):
            let delivery: DesktopActionOutcome.Delivery
            let targetPolicy: TargetPolicy
            switch payload.target {
            case .coordinates:
                delivery = .init(mechanism: .globalEvents, mode: .foreground)
                targetPolicy = .global
            case .elementId, .query:
                delivery = .init(mechanism: .accessibilityAction, mode: .foreground)
                targetPolicy = .handlerRequired
            }
            return .init(completion: .dispatchedUnverified(delivery), targetPolicy: targetPolicy)
        case let .type(payload):
            let hasTarget = payload.target?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            return .init(
                completion: .dispatchedUnverified(.init(
                    mechanism: .globalEvents,
                    mode: .foreground)),
                targetPolicy: hasTarget ? .handlerRequired : .global)
        case let .scroll(payload):
            return .init(
                completion: .dispatchedUnverified(.init(
                    mechanism: payload.request.foreground ? .globalEvents : .accessibilityAction,
                    mode: payload.request.foreground ? .foreground : .background)),
                targetPolicy: payload.request.target == nil ? .global : .handlerRequired)
        case let .clickMenuItem(payload):
            return .init(
                completion: .dispatchedUnverified(.init(
                    mechanism: .accessibilityAction,
                    mode: payload.deliveryMode ?? .foreground)),
                targetPolicy: .requestPinned)
        case let .clickMenuItemByName(payload):
            return .init(
                completion: .dispatchedUnverified(.init(
                    mechanism: .accessibilityAction,
                    mode: payload.deliveryMode ?? .foreground)),
                targetPolicy: .requestPinned)
        case let .launchApplicationWithOptions(payload):
            // The service routes this exact background-only shape through
            // performVerifiedBackgroundLaunchNoOp; it may resolve an app URL but never dispatches a LaunchServices
            // open/start operation.
            guard !payload.isSafeBackgroundNoOp else {
                return .init(completion: .readOnly, targetPolicy: .notApplicable)
            }
            return .init(
                completion: .dispatchedUnverified(.init(
                    mechanism: .nativeFramework,
                    mode: payload.activates ? .foreground : .background)),
                targetPolicy: .responseResolved)
        case let .relaunchApplicationWithOptions(payload):
            return .init(
                completion: .dispatchedUnverified(.init(
                    mechanism: .nativeFramework,
                    mode: payload.launchRequest.activates ? .foreground : .background)),
                targetPolicy: .responseResolved)
        case let .rightClickDockItem(payload):
            return .init(
                completion: .dispatchedUnverified(
                    payload.menuItem == nil
                        ? .init(mechanism: .globalEvents, mode: .foreground)
                        : .init(mechanism: .composite, mode: .foreground)),
                targetPolicy: .external)
        case let .captureScreen(payload):
            return self.directCaptureContract(
                visualizerMode: payload.visualizerMode,
                readOnlyTargetPolicy: .notApplicable,
                mutationTargetPolicy: .global)
        case let .captureWindow(payload):
            return self.directCaptureContract(
                visualizerMode: payload.visualizerMode,
                readOnlyTargetPolicy: .responseResolved,
                mutationTargetPolicy: .responseResolved)
        case let .captureFrontmost(payload):
            return self.directCaptureContract(
                visualizerMode: payload.visualizerMode,
                readOnlyTargetPolicy: .responseResolved,
                mutationTargetPolicy: .responseResolved)
        case let .captureArea(payload):
            return self.directCaptureContract(
                visualizerMode: payload.visualizerMode,
                readOnlyTargetPolicy: .notApplicable,
                mutationTargetPolicy: .global)
        case let .desktopObservation(payload):
            let targetPolicy: TargetPolicy = switch payload.target {
            case .app, .pid, .windowID, .frontmost: .responseResolved
            case .menubarPopover: .external
            case .screen, .allScreens, .area, .menubar: .global
            }
            if case let .menubarPopover(_, openIfNeeded) = payload.target,
               openIfNeeded != nil
            {
                return .init(
                    completion: .dispatchedUnverified(.init(
                        mechanism: .windowTargetedEvents,
                        mode: .background)),
                    targetPolicy: targetPolicy)
            }
            let mode: DesktopActionOutcome.Delivery.Mode = payload.capture.focus == .background
                ? .background
                : .foreground
            let mutatesDesktop = payload.capture.focus != .background ||
                (payload.detection.mode != .none && payload.detection.allowWebFocusFallback)
            return .init(
                completion: mutatesDesktop
                    ? .dispatchedUnverified(.init(mechanism: .capturePipeline, mode: mode))
                    : .readOnly,
                targetPolicy: targetPolicy)
        case let .detectElements(payload):
            guard payload.windowContext?.shouldFocusWebContent == true else {
                return .init(completion: .readOnly, targetPolicy: .global)
            }
            return .init(
                completion: .dispatchedUnverified(.init(
                    mechanism: .accessibilityAction,
                    mode: .background)),
                targetPolicy: payload.windowContext == nil ? .global : .handlerRequired)
        case let .inspectAccessibilityTree(payload):
            guard payload.windowContext?.shouldFocusWebContent == true else {
                return .init(
                    completion: .readOnly,
                    targetPolicy: payload.windowContext == nil ? .global : .responseResolved)
            }
            return .init(
                completion: .dispatchedUnverified(.init(
                    mechanism: .accessibilityAction,
                    mode: .background)),
                targetPolicy: payload.windowContext == nil ? .global : .responseResolved)
        default:
            return self.contract(for: request.operation)
        }
    }

    private static func directCaptureContract(
        visualizerMode: CaptureVisualizerMode,
        readOnlyTargetPolicy: TargetPolicy,
        mutationTargetPolicy: TargetPolicy) -> Contract
    {
        guard visualizerMode != .none else {
            return .init(completion: .readOnly, targetPolicy: readOnlyTargetPolicy)
        }
        return .init(
            completion: .dispatchedUnverified(.init(
                mechanism: .capturePipeline,
                mode: .background)),
            targetPolicy: mutationTargetPolicy)
    }

    static func semanticPlan(for request: PeekabooBridgeRequest) -> PeekabooBridgeRequestPlan {
        self.requestPlan(
            for: request,
            vocabulary: .init(usesCurrentResultSemantics:
                PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics))
    }

    static func requestPlan(
        for request: PeekabooBridgeRequest,
        vocabulary: PeekabooBridgeRequestPlan.Vocabulary) -> PeekabooBridgeRequestPlan
    {
        let carriageRequest = request
        let request = request.unwrappedOperationRequest
        let operation = request.operation
        if case .attestedOperation = request {
            return self.invalidCarriageSemanticPlan(
                request: request,
                operation: operation,
                vocabulary: vocabulary)
        }
        if case .projectedAction = request {
            return self.invalidCarriageSemanticPlan(
                request: request,
                operation: operation,
                vocabulary: vocabulary)
        }
        let descriptor = self.operationPolicy(for: operation)
        let typedResponseRule = self.typedResponseRule(for: request)
        precondition(
            typedResponseRule.isConsistent(with: descriptor.typedResponse),
            "Typed response rule must match the exhaustive operation binding")
        let contract = self.contract(for: request)
        let exactReadTarget = self.exactReadTarget(for: request)
        let readLane = self.desktopReadOperationLane(
            contract: contract,
            policy: descriptor.lane.readPolicy,
            exactTarget: exactReadTarget)
        let requiresPinnedWindowMutation = switch descriptor.pinnedWindow {
        case .required: true
        case .legacyOptionalCurrentRequired: vocabulary == .current
        case .unavailable: false
        }
        return PeekabooBridgeRequestPlan(
            request: request,
            carriageRequest: carriageRequest,
            descriptor: descriptor,
            vocabulary: vocabulary,
            target: .init(
                policy: contract.targetPolicy,
                responseEvidenceSource: descriptor.responseTargetEvidence,
                requestEvidence: request.operationTargetEvidence,
                desktopOperationScope: self.desktopOperationScope(for: request),
                desktopReadOperationLane: readLane,
                exactReadTarget: exactReadTarget,
                pinnedWindowMutation: self.pinnedWindowMutation(for: request),
                requiresPinnedWindowMutation: requiresPinnedWindowMutation),
            result: .init(
                completion: contract.completion,
                responseFamilies: self.responseFamilies(for: request),
                deliveryRules: self.deliveryRules(for: request, contract: contract),
                allowedSuccessStates: self.allowedSuccessStates(
                    for: request,
                    completion: contract.completion),
                successResponsePolicy: self.successResponsePolicy(for: request),
                deliveryAgnosticFailureUnits: self.deliveryAgnosticFailureUnits(for: request),
                typedResponseRule: typedResponseRule))
    }

    private static func invalidCarriageSemanticPlan(
        request: PeekabooBridgeRequest,
        operation: PeekabooBridgeOperation,
        vocabulary: PeekabooBridgeRequestPlan.Vocabulary) -> PeekabooBridgeRequestPlan
    {
        let lane = LanePolicy(nativeOwnership: .bridge, readPolicy: .globalExclusive)
        let descriptor = OperationDescriptor(
            operation: operation,
            requiredPermissions: [],
            lane: lane,
            pinnedWindow: .unavailable,
            typedResponse: .noSuccessResponse,
            windowResponseProof: .none,
            contract: .init(completion: .readOnly, targetPolicy: .notApplicable),
            responseFamilies: [],
            responseTargetEvidence: .none)
        return PeekabooBridgeRequestPlan(
            request: request,
            carriageRequest: request,
            descriptor: descriptor,
            vocabulary: vocabulary,
            target: .init(
                policy: .notApplicable,
                responseEvidenceSource: .none,
                requestEvidence: [],
                desktopOperationScope: .global,
                desktopReadOperationLane: (.global, .write),
                exactReadTarget: nil,
                pinnedWindowMutation: nil,
                requiresPinnedWindowMutation: false),
            result: .init(
                completion: .readOnly,
                responseFamilies: [],
                deliveryRules: [],
                allowedSuccessStates: [],
                successResponsePolicy: .errorOnly,
                deliveryAgnosticFailureUnits: nil,
                typedResponseRule: .none))
    }

    private static func desktopOperationScope(for request: PeekabooBridgeRequest) -> DesktopOperationScope {
        switch request {
        case .foregroundModifierClick:
            .global
        case let .exactWindowTargetedTypeActions(payload):
            .process(payload.expectedWindowIdentity.processIdentity)
        case let .exactWindowPixelFocusType(payload):
            .process(payload.request.windowIdentity.processIdentity)
        case let .exactWindowTargetedHotkey(payload):
            .process(payload.expectedWindowIdentity.processIdentity)
        case let .beginExactWindowHeldPointer(payload):
            .window(payload.request.windowIdentity)
        case let .releaseExactWindowHeldPointer(payload),
             let .revokeExactWindowHeldPointer(payload):
            .window(payload.receipt.windowIdentity)
        case let .targetedHotkey(payload):
            payload.expectedProcessIdentity.map(DesktopOperationScope.process) ?? .global
        case let .targetedTypeActions(payload):
            payload.expectedProcessIdentity.map(DesktopOperationScope.process) ?? .global
        case let .targetedClick(payload):
            if let targetWindowID = payload.targetWindowID,
               let identity = payload.expectedWindowIdentity,
               payload.expectedWindowBounds != nil,
               identity.windowID == targetWindowID
            {
                .process(identity.processIdentity)
            } else {
                payload.expectedProcessIdentity.map(DesktopOperationScope.process) ?? .global
            }
        case let .backgroundCloseWindow(payload),
             let .minimizeWindow(payload),
             let .restoreWindow(payload),
             let .maximizeWindow(payload):
            payload.expectedIdentity.map(DesktopOperationScope.window) ?? .global
        case let .moveWindow(payload):
            payload.expectedIdentity.map(DesktopOperationScope.window) ?? .global
        case let .resizeWindow(payload):
            payload.expectedIdentity.map(DesktopOperationScope.window) ?? .global
        case let .setWindowBounds(payload):
            payload.expectedIdentity.map(DesktopOperationScope.window) ?? .global
        case let .quitApplication(payload):
            payload.expectedIdentity.map(DesktopOperationScope.process) ?? .global
        case let .hideApplication(payload):
            if let identity = payload.expectedIdentity,
               payload.identifier == "PID:\(identity.processIdentifier)"
            {
                .process(identity)
            } else {
                .global
            }
        case let .clickMenuItem(payload):
            payload.expectedIdentity.map(DesktopOperationScope.process) ?? .global
        case let .clickMenuItemByName(payload):
            payload.expectedIdentity.map(DesktopOperationScope.process) ?? .global
        case let .exactDialogClickButton(receipt), let .exactDialogDismiss(receipt):
            .window(receipt.target.identity)
        default:
            .global
        }
    }

    private static func desktopReadOperationLane(
        contract: Contract,
        policy: ReadLanePolicy,
        exactTarget: ExactReadTarget?) -> (scope: DesktopOperationScope, access: DesktopOperationAccess)?
    {
        guard !contract.completion.mutatesDesktop else { return nil }
        switch policy {
        case .none:
            return nil
        case .globalExclusive:
            return (.global, .write)
        case .exactTargetOrGlobalExclusive:
            if case let .validatedWindow(identity) = exactTarget {
                return (.window(identity), .read)
            }
            return (.global, .write)
        }
    }

    private static func exactReadTarget(for request: PeekabooBridgeRequest) -> ExactReadTarget? {
        switch request {
        case let .inspectAccessibilityTree(payload):
            guard let context = payload.windowContext,
                  let identity = context.windowMutationIdentity,
                  context.windowID == identity.windowID,
                  context.applicationProcessId == identity.ownerProcessIdentifier
            else { return nil }
            return .validatedWindow(identity)
        case let .captureWindow(payload):
            if let windowID = payload.windowId {
                return .window(windowID: windowID, expectedOwner: nil)
            }
            return self.explicitProcessIdentifier(payload.appIdentifier).map(ExactReadTarget.process)
        case let .desktopObservation(payload):
            switch payload.target {
            case let .windowID(windowID):
                return .window(windowID: Int(windowID), expectedOwner: nil)
            case let .pid(processIdentifier, selection):
                if case let .id(windowID)? = selection {
                    return .window(windowID: Int(windowID), expectedOwner: processIdentifier)
                }
                return .process(processIdentifier)
            case let .app(_, selection):
                if case let .id(windowID)? = selection {
                    return .window(windowID: Int(windowID), expectedOwner: nil)
                }
                return nil
            case .allScreens, .area, .frontmost, .menubar, .menubarPopover, .screen:
                return nil
            }
        default:
            return nil
        }
    }

    private static func explicitProcessIdentifier(_ identifier: String) -> pid_t? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.uppercased().hasPrefix("PID:"),
              let processIdentifier = pid_t(trimmed.dropFirst("PID:".count)),
              processIdentifier > 0
        else { return nil }
        return processIdentifier
    }

    private static func pinnedWindowMutation(for request: PeekabooBridgeRequest) -> PinnedWindowMutation? {
        switch request {
        case let .moveWindow(payload):
            payload.expectedIdentity.map { .init(target: payload.target, identity: $0) }
        case let .resizeWindow(payload):
            payload.expectedIdentity.map { .init(target: payload.target, identity: $0) }
        case let .setWindowBounds(payload):
            payload.expectedIdentity.map { .init(target: payload.target, identity: $0) }
        case let .focusWindow(payload),
             let .closeWindow(payload),
             let .backgroundCloseWindow(payload),
             let .minimizeWindow(payload),
             let .restoreWindow(payload),
             let .maximizeWindow(payload):
            payload.expectedIdentity.map { .init(target: payload.target, identity: $0) }
        default:
            nil
        }
    }

    private static func typedResponseRule(for request: PeekabooBridgeRequest) -> TypedResponseRule {
        switch request {
        case let .agentExecutionTrace(payload):
            .agentExecutionTrace(payload)
        case let .observeProcessGeneration(payload):
            .processGenerationObservation(payload)
        case let .certificationProducerAttestation(payload):
            .certificationProducerAttestation(payload)
        case let .typeActions(payload):
            .typeActions(.init(actions: payload.actions))
        case let .targetedTypeActions(payload):
            .typeActions(.init(actions: payload.actions))
        case let .exactWindowTargetedTypeActions(payload):
            .typeActions(.init(actions: payload.actions))
        case let .exactWindowPixelFocusType(payload):
            .typeActions(.init(
                actions: payload.request.actions,
                additionalDispatchUnits: 1))
        case let .setValue(payload):
            .setValue(
                target: payload.target,
                value: self.canonicalSetValueDisplayString(payload.value))
        case let .performAction(payload):
            .performAction(target: payload.target, actionName: payload.actionName)
        case .attestedOperation,
             .projectedAction,
             .handshake,
             .permissionsStatus,
             .requestPostEventPermission,
             .daemonStatus,
             .daemonStop,
             .daemonStopIf,
             .browserStatus,
             .browserConnect,
             .browserDisconnect,
             .browserExecute,
             .captureScreen,
             .captureWindow,
             .captureFrontmost,
             .captureArea,
             .detectElements,
             .inspectAccessibilityTree,
             .getFocusedElement,
             .desktopObservation,
             .click,
             .type,
             .scroll,
             .targetedScroll,
             .hotkey,
             .targetedHotkey,
             .exactWindowTargetedHotkey,
             .foregroundModifierClick,
             .createExactWindowHeldPointerOwner,
             .beginExactWindowHeldPointer,
             .releaseExactWindowHeldPointer,
             .revokeExactWindowHeldPointer,
             .disconnectExactWindowHeldPointerOwner,
             .targetedClick,
             .swipe,
             .drag,
             .moveMouse,
             .waitForElement,
             .listWindows,
             .listWindowMutationInventory,
             .focusWindow,
             .moveWindow,
             .resizeWindow,
             .setWindowBounds,
             .closeWindow,
             .backgroundCloseWindow,
             .minimizeWindow,
             .restoreWindow,
             .maximizeWindow,
             .getFocusedWindow,
             .listApplications,
             .listApplicationMutationInventory,
             .findApplication,
             .getFrontmostApplication,
             .isApplicationRunning,
             .launchApplication,
             .launchApplicationWithOptions,
             .relaunchApplicationWithOptions,
             .activateApplication,
             .quitApplication,
             .hideApplication,
             .unhideApplication,
             .hideOtherApplications,
             .showAllApplications,
             .listMenus,
             .listFrontmostMenus,
             .clickMenuItem,
             .clickMenuItemByName,
             .listMenuExtras,
             .clickMenuExtra,
             .menuExtraOpenMenuFrame,
             .listMenuBarItems,
             .clickMenuBarItemNamed,
             .clickMenuBarItemIndex,
             .listDockItems,
             .launchDockItem,
             .rightClickDockItem,
             .hideDock,
             .showDock,
             .isDockHidden,
             .findDockItem,
             .dialogFindActive,
             .dialogClickButton,
             .backgroundDialogClickButton,
             .dialogEnterText,
             .dialogHandleFile,
             .dialogDismiss,
             .dialogListElements,
             .targetedDialogListElements,
             .prepareDialogAction,
             .exactDialogClickButton,
             .exactDialogDismiss,
             .exactDialogEnterText,
             .exactDialogForceDismiss,
             .createSnapshot,
             .storeDetectionResult,
             .getDetectionResult,
             .ownsSnapshot,
             .storeScreenshot,
             .storeObservationSnapshot,
             .storeAnnotatedScreenshot,
             .listSnapshots,
             .getMostRecentSnapshot,
             .invalidateImplicitLatestSnapshot,
             .beginSnapshotMutation,
             .finishSnapshotMutation,
             .cleanSnapshot,
             .cleanSnapshotsOlderThan,
             .cleanAllSnapshots,
             .appleScriptProbe:
            .none
        }
    }

    /// Set-value response semantics must follow the signed wire value, not a caller's in-memory
    /// representation. JSON canonicalization intentionally collapses equivalent numbers such as
    /// `-0.0` and `0`; strings that merely look numeric remain exact strings.
    private static func canonicalSetValueDisplayString(_ value: UIElementValue) -> String {
        guard let data = try? PeekabooBridgeOperationReceiptCoding.canonicalData(value),
              let canonicalValue = try? JSONDecoder.peekabooBridgeDecoder().decode(
                  UIElementValue.self,
                  from: data)
        else {
            // Non-encodable values cannot enter an attested request, but retaining the original
            // representation keeps legacy planning deterministic until request encoding rejects it.
            return value.displayString
        }
        return canonicalValue.displayString
    }

    private static func allowedSuccessStates(
        for request: PeekabooBridgeRequest,
        completion: Completion) -> [DesktopActionOutcome.State]
    {
        guard completion.mutatesDesktop else { return [] }
        let verifiedOrAccepted: [DesktopActionOutcome.State] = [
            .confirmedChange,
            .confirmedNoChange,
            .dispatchedUnverified,
            .suspectedNoop,
        ]
        switch request.operation {
        case .agentExecutionTrace:
            return [.dispatchedUnverified]
        case .requestPostEventPermission, .browserExecute, .swipe, .drag, .moveMouse,
             .clickMenuItem, .clickMenuItemByName, .clickMenuExtra,
             .clickMenuBarItemNamed, .clickMenuBarItemIndex,
             .launchDockItem, .rightClickDockItem,
             .detectElements, .inspectAccessibilityTree,
             .exactDialogForceDismiss:
            return [.dispatchedUnverified]
        case .beginExactWindowHeldPointer:
            return [.dispatchedUnverified]
        case .releaseExactWindowHeldPointer, .revokeExactWindowHeldPointer:
            return [.confirmedNoChange, .dispatchedUnverified]
        case .disconnectExactWindowHeldPointerOwner:
            return [.confirmedNoChange, .dispatchedUnverified]
        case .exactDialogClickButton, .exactDialogDismiss:
            return [.confirmedChange]
        case .exactDialogEnterText:
            return [.confirmedNoChange, .dispatchedUnverified]
        case .relaunchApplicationWithOptions:
            return [.confirmedChange, .dispatchedUnverified]
        case .launchApplication, .launchApplicationWithOptions, .activateApplication, .hideApplication:
            return [.confirmedChange, .confirmedNoChange, .dispatchedUnverified]
        case .hideOtherApplications, .showAllApplications:
            return [.confirmedNoChange, .dispatchedUnverified]
        case .quitApplication:
            return [.confirmedChange, .dispatchedUnverified, .suspectedNoop]
        case .hideDock, .showDock:
            return [.confirmedChange, .confirmedNoChange, .dispatchedUnverified, .suspectedNoop]
        case .unhideApplication, .dialogClickButton, .backgroundDialogClickButton,
             .dialogEnterText, .dialogHandleFile, .dialogDismiss:
            return []
        case .click, .type, .typeActions, .targetedTypeActions, .exactWindowTargetedTypeActions,
             .exactWindowPixelFocusType,
             .foregroundModifierClick,
             .setValue, .performAction, .scroll, .targetedScroll, .hotkey, .targetedHotkey,
             .exactWindowTargetedHotkey, .targetedClick, .exactWindowTargetedClick,
             .focusWindow, .moveWindow, .resizeWindow, .setWindowBounds, .closeWindow,
             .backgroundCloseWindow, .minimizeWindow, .restoreWindow, .maximizeWindow:
            return verifiedOrAccepted
        case .desktopObservation:
            if case let .desktopObservation(payload) = request,
               case let .menubarPopover(_, openIfNeeded) = payload.target,
               openIfNeeded != nil
            {
                return [.confirmedNoChange, .dispatchedUnverified]
            }
            return verifiedOrAccepted
        case .captureScreen, .captureWindow, .captureFrontmost, .captureArea:
            return [.dispatchedUnverified]
        case .browserConnect:
            return [.confirmedNoChange, .dispatchedUnverified]
        case .permissionsStatus, .observeProcessGeneration, .certificationProducerAttestation,
             .createExactWindowHeldPointerOwner,
             .daemonStatus, .daemonStop, .browserStatus,
             .browserDisconnect,
             .getFocusedElement, .waitForElement, .listWindows, .getFocusedWindow,
             .listApplications, .findApplication, .getFrontmostApplication, .isApplicationRunning,
             .listMenus, .listFrontmostMenus, .listMenuExtras, .menuExtraOpenMenuFrame,
             .listMenuBarItems, .listDockItems, .isDockHidden, .findDockItem, .dialogFindActive,
             .dialogListElements, .targetedDialogListElements, .prepareDialogAction, .createSnapshot,
             .storeDetectionResult, .getDetectionResult, .ownsSnapshot, .storeScreenshot,
             .storeObservationSnapshot,
             .storeAnnotatedScreenshot, .listSnapshots, .getMostRecentSnapshot,
             .invalidateImplicitLatestSnapshot, .beginSnapshotMutation, .finishSnapshotMutation,
             .cleanSnapshot, .cleanSnapshotsOlderThan, .cleanAllSnapshots, ._appleScriptProbe:
            return []
        }
    }

    private static func successResponsePolicy(for request: PeekabooBridgeRequest) -> SuccessResponsePolicy {
        switch request.operation {
        case .unhideApplication, .dialogClickButton, .backgroundDialogClickButton,
             .dialogEnterText, .dialogHandleFile, .dialogDismiss:
            .errorOnly
        case .quitApplication:
            .quitBoolean
        case .releaseExactWindowHeldPointer, .revokeExactWindowHeldPointer:
            .heldPointerTerminalReplay
        default:
            .ordinary
        }
    }

    private static func deliveryAgnosticFailureUnits(for request: PeekabooBridgeRequest) -> UnitPolicy? {
        switch request {
        case let .rightClickDockItem(payload) where payload.menuItem != nil:
            // Older providers can omit mixed delivery while retaining the exact two-unit progress.
            .exact(2)
        case .hideOtherApplications, .showAllApplications:
            .variable
        default:
            nil
        }
    }

    static func responseFamilies(for operation: PeekabooBridgeOperation) -> Set<ResponseFamily> {
        self.operationDescriptor(for: operation).responseFamilies
    }

    private static func responseFamilies(for request: PeekabooBridgeRequest) -> Set<ResponseFamily> {
        switch request.unwrappedOperationRequest {
        case .listApplicationMutationInventory:
            [.applicationMutationInventory]
        case .listWindowMutationInventory:
            [.windowMutationInventory]
        default:
            self.responseFamilies(for: request.operation)
        }
    }

    // Delivery is a route result, not just an operation property: several operations have bounded
    // native/AX or AX/window-targeted alternatives. Keep each alternative paired with its unit rule.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func deliveryRules(
        for request: PeekabooBridgeRequest,
        contract: Contract) -> [DeliveryRule]
    {
        let axForeground = DesktopActionOutcome.Delivery(mechanism: .accessibilityAction, mode: .foreground)
        let axBackground = DesktopActionOutcome.Delivery(mechanism: .accessibilityAction, mode: .background)
        let valueForeground = DesktopActionOutcome.Delivery(mechanism: .accessibilityValue, mode: .foreground)
        let valueBackground = DesktopActionOutcome.Delivery(mechanism: .accessibilityValue, mode: .background)
        let globalForeground = DesktopActionOutcome.Delivery(mechanism: .globalEvents, mode: .foreground)
        let processBackground = DesktopActionOutcome.Delivery(mechanism: .processTargetedEvents, mode: .background)
        let windowBackground = DesktopActionOutcome.Delivery(mechanism: .windowTargetedEvents, mode: .background)
        let nativeForeground = DesktopActionOutcome.Delivery(mechanism: .nativeFramework, mode: .foreground)
        let nativeBackground = DesktopActionOutcome.Delivery(mechanism: .nativeFramework, mode: .background)
        let clipboardForeground = DesktopActionOutcome.Delivery(
            mechanism: .clipboardTransaction,
            mode: .foreground)
        let browserBackground = DesktopActionOutcome.Delivery(mechanism: .browserProtocol, mode: .background)
        let browserForeground = DesktopActionOutcome.Delivery(mechanism: .browserProtocol, mode: .foreground)
        let compositeForeground = DesktopActionOutcome.Delivery(mechanism: .composite, mode: .foreground)
        let compositeBackground = DesktopActionOutcome.Delivery(mechanism: .composite, mode: .background)

        func rule(
            _ delivery: DesktopActionOutcome.Delivery,
            _ units: UnitPolicy,
            failureUnits: UnitPolicy? = nil) -> DeliveryRule
        {
            DeliveryRule(delivery: delivery, units: units, failureUnits: failureUnits)
        }

        switch request {
        case let .click(payload):
            switch payload.target {
            case .coordinates:
                return [rule(globalForeground, .variable)]
            case .elementId, .query:
                return [
                    rule(axForeground, .exact(1)),
                    rule(axBackground, .exact(1)),
                    rule(globalForeground, .variable),
                    rule(windowBackground, .variable),
                ]
            }
        case .type:
            return [
                rule(globalForeground, .variable),
                rule(axBackground, .variable),
                rule(valueBackground, .variable),
                rule(processBackground, .variable),
                rule(windowBackground, .variable),
            ]
        case let .scroll(payload):
            return self.scrollDeliveryRules(
                payload.request,
                axBackground: axBackground,
                valueBackground: valueBackground,
                globalForeground: globalForeground,
                windowBackground: windowBackground)
        case let .targetedScroll(payload):
            return self.scrollDeliveryRules(
                payload.request,
                axBackground: axBackground,
                valueBackground: valueBackground,
                globalForeground: globalForeground,
                windowBackground: windowBackground)
        case let .targetedClick(payload):
            return self.targetedClickDeliveryRules(
                payload,
                axBackground: axBackground,
                valueBackground: valueBackground,
                processBackground: processBackground,
                windowBackground: windowBackground)
        case .targetedHotkey:
            return [
                rule(axBackground, .variable),
                rule(processBackground, .variable),
                rule(windowBackground, .variable),
            ]
        case .exactWindowTargetedHotkey:
            return [
                rule(axBackground, .variable),
                rule(windowBackground, .variable),
            ]
        case .beginExactWindowHeldPointer:
            return [rule(windowBackground, .exact(2), failureUnits: .oneOf([1, 2, 3]))]
        case .releaseExactWindowHeldPointer, .revokeExactWindowHeldPointer,
             .disconnectExactWindowHeldPointerOwner:
            return [rule(windowBackground, .exact(1), failureUnits: .exact(2))]
        case .targetedTypeActions:
            return [rule(processBackground, .variable), rule(axBackground, .variable)]
        case .exactWindowTargetedTypeActions:
            return [rule(windowBackground, .variable), rule(axBackground, .variable)]
        case .exactWindowPixelFocusType:
            return [
                rule(compositeBackground, .positive),
                DeliveryRule(
                    delivery: valueBackground,
                    units: .positive,
                    allowsSuccessfulOutcome: false),
            ]
        case .foregroundModifierClick:
            return [
                rule(globalForeground, .positive),
                rule(compositeForeground, .positive),
                DeliveryRule(
                    delivery: nativeForeground,
                    units: .positive,
                    allowsSuccessfulOutcome: false),
                DeliveryRule(
                    delivery: valueForeground,
                    units: .positive,
                    allowsSuccessfulOutcome: false),
                DeliveryRule(
                    delivery: axForeground,
                    units: .positive,
                    allowsSuccessfulOutcome: false),
            ]
        case .typeActions, .hotkey:
            return [rule(globalForeground, .variable)]
        case .swipe, .drag, .moveMouse:
            return [rule(globalForeground, .exact(1))]
        case .setValue:
            return [rule(valueBackground, .exact(1))]
        case .performAction:
            return [rule(axBackground, .exact(1))]
        case .focusWindow:
            return [
                rule(axForeground, .positive),
                rule(valueForeground, .positive),
                rule(nativeForeground, .positive),
                rule(compositeForeground, .positive),
            ]
        case .closeWindow:
            return [
                rule(axBackground, .oneOf([1, 2])),
                rule(axForeground, .positive),
                rule(valueForeground, .positive),
                rule(valueBackground, .exact(1)),
                rule(nativeForeground, .positive),
                rule(globalForeground, .positive),
                rule(compositeForeground, .positive),
            ]
        case .moveWindow, .resizeWindow:
            return [rule(valueBackground, .exact(1))]
        case .setWindowBounds, .maximizeWindow:
            return [rule(valueBackground, .oneOf([1, 2]))]
        case .backgroundCloseWindow:
            return [rule(axBackground, .oneOf([1, 2]))]
        case .minimizeWindow, .restoreWindow:
            return [rule(valueBackground, .exact(1))]
        case .launchApplication, .activateApplication:
            return [rule(nativeForeground, .variable), rule(axForeground, .variable)]
        case let .launchApplicationWithOptions(payload):
            let native = payload.activates ? nativeForeground : nativeBackground
            return payload.activates
                ? [rule(native, .variable), rule(axForeground, .variable)]
                : [rule(native, .variable)]
        case let .relaunchApplicationWithOptions(payload):
            let native = payload.launchRequest.activates ? nativeForeground : nativeBackground
            return payload.launchRequest.activates
                ? [rule(native, .positive), rule(axForeground, .positive)]
                : [rule(native, .positive)]
        case .quitApplication:
            return [rule(nativeBackground, .exact(1))]
        case .hideApplication, .unhideApplication:
            return [rule(nativeBackground, .exact(1)), rule(axBackground, .exact(1))]
        case .hideOtherApplications, .showAllApplications:
            return [rule(axBackground, .variable), rule(nativeBackground, .variable)]
        case let .clickMenuItem(payload):
            return [rule(
                payload.deliveryMode == .background ? axBackground : axForeground,
                .positive)]
        case let .clickMenuItemByName(payload):
            return [rule(
                payload.deliveryMode == .background ? axBackground : axForeground,
                .positive)]
        case .clickMenuExtra, .clickMenuBarItemNamed, .clickMenuBarItemIndex:
            return [
                rule(axForeground, .variable),
                rule(globalForeground, .variable),
                rule(windowBackground, .variable),
            ]
        case .launchDockItem:
            return [rule(axForeground, .exact(1))]
        case let .rightClickDockItem(payload):
            guard payload.menuItem != nil else {
                return [rule(globalForeground, .exact(1))]
            }
            return [
                rule(compositeForeground, .exact(2)),
                DeliveryRule(
                    delivery: globalForeground,
                    units: .exact(1),
                    allowsSuccessfulOutcome: false),
            ]
        case .hideDock, .showDock:
            return [rule(nativeBackground, .exact(2))]
        case .dialogClickButton, .dialogDismiss:
            return [rule(axForeground, .exact(1)), rule(globalForeground, .variable)]
        case .backgroundDialogClickButton:
            return [rule(axBackground, .exact(1))]
        case .dialogEnterText:
            return [
                rule(globalForeground, .variable),
                rule(valueBackground, .variable),
                rule(processBackground, .variable),
                rule(windowBackground, .variable),
            ]
        case .exactDialogEnterText:
            return [rule(valueBackground, .oneOf([1, 2]))]
        case .dialogHandleFile:
            return [rule(globalForeground, .variable), rule(clipboardForeground, .variable)]
        case .exactDialogClickButton, .exactDialogDismiss:
            return [rule(axBackground, .exact(1))]
        case .exactDialogForceDismiss:
            return [rule(globalForeground, .exact(1))]
        case let .desktopObservation(payload):
            if case let .menubarPopover(_, openIfNeeded) = payload.target,
               openIfNeeded != nil
            {
                let pipelineMode: DesktopActionOutcome.Delivery.Mode = payload.capture.focus == .background
                    ? .background
                    : .foreground
                return [
                    rule(windowBackground, .positive),
                    rule(.init(mechanism: .capturePipeline, mode: pipelineMode), .positive),
                    DeliveryRule(
                        delivery: .init(mechanism: .composite, mode: pipelineMode),
                        units: .positive,
                        allowsSuccessfulOutcome: false),
                ]
            }
            let mode: DesktopActionOutcome.Delivery.Mode = payload.capture.focus == .background
                ? .background
                : .foreground
            return [rule(.init(mechanism: .capturePipeline, mode: mode), .variable)]
        case .captureScreen, .captureWindow, .captureFrontmost, .captureArea:
            guard contract.completion.mutatesDesktop else { return [] }
            return [rule(.init(mechanism: .capturePipeline, mode: .background), .exact(1))]
        case .detectElements, .inspectAccessibilityTree:
            return [rule(axBackground, .exact(1))]
        case .requestPostEventPermission:
            return [rule(nativeForeground, .exact(1))]
        case .agentExecutionTrace:
            return [rule(nativeBackground, .exact(1))]
        case .browserConnect:
            return [rule(browserForeground, .exact(1))]
        case .browserExecute:
            return [rule(browserBackground, .variable)]
        default:
            guard let delivery = contract.completion.fixedDelivery else { return [] }
            return [rule(delivery, .exact(1))]
        }
    }

    private static func targetedClickDeliveryRules(
        _ payload: PeekabooBridgeTargetedClickRequest,
        axBackground: DesktopActionOutcome.Delivery,
        valueBackground: DesktopActionOutcome.Delivery,
        processBackground: DesktopActionOutcome.Delivery,
        windowBackground: DesktopActionOutcome.Delivery) -> [DeliveryRule]
    {
        let ax = DeliveryRule(delivery: axBackground, units: .exact(1))
        // AXPress is absent on focusable text fields. ClickService truthfully falls back to one
        // verified AXFocused value write, which is still a single background click action.
        let value = payload.allowsAccessibilityValueDelivery != false
            ? [DeliveryRule(delivery: valueBackground, units: .exact(1))]
            : []
        let process = DeliveryRule(delivery: processBackground, units: .variable)
        let routedUnits: Int? = switch payload.clickType {
        case .single: 3
        case .longPress: nil
        case .right, .middle: 3
        case .double: 5
        case .triple: 7
        }
        let window = routedUnits.map { DeliveryRule(delivery: windowBackground, units: .exact($0)) }
        guard payload.targetWindowID != nil else {
            return switch (payload.target, payload.clickType) {
            case (.elementId, .single), (.query, .single): [ax] + value + [process]
            case (.elementId, .right), (.query, .right):
                [ax, process] + (window.map { [$0] } ?? [])
            case (.elementId, .double), (.query, .double):
                [process] + (window.map { [$0] } ?? [])
            case (.coordinates, _),
                 (.elementId, .middle), (.query, .middle),
                 (.elementId, .triple), (.query, .triple),
                 (.elementId, .longPress), (.query, .longPress): []
            }
        }
        return switch (payload.target, payload.clickType) {
        case (.coordinates, .single): window.map { [$0] } ?? []
        case (.coordinates, .right), (.coordinates, .double), (.coordinates, .middle), (.coordinates, .triple):
            window.map { [$0] } ?? []
        case (.coordinates, .longPress): []
        case (.elementId, .single), (.query, .single): [ax] + value + (window.map { [$0] } ?? [])
        case (.elementId, .right), (.query, .right): [ax] + (window.map { [$0] } ?? [])
        case (.elementId, .double), (.query, .double),
             (.elementId, .middle), (.query, .middle),
             (.elementId, .triple), (.query, .triple):
            window.map { [$0] } ?? []
        case (.elementId, .longPress), (.query, .longPress): []
        }
    }

    private static func scrollDeliveryRules(
        _ request: ScrollRequest,
        axBackground: DesktopActionOutcome.Delivery,
        valueBackground: DesktopActionOutcome.Delivery,
        globalForeground: DesktopActionOutcome.Delivery,
        windowBackground: DesktopActionOutcome.Delivery) -> [DeliveryRule]
    {
        if request.foreground {
            return [.init(delivery: globalForeground, units: .variable)]
        }
        let amount = request.amount == Int.min ? Int.max : max(1, abs(request.amount))
        let accessibilityUnits: UnitPolicy = amount == 1 ? .exact(1) : .oneOf([1, amount])
        return [
            .init(delivery: axBackground, units: accessibilityUnits),
            .init(delivery: valueBackground, units: .exact(1)),
            .init(delivery: windowBackground, units: .exact(amount)),
        ]
    }

    static func successfulOutcomeMatchesContract(
        _ outcome: DesktopActionOutcome,
        response: PeekabooBridgeResponse? = nil,
        request: PeekabooBridgeRequest) -> Bool
    {
        self.successfulOutcomeMatchesContract(
            outcome,
            response: response,
            plan: self.semanticPlan(for: request))
    }

    static func successfulOutcomeMatchesContract(
        _ outcome: DesktopActionOutcome,
        response: PeekabooBridgeResponse? = nil,
        plan: PeekabooBridgeRequestPlan) -> Bool
    {
        guard outcome.route == .bridge,
              plan.contract.completion.mutatesDesktop,
              plan.allowsSuccessState(outcome.state),
              self.successResponseMatchesPolicy(response, outcome: outcome, plan: plan)
        else { return false }
        if outcome.state == .confirmedNoChange {
            return outcome.delivery == nil && outcome.dispatchState == .none
        }
        guard let rule = plan.deliveryRule(for: outcome.delivery)
        else { return false }
        return rule.allowsSuccessfulOutcome &&
            rule.units.acceptsSuccessful(outcome.dispatchState.unitCount)
    }

    private static func successResponseMatchesPolicy(
        _ response: PeekabooBridgeResponse?,
        outcome: DesktopActionOutcome,
        plan: PeekabooBridgeRequestPlan) -> Bool
    {
        switch plan.successResponsePolicy {
        case .ordinary:
            return true
        case .errorOnly:
            return false
        case .quitBoolean:
            guard case let .bool(terminated) = response else { return false }
            if terminated {
                return [.confirmedChange, .dispatchedUnverified].contains(outcome.state)
            }
            return [.suspectedNoop, .dispatchedUnverified].contains(outcome.state)
        case .heldPointerTerminalReplay:
            if outcome.state == .dispatchedUnverified {
                return true
            }
            guard outcome.state == .confirmedNoChange,
                  case let .exactWindowHeldPointerTermination(payload) = response,
                  let termination = payload,
                  termination.reason == .ownerDisconnected,
                  termination.lifecycleDispatchedUnitCount == 0,
                  termination.cleanupOutcome.state == .confirmedNoChange,
                  termination.cleanupOutcome.dispatchState == .none,
                  termination.cleanupOutcome.delivery == nil
            else { return false }
            return true
        }
    }

    static func failureOutcomeMatchesContract(
        _ outcome: DesktopActionOutcome,
        request: PeekabooBridgeRequest) -> Bool
    {
        self.failureOutcomeMatchesContract(outcome, plan: self.semanticPlan(for: request))
    }

    static func failureOutcomeMatchesContract(
        _ outcome: DesktopActionOutcome,
        plan: PeekabooBridgeRequestPlan) -> Bool
    {
        guard outcome.route == .bridge, !outcome.isConfirmed else { return false }
        if outcome.state == .refused {
            return outcome.delivery == nil && outcome.dispatchState == .none
        }
        guard let delivery = outcome.delivery else {
            guard outcome.state == .indeterminate else { return false }
            guard let unitCount = outcome.dispatchState.unitCount else { return true }
            return plan.deliveryAgnosticFailureUnits?.acceptsSuccessful(unitCount) == true
        }
        guard let rule = plan.deliveryRule(for: delivery) else { return false }
        if let units = plan.typedResponseRule.typeActionDispatchUnits {
            return units.acceptsFailureProgress(outcome.dispatchState.unitCount)
        }
        return rule.acceptsFailureProgress(outcome.dispatchState.unitCount)
    }

    static func responseMatchesContract(
        _ response: PeekabooBridgeResponse,
        request: PeekabooBridgeRequest) -> Bool
    {
        self.semanticPlan(for: request).responseMatches(response)
    }

    static func responseMatchesContract(
        _ response: PeekabooBridgeResponse,
        plan: PeekabooBridgeRequestPlan) -> Bool
    {
        plan.responseMatches(response)
    }

    static func nonErrorResponseAllowsFailureOutcome(
        _ response: PeekabooBridgeResponse,
        outcome: DesktopActionOutcome,
        request: PeekabooBridgeRequest) -> Bool
    {
        self.nonErrorResponseAllowsFailureOutcome(
            response,
            outcome: outcome,
            plan: self.semanticPlan(for: request))
    }

    static func nonErrorResponseAllowsFailureOutcome(
        _ response: PeekabooBridgeResponse,
        outcome: DesktopActionOutcome,
        plan: PeekabooBridgeRequestPlan) -> Bool
    {
        guard plan.successResponsePolicy == .quitBoolean,
              case let .bool(terminated) = response,
              !terminated,
              outcome.state == .refused,
              outcome.refusalReason == .targetUnavailable,
              outcome.dispatchState == .none
        else { return false }
        return self.failureOutcomeMatchesContract(outcome, plan: plan)
    }

    static func finalizeSuccessful(
        request: PeekabooBridgeRequest,
        handled: PeekabooBridgeHandledResponse) throws -> PeekabooBridgeHandledResponse
    {
        try self.finalizeSuccessful(plan: self.semanticPlan(for: request), handled: handled)
    }

    static func finalizeSuccessful(
        plan: PeekabooBridgeRequestPlan,
        handled: PeekabooBridgeHandledResponse) throws -> PeekabooBridgeHandledResponse
    {
        let request = plan.request
        guard plan.vocabulary.usesCurrentResultSemantics else { return handled }
        guard plan.result.completion.mutatesDesktop else { return handled }
        if let mutation = handled.mutation {
            let outcome = self.fillingExpectedSuccessfulDispatchUnitCount(
                mutation.outcome,
                plan: plan)
            let normalized = outcome == mutation.outcome
                ? handled
                : handled.finalizingMutation(outcome: outcome, target: mutation.target)
            if self.actionFailure(in: normalized.response) != nil {
                return normalized
            }
            guard [.partial, .refused, .indeterminate].contains(outcome.state),
                  self.failureOutcomeMatchesContract(outcome.routed(to: .bridge), plan: plan),
                  let failure = DesktopActionFailure(
                      outcome: outcome.routed(to: .bridge),
                      message: "The desktop action provider returned a non-success result.",
                      hint: "Follow the canonical outcome metadata before deciding whether to retry.")
            else {
                return normalized
            }
            let failureResult: PeekabooBridgeHandledResponse
            let attributedFailure: DesktopActionFailure
            if case .responseResolved = mutation.target,
               outcome.dispatchState.mutationDispatched
            {
                guard let target = try PeekabooBridgeOperationTargetAttribution.resolve(
                    plan: plan,
                    response: normalized.response,
                    handledTarget: normalized.targetIdentity)
                else {
                    throw DesktopTargetIdentityError.incompleteExactWindow
                }
                failureResult = normalized.finalizingMutation(
                    outcome: outcome,
                    target: .handlerResolved(target))
                attributedFailure = failure.attributed(to: target.actionTargetReceipt)
            } else {
                failureResult = normalized
                attributedFailure = failure
            }
            return failureResult.replacingResponse(.error(.init(
                code: .internalError,
                actionFailure: attributedFailure)))
        }
        if let failure = self.actionFailure(in: handled.response) {
            throw failure.routed(to: .bridge)
        }
        let contract = plan.contract
        guard contract.completion.fixedDelivery != nil else {
            preconditionFailure("Mutating Bridge request has no successful result contract: \(request.operation)")
        }
        guard plan.responseMatches(handled.response) else {
            throw DesktopActionFailure.indeterminate(
                route: .bridge,
                evidence: .completionUnknown,
                message: "Bridge operation returned a response that cannot prove successful completion.",
                hint: "Observe the target before retrying and update the Bridge handler.")
        }
        let successRules = plan.successfulDeliveryRules
        guard successRules.count == 1,
              let rule = successRules.first,
              let unitCount = plan.defaultSuccessfulDispatchUnitCount(for: rule.delivery)
        else {
            throw DesktopActionFailure.indeterminate(
                route: .bridge,
                delivery: successRules.count == 1 ? successRules.first?.delivery : nil,
                evidence: .completionUnknown,
                message: "Bridge operation completed without one provable delivery route and exact dispatch count.",
                hint: "Observe the target before retrying and update the Bridge handler to return a canonical result.")
        }
        let synthesizedOutcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: rule.delivery,
            evidence: .deliveryAccepted,
            unitCount: unitCount)
        let target: PeekabooBridgeHandledResponse.Mutation.TargetDisposition
        if let identity = handled.targetIdentity {
            target = .handlerResolved(identity)
        } else {
            target = switch contract.targetPolicy {
            case .global: .global
            case .requestPinned: .requestPinned
            case .responseResolved: .responseResolved
            case .handlerRequired, .handlerResolvedOrGlobal, .external:
                throw DesktopActionFailure.indeterminate(
                    route: .bridge,
                    delivery: rule.delivery,
                    evidence: .completionUnknown,
                    message: "Bridge operation completed without its required exact target result.",
                    hint: "Observe the intended target before retrying and update the Bridge host.")
            case .notApplicable, .requestDependent:
                preconditionFailure(
                    "Mutating Bridge request has no target contract: \(request.operation)")
            }
        }
        return handled.finalizingMutation(
            outcome: synthesizedOutcome,
            target: target)
    }

    private static func actionFailure(in response: PeekabooBridgeResponse) -> DesktopActionFailure? {
        switch response {
        case let .error(envelope):
            envelope.desktopActionFailure
        case let .browserToolResponse(response):
            response.actionFailure
        case let .projectedAction(projected):
            self.actionFailure(in: projected.response)
        case let .attestedOperation(attested):
            self.actionFailure(in: attested.response)
        default:
            nil
        }
    }

    private static func fillingExpectedSuccessfulDispatchUnitCount(
        _ outcome: DesktopActionOutcome,
        plan: PeekabooBridgeRequestPlan) -> DesktopActionOutcome
    {
        guard outcome.dispatchState.unitCount == nil,
              let delivery = outcome.delivery,
              let unitCount = plan.defaultSuccessfulDispatchUnitCount(for: delivery)
        else { return outcome }
        return outcome.fillingSuccessfulDispatchUnitCount(unitCount)
    }

    static func canonicalFailure(
        _ envelope: PeekabooBridgeErrorEnvelope,
        request: PeekabooBridgeRequest,
        stage: FailureStage) -> PeekabooBridgeErrorEnvelope
    {
        self.canonicalFailure(
            envelope,
            plan: self.semanticPlan(for: request),
            stage: stage)
    }

    static func canonicalFailure(
        _ envelope: PeekabooBridgeErrorEnvelope,
        plan: PeekabooBridgeRequestPlan,
        stage: FailureStage) -> PeekabooBridgeErrorEnvelope
    {
        let usesCurrentVocabulary = plan.vocabulary.usesCurrentResultSemantics
        let compatibleEnvelope = usesCurrentVocabulary
            ? envelope
            : self.removingReceiptOnlyFailureVocabulary(from: envelope)
        if !usesCurrentVocabulary, case .preDispatch(.requestCancelled) = stage {
            // No legacy refusal describes caller cancellation without prescribing the wrong
            // remediation. Preserve the generic timeout envelope and omit canonical fields.
            return compatibleEnvelope
        }
        let compatibleStage: FailureStage = if usesCurrentVocabulary {
            stage
        } else {
            switch stage {
            case .preDispatch(.transportSessionUnavailable):
                // Protocol 1.28 and earlier know neither the transport-session refusal nor its
                // reconnect escalation. Runtime incompatibility is the closest pre-dispatch,
                // retry-safe legacy refusal and also prevents an outer route catch from turning a
                // daemon admission refusal into an unsafe, may-have-dispatched result.
                .preDispatch(.runtimeIncompatible)
            default:
                stage
            }
        }
        guard plan.result.completion.mutatesDesktop, compatibleEnvelope.actionOutcome == nil else {
            return compatibleEnvelope
        }
        let failure: DesktopActionFailure = switch compatibleStage {
        case let .preDispatch(reason):
            .preDispatchRefusal(
                route: .bridge,
                reason: reason,
                message: compatibleEnvelope.message,
                hint: self.preDispatchHint(for: reason),
                causeDescription: compatibleEnvelope.details)
        case .executionMayHaveStarted:
            .indeterminate(
                route: .bridge,
                evidence: .completionUnknown,
                message: compatibleEnvelope.message,
                hint: "Observe the intended target before retrying this operation.",
                causeDescription: compatibleEnvelope.details)
        }
        return .init(
            code: compatibleEnvelope.code,
            actionFailure: failure,
            details: compatibleEnvelope.details,
            permission: compatibleEnvelope.permission,
            kind: compatibleEnvelope.kind,
            context: compatibleEnvelope.context)
    }

    private static func removingReceiptOnlyFailureVocabulary(
        from envelope: PeekabooBridgeErrorEnvelope) -> PeekabooBridgeErrorEnvelope
    {
        guard let outcome = envelope.actionOutcome?.outcome,
              outcome.refusalReason == .transportSessionUnavailable ||
              outcome.refusalReason == .requestCancelled ||
              outcome.escalation == .reconnectSession
        else {
            return envelope
        }
        return envelope.legacyCompatible
    }

    static func validateSuccessfulTargetDisposition(
        request: PeekabooBridgeRequest,
        handled: PeekabooBridgeHandledResponse) throws
    {
        try self.validateSuccessfulTargetDisposition(
            plan: self.semanticPlan(for: request),
            handled: handled)
    }

    static func validateSuccessfulTargetDisposition(
        plan: PeekabooBridgeRequestPlan,
        handled: PeekabooBridgeHandledResponse) throws
    {
        guard plan.result.completion.mutatesDesktop else { return }
        guard !self.isNoDispatchFailure(handled.response) else { return }
        let policy = plan.target.policy
        guard let mutation = handled.mutation else {
            guard self.isDispatchedFailure(handled.response) else {
                throw DesktopTargetIdentityError.incompleteExactWindow
            }
            switch policy {
            case .global:
                break
            case .requestPinned:
                guard try PeekabooBridgeOperationTargetAttribution.resolveRequest(plan) != nil else {
                    throw DesktopTargetIdentityError.incompleteExactWindow
                }
            case .handlerRequired, .handlerResolvedOrGlobal, .responseResolved, .external:
                guard self.actionFailure(in: handled.response)?.targetReceipt != nil else {
                    throw DesktopTargetIdentityError.incompleteExactWindow
                }
            case .notApplicable, .requestDependent:
                throw DesktopTargetIdentityError.incompleteExactWindow
            }
            // A projected error has no successful handler disposition to preserve. For a
            // global operation the plan is sufficient target evidence; for request-pinned
            // operations the exact request identity was revalidated before provider dispatch;
            // otherwise the typed failure must carry the provider-resolved target receipt.
            return
        }
        let valid = switch (policy, mutation.target) {
        case (.global, .global),
             (.requestPinned, .requestPinned),
             (.requestPinned, .handlerResolved),
             (.handlerRequired, .handlerResolved),
             (.handlerResolvedOrGlobal, .handlerResolved),
             (.responseResolved, .responseResolved),
             (.responseResolved, .handlerResolved):
            true
        case (.handlerResolvedOrGlobal, .global):
            mutation.outcome.state == .confirmedNoChange &&
                mutation.outcome.dispatchState == .none &&
                mutation.outcome.delivery == nil
        case (.external, .handlerResolved), (.external, .responseResolved), (.external, .externalBrowser):
            // A process/window identity is an accepted conservative target for an external
            // object. Bare `.external` only names the need and is not itself target evidence.
            true
        case (.notApplicable, _), (.requestDependent, _), (.handlerResolvedOrGlobal, _),
             (_, .external), (_, .externalBrowser),
             (_, .global), (_, .requestPinned), (_, .responseResolved),
             (_, .handlerResolved):
            false
        }
        guard valid else { throw DesktopTargetIdentityError.incompleteExactWindow }
    }

    private static func isDispatchedFailure(_ response: PeekabooBridgeResponse) -> Bool {
        let outcome: DesktopActionOutcome?
        switch response {
        case let .error(envelope):
            outcome = envelope.actionOutcome?.outcome
        case let .projectedAction(projected):
            guard case let .error(envelope) = projected.response else { return false }
            outcome = projected.outcome?.outcome ?? envelope.actionOutcome?.outcome
        default:
            return false
        }
        guard let outcome else { return false }
        return !outcome.isConfirmed && outcome.dispatchState.mutationDispatched
    }

    static func isNoDispatchFailure(_ response: PeekabooBridgeResponse) -> Bool {
        let outcome: DesktopActionOutcome?
        switch response {
        case let .error(envelope):
            outcome = envelope.actionOutcome?.outcome
        case let .browserToolResponse(browserResponse):
            outcome = browserResponse.actionFailure?.outcome
        case let .projectedAction(projected):
            switch projected.response {
            case let .error(envelope):
                outcome = projected.outcome?.outcome ?? envelope.actionOutcome?.outcome
            case let .browserToolResponse(browserResponse):
                outcome = projected.outcome?.outcome ?? browserResponse.actionFailure?.outcome
            default:
                return false
            }
        default:
            return false
        }
        guard let outcome else { return false }
        return outcome.dispatchState.mutationDispatched == false
    }

    static func preDispatchReason(
        for envelope: PeekabooBridgeErrorEnvelope) -> DesktopActionOutcome.RefusalReason
    {
        switch envelope.code {
        case .permissionDenied:
            .permissionDenied
        case .unauthorizedClient:
            .transportSessionUnavailable
        case .notFound:
            .targetUnavailable
        case .operationNotSupported:
            .operationUnsupported
        case .versionMismatch:
            .runtimeIncompatible
        case .serverBusy, .timeout:
            .transportSessionUnavailable
        case .invalidRequest, .decodingFailed:
            .invalidRequest
        case .internalError:
            .runtimeIncompatible
        }
    }

    private static func preDispatchHint(for reason: DesktopActionOutcome.RefusalReason) -> String {
        switch reason {
        case .invalidRequest:
            "Correct the request before retrying."
        case .permissionDenied:
            "Grant the required permission before retrying."
        case .targetUnavailable:
            "Refresh the exact target before retrying."
        case .transportSessionUnavailable:
            "Reconnect the Bridge session before retrying."
        case .requestCancelled:
            "Submit a new request only if the operation is still wanted."
        case .runtimeIncompatible:
            "Update the Bridge runtime before retrying."
        case .foregroundConsentRequired:
            "Retry only with explicit foreground consent."
        case .operationUnsupported:
            "Use a host that supports this operation."
        }
    }
}
