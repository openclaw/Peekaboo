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
        case browserSessionBootstrap
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
        let fixedTextEventKeyPresses: Int
        let fixedSpecialEventKeyPresses: Int
        let fixedEventDispatchUnits: Int
        let flexibleTextAccessibilityUnits: Int
        let flexibleSpecialAccessibilityUnits: Int
        let noChangeCapableAccessibilityKeys: Int
        let flexibleClearCount: Int
        let additionalAccessibilityUnits: Int
        let allowsConfirmedChange: Bool

        init(
            actions: [TypeAction],
            allowsAccessibilityValueDelivery: Bool = false,
            additionalDispatchUnits: Int = 0,
            additionalUsesAccessibilityValue: Bool = false,
            allowsConfirmedChange: Bool = false)
        {
            var totalCharacters = 0
            var fixedTextEventKeyPresses = 0
            var fixedSpecialEventKeyPresses = 0
            var fixedEventDispatchUnits = 0
            var flexibleTextAccessibilityUnits = 0
            var flexibleSpecialAccessibilityUnits = 0
            var noChangeCapableAccessibilityKeys = 0
            var flexibleClearCount = 0
            for action in actions {
                switch action {
                case let .text(text):
                    totalCharacters += text.count
                    if allowsAccessibilityValueDelivery {
                        flexibleTextAccessibilityUnits += text.count
                    } else {
                        fixedTextEventKeyPresses += text.count
                        fixedEventDispatchUnits += text.count
                    }
                case let .key(key):
                    if allowsAccessibilityValueDelivery, key.mayUseAccessibilityValueDelivery {
                        if key.mayCompleteWithoutDispatch {
                            noChangeCapableAccessibilityKeys += 1
                        } else {
                            flexibleSpecialAccessibilityUnits += 1
                        }
                    } else {
                        fixedSpecialEventKeyPresses += 1
                        fixedEventDispatchUnits += 1
                    }
                case .clear:
                    if allowsAccessibilityValueDelivery {
                        flexibleClearCount += 1
                    } else {
                        fixedSpecialEventKeyPresses += 2
                        fixedEventDispatchUnits += 2
                    }
                }
            }
            self.totalCharacters = totalCharacters
            self.fixedTextEventKeyPresses = fixedTextEventKeyPresses
            self.fixedSpecialEventKeyPresses = fixedSpecialEventKeyPresses
            self.fixedEventDispatchUnits = fixedEventDispatchUnits
            self.flexibleTextAccessibilityUnits = flexibleTextAccessibilityUnits
            self.flexibleSpecialAccessibilityUnits = flexibleSpecialAccessibilityUnits
            self.noChangeCapableAccessibilityKeys = noChangeCapableAccessibilityKeys
            self.flexibleClearCount = flexibleClearCount
            self.additionalAccessibilityUnits = additionalUsesAccessibilityValue ? additionalDispatchUnits : 0
            self.allowsConfirmedChange = allowsConfirmedChange && Self.isDeterministicClearLiteral(actions)
            precondition(additionalUsesAccessibilityValue || additionalDispatchUnits == 0)
        }

        var dispatchUnits: UnitPolicy {
            let minimum = self.minimumDispatchUnits
            let maximum = self.maximumDispatchUnits
            return minimum == maximum ? .exact(minimum) : .oneOf(Array(minimum...maximum))
        }

        var hasPositiveDispatch: Bool {
            self.maximumDispatchUnits > 0
        }

        func accepts(
            keyPresses: Int,
            specialKeyPresses: Int?,
            outcome: DesktopActionOutcome) -> Bool
        {
            guard outcome.state != .confirmedChange || self.allowsConfirmedChange else { return false }
            let dispatchUnits: Int
            let expectedUsesAccessibility: Bool
            let expectedUsesKeyboard: Bool
            switch outcome.dispatchState {
            case .none:
                guard outcome.state == .confirmedNoChange, outcome.delivery == nil else { return false }
                dispatchUnits = 0
                expectedUsesAccessibility = false
                expectedUsesKeyboard = false
            case let .dispatched(unitCount):
                guard let unitCount,
                      let deliveryShape = Self.deliveryShape(outcome.delivery)
                else { return false }
                dispatchUnits = unitCount.rawValue
                expectedUsesAccessibility = deliveryShape.usesAccessibility
                expectedUsesKeyboard = deliveryShape.usesKeyboard
            case .mayHaveDispatched:
                return false
            }

            let baseUnits = self.minimumDispatchUnits
            for fallbackClearCount in 0...self.flexibleClearCount {
                let activeNoChangeKeys = dispatchUnits - baseUnits - fallbackClearCount
                guard (0...self.noChangeCapableAccessibilityKeys).contains(activeNoChangeKeys) else { continue }

                if let specialKeyPresses {
                    if self.acceptsExplicitSpecialKeyCount(
                        keyPresses: keyPresses,
                        specialKeyPresses: specialKeyPresses,
                        activeNoChangeKeys: activeNoChangeKeys,
                        fallbackClearCount: fallbackClearCount,
                        expectedDeliveryShape: (
                            usesAccessibility: expectedUsesAccessibility,
                            usesKeyboard: expectedUsesKeyboard))
                    {
                        return true
                    }
                    continue
                }

                let flexibleEventKeyPresses = keyPresses - self.fixedEventKeyPresses - fallbackClearCount * 2
                guard flexibleEventKeyPresses >= 0 else { continue }
                let minimumFlexibleEvents = max(
                    0,
                    flexibleEventKeyPresses - activeNoChangeKeys)
                let maximumFlexibleEvents = min(
                    self.flexibleAccessibilityUnits,
                    flexibleEventKeyPresses)
                guard minimumFlexibleEvents <= maximumFlexibleEvents else { continue }

                let usesKeyboard = self.fixedEventDispatchUnits > 0 ||
                    flexibleEventKeyPresses > 0 || fallbackClearCount > 0
                guard usesKeyboard == expectedUsesKeyboard else { continue }

                let accessibilityIsUnavoidable = self.additionalAccessibilityUnits > 0 ||
                    fallbackClearCount < self.flexibleClearCount
                let noAccessibilityCandidate = !accessibilityIsUnavoidable &&
                    maximumFlexibleEvents == self.flexibleAccessibilityUnits &&
                    activeNoChangeKeys - flexibleEventKeyPresses + maximumFlexibleEvents == 0
                let candidateCount = maximumFlexibleEvents - minimumFlexibleEvents + 1
                let hasAccessibilityCandidate = accessibilityIsUnavoidable ||
                    !noAccessibilityCandidate || candidateCount > 1
                if expectedUsesAccessibility ? hasAccessibilityCandidate : noAccessibilityCandidate {
                    return true
                }
            }
            return false
        }

        private func acceptsExplicitSpecialKeyCount(
            keyPresses: Int,
            specialKeyPresses: Int,
            activeNoChangeKeys: Int,
            fallbackClearCount: Int,
            expectedDeliveryShape: (usesAccessibility: Bool, usesKeyboard: Bool)) -> Bool
        {
            guard specialKeyPresses >= 0, specialKeyPresses <= keyPresses else { return false }
            let textEvents = keyPresses - specialKeyPresses - self.fixedTextEventKeyPresses
            guard (0...self.flexibleTextAccessibilityUnits).contains(textEvents) else { return false }
            let flexibleSpecialEvents = specialKeyPresses - self.fixedSpecialEventKeyPresses -
                fallbackClearCount * 2
            guard flexibleSpecialEvents >= 0 else { return false }
            let minimumSpecialEvents = max(0, flexibleSpecialEvents - activeNoChangeKeys)
            let maximumSpecialEvents = min(
                self.flexibleSpecialAccessibilityUnits,
                flexibleSpecialEvents)
            guard minimumSpecialEvents <= maximumSpecialEvents else { return false }

            for directCapableSpecialEvents in minimumSpecialEvents...maximumSpecialEvents {
                let noChangeKeyEvents = flexibleSpecialEvents - directCapableSpecialEvents
                let usesAccessibility = self.additionalAccessibilityUnits > 0 ||
                    fallbackClearCount < self.flexibleClearCount ||
                    textEvents < self.flexibleTextAccessibilityUnits ||
                    directCapableSpecialEvents < self.flexibleSpecialAccessibilityUnits ||
                    noChangeKeyEvents < activeNoChangeKeys
                let usesKeyboard = self.fixedEventDispatchUnits > 0 || textEvents > 0 ||
                    directCapableSpecialEvents > 0 || noChangeKeyEvents > 0 || fallbackClearCount > 0
                if usesAccessibility == expectedDeliveryShape.usesAccessibility,
                   usesKeyboard == expectedDeliveryShape.usesKeyboard
                {
                    return true
                }
            }
            return false
        }

        private var fixedEventKeyPresses: Int {
            self.fixedTextEventKeyPresses + self.fixedSpecialEventKeyPresses
        }

        private var flexibleAccessibilityUnits: Int {
            self.flexibleTextAccessibilityUnits + self.flexibleSpecialAccessibilityUnits
        }

        private var minimumDispatchUnits: Int {
            self.fixedEventDispatchUnits + self.flexibleAccessibilityUnits + self.flexibleClearCount +
                self.additionalAccessibilityUnits
        }

        private var maximumDispatchUnits: Int {
            self.minimumDispatchUnits + self.noChangeCapableAccessibilityKeys + self.flexibleClearCount
        }

        private static func deliveryShape(
            _ delivery: DesktopActionOutcome.Delivery?) -> (usesAccessibility: Bool, usesKeyboard: Bool)?
        {
            guard let delivery else { return nil }
            return switch delivery.mechanism {
            case .accessibilityValue:
                (true, false)
            case .composite:
                (true, true)
            case .globalEvents, .processTargetedEvents, .windowTargetedEvents:
                (false, true)
            default:
                nil
            }
        }

        private static func isDeterministicClearLiteral(_ actions: [TypeAction]) -> Bool {
            guard let first = actions.first, case .clear = first else { return false }
            return actions.dropFirst().allSatisfy { action in
                guard case let .text(text) = action else { return false }
                return text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
            }
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

        var typeActionAllowsConfirmedChange: Bool? {
            guard case let .typeActions(rule) = self else { return nil }
            return rule.allowsConfirmedChange
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
            case (.typeActions, .error), (.setValue, .error), (.performAction, .error):
                // A canonical failure has no success payload to bind. Its outcome, target receipt,
                // and dispatch count are validated by the failure and receipt contracts instead.
                return
            case let (.typeActions(expected), .typeResult(result)):
                guard expected.hasPositiveDispatch else {
                    throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                        "type response zero-emission success")
                }
                guard result.totalCharacters == expected.totalCharacters
                else {
                    throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                        "type response request counts")
                }
                guard let outcome,
                      expected.accepts(
                          keyPresses: result.keyPresses,
                          specialKeyPresses: result.specialKeyPresses,
                          outcome: outcome)
                else {
                    throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                        "type response key and dispatch units")
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
