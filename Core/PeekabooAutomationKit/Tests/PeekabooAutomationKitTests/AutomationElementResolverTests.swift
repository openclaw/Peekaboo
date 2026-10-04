import AppKit
import ApplicationServices
@preconcurrency import AXorcist
import PeekabooFoundation
import Testing
@testable @_spi(Testing) import PeekabooAutomationKit

@MainActor
struct AutomationElementResolverTests {
    @Test
    func `coordinate scroll selects the nearest ancestor without borrowing siblings or descendants`() throws {
        let leaf = self.makeElement(101), inner = self.makeElement(102), outer = self.makeElement(103)
        let unrelated = self.makeElement(104)
        let window = try self.scrollWindow()
        let reader = ResolverTreeReader(
            descriptors: [
                leaf: self.descriptor(identifier: "leaf", frame: window.bounds),
                inner: self.descriptor(identifier: "inner", frame: window.bounds, role: "AXScrollArea"),
                outer: self.descriptor(identifier: "outer", frame: window.bounds, role: "AXScrollArea"),
                unrelated: self.descriptor(identifier: "sibling", frame: window.bounds, role: "AXScrollArea"),
            ],
            children: [leaf: [unrelated], outer: [unrelated, inner]],
            processIdentifiers: [leaf: getpid(), inner: getpid(), outer: getpid(), unrelated: getpid()],
            hit: .element(leaf),
            parents: [leaf: inner, inner: outer],
            windowIDs: [leaf: 42, inner: 42, outer: 42, unrelated: 42],
            scrollContainers: [inner, outer, unrelated])
        let resolver = AutomationElementResolver(treeReader: reader)

        let result = try resolver.resolveScrollTarget(at: CGPoint(x: 20, y: 30), target: window)

        guard case let .semanticOwner(element, role, bounds) = result else {
            Issue.record("Expected the nearest semantic scroll owner")
            return
        }
        #expect(element.element == inner)
        #expect(role == "AXScrollArea" && bounds == window.bounds)
        #expect(reader.descriptorReads == [leaf, inner])
        #expect(reader.parentReads == [leaf])
        #expect(reader.childrenReads.isEmpty)
        #expect(reader.hitProcessIdentifiers == [getpid()])
    }

    @Test(arguments: [0, 1, 2])
    func `coordinate scroll refuses missing foreign window or foreign process ownership`(kind: Int) throws {
        let hit = self.makeElement(111)
        let window = try self.scrollWindow()
        let reader = ResolverTreeReader(
            descriptors: [hit: self.descriptor(identifier: "hit", frame: window.bounds, role: "AXScrollArea")],
            children: [:],
            processIdentifiers: [hit: kind == 2 ? getpid() + 1 : getpid()],
            hit: .element(hit),
            windowIDs: kind == 0 ? [:] : [hit: kind == 1 ? 99 : 42],
            scrollContainers: [hit])
        let resolver = AutomationElementResolver(treeReader: reader)

        #expect(throws: PeekabooError.self) {
            try resolver.resolveScrollTarget(at: CGPoint(x: 20, y: 30), target: window)
        }
        #expect(reader.parentReads.isEmpty && reader.childrenReads.isEmpty)
    }

    @Test
    func `coordinate scroll ancestor walk refuses cycles and stops at its fixed budget`() throws {
        let nodes = (120..<154).map { self.makeElement(pid_t($0)) }
        let window = try self.scrollWindow()
        let descriptors = Dictionary(uniqueKeysWithValues: nodes.map {
            ($0, self.descriptor(identifier: "plain", frame: window.bounds))
        })
        let processes = Dictionary(uniqueKeysWithValues: nodes.map { ($0, getpid()) })
        let windows = Dictionary(uniqueKeysWithValues: nodes.map { ($0, CGWindowID(42)) })
        let parents = Dictionary(uniqueKeysWithValues: zip(nodes, nodes.dropFirst()).map { ($0.0, $0.1) })
        let reader = ResolverTreeReader(
            descriptors: descriptors,
            children: [:],
            processIdentifiers: processes,
            hit: .element(nodes[0]),
            parents: parents,
            windowIDs: windows)
        let resolver = AutomationElementResolver(treeReader: reader)
        #expect(throws: PeekabooError.self) {
            try resolver.resolveScrollTarget(at: CGPoint(x: 20, y: 30), target: window)
        }
        #expect(reader.descriptorReads.count == 32)
        #expect(!reader.descriptorReads.contains(nodes[32]))
        #expect(reader.childrenReads.isEmpty)

        let cyclic = ResolverTreeReader(
            descriptors: descriptors,
            children: [:],
            processIdentifiers: processes,
            hit: .element(nodes[0]),
            parents: [nodes[0]: nodes[1], nodes[1]: nodes[0]],
            windowIDs: windows)
        #expect(throws: PeekabooError.self) {
            try AutomationElementResolver(treeReader: cyclic).resolveScrollTarget(
                at: CGPoint(x: 20, y: 30), target: window)
        }
        #expect(cyclic.descriptorReads == [nodes[0], nodes[1]])
        #expect(cyclic.childrenReads.isEmpty)
    }

    @Test(arguments: [AXError.notImplemented, .noValue])
    func `coordinate scroll preserves unsupported hit tests as explicit pixel only candidates`(error: AXError) throws {
        let window = try self.scrollWindow()
        let reader = ResolverTreeReader(
            descriptors: [:], children: [:], processIdentifiers: [:], hit: .unavailable(error))
        let result = try AutomationElementResolver(treeReader: reader).resolveScrollTarget(
            at: CGPoint(x: 20, y: 30), target: window)

        guard case let .pixelOnly(reason) = result else {
            Issue.record("Unavailable hit test must not invent a semantic owner")
            return
        }
        #expect(reason == .hitTestUnavailable(error))
        #expect(reader.hitProcessIdentifiers == [getpid()])
        #expect(reader.descriptorReads.isEmpty && reader.processIdentifierReads.isEmpty)
        #expect(reader.parentReads.isEmpty && reader.childrenReads.isEmpty)
    }

    @Test(arguments: [
        AXError.failure, .illegalArgument, .invalidUIElement, .invalidUIElementObserver, .cannotComplete,
        .attributeUnsupported, .actionUnsupported, .notificationUnsupported, .notificationAlreadyRegistered,
        .notificationNotRegistered, .apiDisabled, .parameterizedAttributeUnsupported, .notEnoughPrecision,
    ])
    func `coordinate scroll refuses other hit test failures with their native stage and code`(error: AXError) throws {
        let window = try self.scrollWindow()
        let reader = ResolverTreeReader(
            descriptors: [:], children: [:], processIdentifiers: [:], hit: .unavailable(error))
        let failure = #expect(throws: DesktopActionFailure.self) {
            try AutomationElementResolver(treeReader: reader).resolveScrollTarget(
                at: CGPoint(x: 20, y: 30), target: window)
        }

        #expect(failure?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(failure?.outcome.retrySafety == .safe)
        #expect(failure?.outcome.refusalReason == (error == .apiDisabled ? .permissionDenied : .targetUnavailable))
        #expect(failure?.causeDescription?.contains("AXUIElementCopyElementAtPosition at the application root") == true)
        #expect(failure?.causeDescription?.contains("AX error \(error.rawValue)") == true)
        #expect(failure?.message.contains("different window") == false)
        #expect(failure?.targetReceipt?.processIdentifier == getpid())
        #expect(failure?.targetReceipt?.windowID == 42)
        #expect(reader.descriptorReads.isEmpty && reader.processIdentifierReads.isEmpty)
        #expect(reader.parentReads.isEmpty && reader.childrenReads.isEmpty)
    }

    @Test
    func `coordinate hit test success without an element is a failure rather than pixel unavailability`() throws {
        let missing = AutomationElementHitTestResult(error: .success, element: nil)
        guard case .unavailable(.failure) = missing else {
            Issue.record("Malformed successful hit test must retain a hard failure")
            return
        }
        let window = try self.scrollWindow()
        let reader = ResolverTreeReader(descriptors: [:], children: [:], processIdentifiers: [:], hit: missing)
        let failure = #expect(throws: DesktopActionFailure.self) {
            try AutomationElementResolver(treeReader: reader).resolveScrollTarget(
                at: CGPoint(x: 20, y: 30), target: window)
        }
        #expect(failure?.causeDescription?.contains("AX error \(AXError.failure.rawValue)") == true)
        #expect(failure?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)

        let element = self.makeElement(160)
        guard case let .element(actual) = AutomationElementHitTestResult(error: .success, element: element) else {
            Issue.record("Successful hit test must preserve its exact element")
            return
        }
        #expect(actual == element)
        guard case .unavailable(.cannotComplete) = AutomationElementHitTestResult(
            error: .cannotComplete, element: element)
        else {
            Issue.record("An error must remain authoritative even when a native element value was returned")
            return
        }
    }

    @Test(arguments: [false, true])
    func `coordinate scroll reports no semantic owner only at its verified exact window`(hitWindow: Bool) throws {
        let leaf = self.makeElement(170), terminal = self.makeElement(171), unrelated = self.makeElement(172)
        let window = try self.scrollWindow()
        let reader = ResolverTreeReader(
            descriptors: [
                leaf: self.descriptor(identifier: "leaf", frame: window.bounds),
                terminal: self.descriptor(identifier: "window", frame: window.bounds, role: "AXWindow"),
                unrelated: self.descriptor(identifier: "unrelated", frame: window.bounds, role: "AXScrollArea"),
            ],
            children: [terminal: [unrelated]],
            processIdentifiers: [leaf: getpid(), terminal: getpid(), unrelated: getpid()],
            hit: .element(hitWindow ? terminal : leaf),
            parents: [leaf: terminal, terminal: unrelated],
            windowIDs: [leaf: 42, terminal: 42, unrelated: 42],
            scrollContainers: [unrelated])
        let result = try AutomationElementResolver(treeReader: reader).resolveScrollTarget(
            at: CGPoint(x: 20, y: 30), target: window)

        guard case .pixelOnly(.noSemanticOwner) = result else {
            Issue.record("A fully verified window-only ancestry should remain an explicit pixel candidate")
            return
        }
        #expect(reader.descriptorReads == (hitWindow ? [terminal] : [leaf, terminal]))
        #expect(reader.parentReads == (hitWindow ? [] : [leaf]))
        #expect(reader.childrenReads.isEmpty)
    }

    @Test(arguments: [0, 1, 2, 3])
    func `coordinate scroll never treats incomplete ancestry as a pixel only candidate`(missing: Int) throws {
        let leaf = self.makeElement(180), ancestor = self.makeElement(181)
        let window = try self.scrollWindow()
        let reader = ResolverTreeReader(
            descriptors: missing == 0
                ? [leaf: self.descriptor(identifier: "leaf", frame: window.bounds)]
                : [
                    leaf: self.descriptor(identifier: "leaf", frame: window.bounds),
                    ancestor: self.descriptor(identifier: "ancestor", frame: window.bounds),
                ],
            children: [:],
            processIdentifiers: missing == 1 ? [leaf: getpid()] : [leaf: getpid(), ancestor: getpid()],
            hit: .element(leaf),
            parents: missing == 3 ? [:] : [leaf: ancestor],
            windowIDs: missing == 2 ? [leaf: 42] : [leaf: 42, ancestor: 42])
        #expect(throws: PeekabooError.self) {
            try AutomationElementResolver(treeReader: reader).resolveScrollTarget(
                at: CGPoint(x: 20, y: 30), target: window)
        }
        #expect(reader.childrenReads.isEmpty)
    }

    @Test(arguments: [false, true])
    func `coordinate scroll refuses conflicting owner or terminal window frames`(semanticOwner: Bool) throws {
        let hit = self.makeElement(190)
        let window = try self.scrollWindow()
        let reader = ResolverTreeReader(
            descriptors: [hit: self.descriptor(
                identifier: "hit",
                frame: semanticOwner ? window.bounds.offsetBy(dx: 400, dy: 0) : window.bounds.insetBy(dx: 1, dy: 1),
                role: semanticOwner ? "AXScrollArea" : "AXWindow")],
            children: [:],
            processIdentifiers: [hit: getpid()],
            hit: .element(hit),
            windowIDs: [hit: 42],
            scrollContainers: semanticOwner ? [hit] : [])
        #expect(throws: PeekabooError.self) {
            try AutomationElementResolver(treeReader: reader).resolveScrollTarget(
                at: CGPoint(x: 20, y: 30), target: window)
        }
        #expect(reader.parentReads.isEmpty && reader.childrenReads.isEmpty)
    }

    private func scrollWindow() throws -> UIAutomationTarget.ExactWindow {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
        return try UIAutomationTarget.ExactWindow(
            identity: .init(
                windowID: 42,
                ownerProcessIdentifier: getpid(),
                ownerProcessStartIdentity: 11,
                capturedBounds: bounds),
            bounds: bounds)
    }

    @Test
    func `exact snapshot match disambiguates duplicate identifiers and frames without scanning the tail`() throws {
        let app = try #require(NSWorkspace.shared.runningApplications.first { !$0.isTerminated })
        let root = self.makeElement(1)
        let duplicateIdentifier = self.makeElement(2)
        let duplicateFrame = self.makeElement(3)
        let match = self.makeElement(4)
        let unvisitedTail = self.makeElement(5)
        let targetFrame = CGRect(x: 120, y: 240, width: 80, height: 32)
        let reader = ResolverTreeReader(
            descriptors: [
                duplicateIdentifier: self.descriptor(
                    identifier: "shared-id",
                    frame: CGRect(x: 20, y: 40, width: 80, height: 32)),
                duplicateFrame: self.descriptor(identifier: "different-id", frame: targetFrame),
                match: self.descriptor(identifier: "shared-id", frame: targetFrame),
                unvisitedTail: self.descriptor(identifier: "shared-id", frame: targetFrame),
            ],
            children: [root: [duplicateIdentifier, duplicateFrame, match, unvisitedTail]],
            processIdentifiers: [match: app.processIdentifier])
        let resolver = AutomationElementResolver(
            windowRootResolver: ResolverWindowRootResolver(root: root),
            treeReader: reader)

        let resolved = resolver.resolve(
            detectedElement: self.detectedElement(identifier: "shared-id", frame: targetFrame),
            windowContext: WindowContext(applicationProcessId: app.processIdentifier, windowID: 42),
            targetProcessIdentifier: app.processIdentifier)

        #expect(resolved?.element == match)
        #expect(reader.descriptorReads == [root, duplicateIdentifier, duplicateFrame, match])
        #expect(!reader.descriptorReads.contains(unvisitedTail))
    }

    @Test
    func `exact snapshot match rejects a candidate from another process`() throws {
        let app = try #require(NSWorkspace.shared.runningApplications.first { !$0.isTerminated })
        let root = self.makeElement(11)
        let wrongProcess = self.makeElement(12)
        let targetFrame = CGRect(x: 120, y: 240, width: 80, height: 32)
        let reader = ResolverTreeReader(
            descriptors: [wrongProcess: self.descriptor(identifier: "target-id", frame: targetFrame)],
            children: [root: [wrongProcess]],
            processIdentifiers: [wrongProcess: app.processIdentifier + 1])
        let resolver = AutomationElementResolver(
            windowRootResolver: ResolverWindowRootResolver(root: root),
            treeReader: reader)

        let resolved = resolver.resolve(
            detectedElement: self.detectedElement(identifier: "target-id", frame: targetFrame),
            windowContext: WindowContext(applicationProcessId: app.processIdentifier, windowID: 42),
            targetProcessIdentifier: app.processIdentifier)

        #expect(resolved == nil)
        #expect(reader.processIdentifierReads == [wrongProcess, wrongProcess])
    }

    @Test
    func `foreign fuzzy candidate cannot shadow a valid target process candidate`() throws {
        let app = try #require(NSWorkspace.shared.runningApplications.first { !$0.isTerminated })
        let root = self.makeElement(21)
        let foreignHighScore = self.makeElement(22)
        let validLowerScore = self.makeElement(23)
        let targetFrame = CGRect(x: 120, y: 240, width: 80, height: 32)
        let reader = ResolverTreeReader(
            descriptors: [
                foreignHighScore: self.descriptor(
                    identifier: "target-id",
                    frame: CGRect(x: 420, y: 540, width: 80, height: 32)),
                validLowerScore: self.descriptor(identifier: "other-id", frame: targetFrame),
            ],
            children: [root: [foreignHighScore, validLowerScore]],
            processIdentifiers: [
                foreignHighScore: app.processIdentifier + 1,
                validLowerScore: app.processIdentifier,
            ])
        let resolver = AutomationElementResolver(
            windowRootResolver: ResolverWindowRootResolver(root: root),
            treeReader: reader)

        let resolved = resolver.resolve(
            detectedElement: self.detectedElement(identifier: "target-id", frame: targetFrame),
            windowContext: WindowContext(applicationProcessId: app.processIdentifier, windowID: 42),
            targetProcessIdentifier: app.processIdentifier)

        #expect(resolved?.element == validLowerScore)
        #expect(reader.processIdentifierReads.contains(foreignHighScore))
        #expect(reader.processIdentifierReads.contains(validLowerScore))
    }

    private func detectedElement(identifier: String, frame: CGRect) -> DetectedElement {
        DetectedElement(
            id: "B1",
            type: .button,
            label: "Target",
            bounds: frame,
            attributes: ["identifier": identifier, "role": "AXButton"])
    }

    private func descriptor(identifier: String, frame: CGRect, role: String = "AXButton") -> AXDescriptorReader
    .Descriptor {
        AXDescriptorReader.Descriptor(
            frame: frame,
            role: role,
            title: "Target",
            label: nil,
            value: nil,
            description: nil,
            help: nil,
            roleDescription: nil,
            identifier: identifier,
            isEnabled: true,
            isSelected: nil,
            isFocused: nil,
            placeholder: nil)
    }

    private func makeElement(_ offset: pid_t) -> Element {
        Element(AXUIElementCreateApplication(getpid() + offset))
    }
}

@MainActor
private final class ResolverTreeReader: AutomationElementTreeReading {
    private let descriptors: [Element: AXDescriptorReader.Descriptor]
    private let childMap: [Element: [Element]]
    private let processIdentifiers: [Element: pid_t]
    private let hit: AutomationElementHitTestResult
    private let parentMap: [Element: Element]
    private let windowIDs: [Element: CGWindowID]
    private let scrollContainers: Set<Element>
    private(set) var descriptorReads: [Element] = []
    private(set) var processIdentifierReads: [Element] = []
    private(set) var parentReads: [Element] = []
    private(set) var childrenReads: [Element] = []
    private(set) var hitProcessIdentifiers: [pid_t] = []

    init(
        descriptors: [Element: AXDescriptorReader.Descriptor],
        children: [Element: [Element]],
        processIdentifiers: [Element: pid_t],
        hit: AutomationElementHitTestResult = .unavailable(.notImplemented),
        parents: [Element: Element] = [:],
        windowIDs: [Element: CGWindowID] = [:],
        scrollContainers: Set<Element> = [])
    {
        self.descriptors = descriptors
        self.childMap = children
        self.processIdentifiers = processIdentifiers
        self.hit = hit
        self.parentMap = parents
        self.windowIDs = windowIDs
        self.scrollContainers = scrollContainers
    }

    func descriptor(for element: Element) -> AXDescriptorReader.Descriptor? {
        self.descriptorReads.append(element)
        return self.descriptors[element]
    }

    func children(of element: Element) -> [Element]? {
        self.childrenReads.append(element)
        return self.childMap[element]
    }

    func hitTest(at _: CGPoint, processIdentifier: pid_t) -> AutomationElementHitTestResult {
        self.hitProcessIdentifiers.append(processIdentifier)
        return self.hit
    }

    func parent(of element: Element) -> Element? {
        self.parentReads.append(element)
        return self.parentMap[element]
    }

    func owningWindowID(of element: Element) -> CGWindowID? {
        self.windowIDs[element]
    }

    func isScrollContainer(_ element: Element) -> Bool {
        self.scrollContainers.contains(element)
    }

    func processIdentifier(of element: Element) -> pid_t? {
        self.processIdentifierReads.append(element)
        return self.processIdentifiers[element]
    }
}

@MainActor
private struct ResolverWindowRootResolver: AutomationWindowRootResolving {
    let root: Element

    func root(for _: CGWindowID, in _: NSRunningApplication) -> Element? {
        self.root
    }
}
