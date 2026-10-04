import ApplicationServices
import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct PositionalClickAXReaderTests {
    enum Stage: CaseIterable {
        case hit, owner, actions, role, enabled, subrole, position, size, children, parent
        case focusedSettable, selectedSettable, descendantActions, ancestorActions

        var attribute: String? {
            switch self {
            case .role: kAXRoleAttribute
            case .enabled: kAXEnabledAttribute
            case .subrole: kAXSubroleAttribute
            case .position: kAXPositionAttribute
            case .size: kAXSizeAttribute
            case .children: kAXChildrenAttribute
            case .parent: kAXParentAttribute
            default: nil
            }
        }
    }

    @Test(
        arguments: Stage.allCases,
        [AXError.cannotComplete, .invalidUIElement, .apiDisabled, .failure, .notImplemented])
    func `native AX read errors cannot admit a positional pointer fallback`(stage: Stage, error: AXError) async throws {
        let fixture = Fixture(stage: stage, error: error)
        let failure = await #expect(throws: DesktopActionFailure.self) { try await fixture.dispatch() }

        #expect(failure?.outcome.state == .refused)
        #expect(failure?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(failure?.outcome.retrySafety == .safe)
        #expect(failure?.causeDescription == "AX error \(error.rawValue).")
        #expect(fixture.nativeCalls == 0)
        #expect(fixture.failedReadReached)
    }

    @Test(arguments: [Stage.hit, .owner, .actions, .role, .enabled, .subrole, .position, .size, .children, .parent])
    func `successful native calls with malformed payloads remain unreadable`(stage: Stage) async throws {
        let fixture = Fixture(stage: stage, error: .success)
        let failure = await #expect(throws: DesktopActionFailure.self) { try await fixture.dispatch() }
        #expect(failure?.outcome.state == .refused)
        #expect(fixture.nativeCalls == 0)
        #expect(fixture.failedReadReached)
    }

    @Test(arguments: [AXError.attributeUnsupported, .noValue])
    func `missing required native role is not unsupported click evidence`(error: AXError) async throws {
        let fixture = Fixture(stage: .role, error: error)
        let failure = await #expect(throws: DesktopActionFailure.self) { try await fixture.dispatch() }
        #expect(failure?.outcome.state == .refused)
        #expect(fixture.nativeCalls == 0)
    }

    @Test(arguments: [false, true])
    func `complete unsupported observation and documented empty hit admit exactly one route`(
        emptyHit: Bool) async throws
    {
        let fixture = Fixture(stage: emptyHit ? .hit : nil, error: .noValue)
        let outcome = try await fixture.dispatch()
        #expect(outcome.state == .dispatchedUnverified)
        #expect(outcome.delivery?.mechanism == .windowTargetedEvents)
        #expect(outcome.dispatchState.unitCount?.rawValue == 3)
        #expect(fixture.nativeCalls == 1)
    }

    @Test(arguments: [Stage.actions, .focusedSettable, .selectedSettable])
    func `no value is not a generic empty capability list`(stage: Stage) async throws {
        let fixture = Fixture(stage: stage, error: .noValue)
        let failure = await #expect(throws: DesktopActionFailure.self) { try await fixture.dispatch() }
        #expect(failure?.outcome.state == .refused)
        #expect(fixture.nativeCalls == 0)
        #expect(fixture.failedReadReached)
    }

    @Test
    func `empty-hit status with an unexpected object is inconsistent evidence`() async throws {
        let fixture = Fixture()
        var reader = fixture.reader
        reader.access.hit = { _, _ in (.noValue, fixture.hit) }
        let failure = await #expect(throws: DesktopActionFailure.self) { try await fixture.dispatch(reader: reader) }
        #expect(failure?.outcome.state == .refused)
        #expect(fixture.nativeCalls == 0)
    }

    @Test(arguments: [Stage.focusedSettable, .selectedSettable])
    func `explicitly unsupported writable attribute is a complete negative observation`(stage: Stage) async throws {
        let fixture = Fixture(stage: stage, error: .attributeUnsupported)
        let result = try await fixture.dispatch()
        #expect(result.state == .dispatchedUnverified)
        #expect(fixture.nativeCalls == 1)
        #expect(fixture.failedReadReached)
    }

    @Test(arguments: ["descendants", "depth", "ancestors", "cycle"])
    func `bounded or cyclic native traversal cannot claim unsupported`(limit: String) async throws {
        let fixture = Fixture()
        var reader = fixture.reader
        switch limit {
        case "descendants":
            fixture.hitChildren = [fixture.child]
            reader.maximumDescendants = 0
        case "depth":
            fixture.hitChildren = [fixture.child]
            fixture.childChildren = [fixture.ancestor]
            reader.maximumDepth = 1
        case "ancestors":
            fixture.hitParent = fixture.ancestor
            reader.maximumAncestors = 0
        default:
            fixture.hitChildren = [fixture.child]
            fixture.childChildren = [fixture.hit]
        }
        let failure = await #expect(throws: DesktopActionFailure.self) { try await fixture.dispatch(reader: reader) }
        #expect(failure?.outcome.state == .refused)
        #expect(failure?.outcome.retrySafety == .safe)
        #expect(fixture.nativeCalls == 0)
    }

    @Test
    func `known hit press does not require unreadable unused descendants`() throws {
        let fixture = Fixture(stage: .children, error: .cannotComplete)
        fixture.hitRole = kAXButtonRole
        fixture.pressable = fixture.hit
        guard case let .accessibility(element, action) = try fixture.resolve() else {
            Issue.record("Expected the known hit press")
            return
        }
        #expect(action == .press)
        #expect(element.underlyingAXElement.map { CFEqual($0, fixture.hit) } == true)
        #expect(!fixture.failedReadReached)
    }

    @Test
    func `complete native observations preserve press before row and focus precedence`() throws {
        let fixture = Fixture()
        fixture.hitRole = kAXTextFieldRole
        fixture.focusedSettable = true
        fixture.hitChildren = [fixture.child]
        fixture.childRole = kAXRowRole
        fixture.selectedSettable = true
        guard case let .accessibility(row, rowAction) = try fixture.resolve() else {
            Issue.record("Expected the selectable row")
            return
        }
        #expect(rowAction == .select)
        #expect(row.underlyingAXElement.map { CFEqual($0, fixture.child) } == true)

        fixture.childRole = kAXButtonRole
        fixture.pressable = fixture.child
        guard case let .accessibility(button, buttonAction) = try fixture.resolve() else {
            Issue.record("Expected the descendant press")
            return
        }
        #expect(buttonAction == .press)
        #expect(button.underlyingAXElement.map { CFEqual($0, fixture.child) } == true)
        #expect(fixture.nativeCalls == 0)
    }

    @MainActor
    private final class Fixture {
        let hit = AXUIElementCreateApplication(88001)
        let child = AXUIElementCreateApplication(88002)
        let ancestor = AXUIElementCreateApplication(88003)
        let stage: Stage?
        let error: AXError
        let point = CGPoint(x: 50, y: 50)
        var hitRole = kAXGroupRole
        var childRole = kAXGroupRole
        var hitChildren: [AXUIElement] = []
        var childChildren: [AXUIElement] = []
        var hitParent: AXUIElement?
        var pressable: AXUIElement?
        var selectedSettable = false
        var focusedSettable = false
        var failedReadReached = false
        var nativeCalls = 0

        init(stage: Stage? = nil, error: AXError = .cannotComplete) {
            self.stage = stage
            self.error = error
            if stage == .focusedSettable {
                self.hitRole = kAXTextFieldRole
            }
            if stage == .selectedSettable {
                self.hitRole = kAXRowRole
            }
            if stage == .descendantActions {
                self.hitChildren = [self.child]
            }
            if stage == .ancestorActions {
                self.hitParent = self.ancestor
            }
        }

        var reader: PositionalClickAXReader {
            var access = PositionalClickAXReader.Access()
            access.hit = { _, point in
                #expect(point == self.point)
                if self.stage == .hit {
                    self.failedReadReached = true
                    return (self.error, nil)
                }
                return (.success, self.hit)
            }
            access.processID = { _ in
                if self.stage == .owner {
                    self.failedReadReached = true
                    return (self.error, 0)
                }
                return (.success, 42)
            }
            access.attribute = { element, name in
                if name == self.stage?.attribute {
                    self.failedReadReached = true
                    return (self.error, nil)
                }
                switch name {
                case kAXRoleAttribute:
                    return (.success, (CFEqual(element, self.hit) ? self.hitRole : self.childRole) as CFString)
                case kAXEnabledAttribute:
                    return (.success, kCFBooleanTrue)
                case kAXSubroleAttribute:
                    return (.noValue, nil)
                case kAXPositionAttribute:
                    var origin = CGPoint(x: 10, y: 10)
                    return (.success, AXValueCreate(.cgPoint, &origin))
                case kAXSizeAttribute:
                    var size = CGSize(width: 100, height: 100)
                    return (.success, AXValueCreate(.cgSize, &size))
                case kAXChildrenAttribute:
                    let children = CFEqual(element, self.hit) ? self.hitChildren : self.childChildren
                    return (.success, children as CFArray)
                case kAXParentAttribute:
                    if CFEqual(element, self.hit), let parent = self.hitParent {
                        return (.success, parent)
                    }
                    return (.noValue, nil)
                default:
                    Issue.record("Unexpected native attribute: \(name)")
                    return (.failure, nil)
                }
            }
            access.actions = { element in
                if self.stage == .actions ||
                    (self.stage == .descendantActions && CFEqual(element, self.child)) ||
                    (self.stage == .ancestorActions && CFEqual(element, self.ancestor))
                {
                    self.failedReadReached = true
                    return (self.error, nil)
                }
                let actions = self.pressable.map { CFEqual($0, element) } == true ? [kAXPressAction] : []
                return (.success, actions as CFArray)
            }
            access.settable = { _, name in
                if (self.stage == .focusedSettable && name == kAXFocusedAttribute) ||
                    (self.stage == .selectedSettable && name == kAXSelectedAttribute)
                {
                    self.failedReadReached = true
                    return (self.error, false)
                }
                return (.success, name == kAXSelectedAttribute ? self.selectedSettable : self.focusedSettable)
            }
            return PositionalClickAXReader(access: access)
        }

        func resolve() throws -> BackgroundInputDriver.PositionalClickResolution {
            try self.reader.resolve(at: self.point, targetProcessIdentifier: 42)
        }

        func dispatch(reader: PositionalClickAXReader? = nil) async throws -> DesktopActionOutcome {
            try await BackgroundInputDriver.performSinglePositionalClick(
                resolveAccessibilityTarget: {
                    try (reader ?? self.reader).resolve(at: self.point, targetProcessIdentifier: 42)
                },
                allowsAccessibilityValueDelivery: true,
                routedClick: {
                    self.nativeCalls += 1
                    return .dispatchedUnverified(
                        delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                        evidence: .deliveryAccepted,
                        unitCount: .init(3))
                })
        }
    }
}
