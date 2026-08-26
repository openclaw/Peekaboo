import AppKit
import ApplicationServices
@preconcurrency import AXorcist
import Testing
@testable @_spi(Testing) import PeekabooAutomationKit

@MainActor
struct AutomationElementResolverTests {
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

    private func descriptor(identifier: String, frame: CGRect) -> AXDescriptorReader.Descriptor {
        AXDescriptorReader.Descriptor(
            frame: frame,
            role: "AXButton",
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
    private(set) var descriptorReads: [Element] = []
    private(set) var processIdentifierReads: [Element] = []

    init(
        descriptors: [Element: AXDescriptorReader.Descriptor],
        children: [Element: [Element]],
        processIdentifiers: [Element: pid_t])
    {
        self.descriptors = descriptors
        self.childMap = children
        self.processIdentifiers = processIdentifiers
    }

    func descriptor(for element: Element) -> AXDescriptorReader.Descriptor? {
        self.descriptorReads.append(element)
        return self.descriptors[element]
    }

    func children(of element: Element) -> [Element]? {
        self.childMap[element]
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
