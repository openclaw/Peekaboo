import CoreGraphics
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct BackgroundTextInputReceiverTests {
    enum InvalidReceiver: CaseIterable, Sendable {
        case siblingField, siblingWindow, missingReceiver, missingSnapshot
    }

    @Test(arguments: InvalidReceiver.allCases)
    func `select all validates its exact receiver before web route eligibility`(
        invalid: InvalidReceiver) throws
    {
        let fixture = Fixture(route: .webKeyboard)
        switch invalid {
        case .siblingField:
            fixture.focusedReceiver = .sibling
        case .siblingWindow:
            fixture.focusedReceiver = .sibling
            fixture.siblingWindowID = 43
        case .missingReceiver:
            fixture.focusedReceiver = nil
        case .missingSnapshot:
            fixture.snapshotAvailable = false
        }

        let caught = #expect(throws: DesktopActionFailure.self) {
            try fixture.selectAll()
        }
        let failure = try #require(caught)
        #expect(failure.outcome.state == .refused)
        #expect(failure.outcome.refusalReason == .targetUnavailable)
        #expect(failure.outcome.dispatchState == .none)
        #expect(failure.outcome.projection.retrySafe)
        #expect(fixture.routeChecks.isEmpty)
        #expect(fixture.textReads.isEmpty)
        #expect(fixture.selections.isEmpty)
        switch invalid {
        case .siblingField, .siblingWindow:
            #expect(fixture.calls == ["focus", "snapshot:sibling"])
        case .missingReceiver:
            #expect(fixture.calls == ["focus"])
        case .missingSnapshot:
            #expect(fixture.calls == ["focus", "snapshot:pinned"])
        }
    }

    @Test
    func `select all returns unsupported for a retained web receiver before reading or selecting text`() throws {
        let fixture = Fixture(route: .webKeyboard)

        #expect(try !fixture.selectAll())
        #expect(fixture.calls == ["focus", "snapshot:pinned", "route:pinned"])
        #expect(fixture.routeChecks == [.pinned])
        #expect(fixture.textReads.isEmpty)
        #expect(fixture.selections.isEmpty)
    }

    @Test
    func `select all hard refuses an unproven retained receiver without selecting text`() throws {
        let fixture = Fixture(route: .unproven)

        let caught = #expect(throws: DesktopActionFailure.self) {
            try fixture.selectAll()
        }
        let failure = try #require(caught)
        #expect(failure.outcome.state == .refused)
        #expect(failure.outcome.refusalReason == .targetUnavailable)
        #expect(failure.outcome.dispatchState == .none)
        #expect(failure.outcome.projection.retrySafe)
        #expect(fixture.calls == ["focus", "snapshot:pinned", "route:pinned"])
        #expect(fixture.routeChecks == [.pinned])
        #expect(fixture.textReads.isEmpty)
        #expect(fixture.selections.isEmpty)
    }

    @Test
    func `select all preserves the full UTF16 selection for a retained native receiver`() throws {
        let fixture = Fixture(route: .nativeAX)

        #expect(try fixture.selectAll())
        #expect(fixture.calls == ["focus", "snapshot:pinned", "route:pinned", "text:pinned", "select:pinned"])
        #expect(fixture.routeChecks == [.pinned])
        #expect(fixture.textReads == [.pinned])
        #expect(fixture.selections == [.init(receiver: .pinned, location: 0, length: 4)])
    }

    @Test(arguments: [SpecialKey.return, .tab, .escape, .upArrow, .f1])
    func `event only keys never resolve a focused AX receiver`(key: SpecialKey) async throws {
        // An invalid PID would fail target validation if the AX editing path were entered.
        #expect(try await BackgroundInputDriver.performFocusedTextKey(key, targetProcessIdentifier: -1) == .unsupported)
    }

    @MainActor
    private final class Fixture {
        enum Receiver: String {
            case pinned, sibling
        }

        struct Selection: Equatable {
            let receiver: Receiver
            let location: Int
            let length: Int
        }

        let route: TextInputRoute
        var focusedReceiver: Receiver? = .pinned
        var snapshotAvailable = true
        var siblingWindowID = 42
        private(set) var calls: [String] = []
        private(set) var routeChecks: [Receiver] = []
        private(set) var textReads: [Receiver] = []
        private(set) var selections: [Selection] = []

        init(route: TextInputRoute) {
            self.route = route
        }

        func selectAll() throws -> Bool {
            let bounds = CGRect(x: 0, y: 0, width: 640, height: 480)
            let target = try UIAutomationTarget.ExactWindow(
                identity: WindowMutationIdentity(
                    windowID: 42,
                    ownerProcessIdentifier: 4242,
                    ownerProcessStartIdentity: 7,
                    capturedBounds: bounds),
                bounds: bounds,
                focusedElement: FocusedElementIdentity(
                    processIdentifier: 4242,
                    windowID: 42,
                    role: "AXTextField",
                    title: "Editor",
                    identifier: "pinned",
                    frame: CGRect(x: 20, y: 30, width: 160, height: 30)))
            return try BackgroundInputDriver.performFocusedTextHotkey(
                primaryKey: "a",
                modifierFlags: .maskCommand,
                exactWindow: target,
                access: self.access)
        }

        private var access: BackgroundInputDriver.FocusedTextHotkeyAccess<Receiver> {
            BackgroundInputDriver.FocusedTextHotkeyAccess(
                focusedElement: {
                    self.calls.append("focus")
                    return self.focusedReceiver
                },
                textValue: { receiver in
                    self.calls.append("route:\(receiver.rawValue)")
                    self.routeChecks.append(receiver)
                    guard try self.route.permitsAccessibilityEditing() else { return nil }
                    self.calls.append("text:\(receiver.rawValue)")
                    self.textReads.append(receiver)
                    return "A😀B"
                },
                focusSnapshot: { receiver in
                    self.calls.append("snapshot:\(receiver.rawValue)")
                    guard self.snapshotAvailable else { return nil }
                    return ExactWindowFocusSnapshot(
                        processIdentifier: 4242,
                        windowID: receiver == .pinned ? 42 : self.siblingWindowID,
                        frame: CGRect(x: 20, y: 30, width: 160, height: 30),
                        role: "AXTextField",
                        title: "Editor",
                        identifier: receiver.rawValue)
                },
                selectRange: { range, receiver in
                    self.calls.append("select:\(receiver.rawValue)")
                    self.selections.append(Selection(
                        receiver: receiver,
                        location: range.location,
                        length: range.length))
                    return true
                })
        }
    }
}
