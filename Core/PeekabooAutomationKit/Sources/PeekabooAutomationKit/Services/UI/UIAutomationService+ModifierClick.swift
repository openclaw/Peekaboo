import AppKit
import CoreGraphics
import Foundation
import PeekabooFoundation

extension UIAutomationService {
    public func foregroundModifierClickWithOutcome(
        _ request: ForegroundModifierClickRequest) async throws
        -> UIAutomationActionResult<ForegroundModifierClickResult>
    {
        let focusService = FocusManagementService(operationLaneCoordinator: self.operationLaneCoordinator)
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: self.operationLaneCoordinator,
            dependencies: .init(
                focusExactWindow: { target, firstDispatchGuard in
                    var sequence = DesktopActionSequenceAccumulator()
                    try await focusService.focusWindowWithOwnedLane(
                        windowID: CGWindowID(target.identity.windowID),
                        options: .init(timeout: 2, retryCount: 2, switchSpace: false),
                        expectedIdentity: target.identity,
                        firstDispatchGuard: firstDispatchGuard,
                        onDispatch: { sequence.record($0.sequenceStep) })
                    return FocusDispatchAccounting.verifiedFocusOutcome(sequence.successResolution())
                },
                currentFrontmostIdentity: Self.currentFrontmostProcessIdentity,
                currentFocusedExactWindow: Self.currentFocusedExactWindow,
                activate: Self.activateAndVerify,
                currentCursorLocation: { self.syntheticInputDriver.currentLocation() },
                moveCursor: { try self.syntheticInputDriver.move(to: $0) },
                click: Self.postModifierClick,
                validateExactWindow: self.exactWindowIdentityValidator))
        return try await executor.execute(request)
    }

    private static func currentFrontmostProcessIdentity() -> ApplicationProcessIdentity? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              let generation = SystemIdentityResolver.processStartIdentity(application.processIdentifier)
        else { return nil }
        return ApplicationProcessIdentity(
            processIdentifier: application.processIdentifier,
            processStartIdentity: generation)
    }

    private static func currentFocusedExactWindow() -> UIAutomationTarget.ExactWindow? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              let processStartIdentity = SystemIdentityResolver.processStartIdentity(application.processIdentifier),
              let windowID = WindowIdentityService().focusedWindowID(for: application, timeout: 0.5),
              let identity = SystemIdentityResolver.windowMutationIdentity(windowID: windowID),
              identity.ownerProcessIdentifier == application.processIdentifier,
              identity.ownerProcessStartIdentity == processStartIdentity,
              let bounds = identity.capturedBounds
        else {
            return nil
        }
        return try? UIAutomationTarget.ExactWindow(identity: identity, bounds: bounds)
    }

    private static func activateAndVerify(
        _ identity: ApplicationProcessIdentity,
        firstDispatchGuard: FocusFirstDispatchGuard) async throws -> Bool
    {
        guard SystemIdentityResolver.processStartIdentity(identity.processIdentifier) == identity.processStartIdentity,
              let application = NSRunningApplication(processIdentifier: identity.processIdentifier)
        else { return false }
        try firstDispatchGuard.validate()
        guard application.activate() else { return false }
        for _ in 0..<20 {
            if self.currentFrontmostProcessIdentity() == identity {
                return true
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    private static func postModifierClick(
        point: CGPoint,
        clickType: ClickType,
        modifiers: [PointerModifier]) throws -> DesktopActionOutcome
    {
        guard CGPreflightPostEventAccess() else {
            throw PeekabooError.permissionDeniedEventSynthesizing
        }
        let source = CGEventSource(stateID: .hidSystemState)
        let events = try self.makeModifierClickEvents(
            point: point,
            clickType: clickType,
            modifiers: modifiers,
            source: source)
        events.forEach { $0.post(tap: .cghidEventTap) }
        return .dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one)
    }

    static func makeModifierClickEvents(
        point: CGPoint,
        clickType: ClickType,
        modifiers: [PointerModifier],
        source: CGEventSource?) throws -> [CGEvent]
    {
        let descriptor = self.mouseEventDescriptor(for: clickType)
        let flags = self.flags(for: modifiers)
        var events: [CGEvent] = []
        events.reserveCapacity(descriptor.count * 2)
        for clickState in 1...descriptor.count {
            guard let down = CGEvent(
                mouseEventSource: source,
                mouseType: descriptor.down,
                mouseCursorPosition: point,
                mouseButton: descriptor.button),
                let up = CGEvent(
                    mouseEventSource: source,
                    mouseType: descriptor.up,
                    mouseCursorPosition: point,
                    mouseButton: descriptor.button)
            else {
                throw PeekabooError.invalidInput("Could not create modifier-click mouse events")
            }
            for event in [down, up] {
                event.flags = flags
                event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
                events.append(event)
            }
        }
        return events
    }

    private static func flags(for modifiers: [PointerModifier]) -> CGEventFlags {
        modifiers.reduce(into: CGEventFlags()) { $0.insert(self.flag(for: $1)) }
    }

    private static func flag(for modifier: PointerModifier) -> CGEventFlags {
        switch modifier {
        case .command: .maskCommand
        case .shift: .maskShift
        case .option: .maskAlternate
        case .control: .maskControl
        }
    }

    private static func mouseEventDescriptor(for clickType: ClickType) -> (
        button: CGMouseButton,
        down: CGEventType,
        up: CGEventType,
        count: Int)
    {
        switch clickType {
        case .right:
            (.right, .rightMouseDown, .rightMouseUp, 1)
        case .middle:
            (.center, .otherMouseDown, .otherMouseUp, 1)
        case .double:
            (.left, .leftMouseDown, .leftMouseUp, 2)
        case .triple:
            (.left, .leftMouseDown, .leftMouseUp, 3)
        case .single, .longPress:
            (.left, .leftMouseDown, .leftMouseUp, 1)
        }
    }
}
