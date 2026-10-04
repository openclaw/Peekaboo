import AppKit
import ApplicationServices
@preconcurrency import AXorcist
import CoreGraphics
import Foundation
import PeekabooFoundation

enum DetectedElementRootPolicy {
    static let sourceAttribute = "source"
    static let applicationMenuBarSource = "applicationMenuBar"

    static func requiresApplicationRoot(_ element: DetectedElement) -> Bool {
        let role = element.attributes["role"]?.lowercased()
        if role == "axmenubar" || role == "axmenubaritem" {
            return true
        }

        let hasLegacyMenuBarID = element.id.hasPrefix("menu_") || element.id.hasPrefix("menuitem_")
        let isMenu = element.type == .menu || element.type == .menuItem ||
            role == "axmenu" || role == "axmenuitem" || hasLegacyMenuBarID
        guard isMenu else { return false }

        if element.attributes[self.sourceAttribute]?.lowercased() == self.applicationMenuBarSource.lowercased() {
            return true
        }

        // Disk-backed snapshots predate the source marker but retain collector-specific IDs.
        return hasLegacyMenuBarID
    }
}

/// Re-resolves snapshot/query targets to live AX elements for action invocation.
@MainActor
protocol AutomationElementResolving: Sendable {
    func resolveScrollTarget(at point: CGPoint, target: UIAutomationTarget.ExactWindow) throws
        -> ScrollCoordinateTarget
    func resolve(detectedElement: DetectedElement, windowContext: WindowContext?) -> AutomationElement?
    func resolve(
        detectedElement: DetectedElement,
        windowContext: WindowContext?,
        targetProcessIdentifier: pid_t?) -> AutomationElement?
    func resolve(query: String, windowContext: WindowContext?, requireTextInput: Bool) -> AutomationElement?
    func resolve(
        query: String,
        windowContext: WindowContext?,
        targetProcessIdentifier: pid_t?,
        requireTextInput: Bool) -> AutomationElement?
}

extension AutomationElementResolving {
    func resolveScrollTarget(at _: CGPoint, target _: UIAutomationTarget.ExactWindow) throws -> ScrollCoordinateTarget {
        throw ActionInputError.unsupported(.missingElement)
    }

    func resolve(detectedElement: DetectedElement, windowContext: WindowContext?) -> AutomationElement? {
        self.resolve(
            detectedElement: detectedElement,
            windowContext: windowContext,
            targetProcessIdentifier: nil)
    }

    func resolve(query: String, windowContext: WindowContext?, requireTextInput: Bool) -> AutomationElement? {
        self.resolve(
            query: query,
            windowContext: windowContext,
            targetProcessIdentifier: nil,
            requireTextInput: requireTextInput)
    }
}

enum ScrollCoordinateTarget {
    case semanticOwner(element: AutomationElement, role: String, bounds: CGRect)
    case pixelOnly(ScrollCoordinateUnavailability)
}

enum ScrollCoordinateUnavailability: Equatable {
    case hitTestUnavailable(AXError)
    case noSemanticOwner
}

enum AutomationElementHitTestResult {
    case element(Element)
    case unavailable(AXError)

    init(error: AXError, element: Element?) {
        guard error == .success else {
            self = .unavailable(error)
            return
        }
        self = element.map(Self.element) ?? .unavailable(.failure)
    }
}

@MainActor
protocol AutomationWindowRootResolving: Sendable {
    func root(for windowID: CGWindowID, in application: NSRunningApplication) -> Element?
}

@MainActor
protocol AutomationElementTreeReading: Sendable {
    func descriptor(for element: Element) -> AXDescriptorReader.Descriptor?
    func children(of element: Element) -> [Element]?
    func processIdentifier(of element: Element) -> pid_t?
    func hitTest(at point: CGPoint, processIdentifier: pid_t) -> AutomationElementHitTestResult
    func parent(of element: Element) -> Element?
    func owningWindowID(of element: Element) -> CGWindowID?
    func isScrollContainer(_ element: Element) -> Bool
    func scrollDescriptor(for element: Element) -> AXDescriptorReader.Descriptor?
}

extension AutomationElementTreeReading {
    func hitTest(at _: CGPoint, processIdentifier _: pid_t) -> AutomationElementHitTestResult {
        .unavailable(.notImplemented)
    }

    func parent(of _: Element) -> Element? {
        nil
    }

    func owningWindowID(of _: Element) -> CGWindowID? {
        nil
    }

    func isScrollContainer(_: Element) -> Bool {
        false
    }

    func scrollDescriptor(for element: Element) -> AXDescriptorReader.Descriptor? {
        self.descriptor(for: element)
    }
}

@MainActor
private struct SystemAutomationWindowRootResolver: AutomationWindowRootResolving {
    private let identityService = WindowIdentityService()

    func root(for windowID: CGWindowID, in application: NSRunningApplication) -> Element? {
        self.identityService.findWindow(byID: windowID, in: application)?.element
    }
}

@MainActor
private struct SystemAutomationElementTreeReader: AutomationElementTreeReading {
    func hitTest(at point: CGPoint, processIdentifier: pid_t) -> AutomationElementHitTestResult {
        let application = AXUIElementCreateApplication(processIdentifier)
        return self.boundedRead(application) {
            var hit: AXUIElement?
            let error = AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &hit)
            return AutomationElementHitTestResult(error: error, element: hit.map(Element.init))
        }
    }

    func parent(of element: Element) -> Element? {
        self.boundedRead(element.underlyingElement) { element.parent() }
    }

    func owningWindowID(of element: Element) -> CGWindowID? {
        self.boundedRead(element.underlyingElement) {
            AXWindowIDResolver.owningWindowID(of: element.underlyingElement)
        }
    }

    func isScrollContainer(_ element: Element) -> Bool {
        self.boundedRead(element.underlyingElement) {
            let wrapped = AutomationElement(element)
            return element.isScrollable() || wrapped.role == "AXScrollBar" || wrapped.role == "AXWebArea" ||
                ["AXScrollUpByPage", "AXScrollDownByPage", "AXScrollLeftByPage", "AXScrollRightByPage"]
                .contains { wrapped.supportsAction($0) }
        }
    }

    func scrollDescriptor(for element: Element) -> AXDescriptorReader.Descriptor? {
        self.boundedRead(element.underlyingElement) { AXDescriptorReader.describe(element) }
    }

    private func boundedRead<T>(_ element: AXUIElement, _ operation: () -> T) -> T {
        AXUIElementSetMessagingTimeout(element, 0.05)
        defer { AXUIElementSetMessagingTimeout(element, 0) }
        return operation()
    }

    func descriptor(for element: Element) -> AXDescriptorReader.Descriptor? {
        AXDescriptorReader.describe(element)
    }

    func children(of element: Element) -> [Element]? {
        element.children()
    }

    func processIdentifier(of element: Element) -> pid_t? {
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element.underlyingElement, &processIdentifier) == .success else {
            return nil
        }
        return processIdentifier
    }
}

@MainActor
struct AutomationElementResolver: AutomationElementResolving {
    private let windowRootResolver: any AutomationWindowRootResolving
    private let treeReader: any AutomationElementTreeReading

    init(
        windowRootResolver: any AutomationWindowRootResolving = SystemAutomationWindowRootResolver(),
        treeReader: any AutomationElementTreeReading = SystemAutomationElementTreeReader())
    {
        self.windowRootResolver = windowRootResolver
        self.treeReader = treeReader
    }

    static func processIdentifier(of element: AutomationElement) -> pid_t? {
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element.element.underlyingElement, &processIdentifier) == .success else {
            return nil
        }
        return processIdentifier
    }

    func resolveScrollTarget(
        at point: CGPoint,
        target: UIAutomationTarget.ExactWindow) throws -> ScrollCoordinateTarget
    {
        guard point.x.isFinite, point.y.isFinite, target.bounds.contains(point)
        else { throw ActionInputError.unsupported(.missingElement) }
        try Task.checkCancellation()
        let hit = self.treeReader.hitTest(at: point, processIdentifier: target.identity.ownerProcessIdentifier)
        try Task.checkCancellation()
        var current: Element
        switch hit {
        case let .element(element):
            current = element
        case .unavailable(.notImplemented):
            return .pixelOnly(.hitTestUnavailable(.notImplemented))
        case .unavailable(.noValue):
            return .pixelOnly(.hitTestUnavailable(.noValue))
        case let .unavailable(error):
            throw DesktopActionFailure.preDispatchRefusal(
                reason: error == .apiDisabled ? .permissionDenied : .targetUnavailable,
                message: "Coordinate scroll could not complete its Accessibility hit test.",
                hint: "Observe the exact target window before retrying coordinate scroll.",
                causeDescription: "AXUIElementCopyElementAtPosition at the application root failed with " +
                    "AX error \(error.rawValue).",
                standardErrorCode: error == .apiDisabled ? .accessibilityPermissionDenied : .unknownError)
                .attributed(to: DesktopTargetIdentity(exactWindow: target).actionTargetReceipt)
        }
        var visited = Set<Element>()
        for _ in 0..<32 {
            try Task.checkCancellation()
            guard visited.insert(current).inserted,
                  self.treeReader.processIdentifier(of: current) == target.identity.ownerProcessIdentifier,
                  self.treeReader.owningWindowID(of: current).map(Int.init) == target.identity.windowID,
                  let descriptor = self.treeReader.scrollDescriptor(for: current)
            else {
                throw PeekabooError.snapshotStale("Coordinate scroll could not verify the hit's exact-window ancestry")
            }
            if self.treeReader.isScrollContainer(current) {
                let frame = descriptor.frame
                guard frame.origin.x.isFinite, frame.origin.y.isFinite, frame.width.isFinite, frame.height.isFinite,
                      frame.width > 0, frame.height > 0, frame.contains(point)
                else {
                    throw PeekabooError.snapshotStale("The owning scroller no longer contains the requested point")
                }
                return .semanticOwner(element: AutomationElement(current), role: descriptor.role, bounds: frame)
            }
            if descriptor.role == "AXWindow" {
                guard descriptor.frame == target.bounds else {
                    throw PeekabooError.snapshotStale("The exact window changed during coordinate scroll resolution")
                }
                return .pixelOnly(.noSemanticOwner)
            }
            guard let parent = self.treeReader.parent(of: current) else {
                throw PeekabooError.snapshotStale("Coordinate scroll ancestry ended before its exact window")
            }
            current = parent
        }
        throw PeekabooError.snapshotStale("Coordinate scroll ancestry exceeded its bounded traversal")
    }

    func resolve(
        detectedElement: DetectedElement,
        windowContext: WindowContext?) -> AutomationElement?
    {
        self.resolve(
            detectedElement: detectedElement,
            windowContext: windowContext,
            targetProcessIdentifier: nil)
    }

    func resolve(
        detectedElement: DetectedElement,
        windowContext: WindowContext?,
        targetProcessIdentifier: pid_t?) -> AutomationElement?
    {
        self.bestElement(
            in: self.roots(
                windowContext: windowContext,
                targetProcessIdentifier: targetProcessIdentifier,
                detectedElement: detectedElement),
            targetProcessIdentifier: targetProcessIdentifier,
            exactSnapshotElement: self.canUseExactSnapshotFastPath(
                detectedElement: detectedElement,
                windowContext: windowContext) ? detectedElement : nil)
        { _, descriptor in
            self.score(descriptor: descriptor, for: detectedElement)
        }
    }

    func resolve(
        query: String,
        windowContext: WindowContext?,
        requireTextInput: Bool = false) -> AutomationElement?
    {
        self.resolve(
            query: query,
            windowContext: windowContext,
            targetProcessIdentifier: nil,
            requireTextInput: requireTextInput)
    }

    func resolve(
        query: String,
        windowContext: WindowContext?,
        targetProcessIdentifier: pid_t?,
        requireTextInput: Bool = false) -> AutomationElement?
    {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return nil }

        return self.bestElement(
            in: self.roots(
                windowContext: windowContext,
                targetProcessIdentifier: targetProcessIdentifier),
            targetProcessIdentifier: targetProcessIdentifier)
        { _, descriptor in
            if requireTextInput, !self.isTextInput(role: descriptor.role) {
                return nil
            }
            return self.score(descriptor: descriptor, query: query)
        }
    }

    func roots(
        windowContext: WindowContext?,
        targetProcessIdentifier: pid_t?,
        detectedElement: DetectedElement? = nil) -> [Element]
    {
        guard let app = self.application(
            windowContext: windowContext,
            targetProcessIdentifier: targetProcessIdentifier)
        else {
            return []
        }

        let axApp = AXApp(app)
        if let detectedElement, DetectedElementRootPolicy.requiresApplicationRoot(detectedElement) {
            return [axApp.element]
        }

        if let rawWindowID = windowContext?.windowID {
            guard let windowID = CGWindowID(exactly: rawWindowID),
                  let root = self.windowRootResolver.root(for: windowID, in: app)
            else {
                return []
            }
            return [root]
        }

        let windows = axApp.windows() ?? []

        if let title = windowContext?.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty,
           let match = windows.first(where: { $0.title() == title })
        {
            return [match, axApp.element]
        }

        if let focused = axApp.focusedWindow() {
            return [focused] + windows + [axApp.element]
        }

        return windows + [axApp.element]
    }

    func application(windowContext: WindowContext?, targetProcessIdentifier: pid_t?) -> NSRunningApplication? {
        if let targetProcessIdentifier {
            if let contextProcessIdentifier = windowContext?.applicationProcessId,
               contextProcessIdentifier != targetProcessIdentifier
            {
                return nil
            }

            guard let app = NSRunningApplication(processIdentifier: targetProcessIdentifier),
                  !app.isTerminated
            else {
                return nil
            }
            if let expectedBundleIdentifier = windowContext?.applicationBundleId,
               let actualBundleIdentifier = app.bundleIdentifier,
               expectedBundleIdentifier != actualBundleIdentifier
            {
                return nil
            }
            return app
        }

        if let processId = windowContext?.applicationProcessId,
           let app = NSRunningApplication(processIdentifier: processId)
        {
            return app.isTerminated ? nil : app
        }

        if let bundleIdentifier = windowContext?.applicationBundleId,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
        {
            return app
        }

        return NSWorkspace.shared.frontmostApplication
    }

    private func bestElement(
        in roots: [Element],
        targetProcessIdentifier: pid_t? = nil,
        exactSnapshotElement: DetectedElement? = nil,
        scorer: (Element, AXDescriptorReader.Descriptor) -> Int?) -> AutomationElement?
    {
        var visited = 0
        var stack = roots
        var best: Element?
        var bestScore = 0

        while let element = stack.popLast(), visited < 4000 {
            visited += 1

            if let descriptor = self.treeReader.descriptor(for: element) {
                if let exactSnapshotElement,
                   self.isExactSnapshotMatch(descriptor: descriptor, for: exactSnapshotElement),
                   self.matchesProcessIdentifier(element, targetProcessIdentifier)
                {
                    return AutomationElement(element)
                }

                if self.matchesProcessIdentifier(element, targetProcessIdentifier),
                   let score = scorer(element, descriptor),
                   score > bestScore
                {
                    best = element
                    bestScore = score
                }
            }

            if let children = self.treeReader.children(of: element) {
                stack.append(contentsOf: children.reversed())
            }
        }

        guard let best else { return nil }
        return AutomationElement(best)
    }

    private func canUseExactSnapshotFastPath(
        detectedElement: DetectedElement,
        windowContext: WindowContext?) -> Bool
    {
        windowContext?.windowID != nil || DetectedElementRootPolicy.requiresApplicationRoot(detectedElement)
    }

    private func isExactSnapshotMatch(
        descriptor: AXDescriptorReader.Descriptor,
        for element: DetectedElement) -> Bool
    {
        guard let expectedIdentifier = self.normalized(element.attributes["identifier"]),
              let actualIdentifier = self.normalized(descriptor.identifier),
              expectedIdentifier == actualIdentifier,
              descriptor.frame.equalTo(element.bounds)
        else {
            return false
        }

        if let expectedRole = self.normalized(element.attributes["role"]) {
            return self.normalized(descriptor.role) == expectedRole
        }

        // `.other` deliberately accepts any role in fuzzy scoring, so it cannot establish exact identity.
        return element.type != .other && self.elementType(element.type, matchesRole: descriptor.role)
    }

    private func matchesProcessIdentifier(_ element: Element, _ expectedProcessIdentifier: pid_t?) -> Bool {
        guard let expectedProcessIdentifier else { return true }
        return self.treeReader.processIdentifier(of: element) == expectedProcessIdentifier
    }

    private func normalized(_ value: String?) -> String? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty
        else {
            return nil
        }
        return normalized
    }

    private func score(descriptor: AXDescriptorReader.Descriptor, for element: DetectedElement) -> Int? {
        var score = 0
        let candidates = self.candidates(from: descriptor)
        let elementCandidates = [
            element.attributes["identifier"],
            element.label,
            element.value,
            element.attributes["title"],
            element.attributes["description"],
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        if let identifier = element.attributes["identifier"]?.lowercased(),
           descriptor.identifier?.lowercased() == identifier
        {
            score += 500
        }

        for candidate in elementCandidates where candidates.contains(candidate) {
            score += 180
        }

        if self.elementType(element.type, matchesRole: descriptor.role) {
            score += 50
        }

        score += self.frameScore(descriptor.frame, element.bounds)

        return score >= 180 ? score : nil
    }

    private func score(descriptor: AXDescriptorReader.Descriptor, query: String) -> Int? {
        var score = 0
        for candidate in self.candidates(from: descriptor) {
            if candidate == query {
                score += 300
            } else if candidate.contains(query) {
                score += 100
            }
        }

        return score > 0 ? score : nil
    }

    private func candidates(from descriptor: AXDescriptorReader.Descriptor) -> [String] {
        [
            descriptor.identifier,
            descriptor.title,
            descriptor.label,
            descriptor.value,
            descriptor.description,
            descriptor.help,
            descriptor.roleDescription,
            descriptor.placeholder,
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    private func frameScore(_ lhs: CGRect, _ rhs: CGRect) -> Int {
        guard !lhs.isNull, !rhs.isNull, lhs.width > 0, lhs.height > 0, rhs.width > 0, rhs.height > 0 else {
            return 0
        }

        if lhs.equalTo(rhs) {
            return 250
        }

        let midpointDistance = hypot(lhs.midX - rhs.midX, lhs.midY - rhs.midY)
        if midpointDistance <= 4 {
            return 180
        }
        if midpointDistance <= 12 {
            return 100
        }

        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        let overlap = (intersection.width * intersection.height) / max(
            1,
            min(lhs.width * lhs.height, rhs.width * rhs.height))
        return overlap >= 0.75 ? 100 : 0
    }

    private func elementType(_ type: ElementType, matchesRole role: String) -> Bool {
        let role = role.lowercased()
        switch type {
        case .button:
            return role.contains("button")
        case .textField:
            return self.isTextInput(role: role)
        case .link:
            return role.contains("link")
        case .image:
            return role.contains("image")
        case .slider:
            return role.contains("slider")
        case .checkbox:
            return role.contains("checkbox") || role.contains("check")
        case .menu:
            return role.contains("menu")
        case .group:
            return role.contains("group")
        case .staticText:
            return role.contains("static") || role.contains("text")
        case .radioButton:
            return role.contains("radio")
        case .menuItem:
            return role.contains("menuitem") || role.contains("menu item")
        case .window:
            return role.contains("window")
        case .dialog:
            return role.contains("dialog") || role.contains("sheet")
        case .other:
            return true
        }
    }

    private func isTextInput(role: String) -> Bool {
        let role = role.lowercased()
        return role.contains("textfield") || role.contains("textarea") || role.contains("searchfield")
    }
}
