import AppKit
import ApplicationServices
@preconcurrency import AXorcist
import CoreGraphics
import Foundation
import PeekabooAutomationKitTestSupport
import struct PeekabooFoundation.DesktopActionFailure
import struct PeekabooFoundation.DesktopActionOutcome
import enum PeekabooFoundation.PeekabooError
import enum PeekabooFoundation.ScrollDirection
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooAutomationKit

@MainActor
final class ClickRecordingSyntheticInputDriver: SyntheticInputDriving {
    enum Event: Equatable {
        case click(point: CGPoint, button: MouseButton, count: Int)
        case targetedClick(
            point: CGPoint,
            button: MouseButton,
            count: Int,
            targetProcessIdentifier: pid_t,
            targetWindowID: CGWindowID?)
        case move(CGPoint)
        case currentLocation
        case scroll(deltaX: Double, deltaY: Double, at: CGPoint?)
    }

    private(set) var events: [Event] = []
    private(set) var targetedClickAttempts = 0
    private var globalClickAttempts = 0
    private let targetedClickError: (any Error)?
    private let targetedClickOutcome: DesktopActionOutcome
    private let failGlobalClickAt: Int?

    init(
        targetedClickError: (any Error)? = nil,
        targetedClickOutcome: DesktopActionOutcome = AutomationTestFixtures.uiActionReceipt().outcome,
        failGlobalClickAt: Int? = nil)
    {
        self.targetedClickError = targetedClickError
        self.targetedClickOutcome = targetedClickOutcome
        self.failGlobalClickAt = failGlobalClickAt
    }

    func click(at point: CGPoint, button: MouseButton, count: Int) throws -> DesktopActionOutcome {
        self.globalClickAttempts += 1
        if let failGlobalClickAt, self.globalClickAttempts == failGlobalClickAt {
            throw ActionInputError.failed("synthetic click failure")
        }
        self.events.append(.click(point: point, button: button, count: count))
        return .dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted)
    }

    func click(
        at point: CGPoint,
        button: MouseButton,
        count: Int,
        targetProcessIdentifier: pid_t) async throws -> DesktopActionOutcome
    {
        try await self.click(
            at: point,
            button: button,
            count: count,
            targetProcessIdentifier: targetProcessIdentifier,
            targetWindowID: nil)
    }

    func click(
        at point: CGPoint,
        button: MouseButton,
        count: Int,
        targetProcessIdentifier: pid_t,
        targetWindowID: CGWindowID?) async throws -> DesktopActionOutcome
    {
        self.targetedClickAttempts += 1
        if let targetedClickError {
            throw targetedClickError
        }
        self.events.append(.targetedClick(
            point: point,
            button: button,
            count: count,
            targetProcessIdentifier: targetProcessIdentifier,
            targetWindowID: targetWindowID))
        return self.targetedClickOutcome
    }

    func move(to point: CGPoint) throws {
        self.events.append(.move(point))
    }

    func currentLocation() -> CGPoint? {
        self.events.append(.currentLocation)
        return nil
    }

    func pressHold(at _: CGPoint, button _: MouseButton, duration _: TimeInterval) async throws {}

    func scroll(deltaX: Double, deltaY: Double, at point: CGPoint?) throws {
        self.events.append(.scroll(deltaX: deltaX, deltaY: deltaY, at: point))
    }

    func type(_: String, delayPerCharacter _: TimeInterval) throws {}

    func tapKey(_: SpecialKey, modifiers _: CGEventFlags) throws {}

    func hotkey(keys _: [String], holdDuration _: TimeInterval) throws {}
}
