import AppKit
import AXorcist
import CoreGraphics
import Darwin
import Foundation
import PeekabooFoundation

enum WindowRoutedPointerTransport: Equatable, Sendable {
    case publicCGEvent
    case skyLight
}

/// Posts a pixel-addressed pointer sequence to one exact background window.
///
/// Every event carries both screen and window-local coordinates plus the target PID/window routing
/// fields. The physical cursor is never warped and no activation API is called. The exact window
/// owner, owner process generation, and bounds are revalidated before every event boundary.
@MainActor
struct WindowRoutedPointerDriver {
    struct RouteReceipt: Equatable, Sendable {
        let identity: WindowMutationIdentity
        let bounds: CGRect
        let screenPoint: CGPoint
        let windowLayer: Int

        init(
            identity: WindowMutationIdentity,
            bounds: CGRect,
            screenPoint: CGPoint,
            windowLayer: Int = Int(CGWindowLevelForKey(.normalWindow)))
        {
            self.identity = identity
            self.bounds = bounds
            self.screenPoint = screenPoint
            self.windowLayer = windowLayer
        }

        var windowPoint: CGPoint {
            CGPoint(
                x: self.screenPoint.x - self.bounds.minX,
                y: self.screenPoint.y - self.bounds.minY)
        }
    }

    struct EventSpecification: Equatable, Sendable {
        let type: CGEventType
        let button: CGMouseButton
        let clickState: Int64
        let buttonNumber: Int64
    }

    private struct DispatchContext {
        let receipt: RouteReceipt
        let clickGroup: Int64
        let transport: WindowRoutedPointerTransport
    }

    struct HeldPointerDispatch: Sendable {
        let receipt: RouteReceipt
        let clickGroup: Int64
        let transport: WindowRoutedPointerTransport
        let down: EventSpecification
        let up: EventSpecification
    }

    enum HeldPointerRouteState: Equatable, Sendable {
        case current
        case windowChanged
        case processGenerationChanged
    }

    typealias RouteResolver = @MainActor (
        _ pid: pid_t,
        _ windowID: CGWindowID,
        _ point: CGPoint) throws -> RouteReceipt
    typealias RouteValidator = @MainActor (_ receipt: RouteReceipt) -> Bool
    typealias ProcessGenerationValidator = @MainActor (_ receipt: RouteReceipt) -> Bool
    typealias EventFactory = @MainActor (
        _ specification: EventSpecification,
        _ screenPoint: CGPoint) -> CGEvent?
    typealias ScrollEventFactory = @MainActor (
        _ direction: PeekabooFoundation.ScrollDirection,
        _ screenPoint: CGPoint) -> CGEvent?
    typealias WindowLocationStamper = @MainActor (_ event: CGEvent, _ windowPoint: CGPoint) -> Bool
    typealias EventPoster = @MainActor (_ event: CGEvent, _ pid: pid_t) -> Void
    typealias SkyLightEventPoster = @MainActor (_ event: CGEvent, _ pid: pid_t) -> Bool
    typealias TransportResolver = @MainActor (_ pid: pid_t) -> WindowRoutedPointerTransport
    typealias ApplicationVisibilityValidator = @MainActor (_ pid: pid_t) -> Bool
    typealias WindowVisibilityValidator = @MainActor (_ receipt: RouteReceipt) -> Bool
    typealias Sleeper = @MainActor (_ duration: Duration) async -> Void

    private let hasPostEventAccess: () -> Bool
    private let resolveRoute: RouteResolver
    private let routeIsCurrent: RouteValidator
    private let processGenerationIsCurrent: ProcessGenerationValidator
    private let makeEvent: EventFactory
    private let makeScrollEvent: ScrollEventFactory
    private let stampWindowLocation: WindowLocationStamper
    private let postSkyLight: SkyLightEventPoster
    private let postPublic: EventPoster
    private let resolveTransport: TransportResolver
    private let applicationIsVisible: ApplicationVisibilityValidator
    private let windowIsVisible: WindowVisibilityValidator
    private let sleep: Sleeper
    private let clickGroupIdentifier: () -> Int64

    init(
        hasPostEventAccess: @escaping () -> Bool = { CGPreflightPostEventAccess() },
        resolveRoute: @escaping RouteResolver = Self.resolveLiveRoute,
        routeIsCurrent: @escaping RouteValidator = Self.validateLiveRoute,
        processGenerationIsCurrent: @escaping ProcessGenerationValidator = Self.validateLiveProcessGeneration,
        makeEvent: @escaping EventFactory = Self.makeCGEvent,
        makeScrollEvent: @escaping ScrollEventFactory = Self.makeCGScrollEvent,
        stampWindowLocation: @escaping WindowLocationStamper = WindowRoutedPointerSPI.setWindowLocation,
        postSkyLight: @escaping SkyLightEventPoster = WindowRoutedPointerSPI.postToPid,
        postPublic: @escaping EventPoster = { event, pid in event.postToPid(pid) },
        resolveTransport: @escaping TransportResolver = Self.resolveLiveTransport,
        applicationIsVisible: @escaping ApplicationVisibilityValidator =
            WindowRoutedApplicationClassifier.applicationIsVisible,
        windowIsVisible: @escaping WindowVisibilityValidator = Self.validateLiveWindowVisibility,
        sleep: @escaping Sleeper = { duration in
            // A mouse-down must always be paired with its mouse-up. Detached sleeping makes the
            // short down/up interval non-cancellable; cancellation is observed immediately after
            // the completed pair and before a second click begins.
            _ = await Task.detached {
                try? await Task.sleep(for: duration)
            }.value
        },
        clickGroupIdentifier: @escaping () -> Int64 = {
            Int64(bitPattern: DispatchTime.now().uptimeNanoseconds)
        })
    {
        self.hasPostEventAccess = hasPostEventAccess
        self.resolveRoute = resolveRoute
        self.routeIsCurrent = routeIsCurrent
        self.processGenerationIsCurrent = processGenerationIsCurrent
        self.makeEvent = makeEvent
        self.makeScrollEvent = makeScrollEvent
        self.stampWindowLocation = stampWindowLocation
        self.postSkyLight = postSkyLight
        self.postPublic = postPublic
        self.resolveTransport = resolveTransport
        self.applicationIsVisible = applicationIsVisible
        self.windowIsVisible = windowIsVisible
        self.sleep = sleep
        self.clickGroupIdentifier = clickGroupIdentifier
    }

    func click(
        at point: CGPoint,
        button: MouseButton,
        count: Int,
        targetProcessIdentifier: pid_t,
        targetWindowID: CGWindowID,
        expectedWindowIdentity: WindowMutationIdentity? = nil,
        expectedWindowBounds: CGRect? = nil,
        allowedWindowLayers: Set<Int> = [Int(CGWindowLevelForKey(.normalWindow))]) async throws
        -> DesktopActionOutcome
    {
        guard button == .left || button == .right || button == .middle else {
            throw PeekabooError.serviceUnavailable(
                "Window-routed background pointer delivery supports left, right, and middle buttons only")
        }
        guard (1...3).contains(count) else {
            throw PeekabooError.invalidInput("Window-routed click count must be between 1 and 3")
        }
        guard self.hasPostEventAccess() else {
            throw PeekabooError.permissionDeniedEventSynthesizing
        }
        try Task.checkCancellation()

        let receipt = try self.resolveRoute(targetProcessIdentifier, targetWindowID, point)
        guard receipt.identity.ownerProcessIdentifier == targetProcessIdentifier,
              receipt.identity.windowID == Int(targetWindowID),
              allowedWindowLayers.contains(receipt.windowLayer),
              receipt.bounds.contains(point),
              expectedWindowIdentity.map({ $0 == receipt.identity }) ?? true,
              expectedWindowBounds.map({ $0 == receipt.bounds }) ?? true
        else {
            throw PeekabooError.snapshotStale(
                "Resolved background pointer route does not match the requested PID, window, or point")
        }
        let clickGroup = self.clickGroupIdentifier()
        let transport = self.resolveTransport(targetProcessIdentifier)
        var postedEventCount = 0

        let primer = EventSpecification(
            type: .mouseMoved,
            button: .left,
            clickState: 0,
            buttonNumber: 0)
        try self.post(
            primer,
            receipt: receipt,
            clickGroup: clickGroup,
            transport: transport,
            postedEventCount: &postedEventCount)
        await self.sleep(.milliseconds(12))

        for pairIndex in 0..<count {
            try Self.checkCancellation(afterPosting: postedEventCount)
            let clickState = Int64(pairIndex + 1)
            let eventKinds = Self.eventKinds(for: button)
            let down = EventSpecification(
                type: eventKinds.down,
                button: eventKinds.button,
                clickState: clickState,
                buttonNumber: eventKinds.buttonNumber)
            let up = EventSpecification(
                type: eventKinds.up,
                button: eventKinds.button,
                clickState: clickState,
                buttonNumber: eventKinds.buttonNumber)

            try self.post(
                down,
                receipt: receipt,
                clickGroup: clickGroup,
                transport: transport,
                postedEventCount: &postedEventCount)
            await self.sleep(.milliseconds(28))
            do {
                try self.post(
                    up,
                    receipt: receipt,
                    clickGroup: clickGroup,
                    transport: transport,
                    postedEventCount: &postedEventCount)
            } catch {
                try self.releaseAfterInterruptedDown(
                    up,
                    context: DispatchContext(
                        receipt: receipt,
                        clickGroup: clickGroup,
                        transport: transport),
                    postedEventCount: &postedEventCount,
                    cause: error)
            }

            guard pairIndex + 1 < count else { continue }
            await self.sleep(.milliseconds(80))
        }

        guard let unitCount = DesktopActionOutcome.DispatchUnitCount(postedEventCount) else {
            throw PeekabooError.operationError(
                message: "Window-routed pointer delivery completed without posting an event")
        }
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: unitCount)
        do {
            try Self.checkCancellation(afterPosting: postedEventCount)
            try self.requireCurrentRoute(receipt, afterPosting: postedEventCount)
        } catch {
            throw DesktopActionFailure.dispatchedUnverified(
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: unitCount,
                message: "Window-routed pointer events were posted, but final delivery validation failed",
                hint: "Observe the target before retrying this click.",
                causeDescription: error.localizedDescription)
        }
        return outcome
    }

    func prepareHold(
        at point: CGPoint,
        button: MouseButton,
        target: ExactWindowPointerTarget) throws -> HeldPointerDispatch
    {
        guard button == .left || button == .right else {
            throw PeekabooError.serviceUnavailable(
                "Exact-window held pointer delivery supports left and right buttons only")
        }
        guard self.hasPostEventAccess() else {
            throw PeekabooError.permissionDeniedEventSynthesizing
        }
        try Task.checkCancellation()

        let targetProcessIdentifier = target.identity.ownerProcessIdentifier
        let receipt = try self.resolveRoute(
            targetProcessIdentifier,
            CGWindowID(target.identity.windowID),
            point)
        guard receipt.identity == target.identity,
              receipt.bounds == target.bounds,
              receipt.windowLayer == Int(CGWindowLevelForKey(.normalWindow)),
              receipt.bounds.contains(point)
        else {
            throw PeekabooError.snapshotStale(
                "Resolved held pointer route does not match the requested process generation, window, bounds, or point")
        }
        let isRight = button == .right
        return HeldPointerDispatch(
            receipt: receipt,
            clickGroup: self.clickGroupIdentifier(),
            transport: self.resolveTransport(targetProcessIdentifier),
            down: EventSpecification(
                type: isRight ? .rightMouseDown : .leftMouseDown,
                button: isRight ? .right : .left,
                clickState: 1,
                buttonNumber: isRight ? 1 : 0),
            up: EventSpecification(
                type: isRight ? .rightMouseUp : .leftMouseUp,
                button: isRight ? .right : .left,
                clickState: 1,
                buttonNumber: isRight ? 1 : 0))
    }

    /// Posts the routing primer and mouse-down while the caller owns the exact-window lane.
    func postHeldDown(_ dispatch: HeldPointerDispatch) async throws -> Int {
        var postedEventCount = 0
        let primer = EventSpecification(
            type: .mouseMoved,
            button: .left,
            clickState: 0,
            buttonNumber: 0)
        try self.post(
            primer,
            receipt: dispatch.receipt,
            clickGroup: dispatch.clickGroup,
            transport: dispatch.transport,
            postedEventCount: &postedEventCount)
        await self.sleep(.milliseconds(12))
        do {
            try self.post(
                dispatch.down,
                receipt: dispatch.receipt,
                clickGroup: dispatch.clickGroup,
                transport: dispatch.transport,
                postedEventCount: &postedEventCount)
        } catch {
            throw InputDeliveryIndeterminateError(
                operation: .click,
                emittedUnitCount: postedEventCount,
                causeDescription: "The held-pointer routing primer was posted, but mouse-down failed. " +
                    error.localizedDescription)
        }
        return postedEventCount
    }

    /// Releases only to the original live process generation. Window drift is deliberately ignored
    /// for cleanup because the matching generation received the down event; PID recycling is not.
    func postHeldRelease(_ dispatch: HeldPointerDispatch) throws -> Int {
        var postedEventCount = 0
        try self.postRelease(
            dispatch.up,
            receipt: dispatch.receipt,
            clickGroup: dispatch.clickGroup,
            transport: dispatch.transport,
            postedEventCount: &postedEventCount)
        return postedEventCount
    }

    func heldPointerRouteState(_ dispatch: HeldPointerDispatch) -> HeldPointerRouteState {
        guard self.processGenerationIsCurrent(dispatch.receipt) else {
            return .processGenerationChanged
        }
        return self.routeIsCurrent(dispatch.receipt) ? .current : .windowChanged
    }

    private static func eventKinds(for button: MouseButton) -> (
        button: CGMouseButton,
        down: CGEventType,
        up: CGEventType,
        buttonNumber: Int64)
    {
        switch button {
        case .left:
            (.left, .leftMouseDown, .leftMouseUp, 0)
        case .right:
            (.right, .rightMouseDown, .rightMouseUp, 1)
        case .middle:
            (.center, .otherMouseDown, .otherMouseUp, 2)
        }
    }

    // swiftlint:disable function_parameter_count
    /// Posts line-based wheel events to one exact visible background window without cursor movement.
    ///
    /// This is intentionally lower-level than an Accessibility scroll action. Callers must first
    /// capability-gate the target application and retain a fresh exact-window capture receipt.
    func scroll(
        at point: CGPoint,
        direction: PeekabooFoundation.ScrollDirection,
        ticks: Int,
        targetProcessIdentifier: pid_t,
        targetWindowID: CGWindowID,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws -> DesktopActionOutcome
    {
        guard ticks > 0 else {
            throw PeekabooError.invalidInput("Window-routed scroll requires at least one tick")
        }
        guard self.hasPostEventAccess() else {
            throw PeekabooError.permissionDeniedEventSynthesizing
        }
        try Task.checkCancellation()

        let receipt = try self.resolveRoute(targetProcessIdentifier, targetWindowID, point)
        guard receipt.identity == expectedWindowIdentity,
              receipt.windowLayer == Int(CGWindowLevelForKey(.normalWindow)),
              receipt.bounds == expectedWindowBounds,
              receipt.bounds.contains(point),
              self.scrollTargetIsVisible(receipt)
        else {
            throw PeekabooError.snapshotStale(
                "Resolved background wheel route does not match the visible captured PID, window, bounds, or point")
        }

        let transport = self.resolveTransport(targetProcessIdentifier)
        var postedEventCount = 0
        for tick in 0..<ticks {
            if Task.isCancelled {
                if postedEventCount == 0 {
                    throw CancellationError()
                }
                throw Self.scrollDispatchFailure(
                    eventCount: postedEventCount,
                    cause: "The request was cancelled after routed wheel events were emitted")
            }
            guard self.scrollRouteIsCurrent(receipt) else {
                if postedEventCount == 0 {
                    throw PeekabooError.snapshotStale(
                        "Background wheel target changed visibility, owner, process generation, window, or bounds")
                }
                throw Self.scrollDispatchFailure(
                    eventCount: postedEventCount,
                    cause: "The exact background wheel route changed during delivery")
            }
            guard let event = self.makeScrollEvent(direction, receipt.screenPoint) else {
                if postedEventCount == 0 {
                    throw PeekabooError.operationError(message: "Failed to create a window-routed wheel event")
                }
                throw Self.scrollDispatchFailure(
                    eventCount: postedEventCount,
                    cause: "The next window-routed wheel event could not be constructed")
            }
            guard self.stampWindowLocation(event, receipt.windowPoint) else {
                if postedEventCount == 0 {
                    throw PeekabooError.serviceUnavailable(
                        "Window-local wheel routing is unavailable on this macOS build; no scroll was dispatched")
                }
                throw Self.scrollDispatchFailure(
                    eventCount: postedEventCount,
                    cause: "The next wheel event could not be stamped with its window-local point")
            }

            Self.stampRoutingFields(
                on: event,
                receipt: receipt,
                clickGroup: self.clickGroupIdentifier())
            try self.postScrollEvent(
                event,
                receipt: receipt,
                transport: transport,
                postedEventCount: &postedEventCount)
            if tick + 1 < ticks {
                await self.sleep(.milliseconds(12))
            }
        }

        guard self.scrollRouteIsCurrent(receipt) else {
            throw Self.scrollDispatchFailure(
                eventCount: postedEventCount,
                cause: "Window-routed wheel events were posted, but final target validation failed",
                completedRequest: true)
        }
        guard let unitCount = DesktopActionOutcome.DispatchUnitCount(postedEventCount) else {
            throw PeekabooError.operationError(
                message: "Window-routed wheel delivery completed without posting an event")
        }
        return .dispatchedUnverified(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: unitCount)
    }

    // swiftlint:enable function_parameter_count

    private func scrollRouteIsCurrent(_ receipt: RouteReceipt) -> Bool {
        self.routeIsCurrent(receipt) && self.scrollTargetIsVisible(receipt)
    }

    private func scrollTargetIsVisible(_ receipt: RouteReceipt) -> Bool {
        self.applicationIsVisible(receipt.identity.ownerProcessIdentifier) && self.windowIsVisible(receipt)
    }

    private func postScrollEvent(
        _ event: CGEvent,
        receipt: RouteReceipt,
        transport: WindowRoutedPointerTransport,
        postedEventCount: inout Int) throws
    {
        switch transport {
        case .publicCGEvent:
            self.postPublic(event, receipt.identity.ownerProcessIdentifier)
        case .skyLight:
            guard self.postSkyLight(event, receipt.identity.ownerProcessIdentifier) else {
                let cause = "SkyLight PID wheel routing is unavailable; no global fallback was used"
                if postedEventCount == 0 {
                    throw PeekabooError.serviceUnavailable(cause)
                }
                throw Self.scrollDispatchFailure(eventCount: postedEventCount, cause: cause)
            }
        }
        postedEventCount += 1
    }

    private static func scrollDispatchFailure(
        eventCount: Int,
        cause: String,
        completedRequest: Bool = false) -> DesktopActionFailure
    {
        let unitCount = DesktopActionOutcome.DispatchUnitCount(eventCount)
        let delivery = DesktopActionOutcome.Delivery(mechanism: .windowTargetedEvents, mode: .background)
        if completedRequest {
            return .dispatchedUnverified(
                delivery: delivery,
                evidence: .deliveryAccepted,
                unitCount: unitCount,
                message: "Window-routed wheel delivery completed but final validation failed",
                hint: "Observe the target before taking another scroll action.",
                causeDescription: cause)
        }
        return .partial(
            delivery: delivery,
            unitCount: unitCount,
            message: "Window-routed wheel delivery stopped after an accepted prefix",
            hint: "Observe the target before taking another scroll action.",
            causeDescription: cause)
    }

    private func post(
        _ specification: EventSpecification,
        receipt: RouteReceipt,
        clickGroup: Int64,
        transport: WindowRoutedPointerTransport,
        postedEventCount: inout Int) throws
    {
        try self.requireCurrentRoute(receipt, afterPosting: postedEventCount)
        try self.postPrepared(
            specification,
            receipt: receipt,
            clickGroup: clickGroup,
            transport: transport,
            postedEventCount: &postedEventCount)
    }

    private func postPrepared(
        _ specification: EventSpecification,
        receipt: RouteReceipt,
        clickGroup: Int64,
        transport: WindowRoutedPointerTransport,
        postedEventCount: inout Int) throws
    {
        guard let event = self.makeEvent(specification, receipt.screenPoint) else {
            if postedEventCount > 0 {
                throw InputDeliveryIndeterminateError(
                    operation: .click,
                    emittedUnitCount: postedEventCount,
                    causeDescription: "The next window-routed pointer event could not be constructed")
            }
            throw PeekabooError.operationError(message: "Failed to create a window-routed pointer event")
        }
        guard self.stampWindowLocation(event, receipt.windowPoint) else {
            if postedEventCount > 0 {
                throw InputDeliveryIndeterminateError(
                    operation: .click,
                    emittedUnitCount: postedEventCount,
                    causeDescription: "The next pointer event could not be stamped with its window-local point")
            }
            throw PeekabooError.serviceUnavailable(
                "Window-local pointer routing is unavailable on this macOS build; no click was dispatched")
        }

        Self.stampRoutingFields(on: event, receipt: receipt, clickGroup: clickGroup)
        Self.setIntegerField(1, clickState: specification.clickState, on: event)
        Self.setIntegerField(3, clickState: specification.buttonNumber, on: event)
        Self.setIntegerField(7, clickState: 3, on: event)

        // A logical event is posted exactly once. AppKit consumes the public PID route while
        // Chromium/Catalyst require SkyLight's activity-monitor path; broadcasting to both makes
        // some AppKit controls observe duplicate clicks.
        switch transport {
        case .publicCGEvent:
            self.postPublic(event, receipt.identity.ownerProcessIdentifier)
        case .skyLight:
            guard self.postSkyLight(event, receipt.identity.ownerProcessIdentifier) else {
                let message = "SkyLight PID pointer routing is unavailable; no desktop-global fallback was used"
                if postedEventCount == 0 {
                    throw PeekabooError.serviceUnavailable(message)
                }
                throw InputDeliveryIndeterminateError(
                    operation: .click,
                    emittedUnitCount: postedEventCount,
                    causeDescription: message)
            }
        }
        postedEventCount += 1
    }

    /// A routed mouse-down can put AppKit into a nested tracking loop. If exact-window validation
    /// changes during the non-cancellable down/up interval, release the button to the same live
    /// process generation before returning an indeterminate result. Never send cleanup to a
    /// recycled PID: a replacement generation did not receive the down event.
    private func releaseAfterInterruptedDown(
        _ up: EventSpecification,
        context: DispatchContext,
        postedEventCount: inout Int,
        cause: any Error) throws -> Never
    {
        guard self.processGenerationIsCurrent(context.receipt) else {
            throw InputDeliveryIndeterminateError(
                operation: .click,
                emittedUnitCount: postedEventCount,
                causeDescription: "The original process generation disappeared after mouse-down; mouse-up was " +
                    "not retargeted to a replacement PID. \(cause.localizedDescription)")
        }

        do {
            try self.postRelease(
                up,
                receipt: context.receipt,
                clickGroup: context.clickGroup,
                transport: context.transport,
                postedEventCount: &postedEventCount)
        } catch {
            throw InputDeliveryIndeterminateError(
                operation: .click,
                emittedUnitCount: postedEventCount,
                causeDescription: "Paired mouse-up could not be dispatched to the original process generation. " +
                    error.localizedDescription)
        }
        throw InputDeliveryIndeterminateError(
            operation: .click,
            emittedUnitCount: postedEventCount,
            causeDescription: "The route changed after mouse-down; paired mouse-up was dispatched " +
                "non-cancellably to the original generation. \(cause.localizedDescription)")
    }

    private func postRelease(
        _ specification: EventSpecification,
        receipt: RouteReceipt,
        clickGroup: Int64,
        transport: WindowRoutedPointerTransport,
        postedEventCount: inout Int) throws
    {
        guard self.processGenerationIsCurrent(receipt) else {
            throw PeekabooError.operationError(
                message: "Original process generation disappeared before mouse-up cleanup")
        }
        try self.postPrepared(
            specification,
            receipt: receipt,
            clickGroup: clickGroup,
            transport: transport,
            postedEventCount: &postedEventCount)
    }

    private func requireCurrentRoute(_ receipt: RouteReceipt, afterPosting eventCount: Int) throws {
        guard self.routeIsCurrent(receipt) else {
            if eventCount == 0 {
                throw PeekabooError.snapshotStale(
                    "Background pointer target disappeared or changed owner, process generation, or bounds")
            }
            throw InputDeliveryIndeterminateError(
                operation: .click,
                emittedUnitCount: eventCount,
                causeDescription: "Background pointer target changed during routed delivery")
        }
    }

    private static func setIntegerField(_ rawField: UInt32, clickState value: Int64, on event: CGEvent) {
        guard let field = CGEventField(rawValue: rawField) else { return }
        event.setIntegerValueField(field, value: value)
    }

    private static func stampRoutingFields(
        on event: CGEvent,
        receipt: RouteReceipt,
        clickGroup: Int64)
    {
        let targetPID = Int64(receipt.identity.ownerProcessIdentifier)
        let windowID = Int64(receipt.identity.windowID)
        event.setIntegerValueField(.eventTargetUnixProcessID, value: targetPID)
        Self.setIntegerField(51, clickState: windowID, on: event)
        Self.setIntegerField(58, clickState: clickGroup, on: event)
        Self.setIntegerField(91, clickState: windowID, on: event)
        Self.setIntegerField(92, clickState: windowID, on: event)
    }

    private static func checkCancellation(afterPosting eventCount: Int) throws {
        guard Task.isCancelled else { return }
        guard eventCount > 0 else { throw CancellationError() }
        throw InputDeliveryIndeterminateError(
            operation: .click,
            emittedUnitCount: eventCount,
            causeDescription: "The request was cancelled after routed click events were emitted")
    }

    private static func makeCGEvent(
        _ specification: EventSpecification,
        _ screenPoint: CGPoint) -> CGEvent?
    {
        CGEvent(
            mouseEventSource: CGEventSource(stateID: .hidSystemState),
            mouseType: specification.type,
            mouseCursorPosition: screenPoint,
            mouseButton: specification.button)
    }

    private static func makeCGScrollEvent(
        _ direction: PeekabooFoundation.ScrollDirection,
        _ screenPoint: CGPoint) -> CGEvent?
    {
        let (vertical, horizontal): (Int32, Int32) = switch direction {
        case .up: (1, 0)
        case .down: (-1, 0)
        case .left: (0, 1)
        case .right: (0, -1)
        }
        guard let event = CGEvent(
            scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState),
            units: .line,
            wheelCount: 2,
            wheel1: vertical,
            wheel2: horizontal,
            wheel3: 0)
        else {
            return nil
        }
        event.location = screenPoint
        return event
    }

    private static func resolveLiveRoute(
        _ targetProcessIdentifier: pid_t,
        _ targetWindowID: CGWindowID,
        _ point: CGPoint) throws -> RouteReceipt
    {
        guard targetProcessIdentifier > 0,
              let window = SystemIdentityResolver.windowIdentity(targetWindowID),
              window.ownerProcessIdentifier == targetProcessIdentifier,
              window.bounds.contains(point),
              let identity = SystemIdentityResolver.windowMutationIdentity(windowID: targetWindowID),
              identity.ownerProcessIdentifier == targetProcessIdentifier
        else {
            throw PeekabooError.snapshotStale(
                "Cannot prove the exact PID/window owner, generation, and bounds for background pointer delivery")
        }
        return RouteReceipt(
            identity: identity,
            bounds: window.bounds,
            screenPoint: point,
            windowLayer: window.layer)
    }

    private static func validateLiveRoute(_ receipt: RouteReceipt) -> Bool {
        let identityIsCurrent = SystemIdentityResolver.validateWindowMutationIdentity(receipt.identity)
        let finalWindow = CGWindowID(exactly: receipt.identity.windowID)
            .flatMap(SystemIdentityResolver.windowIdentity)
        let finalProcessStartIdentity = finalWindow.flatMap {
            SystemIdentityResolver.processStartIdentity($0.ownerProcessIdentifier)
        }
        return self.routeRemainsCurrent(
            receipt,
            identityIsCurrent: identityIsCurrent,
            finalWindow: finalWindow,
            finalProcessStartIdentity: finalProcessStartIdentity)
    }

    static func routeRemainsCurrent(
        _ receipt: RouteReceipt,
        identityIsCurrent: Bool,
        finalWindow: SystemWindowIdentity?,
        finalProcessStartIdentity: UInt64?) -> Bool
    {
        guard identityIsCurrent,
              let expectedWindowID = CGWindowID(exactly: receipt.identity.windowID),
              let finalWindow,
              finalWindow.windowID == expectedWindowID,
              finalWindow.ownerProcessIdentifier == receipt.identity.ownerProcessIdentifier,
              finalProcessStartIdentity == receipt.identity.ownerProcessStartIdentity,
              finalWindow.layer == receipt.windowLayer,
              finalWindow.bounds == receipt.bounds,
              finalWindow.bounds.contains(receipt.screenPoint)
        else {
            return false
        }
        return true
    }

    private static func validateLiveProcessGeneration(_ receipt: RouteReceipt) -> Bool {
        SystemIdentityResolver.processStartIdentity(receipt.identity.ownerProcessIdentifier) ==
            receipt.identity.ownerProcessStartIdentity
    }

    private static func validateLiveWindowVisibility(_ receipt: RouteReceipt) -> Bool {
        guard let windowID = CGWindowID(exactly: receipt.identity.windowID),
              let window = SystemIdentityResolver.windowIdentity(windowID),
              window.windowID == windowID,
              window.ownerProcessIdentifier == receipt.identity.ownerProcessIdentifier,
              window.bounds == receipt.bounds,
              window.layer == receipt.windowLayer,
              window.isOnScreen,
              window.alpha > 0,
              window.bounds.contains(receipt.screenPoint)
        else {
            return false
        }
        return true
    }

    private static func resolveLiveTransport(_ processIdentifier: pid_t) -> WindowRoutedPointerTransport {
        switch WindowRoutedApplicationClassifier.kind(processIdentifier: processIdentifier) {
        case .catalyst, .chromium, .electron:
            .skyLight
        case .appKit, .webKit:
            .publicCGEvent
        }
    }
}

@MainActor
private enum WindowRoutedPointerSPI {
    private typealias SetWindowLocationFunction = @convention(c) (CGEvent, CGFloat, CGFloat) -> Void
    private typealias PostToPidFunction = @convention(c) (pid_t, CGEvent) -> Void

    private static let skyLightHandle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        RTLD_LAZY | RTLD_GLOBAL)

    private static let setWindowLocationFunction: SetWindowLocationFunction? = {
        _ = Self.skyLightHandle
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else {
            return nil
        }
        return unsafeBitCast(symbol, to: SetWindowLocationFunction.self)
    }()

    private static let postToPidFunction: PostToPidFunction? = {
        guard let skyLightHandle,
              let symbol = dlsym(skyLightHandle, "SLEventPostToPid")
        else {
            return nil
        }
        return unsafeBitCast(symbol, to: PostToPidFunction.self)
    }()

    static func setWindowLocation(_ event: CGEvent, _ point: CGPoint) -> Bool {
        guard let setWindowLocationFunction else { return false }
        setWindowLocationFunction(event, point.x, point.y)
        return true
    }

    static func postToPid(_ event: CGEvent, _ pid: pid_t) -> Bool {
        guard let postToPidFunction else { return false }
        postToPidFunction(pid, event)
        return true
    }
}
