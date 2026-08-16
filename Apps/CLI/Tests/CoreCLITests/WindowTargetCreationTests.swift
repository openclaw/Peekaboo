import CoreGraphics
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

struct WindowTargetCreationTests {
    @Test
    func `window CLI syntax preserves matching redundant PID channels`() throws {
        var options = WindowIdentificationOptions()
        options.app = "PID:12345"
        options.pid = 12345

        try options.validate()
        #expect(try options.selector.normalizedApplicationTarget(policy: .windowCLI()) == "PID:12345")
    }

    @Test
    func `window CLI syntax preserves conflicting PID error`() {
        var options = WindowIdentificationOptions()
        options.app = "PID:12345"
        options.pid = 54321

        do {
            try options.validate()
            Issue.record("Expected conflicting PID validation error")
        } catch {
            #expect(error.localizedDescription.contains("Conflicting PIDs"))
            #expect(error.localizedDescription.contains("12345"))
            #expect(error.localizedDescription.contains("54321"))
        }
    }

    @Test
    func `window mutation grammar rejects every conflicting selector pair`() {
        let selectorPairs: [(windowID: Int?, title: String?, index: Int?)] = [
            (123, "Draft", nil),
            (123, nil, 0),
            (nil, "Draft", 0),
        ]

        for selectors in selectorPairs {
            var options = WindowIdentificationOptions()
            options.app = "Fixture"
            options.windowId = selectors.windowID
            options.windowTitle = selectors.title
            options.windowIndex = selectors.index

            do {
                try options.validateMutation()
                Issue.record("Expected conflicting mutation selectors to be rejected")
            } catch {
                #expect(error.localizedDescription.contains("Provide only one of"))
            }
        }
    }

    @Test
    @MainActor
    func `exact window resolver rejects duplicate exact titles`() throws {
        var options = WindowIdentificationOptions()
        options.app = "Fixture"
        options.windowTitle = "Draft"
        try options.validateMutation()

        #expect(throws: ExactWindowSelectorResolutionError.self) {
            _ = try options.selectMutationWindow(
                from: [
                    Self.window(id: 101, title: "Draft", index: 0),
                    Self.window(id: 102, title: "Draft", index: 1),
                ],
                operation: "Window test"
            )
        }
    }

    @Test
    @MainActor
    func `exact window resolver rejects duplicate partial titles`() throws {
        var options = WindowIdentificationOptions()
        options.app = "Fixture"
        options.windowTitle = "Draft"
        try options.validateMutation()

        #expect(throws: ExactWindowSelectorResolutionError.self) {
            _ = try options.selectMutationWindow(
                from: [
                    Self.window(id: 101, title: "Draft One", index: 0),
                    Self.window(id: 102, title: "Draft Two", index: 1),
                ],
                operation: "Window test"
            )
        }
    }

    @Test
    @MainActor
    func `exact window resolver returns one unique partial title match`() throws {
        var options = WindowIdentificationOptions()
        options.app = "Fixture"
        options.windowTitle = "Notes"
        try options.validateMutation()

        let selected = try options.selectMutationWindow(
            from: [
                Self.window(id: 101, title: "Draft One", index: 0),
                Self.window(id: 102, title: "Release Notes", index: 1),
            ],
            operation: "Window test"
        )
        #expect(selected.windowID == 102)
    }

    @Test
    func `app + windowTitle creates .applicationAndTitle`() throws {
        var options = WindowIdentificationOptions()
        options.app = "Safari"
        options.windowTitle = "GitHub"

        switch try options.createTarget() {
        case let .applicationAndTitle(app, title):
            #expect(app == "Safari")
            #expect(title == "GitHub")
        default:
            Issue.record("Expected .applicationAndTitle")
        }
    }

    @Test
    func `app + windowIndex creates .index`() throws {
        var options = WindowIdentificationOptions()
        options.app = "Safari"
        options.windowIndex = 0

        switch try options.createTarget() {
        case let .index(app, index):
            #expect(app == "Safari")
            #expect(index == 0)
        default:
            Issue.record("Expected .index")
        }
    }

    @Test
    func `app only creates .application`() throws {
        var options = WindowIdentificationOptions()
        options.app = "Safari"

        switch try options.createTarget() {
        case let .application(app):
            #expect(app == "Safari")
        default:
            Issue.record("Expected .application")
        }
    }

    @Test
    func `windowId creates .windowId`() throws {
        var options = WindowIdentificationOptions()
        options.windowId = 12345

        switch try options.createTarget() {
        case let .windowId(id):
            #expect(id == 12345)
        default:
            Issue.record("Expected .windowId")
        }
    }

    @Test
    func `app window target prefers title over index`() throws {
        var options = WindowIdentificationOptions()
        options.app = "Safari"
        options.windowTitle = "GitHub"
        options.windowIndex = 2

        switch try options.toWindowTarget() {
        case let .applicationAndTitle(app, title):
            #expect(app == "Safari")
            #expect(title == "GitHub")
        default:
            Issue.record("Expected .applicationAndTitle")
        }
    }

    @Test
    func `createTarget supports pid targets`() throws {
        var options = WindowIdentificationOptions()
        options.pid = 12345

        switch try options.createTarget() {
        case let .application(app):
            #expect(app == "PID:12345")
        default:
            Issue.record("Expected PID application target")
        }
    }

    @Test
    func `toWindowTarget prefers windowId without app`() throws {
        var options = WindowIdentificationOptions()
        options.windowId = 12345
        let target = try options.toWindowTarget()
        switch target {
        case let .windowId(id):
            #expect(id == 12345)
        default:
            Issue.record("Expected .windowId")
        }
    }

    @Test
    func `exact mutation selection inventories only the requested PID owner`() throws {
        var options = WindowIdentificationOptions()
        options.pid = 12345
        options.windowId = 678

        switch try options.toWindowSelectionTarget() {
        case let .application(app):
            #expect(app == "PID:12345")
        default:
            Issue.record("Expected PID application inventory target")
        }
    }

    @Test
    func `exact mutation selection without an owner keeps exact ID lookup`() throws {
        var options = WindowIdentificationOptions()
        options.windowId = 678

        switch try options.toWindowSelectionTarget() {
        case let .windowId(id):
            #expect(id == 678)
        default:
            Issue.record("Expected exact window ID target")
        }
    }

    @Test
    @MainActor
    func `exact PID mutation selection rejects another owner receipt`() {
        var options = WindowIdentificationOptions()
        options.pid = 42
        options.windowId = 678
        let window = ServiceWindowInfo(
            windowID: 678,
            title: "Fixture",
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            mutationIdentity: WindowMutationIdentity(
                windowID: 678,
                ownerProcessIdentifier: 99,
                ownerProcessStartIdentity: 8,
                capturedBounds: CGRect(x: 0, y: 0, width: 100, height: 100)
            )
        )
        let application = ServiceApplicationInfo(
            processIdentifier: 42,
            processStartIdentity: 7,
            bundleIdentifier: "example.fixture",
            name: "Fixture"
        )

        let failure = #expect(throws: DesktopActionFailure.self) {
            try options.requireMutationWindow(
                from: [window],
                expectedApplication: application,
                action: "restore"
            )
        }
        #expect(failure?.outcome.state == .refused)
        #expect(failure?.outcome.refusalReason == .targetUnavailable)
        #expect(failure?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(failure?.outcome.retrySafety == .safe)
    }

    @Test
    @MainActor
    func `mutation selection never substitutes an unrelated minimized window`() {
        var options = WindowIdentificationOptions()
        options.app = "Fixture"
        options.windowTitle = "Requested"
        let unrelated = ServiceWindowInfo(
            windowID: 678,
            title: "Unrelated",
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            isMinimized: true
        )

        #expect(throws: (any Error).self) {
            try options.requireMutationWindow(
                from: [unrelated],
                expectedApplication: nil,
                action: "restore"
            )
        }
    }

    @Test
    @MainActor
    func `out of range mutation index never falls back to another window`() {
        var options = WindowIdentificationOptions()
        options.app = "Fixture"
        options.windowIndex = 4
        let onlyWindow = ServiceWindowInfo(
            windowID: 678,
            title: "Only",
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            isMinimized: true
        )

        #expect(throws: (any Error).self) {
            try options.requireMutationWindow(
                from: [onlyWindow],
                expectedApplication: nil,
                action: "restore"
            )
        }
    }

    @Test
    @MainActor
    func `application mutation selector rejects inventory from another owner`() {
        var options = WindowIdentificationOptions()
        options.app = "Fixture"
        let wrongOwner = ServiceWindowInfo(
            windowID: 678,
            title: "Only",
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            mutationIdentity: WindowMutationIdentity(
                windowID: 678,
                ownerProcessIdentifier: 99,
                ownerProcessStartIdentity: 8,
                capturedBounds: CGRect(x: 0, y: 0, width: 100, height: 100)
            )
        )
        let application = ServiceApplicationInfo(
            processIdentifier: 42,
            processStartIdentity: 7,
            bundleIdentifier: "example.fixture",
            name: "Fixture"
        )

        let failure = #expect(throws: DesktopActionFailure.self) {
            try options.requireMutationWindow(
                from: [wrongOwner],
                expectedApplication: application,
                action: "close"
            )
        }
        #expect(failure?.outcome.state == .refused)
        #expect(failure?.outcome.refusalReason == .targetUnavailable)
        #expect(failure?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(failure?.outcome.retrySafety == .safe)
    }

    @Test
    @MainActor
    func `mutation selector reports inconsistent bounds provenance as canonical refusal`() {
        var options = WindowIdentificationOptions()
        options.windowId = 678
        let window = ServiceWindowInfo(
            windowID: 678,
            title: "Fixture",
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            mutationIdentity: WindowMutationIdentity(
                windowID: 678,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 7,
                capturedBounds: CGRect(x: 1, y: 0, width: 100, height: 100)
            )
        )

        let failure = #expect(throws: DesktopActionFailure.self) {
            try options.requireMutationWindow(
                from: [window],
                expectedApplication: nil,
                action: "maximize"
            )
        }
        #expect(failure?.outcome.state == .refused)
        #expect(failure?.outcome.refusalReason == .targetUnavailable)
        #expect(failure?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(failure?.outcome.retrySafety == .safe)
    }

    @Test
    func `validation can allow snapshot-only focus target`() throws {
        var options = WindowIdentificationOptions()
        try options.validate(allowMissingTarget: true)

        options.windowIndex = -1
        #expect(throws: (any Error).self) {
            try options.validate(allowMissingTarget: true)
        }
    }

    @Test
    func `snapshot window target prefers window id`() {
        let snapshot = UIAutomationSnapshot(
            applicationName: "Example",
            applicationBundleId: "com.example.app",
            windowTitle: "Main",
            windowID: 42
        )

        switch windowTarget(from: snapshot) {
        case let .windowId(windowID):
            #expect(windowID == 42)
        default:
            Issue.record("Expected .windowId")
        }
    }

    @Test
    func `snapshot window target falls back to app and title`() {
        let snapshot = UIAutomationSnapshot(
            applicationName: "Example",
            applicationBundleId: "com.example.app",
            windowTitle: "Main"
        )

        switch windowTarget(from: snapshot) {
        case let .applicationAndTitle(app, title):
            #expect(app == "com.example.app")
            #expect(title == "Main")
        default:
            Issue.record("Expected .applicationAndTitle")
        }
    }

    @Test
    func `snapshot display name prefers application name`() {
        let snapshot = UIAutomationSnapshot(
            applicationName: "Example",
            applicationBundleId: "com.example.app"
        )

        #expect(windowDisplayName(from: snapshot, snapshotId: "snapshot-1") == "Example")
    }

    private static func window(id: Int, title: String, index: Int) -> ServiceWindowInfo {
        let position = CGFloat(index * 20)
        return ServiceWindowInfo(
            windowID: id,
            title: title,
            bounds: CGRect(x: position, y: position, width: 640, height: 480),
            index: index
        )
    }
}
