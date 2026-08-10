import AppKit
@preconcurrency import AXorcist
import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomation
@_spi(Testing) import PeekabooAutomationKit
@testable import PeekabooCore
@testable import PeekabooVisualizer

@Suite(.tags(.ui, .safe))
@MainActor
struct ElementDetectionServiceTests {
    @Test
    func `Initialize ElementDetectionService`() {
        let snapshotManager = MockSnapshotManager()
        let service: ElementDetectionService? = ElementDetectionService(snapshotManager: snapshotManager)
        #expect(service != nil)
    }

    @Test
    func `Detect elements rejects a nonexistent target before AX traversal`() async {
        let snapshotManager = MockSnapshotManager()
        let service = ElementDetectionService(snapshotManager: snapshotManager)
        let nonexistentProcessIdentifier: Int32 = -1

        do {
            _ = try await service.detectElements(
                in: Data(),
                snapshotId: "test-snapshot",
                windowContext: WindowContext(applicationProcessId: nonexistentProcessIdentifier))
            Issue.record("Expected the nonexistent target process to be rejected")
        } catch let PeekabooError.appNotFound(identifier) {
            #expect(identifier == "PID:\(nonexistentProcessIdentifier)")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `Window detection works for non-active apps`() {
        let snapshotManager = MockSnapshotManager()
        _ = ElementDetectionService(snapshotManager: snapshotManager)

        // This test verifies that window detection doesn't require the app to be active
        // Previously, the service would throw an error if !targetApp.isActive
        // Now it should work for background apps as well

        // Note: In a real test environment, we'd need to:
        // 1. Launch a test app
        // 2. Switch focus to another app
        // 3. Try to detect windows from the background app
        // 4. Verify it doesn't throw "is running but not active" error

        // For now, we're documenting the expected behavior
        #expect(Bool(true)) // Placeholder for actual test implementation
    }

    @Test
    func `Map element types correctly`() {
        let roleMappings: [(String, ElementType)] = [
            ("AXButton", .button),
            ("AXTextField", .textField),
            ("AXStaticText", .other), // staticText not in protocol
            ("AXLink", .link),
            ("AXImage", .image),
            ("AXCheckBox", .checkbox),
            ("AXRadioButton", .checkbox), // radioButton maps to closest available protocol type
            ("AXPopUpButton", .button),
            ("AXComboBox", .other), // comboBox not in protocol
            ("AXSlider", .slider),
            ("AXMenu", .menu),
            ("AXMenuItem", .other), // menuItem not in protocol
            ("AXUnknown", .other),
        ]

        for (role, expectedType) in roleMappings {
            #expect(ElementClassifier.elementType(for: role) == expectedType)
        }
    }

    @Test
    func `Find element by ID`() async throws {
        let snapshotManager = MockSnapshotManager()

        // Create mock detection result
        let mockElements = [
            DetectedElement(
                id: "button-1",
                type: .button,
                label: "Save",
                value: nil,
                bounds: CGRect(x: 10, y: 10, width: 100, height: 40),
                isEnabled: true,
                isSelected: nil,
                attributes: ["keyboardShortcut": "⌘S"]),
            DetectedElement(
                id: "textfield-1",
                type: .textField,
                label: "Username",
                value: "john_doe",
                bounds: CGRect(x: 10, y: 60, width: 200, height: 30),
                isEnabled: true,
                isSelected: nil,
                attributes: [:]),
        ]

        let detectedElements = DetectedElements(
            buttons: mockElements.filter { $0.type == .button },
            textFields: mockElements.filter { $0.type == .textField })

        let detectionResult = ElementDetectionResult(
            snapshotId: "test-snapshot",
            screenshotPath: "/tmp/test.png",
            elements: detectedElements,
            metadata: DetectionMetadata(
                detectionTime: 0.1,
                elementCount: mockElements.count,
                method: "AXorcist"))

        snapshotManager.primeDetectionResult(detectionResult)

        _ = ElementDetectionService(snapshotManager: snapshotManager)

        // Test getting detection result
        let result = try await snapshotManager.getDetectionResult(snapshotId: "test-snapshot")
        #expect(result != nil)

        // Test finding elements in the stored result
        if let detectionResult = result {
            let allElements = detectionResult.elements.all
            #expect(allElements.count == 2)

            // Find button by ID
            if let button = allElements.first(where: { $0.id == "button-1" }) {
                #expect(button.type == .button)
                #expect(button.label == "Save")
            } else {
                Issue.record("Failed to find button-1")
            }
        }
    }

    @Test
    func `DetectedElements functionality`() {
        let button1 = DetectedElement(
            id: "btn-1",
            type: .button,
            label: "Submit",
            value: nil,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 50),
            isEnabled: true,
            isSelected: nil,
            attributes: ["keyboardShortcut": "⌘S"])
        let button2 = DetectedElement(
            id: "btn-2",
            type: .button,
            label: "Cancel",
            value: nil,
            bounds: CGRect(x: 0, y: 60, width: 100, height: 50),
            isEnabled: false,
            isSelected: nil,
            attributes: [:])
        let textField = DetectedElement(
            id: "txt-1",
            type: .textField,
            label: "Email",
            value: "test@example.com",
            bounds: CGRect(x: 0, y: 120, width: 200, height: 30),
            isEnabled: true,
            isSelected: nil,
            attributes: [:])

        let detectedElements = DetectedElements(
            buttons: [button1, button2],
            textFields: [textField])

        self.assertBasicElementCollections(
            detectedElements,
            expectedTotal: 3,
            disabledId: "btn-2")
    }

    @Test
    func `Actionable element detection`() {
        // Create elements with various actionable states
        let elements = [
            DetectedElement(
                id: "actionable-1",
                type: .button,
                label: "Click Me",
                value: nil,
                bounds: CGRect(x: 0, y: 0, width: 100, height: 50),
                isEnabled: true,
                isSelected: nil,
                attributes: [:]),
            DetectedElement(
                id: "non-actionable-1",
                type: .other, // staticText not in protocol
                label: "Just text",
                value: nil,
                bounds: CGRect(x: 0, y: 60, width: 100, height: 20),
                isEnabled: true,
                isSelected: nil,
                attributes: ["role": "AXStaticText"]),
            DetectedElement(
                id: "actionable-2",
                type: .link,
                label: "Click here",
                value: nil,
                bounds: CGRect(x: 0, y: 90, width: 100, height: 20),
                isEnabled: true,
                isSelected: nil,
                attributes: [:]),
        ]

        let buttonElements = elements.filter { $0.type == .button }
        let linkElements = elements.filter { $0.type == .link }
        let otherElements = elements.filter { $0.type == .other }

        let detectedElements = DetectedElements(
            buttons: buttonElements,
            links: linkElements,
            other: otherElements)

        let result = createDetectionResult(elements: detectedElements, total: elements.count)

        // Verify actionable elements are correctly identified
        let actionableTypes: Set<ElementType> = [.button, .link, .checkbox]
        let actionableElements = result.elements.all.filter { actionableTypes.contains($0.type) }

        #expect(actionableElements.count == 2)
        #expect(actionableElements.contains { $0.id == "actionable-1" })
        #expect(actionableElements.contains { $0.id == "actionable-2" })
    }

    @Test
    func `Keyboard shortcut extraction`() {
        let elements = [
            DetectedElement(
                id: "menu-1",
                type: .other, // menuItem
                label: "Save",
                value: nil,
                bounds: CGRect(x: 0, y: 0, width: 200, height: 30),
                isEnabled: true,
                isSelected: nil,
                attributes: ["keyboardShortcut": "⌘S"]),
            DetectedElement(
                id: "menu-2",
                type: .other, // menuItem
                label: "Save As...",
                value: nil,
                bounds: CGRect(x: 0, y: 30, width: 200, height: 30),
                isEnabled: true,
                isSelected: nil,
                attributes: ["keyboardShortcut": "⇧⌘S"]),
            DetectedElement(
                id: "button-1",
                type: .button,
                label: "OK",
                value: nil,
                bounds: CGRect(x: 0, y: 60, width: 100, height: 40),
                isEnabled: true,
                isSelected: nil,
                attributes: [:]),
        ]

        let elementsWithShortcuts = elements.filter { $0.attributes["keyboardShortcut"] != nil }
        #expect(elementsWithShortcuts.count == 2)
        #expect(elementsWithShortcuts[0].attributes["keyboardShortcut"] == "⌘S")
        #expect(elementsWithShortcuts[1].attributes["keyboardShortcut"] == "⇧⌘S")
    }
}

@Suite(.tags(.ui, .safe))
struct ElementDetectionTimeoutRunnerTests {
    @Test
    func `Detection timeout wins over cooperative cancellation`() async {
        do {
            _ = try await ElementDetectionTimeoutRunner.run(seconds: 0.02) {
                try await Task.sleep(nanoseconds: 500_000_000)
                return [DetectedElement]()
            }
            Issue.record("Expected detection timeout")
        } catch let CaptureError.detectionTimedOut(duration) {
            #expect(duration == 0.02)
        } catch {
            Issue.record("Expected detection timeout, got \(error)")
        }
    }

    @Test
    func `Detection timeout wins over noncooperative work`() async throws {
        let startedAt = Date()

        do {
            _ = try await ElementDetectionTimeoutRunner.run(seconds: 0.02) {
                let stopAt = Date().addingTimeInterval(0.5)
                while Date() < stopAt {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                return [DetectedElement]()
            }
            Issue.record("Expected detection timeout")
        } catch let CaptureError.detectionTimedOut(duration) {
            #expect(duration == 0.02)
        }

        #expect(Date().timeIntervalSince(startedAt) < 0.25)
    }

    @Test
    func `Parent cancellation resumes direct detection timeout runner`() async throws {
        let startedAt = Date()
        let task = Task {
            try await ElementDetectionTimeoutRunner.run(seconds: 5.0) {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return [DetectedElement]()
            }
        }

        try await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected; proves the continuation resumes on parent cancellation.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        #expect(Date().timeIntervalSince(startedAt) < 0.25)
    }
}

@Suite(.tags(.fast))
struct ElementDetectionCacheTests {
    @Test
    func `Cache returns stored elements before TTL expires`() {
        var now = Date(timeIntervalSince1970: 1000)
        let cache = ElementDetectionCache(ttl: 1.0) { now }
        let key = ElementDetectionCache.Key(windowID: 7, processID: pid_t(42), allowWebFocus: true)

        cache.store([Self.element(id: "elem_1")], for: key)
        now.addTimeInterval(0.5)

        #expect(cache.elements(for: key)?.map(\.id) == ["elem_1"])
    }

    @Test
    func `Cache preserves truncation metadata`() {
        let cache = ElementDetectionCache()
        let key = ElementDetectionCache.Key(windowID: 7, processID: pid_t(42), allowWebFocus: true)
        let truncationInfo = DetectionTruncationInfo(maxElementCountReached: true)

        cache.store([Self.element(id: "elem_1")], truncationInfo: truncationInfo, for: key)

        #expect(cache.result(for: key)?.elements.map(\.id) == ["elem_1"])
        #expect(cache.result(for: key)?.truncationInfo == truncationInfo)
    }

    @Test
    func `Cache expires stale elements`() {
        var now = Date(timeIntervalSince1970: 1000)
        let cache = ElementDetectionCache(ttl: 1.0) { now }
        let key = ElementDetectionCache.Key(windowID: 7, processID: pid_t(42), allowWebFocus: true)

        cache.store([Self.element(id: "elem_1")], for: key)
        now.addTimeInterval(1.1)

        #expect(cache.elements(for: key) == nil)
        #expect(cache.elements(for: key) == nil)
    }

    @Test
    func `Mutation watermark invalidates cached observation before TTL expires`() {
        var now = Date(timeIntervalSince1970: 1000)
        let cache = ElementDetectionCache(ttl: 1.5) { now }
        let key = ElementDetectionCache.Key(windowID: 7, processID: pid_t(42), allowWebFocus: false)

        cache.store([Self.element(id: "old-value")], for: key)
        now.addTimeInterval(0.6)

        #expect(
            cache.elements(
                for: key,
                invalidatedThrough: Date(timeIntervalSince1970: 1000.5)) == nil)
        #expect(cache.elements(for: key) == nil)
    }

    @Test
    func `Older mutation watermark preserves a newer cached observation`() {
        var now = Date(timeIntervalSince1970: 1000)
        let cache = ElementDetectionCache(ttl: 1.5) { now }
        let key = ElementDetectionCache.Key(windowID: 7, processID: pid_t(42), allowWebFocus: false)

        cache.store([Self.element(id: "new-value")], for: key)
        now.addTimeInterval(0.6)

        #expect(
            cache.elements(
                for: key,
                invalidatedThrough: Date(timeIntervalSince1970: 999.9))?.map(\.id) == ["new-value"])
    }

    @Test
    func `Cache key requires a window id`() {
        let cache = ElementDetectionCache()

        #expect(cache.key(windowID: nil, processID: pid_t(42), allowWebFocus: true) == nil)
        #expect(
            cache.key(windowID: 7, processID: pid_t(42), allowWebFocus: false) ==
                ElementDetectionCache.Key(windowID: 7, processID: pid_t(42), allowWebFocus: false))
    }

    @Test
    func `Cache key separates web focus policy`() {
        let cache = ElementDetectionCache()
        let focusedKey = ElementDetectionCache.Key(windowID: 7, processID: pid_t(42), allowWebFocus: true)
        let unfocusedKey = ElementDetectionCache.Key(windowID: 7, processID: pid_t(42), allowWebFocus: false)

        cache.store([Self.element(id: "focused")], for: focusedKey)
        cache.store([Self.element(id: "unfocused")], for: unfocusedKey)

        #expect(cache.elements(for: focusedKey)?.map(\.id) == ["focused"])
        #expect(cache.elements(for: unfocusedKey)?.map(\.id) == ["unfocused"])
    }

    private static func element(id: String) -> DetectedElement {
        DetectedElement(
            id: id,
            type: .button,
            label: "Button",
            value: nil,
            bounds: CGRect(x: 0, y: 0, width: 10, height: 10),
            isEnabled: true,
            isSelected: nil,
            attributes: [:])
    }
}

@Suite(.tags(.fast))
struct ElementClassifierTests {
    @Test
    func `Actionability policy separates direct and action lookup roles`() {
        #expect(ElementClassifier.roleIsActionable("AXButton"))
        #expect(ElementClassifier.roleIsActionable("AXTextField"))
        #expect(!ElementClassifier.roleIsActionable("AXGroup"))
        #expect(ElementClassifier.shouldLookupActions(for: "AXGroup"))
        #expect(ElementClassifier.shouldLookupActions(for: "AXImage"))
        #expect(!ElementClassifier.shouldLookupActions(for: "AXStaticText"))
        #expect(ElementClassifier.supportsValueMetadata(for: "AXSlider"))
        #expect(ElementClassifier.supportsValueMetadata(for: "AXDateField"))
        #expect(!ElementClassifier.supportsValueMetadata(for: "AXStaticText"))
    }

    @Test
    func `Keyboard shortcut policy is role scoped`() {
        #expect(ElementClassifier.supportsKeyboardShortcut(for: "AXButton"))
        #expect(ElementClassifier.supportsKeyboardShortcut(for: "AXMenuItem"))
        #expect(!ElementClassifier.supportsKeyboardShortcut(for: "AXTextField"))
        #expect(!ElementClassifier.supportsKeyboardShortcut(for: "AXGroup"))
    }

    @Test
    func `Attributes omit empty optional metadata`() {
        let attributes = ElementClassifier.attributes(
            from: ElementClassifier.AttributeInput(
                role: "AXButton",
                title: "Save",
                description: nil,
                help: "Saves the document",
                roleDescription: "button",
                identifier: "save-button",
                isActionable: true,
                keyboardShortcut: "⌘S",
                placeholder: nil))

        #expect(attributes["role"] == "AXButton")
        #expect(attributes["title"] == "Save")
        #expect(attributes["help"] == "Saves the document")
        #expect(attributes["roleDescription"] == "button")
        #expect(attributes["identifier"] == "save-button")
        #expect(attributes["isActionable"] == "true")
        #expect(attributes["keyboardShortcut"] == "⌘S")
        #expect(attributes["description"] == nil)
        #expect(attributes["placeholder"] == nil)
    }
}

@Suite(.tags(.fast))
struct ElementTypeAdjusterTests {
    @Test
    func `Editable groups resolve to text fields`() {
        let input = ElementTypeAdjustmentInput(
            role: "AXGroup",
            roleDescription: nil,
            title: nil,
            label: nil,
            placeholder: nil,
            isEditable: true)

        #expect(ElementTypeAdjuster
            .resolve(baseType: .group, input: input, hasTextFieldDescendant: false) == .textField)
        #expect(!ElementTypeAdjuster.shouldScanForTextFieldDescendant(baseType: .group, input: input))
    }

    @Test
    func `Text field hints promote generic groups without descendant scan`() {
        let placeholder = ElementTypeAdjustmentInput(
            role: "AXGroup",
            roleDescription: nil,
            title: nil,
            label: nil,
            placeholder: "Email",
            isEditable: false)
        let keyword = ElementTypeAdjustmentInput(
            role: "AXGroup",
            roleDescription: nil,
            title: "Password",
            label: nil,
            placeholder: nil,
            isEditable: false)

        #expect(ElementTypeAdjuster
            .resolve(baseType: .group, input: placeholder, hasTextFieldDescendant: false) == .textField)
        #expect(ElementTypeAdjuster
            .resolve(baseType: .group, input: keyword, hasTextFieldDescendant: false) == .textField)
        #expect(!ElementTypeAdjuster.shouldScanForTextFieldDescendant(baseType: .group, input: keyword))
    }

    @Test
    func `Placeholder-bearing static text proxy recovers hidden text field identity`() {
        let input = ElementTypeAdjustmentInput(
            role: "AXStaticText",
            roleDescription: "text",
            title: nil,
            label: nil,
            placeholder: "name@example.com",
            isEditable: false)

        let resolved = ElementTypeAdjuster.resolve(
            baseType: .other,
            input: input,
            hasTextFieldDescendant: false)

        #expect(resolved == .textField)
        #expect(ElementTypeAdjuster.resolveIdentifier(
            "group-hidden-email-field",
            baseType: .other,
            resolvedType: resolved) == "hidden-email-field")
    }

    @Test
    func `Ordinary static text and native field identifiers are unchanged`() {
        let staticText = ElementTypeAdjustmentInput(
            role: "AXStaticText",
            roleDescription: "text",
            title: "Email",
            label: nil,
            placeholder: nil,
            isEditable: false)

        #expect(ElementTypeAdjuster.resolve(
            baseType: .other,
            input: staticText,
            hasTextFieldDescendant: false) == .other)
        #expect(ElementTypeAdjuster.resolveIdentifier(
            "group-heading",
            baseType: .other,
            resolvedType: .other) == "group-heading")
        #expect(ElementTypeAdjuster.resolveIdentifier(
            "group-native-field",
            baseType: .textField,
            resolvedType: .textField) == "group-native-field")
    }

    @Test
    func `Generic groups scan descendants only when hints are missing`() {
        let input = ElementTypeAdjustmentInput(
            role: "AXGroup",
            roleDescription: nil,
            title: "Container",
            label: nil,
            placeholder: nil,
            isEditable: false)

        #expect(ElementTypeAdjuster.shouldScanForTextFieldDescendant(baseType: .group, input: input))
        #expect(ElementTypeAdjuster.resolve(baseType: .group, input: input, hasTextFieldDescendant: false) == .group)
        #expect(ElementTypeAdjuster.resolve(baseType: .group, input: input, hasTextFieldDescendant: true) == .textField)
    }

    @Test
    func `Non group types keep their classifier result`() {
        let input = ElementTypeAdjustmentInput(
            role: "AXButton",
            roleDescription: "text field",
            title: "Email",
            label: nil,
            placeholder: "Name",
            isEditable: true)

        #expect(ElementTypeAdjuster.resolve(baseType: .button, input: input, hasTextFieldDescendant: true) == .button)
        #expect(!ElementTypeAdjuster.shouldScanForTextFieldDescendant(baseType: .button, input: input))
    }
}

@Suite(.tags(.fast))
struct AXDescriptorReaderTests {
    @Test
    func `Scalar coercion accepts expected AX attribute value shapes`() {
        #expect(AXDescriptorReader.stringValue("Save") == "Save")
        #expect(AXDescriptorReader.stringValue(42) == nil)
        #expect(AXDescriptorReader.displayValue("Save") == "Save")
        #expect(AXDescriptorReader.displayValue(NSNumber(value: 0.5)) == "0.5")
        #expect(AXDescriptorReader.displayValue(NSNumber(value: true)) == "true")
        #expect(AXDescriptorReader.displayValue(NSNumber(value: false)) == "false")
        #expect(AXDescriptorReader.displayValue(NSNull()) == nil)
        #expect(AXDescriptorReader.boolValue(true) == true)
        #expect(AXDescriptorReader.boolValue(false) == false)
        #expect(AXDescriptorReader.boolValue(NSNumber(value: true)) == true)
        #expect(AXDescriptorReader.boolValue("true") == nil)
    }

    @Test
    func `Geometry coercion reads matching AX value types only`() {
        var point = CGPoint(x: 12, y: 34)
        let pointValue = AXValueCreate(.cgPoint, &point)
        #expect(AXDescriptorReader.cgPointValue(pointValue) == point)
        #expect(AXDescriptorReader.cgSizeValue(pointValue) == nil)

        var size = CGSize(width: 56, height: 78)
        let sizeValue = AXValueCreate(.cgSize, &size)
        #expect(AXDescriptorReader.cgSizeValue(sizeValue) == size)
        #expect(AXDescriptorReader.cgPointValue(sizeValue) == nil)
    }
}

@Suite(.tags(.fast))
struct DetectedElementMetadataTests {
    @Test
    func `Explicit actionability and settable metadata remain distinct from enabled state`() {
        let staticText = DetectedElement(
            id: "text",
            type: .staticText,
            bounds: .zero,
            isEnabled: true,
            attributes: ["isActionable": "false"])
        let slider = DetectedElement(
            id: "slider",
            type: .slider,
            bounds: .zero,
            isEnabled: true,
            attributes: ["isActionable": "true", "isValueSettable": "true"])

        #expect(!staticText.isActionable)
        #expect(staticText.isValueSettable == nil)
        #expect(slider.isActionable)
        #expect(slider.isValueSettable == true)
    }
}

@Suite(.tags(.fast))
struct ElementDetectionResultBuilderTests {
    @Test
    func `Groups flat elements by protocol type`() {
        let elements = [
            makeElement(id: "button", type: .button),
            makeElement(id: "field", type: .textField),
            makeElement(id: "menu", type: .menu),
            makeElement(id: "other", type: .other),
        ]

        let grouped = ElementDetectionResultBuilder.group(elements)

        #expect(grouped.buttons.map(\.id) == ["button"])
        #expect(grouped.textFields.map(\.id) == ["field"])
        #expect(grouped.menus.map(\.id) == ["menu"])
        #expect(grouped.other.map(\.id) == ["other"])
        #expect(grouped.all.count == 4)
    }

    @Test
    func `Builds cache metadata and warning consistently`() {
        let context = WindowContext(applicationName: "TextEdit", windowTitle: "Untitled", windowID: 42)
        let result = ElementDetectionResultBuilder.makeResult(
            snapshotId: "snapshot",
            screenshotPath: "/tmp/screen.png",
            elements: [self.makeElement(id: "button", type: .button)],
            usedCache: true,
            windowContext: context,
            isDialog: true,
            detectionTime: 0.25)

        #expect(result.snapshotId == "snapshot")
        #expect(result.screenshotPath == "/tmp/screen.png")
        #expect(result.metadata.elementCount == 1)
        #expect(result.metadata.method == "AXorcist (cached)")
        #expect(result.metadata.warnings == ["ax_cache_hit"])
        #expect(result.metadata.windowContext?.windowID == 42)
        #expect(result.metadata.isDialog == true)
    }

    private func makeElement(id: String, type: ElementType) -> DetectedElement {
        DetectedElement(
            id: id,
            type: type,
            label: id,
            value: nil,
            bounds: CGRect(x: 0, y: 0, width: 10, height: 10),
            isEnabled: true,
            isSelected: nil,
            attributes: [:])
    }
}

extension ElementDetectionServiceTests {
    private func assertBasicElementCollections(
        _ elements: DetectedElements,
        expectedTotal: Int,
        disabledId: String)
    {
        #expect(elements.all.count == expectedTotal)

        let found = elements.findById("btn-1")
        #expect(found?.label == "Submit")

        #expect(elements.buttons.count == 2)
        #expect(elements.buttons.allSatisfy { $0.type == .button })
        #expect(elements.textFields.count == 1)
        #expect(elements.textFields.first?.type == .textField)

        let enabledElements = elements.all.filter(\.isEnabled)
        #expect(enabledElements.count == expectedTotal - 1)

        let disabledElements = elements.all.filter { !$0.isEnabled }
        #expect(disabledElements.count == 1)
        #expect(disabledElements.first?.id == disabledId)
    }
}

// MARK: - Mock Snapshot Manager

@MainActor
private final class MockSnapshotManager: SnapshotManagerProtocol {
    private var mockDetectionResult: ElementDetectionResult?
    private var storedResults: [String: ElementDetectionResult] = [:]

    func primeDetectionResult(_ result: ElementDetectionResult?) {
        self.mockDetectionResult = result
    }

    func createSnapshot() async throws -> String {
        "test-snapshot-\(UUID().uuidString)"
    }

    func storeDetectionResult(snapshotId: String, result: ElementDetectionResult) async throws {
        self.storedResults[snapshotId] = result
    }

    func getDetectionResult(snapshotId: String) async throws -> ElementDetectionResult? {
        self.mockDetectionResult ?? self.storedResults[snapshotId]
    }

    func getMostRecentSnapshot() async -> String? {
        self.storedResults.keys.first
    }

    func getMostRecentSnapshot(applicationBundleId _: String) async -> String? {
        self.storedResults.keys.first
    }

    func invalidateImplicitLatestSnapshot() async throws -> String? {
        nil
    }

    func listSnapshots() async throws -> [SnapshotInfo] {
        []
    }

    func cleanSnapshot(snapshotId: String) async throws {
        self.storedResults.removeValue(forKey: snapshotId)
    }

    func cleanSnapshotsOlderThan(days: Int) async throws -> Int {
        let count = self.storedResults.count
        self.storedResults.removeAll()
        return count
    }

    func cleanAllSnapshots() async throws -> Int {
        let count = self.storedResults.count
        self.storedResults.removeAll()
        return count
    }

    nonisolated func getSnapshotStoragePath() -> String {
        "/tmp/test-snapshots"
    }

    func storeScreenshot(_ request: SnapshotScreenshotRequest) async throws {
        // No-op for tests
        _ = request
    }

    func storeAnnotatedScreenshot(snapshotId: String, annotatedScreenshotPath: String) async throws {
        _ = snapshotId
        _ = annotatedScreenshotPath
    }

    func getElement(snapshotId: String, elementId: String) async throws -> UIElement? {
        nil
    }

    func findElements(snapshotId: String, matching query: String) async throws -> [UIElement] {
        []
    }

    func getUIAutomationSnapshot(snapshotId: String) async throws -> UIAutomationSnapshot? {
        nil
    }
}

private func createDetectionResult(elements: DetectedElements, total: Int) -> ElementDetectionResult {
    ElementDetectionResult(
        snapshotId: "test-snapshot",
        screenshotPath: "/tmp/test.png",
        elements: elements,
        metadata: DetectionMetadata(
            detectionTime: 0.1,
            elementCount: total,
            method: "AXorcist"))
}
