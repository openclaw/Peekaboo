import Foundation
@_spi(Bridge) import PeekabooAutomationKit
import PeekabooFoundation

@MainActor
extension PeekabooBridgeServer {
    func handleCaptureRequest(_ request: PeekabooBridgeRequest) async throws
        -> PeekabooBridgeResponse
    {
        switch request {
        case let .captureScreen(payload):
            let capture = try await self.services.screenCapture.captureScreen(
                displayIndex: payload.displayIndex,
                visualizerMode: payload.visualizerMode,
                scale: payload.scale)
            return .capture(capture)
        case let .captureWindow(payload):
            return try await self.handleCaptureWindow(payload)
        case let .captureFrontmost(payload):
            let capture = try await self.services.screenCapture.captureFrontmost(
                visualizerMode: payload.visualizerMode,
                scale: payload.scale)
            return .capture(capture)
        case let .captureArea(payload):
            let capture = try await self.services.screenCapture.captureArea(
                payload.rect,
                visualizerMode: payload.visualizerMode,
                scale: payload.scale)
            return .capture(capture)
        default:
            throw Self.invalidRequest(for: request)
        }
    }

    private func handleCaptureWindow(
        _ payload: PeekabooBridgeCaptureWindowRequest) async throws -> PeekabooBridgeResponse
    {
        if let windowID = try payload.validatedWindowID() {
            let capture = try await self.services.screenCapture.captureWindow(
                windowID: windowID,
                visualizerMode: payload.visualizerMode,
                scale: payload.scale)
            return .capture(capture)
        }

        guard !payload.appIdentifier.isEmpty else {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "captureWindow requires appIdentifier or windowId")
        }

        let capture = try await self.services.screenCapture.captureWindow(
            appIdentifier: payload.appIdentifier,
            windowIndex: payload.windowIndex,
            visualizerMode: payload.visualizerMode,
            scale: payload.scale)
        return .capture(capture)
    }

    func handleDesktopObservationRequest(_ request: PeekabooBridgeRequest) async throws
        -> PeekabooBridgeHandledResponse
    {
        switch request {
        case let .desktopObservation(payload):
            try Self.validateAttestedWebFocusTarget(payload)
            let hostRegisteredScreenCaptureKitOwnership = self.hostCapabilities.contains(
                PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership)
            let currentScreenCaptureKitOwnerReceipt: ScreenCaptureKitOwnerLease.OwnerReceipt? = if
                hostRegisteredScreenCaptureKitOwnership,
                payload.capture.engine == .auto,
                payload.capture.focus == .background,
                case .screen = payload.target
            {
                try? self.screenCaptureKitOwnerClaimProvider()
            } else {
                nil
            }
            let prefersModernFirstAutomaticCapture = Self.desktopObservationPrefersModernFirstAutomaticCapture(
                payload,
                hostRegisteredScreenCaptureKitOwnership: hostRegisteredScreenCaptureKitOwnership,
                hostIdentity: self.hostIdentity,
                currentScreenCaptureKitOwnerReceipt: currentScreenCaptureKitOwnerReceipt)
            if self.services.desktopObservation is any DesktopObservationActionResultProviding {
                let result = try await ScreenCaptureService.withModernFirstAutomaticCapture(
                    prefersModernFirstAutomaticCapture)
                {
                    try await self.services.desktopObservation.observeResult(payload)
                }
                try Self.validateAttestedObservationBinding(
                    payload,
                    result: result.payload,
                    requireContentDigest: false)
                let attested = try result.payload.attestingCaptureContent()
                try Self.validateAttestedObservationBinding(payload, result: attested)
                let response = PeekabooBridgeResponse.desktopObservation(attested.withoutImageData())
                guard request.mayMutateDesktop else {
                    if let failure = Self.readOnlyObservationFailure(result) {
                        let target = try PeekabooBridgeOperationTargetAttribution.resolve(
                            request: request,
                            response: response,
                            handledTarget: result.targetIdentity)
                        return .init(
                            response: .error(
                                .init(
                                    code: .internalError,
                                    actionFailure: failure.routed(to: .bridge))),
                            targetIdentity: target)
                    }
                    return .init(response: response, targetIdentity: result.targetIdentity)
                }
                let outcome = try Self.requireSuccessfulObservationOutcome(result)
                let target =
                    result.targetIdentity.map {
                        PeekabooBridgeHandledResponse.Mutation.TargetDisposition.handlerResolved($0)
                    } ?? Self.observationFallbackTarget(for: payload)
                if let failure = Self.observationFailure(result, outcome: outcome) {
                    return .init(
                        response: .error(
                            .init(
                                code: .internalError,
                                actionFailure: failure.routed(to: .bridge))),
                        mutation: .init(outcome: outcome, target: target))
                }
                return .init(
                    response: response,
                    mutation: .init(outcome: outcome, target: target))
            }
            if case let .menubarPopover(_, openIfNeeded) = payload.target,
               openIfNeeded != nil
            {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .runtimeIncompatible,
                    message: "Menu-bar popover opening requires an action-result-aware observation service.",
                    hint: "Update the runtime host before retrying this conditional background mutation.")
            }
            let observation = try await ScreenCaptureService.withModernFirstAutomaticCapture(
                prefersModernFirstAutomaticCapture)
            {
                try await self.services.desktopObservation.observe(payload)
            }
            try Self.validateAttestedObservationBinding(
                payload,
                result: observation,
                requireContentDigest: false)
            let attested = try observation.attestingCaptureContent()
            try Self.validateAttestedObservationBinding(payload, result: attested)
            let response = PeekabooBridgeResponse.desktopObservation(attested.withoutImageData())
            guard request.mayMutateDesktop else {
                return .init(response: response)
            }
            let mode: DesktopActionOutcome.Delivery.Mode =
                payload.capture.focus == .background
                    ? .background
                    : .foreground
            return .init(
                response: response,
                mutation: .init(
                    outcome: .dispatchedUnverified(
                        delivery: .init(mechanism: .capturePipeline, mode: mode),
                        evidence: .deliveryAccepted,
                        unitCount: .one),
                    target: Self.observationFallbackTarget(for: payload)))
        default:
            throw Self.invalidRequest(for: request)
        }
    }

    /// A Bridge-owned ScreenCaptureKit process can capture a background display directly. Keeping `auto` as
    /// classic-first here serializes every request behind `/usr/sbin/screencapture`; that helper can stall despite the
    /// host's usable ScreenCaptureKit grant and consume half of the Bridge deadline before modern fallback begins.
    /// Registration and preparation do not claim the process-lifetime lease. The eligible request therefore claims
    /// it atomically, then requires the returned live receipt to match this Bridge generation before selecting a
    /// scoped modern-first automatic order. Legacy remains the fallback, and explicit engine choices plus
    /// caller-local capture retain their existing contracts.
    static func desktopObservationPrefersModernFirstAutomaticCapture(
        _ request: DesktopObservationRequest,
        hostRegisteredScreenCaptureKitOwnership: Bool,
        hostIdentity: PeekabooBridgeHostIdentity?,
        currentScreenCaptureKitOwnerReceipt: ScreenCaptureKitOwnerLease.OwnerReceipt?)
        -> Bool
    {
        guard hostRegisteredScreenCaptureKitOwnership,
              let hostIdentity,
              let hostProcessStartIdentity = hostIdentity.processStartIdentity,
              let currentScreenCaptureKitOwnerReceipt,
              currentScreenCaptureKitOwnerReceipt.processIdentifier == hostIdentity.processIdentifier,
              currentScreenCaptureKitOwnerReceipt.processStartIdentity == hostProcessStartIdentity,
              request.capture.engine == .auto,
              request.capture.focus == .background,
              case .screen = request.target
        else { return false }
        return true
    }

    private static func readOnlyObservationFailure(
        _ result: UIAutomationActionResult<DesktopObservationResult>) -> DesktopActionFailure?
    {
        guard let outcome = result.outcome else { return nil }
        let targetReceipt = result.targetIdentity?.actionTargetReceipt
        if outcome.state == .confirmedNoChange,
           outcome.delivery == nil,
           outcome.dispatchState == .none
        {
            return nil
        }
        if let failure = DesktopActionFailure(
            outcome: outcome,
            message: "Read-only desktop observation returned a non-success or dispatching outcome.",
            hint: "Observe the target before retrying and update the runtime host.",
            targetReceipt: targetReceipt)
        {
            return failure
        }
        return DesktopActionFailure.indeterminate(
            route: outcome.route,
            delivery: outcome.delivery,
            evidence: .completionUnknown,
            unitCount: outcome.dispatchState.unitCount,
            message: "Read-only desktop observation contradicted its no-dispatch contract.",
            hint: "Observe the target before retrying and update the runtime host.")
            .attributed(to: targetReceipt)
    }
}
