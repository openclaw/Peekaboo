import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

extension ForegroundModifierClickExecutorTests {
    func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-modifier-click-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func priorWindow(process: ApplicationProcessIdentity) throws -> UIAutomationTarget.ExactWindow {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        return try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 6,
                ownerProcessIdentifier: process.processIdentifier,
                ownerProcessStartIdentity: process.processStartIdentity,
                capturedBounds: bounds),
            bounds: bounds)
    }
}

@MainActor
final class ModifierClickDispatchGuardState {
    var ownershipIsValid = true
    var validationCount = 0
    var adoptionCount = 0
    var currentState = 0
    var expectedState = 0
    var intermediateState = 1
    var finalState = 2
}

final class ModifierClickValidationCounter: @unchecked Sendable {
    var count = 0
    var routeQueryCount = 0
    var identityIsCurrent = true
}

enum ModifierClickPointerReceiverCase: CaseIterable, Sendable {
    case matching
    case overlayReceiver
    case unavailable
}

enum HeldInputCase: CaseIterable, Sendable {
    case keyAutorepeat
    case mouseButton

    func activity(after token: SharedInputActivityToken) -> SharedInputActivityToken {
        switch self {
        case .keyAutorepeat:
            token.withHeldKey(4)
        case .mouseButton:
            token.withHeldMouseButton(.left)
        }
    }
}

enum FocusInputTransition: CaseIterable, Sendable {
    case key
    case mouseButton
    case modifierFlags

    func activity(after token: SharedInputActivityToken) -> SharedInputActivityToken {
        switch self {
        case .key:
            token.withHeldKey(4)
        case .mouseButton:
            token.withHeldMouseButton(.left)
        case .modifierFlags:
            token.afterModifierFlagsChange()
        }
    }
}

enum SharedDesktopInterruption: CaseIterable, Sendable {
    case stationaryClick
    case keyboard
    case scroll
    case modifierFlags

    func activity(after token: SharedInputActivityToken) -> SharedInputActivityToken {
        switch self {
        case .stationaryClick:
            token.afterModifierClick(.single)
        case .keyboard:
            token.afterKeyboardInput()
        case .scroll:
            token.afterScrollInput()
        case .modifierFlags:
            token.afterModifierFlagsChange()
        }
    }
}

enum ModifierClickTestError: LocalizedError {
    case cursorRestoreFailed
    case focusRestoreFailed

    var errorDescription: String? {
        switch self {
        case .cursorRestoreFailed:
            "cursor restore failed"
        case .focusRestoreFailed:
            "focus restore failed"
        }
    }
}

actor ModifierClickLaneSuspension {
    private var held = false
    private var heldContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func hold() async {
        self.held = true
        let continuations = self.heldContinuations
        self.heldContinuations.removeAll()
        continuations.forEach { $0.resume() }
        await withCheckedContinuation { self.releaseContinuation = $0 }
    }

    func waitUntilHeld() async {
        guard !self.held else { return }
        await withCheckedContinuation { self.heldContinuations.append($0) }
    }

    func release() {
        self.releaseContinuation?.resume()
        self.releaseContinuation = nil
    }
}
