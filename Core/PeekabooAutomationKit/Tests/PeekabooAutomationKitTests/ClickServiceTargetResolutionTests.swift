import AppKit
import ApplicationServices
@preconcurrency import AXorcist
import CoreGraphics
import Foundation
import enum PeekabooFoundation.PeekabooError
import enum PeekabooFoundation.ScrollDirection
import Testing
@testable import PeekabooAutomationKit

@Suite(.serialized)
struct ClickServiceTargetResolutionTests {
    @Test
    @MainActor
    func `action-first missing snapshot fails as stale instead of falling back`() async {
        let service = ClickService(
            snapshotManager: InMemorySnapshotManager(),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst))

        do {
            try await service.click(target: .elementId("B1"), clickType: .single, snapshotId: "missing")
            Issue.record("Expected stale element error for missing action snapshot.")
        } catch let error as ActionInputError {
            #expect(error == .staleElement)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    @MainActor
    func `synthetic click treats explicit missing snapshot as authoritative`() async {
        let synthetic = ClickRecordingSyntheticInputDriver()
        let service = ClickService(
            snapshotManager: InMemorySnapshotManager(),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            syntheticInputDriver: synthetic)

        do {
            try await service.click(
                target: .query("missing-\(UUID().uuidString)"),
                clickType: .single,
                snapshotId: "missing")
            Issue.record("Expected stale element error for missing synthetic snapshot.")
        } catch let error as ActionInputError {
            #expect(error == .staleElement)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(synthetic.events.isEmpty)
    }

    @Test
    @MainActor
    func `action-first unresolved snapshot element falls back to coordinate click`() async throws {
        let element = DetectedElement(
            id: "C1",
            type: .other,
            label: "peekaboo-unresolved-canvas-control-\(UUID().uuidString)",
            value: nil,
            bounds: .init(x: 100, y: 120, width: 40, height: 20),
            isEnabled: true,
            isSelected: nil,
            attributes: [:])
        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot",
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(other: [element]),
            metadata: DetectionMetadata(detectionTime: 0.01, elementCount: 1, method: "test"))
        let synthetic = ClickRecordingSyntheticInputDriver()
        let service = ClickService(
            snapshotManager: InMemorySnapshotManager(detectionResult: detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            syntheticInputDriver: synthetic)

        let result = try await service.click(target: .elementId("C1"), clickType: .right, snapshotId: "snapshot")

        #expect(result.path == .synth)
        #expect(result.fallbackReason == .missingElement)
        #expect(synthetic.events == [
            .click(point: CGPoint(x: 120, y: 130), button: .right, count: 1),
        ])
    }

    @Test
    @MainActor
    func `background click delivers synthetic click to target process`() async throws {
        let synthetic = ClickRecordingSyntheticInputDriver()
        let service = ClickService(
            snapshotManager: InMemorySnapshotManager(),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            syntheticInputDriver: synthetic)

        let result = try await service.click(
            target: .coordinates(CGPoint(x: 10, y: 20)),
            clickType: .single,
            snapshotId: nil,
            targetProcessIdentifier: 12345)

        #expect(result.path == .synth)
        #expect(result.strategy == .actionFirst)
        #expect(result.fallbackReason == .missingElement)
        #expect(synthetic.events == [
            .targetedClick(
                point: CGPoint(x: 10, y: 20),
                button: .left,
                count: 1,
                targetProcessIdentifier: 12345,
                targetWindowID: nil),
        ])
    }

    @Test
    @MainActor
    func `background double click fails fast instead of reporting background success`() async {
        let synthetic = ClickRecordingSyntheticInputDriver()
        let service = ClickService(
            snapshotManager: InMemorySnapshotManager(),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            syntheticInputDriver: synthetic)

        do {
            _ = try await service.click(
                target: .coordinates(CGPoint(x: 10, y: 20)),
                clickType: .double,
                snapshotId: nil,
                targetProcessIdentifier: 12345)
            Issue.record("Expected background double-click to be rejected")
        } catch let PeekabooError.serviceUnavailable(message) {
            #expect(message.contains("--foreground"))
            #expect(message.contains("double-click"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(synthetic.events.isEmpty)
    }

    @Test
    @MainActor
    func `background element double click is rejected before AX or synthesis run`() async {
        let pid = getpid()
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Background Button",
            bounds: .init(x: 20, y: 30, width: 100, height: 40))
        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot",
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(buttons: [element]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 1,
                method: "test",
                windowContext: WindowContext(applicationProcessId: pid, windowID: 42)))
        let action = ClickSuccessfulActionInputDriver()
        let synthetic = ClickRecordingSyntheticInputDriver()
        let service = ClickService(
            snapshotManager: InMemorySnapshotManager(detectionResult: detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            actionInputDriver: action,
            syntheticInputDriver: synthetic,
            automationElementResolver: ClickFixedAutomationElementResolver())

        do {
            _ = try await service.click(
                target: .elementId("B1"),
                clickType: .double,
                snapshotId: "snapshot",
                targetProcessIdentifier: pid)
            Issue.record("Expected background double-click to be rejected")
        } catch let PeekabooError.serviceUnavailable(message) {
            #expect(message.contains("--foreground"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(action.performedActionNames.isEmpty)
        #expect(synthetic.events.isEmpty)
    }

    @Test
    @MainActor
    func `background element click uses action first with targeted synthetic fallback`() async throws {
        let pid = getpid()
        let tracker = ClickWindowTracker(bounds: .zero)
        WindowMovementTracking.provider = tracker
        defer { WindowMovementTracking.provider = nil }
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Background Button",
            value: nil,
            bounds: .init(x: 20, y: 30, width: 100, height: 40),
            isEnabled: true,
            isSelected: nil,
            attributes: ["identifier": "background-button", "role": "AXButton"])
        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot",
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(buttons: [element]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 1,
                method: "test",
                windowContext: WindowContext(applicationProcessId: pid, windowID: 42)))
        let synthetic = ClickRecordingSyntheticInputDriver()
        let service = ClickService(
            snapshotManager: InMemorySnapshotManager(detectionResult: detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            syntheticInputDriver: synthetic)

        let result = try await service.click(
            target: .elementId("B1"),
            clickType: .single,
            snapshotId: "snapshot",
            targetProcessIdentifier: pid)

        #expect(result.path == .synth)
        #expect(result.strategy == .actionFirst)
        #expect(result.fallbackReason == .missingElement)
        #expect(synthetic.events == [
            .targetedClick(
                point: CGPoint(x: 70, y: 50),
                button: .left,
                count: 1,
                targetProcessIdentifier: pid,
                targetWindowID: 42),
        ])
    }

    @Test
    @MainActor
    func `background element click succeeds through AX action without synthesis`() async throws {
        let pid = getpid()
        let tracker = ClickWindowTracker(bounds: .zero)
        WindowMovementTracking.provider = tracker
        defer { WindowMovementTracking.provider = nil }
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Background Button",
            bounds: .init(x: 20, y: 30, width: 100, height: 40))
        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot",
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(buttons: [element]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 1,
                method: "test",
                windowContext: WindowContext(applicationProcessId: pid, windowID: 42)))
        let action = ClickSuccessfulActionInputDriver()
        let synthetic = ClickRecordingSyntheticInputDriver()
        let resolver = ClickFixedAutomationElementResolver()
        let service = ClickService(
            snapshotManager: InMemorySnapshotManager(detectionResult: detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            actionInputDriver: action,
            syntheticInputDriver: synthetic,
            automationElementResolver: resolver)

        let result = try await service.click(
            target: .elementId("B1"),
            clickType: .single,
            snapshotId: "snapshot",
            targetProcessIdentifier: pid)

        #expect(result.path == .action)
        #expect(result.actionName == "AXPress")
        #expect(action.clickCount == 0)
        #expect(action.performedActionNames == [AXActionNames.kAXPressAction])
        #expect(synthetic.events.isEmpty)
        #expect(resolver.targetProcessIdentifiers == [pid])
    }

    @Test
    @MainActor
    func `background element right click succeeds through AXShowMenu without synthesis`() async throws {
        let pid = getpid()
        let tracker = ClickWindowTracker(bounds: .zero)
        WindowMovementTracking.provider = tracker
        defer { WindowMovementTracking.provider = nil }
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Background Button",
            bounds: .init(x: 20, y: 30, width: 100, height: 40))
        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot",
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(buttons: [element]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 1,
                method: "test",
                windowContext: WindowContext(applicationProcessId: pid, windowID: 42)))
        let action = ClickSuccessfulActionInputDriver()
        let synthetic = ClickRecordingSyntheticInputDriver()
        let resolver = ClickFixedAutomationElementResolver()
        let service = ClickService(
            snapshotManager: InMemorySnapshotManager(detectionResult: detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            actionInputDriver: action,
            syntheticInputDriver: synthetic,
            automationElementResolver: resolver)

        let result = try await service.click(
            target: .elementId("B1"),
            clickType: .right,
            snapshotId: "snapshot",
            targetProcessIdentifier: pid)

        #expect(result.path == .action)
        #expect(result.actionName == AXActionNames.kAXShowMenuAction)
        #expect(action.rightClickCount == 1)
        #expect(synthetic.events.isEmpty)
        #expect(resolver.targetProcessIdentifiers == [pid])
    }

    @Test
    @MainActor
    func `background element right click reports synthetic permission when AX fallback fails`() async throws {
        let pid = getpid()
        let tracker = ClickWindowTracker(bounds: .zero)
        WindowMovementTracking.provider = tracker
        defer { WindowMovementTracking.provider = nil }
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Background Button",
            bounds: .init(x: 20, y: 30, width: 100, height: 40))
        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot",
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(buttons: [element]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 1,
                method: "test",
                windowContext: WindowContext(applicationProcessId: pid, windowID: 42)))
        let synthetic = ClickRecordingSyntheticInputDriver(
            targetedClickError: PeekabooError.permissionDeniedEventSynthesizing)
        let resolver = ClickFixedAutomationElementResolver()
        let service = ClickService(
            snapshotManager: InMemorySnapshotManager(detectionResult: detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            actionInputDriver: ClickFailingActionInputDriver(error: .permissionDenied),
            syntheticInputDriver: synthetic,
            automationElementResolver: resolver)

        do {
            _ = try await service.click(
                target: .elementId("B1"),
                clickType: .right,
                snapshotId: "snapshot",
                targetProcessIdentifier: pid)
            Issue.record("Expected Event Synthesizing permission error")
        } catch PeekabooError.permissionDeniedEventSynthesizing {
            // Expected after AX permission failure requests synthetic fallback.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(synthetic.targetedClickAttempts == 1)
        #expect(resolver.targetProcessIdentifiers == [pid])
    }

    @Test
    @MainActor
    func `background non-menu click rejects snapshot without exact window`() async throws {
        let pid = getpid()
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Background Button",
            bounds: .init(x: 20, y: 30, width: 100, height: 40))
        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot",
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(buttons: [element]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 1,
                method: "test",
                windowContext: WindowContext(applicationProcessId: pid)))
        let action = ClickSuccessfulActionInputDriver()
        let synthetic = ClickRecordingSyntheticInputDriver()
        let resolver = ClickFixedAutomationElementResolver()
        let service = ClickService(
            snapshotManager: InMemorySnapshotManager(detectionResult: detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            actionInputDriver: action,
            syntheticInputDriver: synthetic,
            automationElementResolver: resolver)

        await #expect(throws: ActionInputError.self) {
            try await service.click(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: "snapshot",
                targetProcessIdentifier: pid)
        }

        #expect(action.performedActionNames.isEmpty)
        #expect(resolver.targetProcessIdentifiers.isEmpty)
        #expect(synthetic.events.isEmpty)
    }

    @Test
    @MainActor
    func `background menu AX action may resolve from application root without window id`() async throws {
        let pid = getpid()
        let element = DetectedElement(
            id: "M1",
            type: .menuItem,
            label: "Save",
            bounds: .init(x: 20, y: 30, width: 100, height: 40),
            attributes: [
                "role": "AXMenuItem",
                DetectedElementRootPolicy.sourceAttribute: DetectedElementRootPolicy.applicationMenuBarSource,
            ])
        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot",
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(menus: [element]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 1,
                method: "test",
                windowContext: WindowContext(applicationProcessId: pid)))
        let action = ClickSuccessfulActionInputDriver()
        let synthetic = ClickRecordingSyntheticInputDriver()
        let resolver = ClickFixedAutomationElementResolver()
        let service = ClickService(
            snapshotManager: InMemorySnapshotManager(detectionResult: detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            actionInputDriver: action,
            syntheticInputDriver: synthetic,
            automationElementResolver: resolver)

        let result = try await service.click(
            target: .elementId("M1"),
            clickType: .single,
            snapshotId: "snapshot",
            targetProcessIdentifier: pid)

        #expect(result.path == .action)
        #expect(action.performedActionNames == [AXActionNames.kAXPressAction])
        #expect(resolver.targetProcessIdentifiers == [pid])
        #expect(synthetic.events.isEmpty)
    }

    @Test
    @MainActor
    func `background query live fallback stays pinned to snapshot window`() async throws {
        let pid = getpid()
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Different Button",
            bounds: .init(x: 20, y: 30, width: 100, height: 40))
        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot",
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(buttons: [element]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 1,
                method: "test",
                windowContext: WindowContext(
                    applicationProcessId: pid,
                    windowID: 42)))
        let action = ClickSuccessfulActionInputDriver()
        let resolver = ClickFixedAutomationElementResolver()
        let service = ClickService(
            snapshotManager: InMemorySnapshotManager(detectionResult: detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            actionInputDriver: action,
            automationElementResolver: resolver)

        let result = try await service.click(
            target: .query("Live Button"),
            clickType: .single,
            snapshotId: "snapshot",
            targetProcessIdentifier: pid)

        #expect(result.path == .action)
        #expect(action.performedActionNames == [AXActionNames.kAXPressAction])
        #expect(resolver.queryWindowIDs == [42])
        #expect(resolver.queryTargetProcessIdentifiers == [pid])
    }

    @Test
    @MainActor
    func `background missing snapshot query never synthesizes outside its window`() async {
        let pid = getpid()
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Different Button",
            bounds: .init(x: 20, y: 30, width: 100, height: 40))
        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot",
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(buttons: [element]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 1,
                method: "test",
                windowContext: WindowContext(
                    applicationProcessId: pid,
                    windowID: 42)))
        let synthetic = ClickRecordingSyntheticInputDriver()
        let resolver = ClickFixedAutomationElementResolver(resolveQueries: false)
        let service = ClickService(
            snapshotManager: InMemorySnapshotManager(detectionResult: detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            syntheticInputDriver: synthetic,
            automationElementResolver: resolver)

        await #expect(throws: (any Error).self) {
            try await service.click(
                target: .query("Missing Button"),
                clickType: .single,
                snapshotId: "snapshot",
                targetProcessIdentifier: pid)
        }

        #expect(synthetic.events.isEmpty)
        #expect(resolver.queryWindowIDs == [42, 42])
        #expect(resolver.queryTargetProcessIdentifiers == [pid, pid])
    }

    @Test
    @MainActor
    func `background element click rejects vanished window without snapshot bounds`() async {
        let pid = getpid()
        let tracker = ClickWindowTracker(bounds: nil)
        WindowMovementTracking.provider = tracker
        defer { WindowMovementTracking.provider = nil }

        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Background Button",
            bounds: .init(x: 20, y: 30, width: 100, height: 40))
        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot",
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(buttons: [element]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 1,
                method: "test",
                windowContext: WindowContext(
                    applicationProcessId: pid,
                    windowID: 42)))
        let action = ClickSuccessfulActionInputDriver()
        let synthetic = ClickRecordingSyntheticInputDriver()
        let service = ClickService(
            snapshotManager: InMemorySnapshotManager(detectionResult: detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            actionInputDriver: action,
            syntheticInputDriver: synthetic,
            automationElementResolver: ClickFixedAutomationElementResolver())

        await #expect(throws: (any Error).self) {
            try await service.click(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: "snapshot",
                targetProcessIdentifier: pid)
        }

        #expect(action.performedActionNames.isEmpty)
        #expect(synthetic.events.isEmpty)
    }

    @Test
    @MainActor
    func `background AX resolution adjusts the snapshot frame after window movement`() async throws {
        let pid = getpid()
        let tracker = ClickWindowTracker(bounds: CGRect(x: 300, y: 400, width: 300, height: 300))
        WindowMovementTracking.provider = tracker
        defer { WindowMovementTracking.provider = nil }

        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Duplicate",
            bounds: CGRect(x: 120, y: 140, width: 80, height: 30))
        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot",
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(buttons: [element]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 1,
                method: "test",
                windowContext: WindowContext(
                    applicationProcessId: pid,
                    windowID: 42,
                    windowBounds: CGRect(x: 100, y: 100, width: 300, height: 300))))
        let resolver = ClickFixedAutomationElementResolver()
        let synthetic = ClickRecordingSyntheticInputDriver()
        let service = ClickService(
            snapshotManager: InMemorySnapshotManager(detectionResult: detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            actionInputDriver: ClickSuccessfulActionInputDriver(),
            syntheticInputDriver: synthetic,
            automationElementResolver: resolver)

        let result = try await service.click(
            target: .elementId("B1"),
            clickType: .single,
            snapshotId: "snapshot",
            targetProcessIdentifier: pid)

        #expect(result.path == .action)
        #expect(resolver.detectedElements.map(\.bounds) == [
            CGRect(x: 320, y: 440, width: 80, height: 30),
        ])
        #expect(resolver.targetProcessIdentifiers == [pid])
        #expect(synthetic.events.isEmpty)
    }

    @Test
    @MainActor
    func `background AX permission denial falls back to targeted synthesis`() async throws {
        let pid = getpid()
        let tracker = ClickWindowTracker(bounds: .zero)
        WindowMovementTracking.provider = tracker
        defer { WindowMovementTracking.provider = nil }
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Background Button",
            bounds: .init(x: 20, y: 30, width: 100, height: 40))
        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot",
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(buttons: [element]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 1,
                method: "test",
                windowContext: WindowContext(applicationProcessId: pid, windowID: 42)))
        let synthetic = ClickRecordingSyntheticInputDriver()
        let service = ClickService(
            snapshotManager: InMemorySnapshotManager(detectionResult: detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            actionInputDriver: ClickFailingActionInputDriver(error: .permissionDenied),
            syntheticInputDriver: synthetic,
            automationElementResolver: ClickFixedAutomationElementResolver())

        let result = try await service.click(
            target: .elementId("B1"),
            clickType: .single,
            snapshotId: "snapshot",
            targetProcessIdentifier: pid)

        #expect(result.path == .synth)
        #expect(result.fallbackReason == .actionUnsupported)
        #expect(synthetic.events == [
            .targetedClick(
                point: CGPoint(x: 70, y: 50),
                button: .left,
                count: 1,
                targetProcessIdentifier: pid,
                targetWindowID: 42),
        ])
    }

    @Test
    @MainActor
    func `background element click rejects snapshot from another process`() async {
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Background Button",
            bounds: .init(x: 20, y: 30, width: 100, height: 40),
            attributes: ["identifier": "background-button", "role": "AXButton"])
        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot",
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(buttons: [element]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 1,
                method: "test",
                windowContext: WindowContext(applicationProcessId: 222)))
        let synthetic = ClickRecordingSyntheticInputDriver()
        let service = ClickService(
            snapshotManager: InMemorySnapshotManager(detectionResult: detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            syntheticInputDriver: synthetic)

        await #expect(throws: (any Error).self) {
            try await service.click(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: "snapshot",
                targetProcessIdentifier: 333)
        }
        #expect(synthetic.events.isEmpty)
    }

    @Test
    @MainActor
    func `background element click rejects snapshot without process identity`() async {
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Background Button",
            bounds: .init(x: 20, y: 30, width: 100, height: 40))
        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot",
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(buttons: [element]),
            metadata: DetectionMetadata(detectionTime: 0.01, elementCount: 1, method: "test"))
        let synthetic = ClickRecordingSyntheticInputDriver()
        let service = ClickService(
            snapshotManager: InMemorySnapshotManager(detectionResult: detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            syntheticInputDriver: synthetic)

        await #expect(throws: (any Error).self) {
            try await service.click(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: "snapshot",
                targetProcessIdentifier: getpid())
        }
        #expect(synthetic.events.isEmpty)
    }

    @Test
    @MainActor
    func `targeted action-only permission denial maps to accessibility permission`() async {
        let pid = getpid()
        let tracker = ClickWindowTracker(bounds: .zero)
        WindowMovementTracking.provider = tracker
        defer { WindowMovementTracking.provider = nil }
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Background Button",
            bounds: .init(x: 20, y: 30, width: 100, height: 40))
        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot",
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(buttons: [element]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 1,
                method: "test",
                windowContext: WindowContext(applicationProcessId: pid, windowID: 42)))
        let service = ClickService(
            snapshotManager: InMemorySnapshotManager(detectionResult: detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionOnly),
            actionInputDriver: ClickFailingActionInputDriver(error: .permissionDenied),
            automationElementResolver: ClickFixedAutomationElementResolver())

        do {
            try await service.click(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: "snapshot",
                targetProcessIdentifier: pid)
            Issue.record("Expected Accessibility permission error")
        } catch PeekabooError.permissionDeniedAccessibility {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    @MainActor
    func `strict resolver never falls through from a missing target process`() {
        let context = WindowContext(
            applicationBundleId: Bundle.main.bundleIdentifier,
            applicationProcessId: Int32.max)

        let app = AutomationElementResolver().application(
            windowContext: context,
            targetProcessIdentifier: Int32.max)

        #expect(app == nil)
    }

    @Test
    @MainActor
    func `strict resolver pins AX traversal to snapshot window ID`() throws {
        let app = try #require(NSWorkspace.shared.runningApplications.first { !$0.isTerminated })
        let marker = Element(AXUIElementCreateApplication(getpid()))
        let windowResolver = ClickWindowRootResolver(root: marker)
        let context = WindowContext(
            applicationProcessId: app.processIdentifier,
            windowTitle: "duplicate",
            windowID: 42)

        let roots = AutomationElementResolver(windowRootResolver: windowResolver).roots(
            windowContext: context,
            targetProcessIdentifier: app.processIdentifier)

        #expect(roots.count == 1)
        #expect(windowResolver.windowIDs == [42])
        #expect(windowResolver.processIdentifiers == [app.processIdentifier])
    }

    @Test
    @MainActor
    func `strict resolver does not fall back when snapshot window is gone`() throws {
        let app = try #require(NSWorkspace.shared.runningApplications.first { !$0.isTerminated })
        let windowResolver = ClickWindowRootResolver(root: nil)
        let context = WindowContext(
            applicationProcessId: app.processIdentifier,
            windowTitle: "matching title must not broaden lookup",
            windowID: 42)

        let roots = AutomationElementResolver(windowRootResolver: windowResolver).roots(
            windowContext: context,
            targetProcessIdentifier: app.processIdentifier)

        #expect(roots.isEmpty)
        #expect(windowResolver.windowIDs == [42])
    }

    @Test
    @MainActor
    func `menu snapshot elements resolve from the application AX root`() throws {
        let app = try #require(NSWorkspace.shared.runningApplications.first { !$0.isTerminated })
        let windowResolver = ClickWindowRootResolver(root: nil)
        let menuItem = DetectedElement(
            id: "M1",
            type: .other,
            label: "Save",
            bounds: .zero,
            attributes: [
                "role": "AXMenuItem",
                DetectedElementRootPolicy.sourceAttribute: DetectedElementRootPolicy.applicationMenuBarSource,
            ])
        let context = WindowContext(
            applicationProcessId: app.processIdentifier,
            windowID: 42)

        let roots = AutomationElementResolver(windowRootResolver: windowResolver).roots(
            windowContext: context,
            targetProcessIdentifier: app.processIdentifier,
            detectedElement: menuItem)

        #expect(roots.count == 1)
        #expect(windowResolver.windowIDs.isEmpty)
    }

    @Test
    @MainActor
    func `context menu snapshot elements resolve from the exact window AX root`() throws {
        let app = try #require(NSWorkspace.shared.runningApplications.first { !$0.isTerminated })
        let marker = Element(AXUIElementCreateApplication(getpid()))
        let windowResolver = ClickWindowRootResolver(root: marker)
        let menuItem = DetectedElement(
            id: "context-menu-item",
            type: .menuItem,
            label: "Open",
            bounds: .zero,
            attributes: ["role": "AXMenuItem"])
        let context = WindowContext(
            applicationProcessId: app.processIdentifier,
            windowID: 42)

        let roots = AutomationElementResolver(windowRootResolver: windowResolver).roots(
            windowContext: context,
            targetProcessIdentifier: app.processIdentifier,
            detectedElement: menuItem)

        #expect(roots.count == 1)
        #expect(windowResolver.windowIDs == [42])
    }

    @Test
    @MainActor
    func `background synth only click rejects snapshot from another process`() async {
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Background Button",
            bounds: .init(x: 20, y: 30, width: 100, height: 40))
        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot",
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(buttons: [element]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 1,
                method: "test",
                windowContext: WindowContext(applicationProcessId: 222)))
        let synthetic = ClickRecordingSyntheticInputDriver()
        let service = ClickService(
            snapshotManager: InMemorySnapshotManager(detectionResult: detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            syntheticInputDriver: synthetic)

        await #expect(throws: (any Error).self) {
            try await service.click(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: "snapshot",
                targetProcessIdentifier: 333)
        }
        #expect(synthetic.events.isEmpty)
    }

    @Test
    @MainActor
    func `background action only click never synthesizes when element cannot resolve`() async {
        let synthetic = ClickRecordingSyntheticInputDriver()
        let service = ClickService(
            snapshotManager: InMemorySnapshotManager(),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionOnly),
            syntheticInputDriver: synthetic)

        await #expect(throws: ActionInputError.self) {
            try await service.click(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: "missing",
                targetProcessIdentifier: 12345)
        }
        #expect(synthetic.events.isEmpty)
    }

    @Test
    @MainActor
    func `targeted query search never falls back to app under mouse`() {
        var usedMouseFallback = false

        let app = ClickService.querySearchApplication(targetProcessIdentifier: Int32.max) {
            usedMouseFallback = true
            return nil
        }

        #expect(app == nil)
        #expect(!usedMouseFallback)
    }

    @Test
    @MainActor
    func `resolveTargetElement matches identifier and exact label`() {
        let focusButton = DetectedElement(
            id: "B1",
            type: .button,
            label: "Focus Basic Field",
            value: nil,
            bounds: .init(x: 0, y: 0, width: 80, height: 30),
            isEnabled: true,
            isSelected: nil,
            attributes: ["identifier": "focus-basic-button", "role": "AXButton"])
        let basicField = DetectedElement(
            id: "T1",
            type: .textField,
            label: "Type here...",
            value: nil,
            bounds: .init(x: 0, y: 40, width: 200, height: 20),
            isEnabled: true,
            isSelected: nil,
            attributes: ["identifier": "basic-text-field", "role": "AXTextField"])

        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot",
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(buttons: [focusButton], textFields: [basicField]),
            metadata: DetectionMetadata(detectionTime: 0.01, elementCount: 2, method: "test"))

        #expect(ClickService.resolveTargetElement(query: "focus-basic-button", in: detectionResult)?.id == "B1")
        #expect(ClickService.resolveTargetElement(query: "Focus Basic Field", in: detectionResult)?.id == "B1")
    }

    @Test
    @MainActor
    func `resolveTargetElement breaks ties deterministically`() {
        let higher = DetectedElement(
            id: "T_HIGH",
            type: .textField,
            label: "Type here...",
            value: nil,
            bounds: .init(x: 0, y: 100, width: 200, height: 20),
            isEnabled: true,
            isSelected: nil,
            attributes: ["identifier": "basic-text-field", "role": "AXTextField"])
        let lower = DetectedElement(
            id: "T_LOW",
            type: .textField,
            label: "Type here...",
            value: nil,
            bounds: .init(x: 0, y: 40, width: 200, height: 20),
            isEnabled: true,
            isSelected: nil,
            attributes: ["identifier": "basic-text-field", "role": "AXTextField"])

        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot",
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(textFields: [higher, lower]),
            metadata: DetectionMetadata(detectionTime: 0.01, elementCount: 2, method: "test"))

        #expect(ClickService.resolveTargetElement(query: "basic-text-field", in: detectionResult)?.id == "T_LOW")
    }
}

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
    private let targetedClickError: (any Error)?

    init(targetedClickError: (any Error)? = nil) {
        self.targetedClickError = targetedClickError
    }

    func click(at point: CGPoint, button: MouseButton, count: Int) throws {
        self.events.append(.click(point: point, button: button, count: count))
    }

    func click(at point: CGPoint, button: MouseButton, count: Int, targetProcessIdentifier: pid_t) async throws {
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
        targetWindowID: CGWindowID?) async throws
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

@MainActor
private final class ClickFixedAutomationElementResolver: AutomationElementResolving {
    private let element = AutomationElement(Element(AXUIElementCreateApplication(getpid())))
    private let resolveQueries: Bool
    private(set) var targetProcessIdentifiers: [pid_t?] = []
    private(set) var detectedElements: [DetectedElement] = []
    private(set) var queryWindowIDs: [Int?] = []
    private(set) var queryTargetProcessIdentifiers: [pid_t?] = []

    init(resolveQueries: Bool = true) {
        self.resolveQueries = resolveQueries
    }

    func resolve(detectedElement _: DetectedElement, windowContext _: WindowContext?) -> AutomationElement? {
        self.element
    }

    func resolve(
        detectedElement: DetectedElement,
        windowContext _: WindowContext?,
        targetProcessIdentifier: pid_t?) -> AutomationElement?
    {
        self.detectedElements.append(detectedElement)
        self.targetProcessIdentifiers.append(targetProcessIdentifier)
        return self.element
    }

    func resolve(query _: String, windowContext _: WindowContext?, requireTextInput _: Bool) -> AutomationElement? {
        self.resolveQueries ? self.element : nil
    }

    func resolve(
        query _: String,
        windowContext: WindowContext?,
        targetProcessIdentifier: pid_t?,
        requireTextInput _: Bool) -> AutomationElement?
    {
        self.queryWindowIDs.append(windowContext?.windowID)
        self.queryTargetProcessIdentifiers.append(targetProcessIdentifier)
        return self.resolveQueries ? self.element : nil
    }
}

private final class ClickWindowTracker: WindowTrackingProviding, @unchecked Sendable {
    private let bounds: CGRect?

    init(bounds: CGRect?) {
        self.bounds = bounds
    }

    @MainActor
    func windowBounds(for _: CGWindowID) -> CGRect? {
        self.bounds
    }
}

@MainActor
private final class ClickWindowRootResolver: AutomationWindowRootResolving {
    private let root: Element?
    private(set) var windowIDs: [CGWindowID] = []
    private(set) var processIdentifiers: [pid_t] = []

    init(root: Element?) {
        self.root = root
    }

    func root(for windowID: CGWindowID, in application: NSRunningApplication) -> Element? {
        self.windowIDs.append(windowID)
        self.processIdentifiers.append(application.processIdentifier)
        return self.root
    }
}

@MainActor
private final class ClickSuccessfulActionInputDriver: ActionInputDriving {
    private(set) var clickCount = 0
    private(set) var rightClickCount = 0
    private(set) var performedActionNames: [String] = []

    func tryClick(element _: AutomationElement) throws -> ActionInputResult {
        self.clickCount += 1
        return ActionInputResult(actionName: "AXPress", anchorPoint: CGPoint(x: 70, y: 50), elementRole: "AXButton")
    }

    func tryRightClick(element _: any AutomationElementRepresenting) async throws -> ActionInputResult {
        self.rightClickCount += 1
        return ActionInputResult(
            actionName: AXActionNames.kAXShowMenuAction,
            anchorPoint: CGPoint(x: 70, y: 50),
            elementRole: "AXButton")
    }

    func tryScroll(element _: AutomationElement, direction _: ScrollDirection, pages _: Int) throws
    -> ActionInputResult {
        ActionInputResult()
    }

    func trySetText(element _: AutomationElement, text _: String, replace _: Bool) throws
    -> ActionInputResult {
        ActionInputResult()
    }

    func tryHotkey(application _: NSRunningApplication, keys _: [String]) throws
    -> ActionInputResult {
        ActionInputResult()
    }

    func trySetValue(element _: AutomationElement, value _: UIElementValue) throws
    -> ActionInputResult {
        ActionInputResult()
    }

    func tryPerformAction(element _: AutomationElement, actionName: String) throws
    -> ActionInputResult {
        self.performedActionNames.append(actionName)
        return ActionInputResult(
            actionName: actionName,
            anchorPoint: CGPoint(x: 70, y: 50),
            elementRole: "AXButton")
    }
}

@MainActor
private final class ClickFailingActionInputDriver: ActionInputDriving {
    let error: ActionInputError

    init(error: ActionInputError) {
        self.error = error
    }

    func tryClick(element _: AutomationElement) throws -> ActionInputResult {
        throw self.error
    }

    func tryRightClick(element _: any AutomationElementRepresenting) async throws -> ActionInputResult {
        throw self.error
    }

    func tryScroll(element _: AutomationElement, direction _: ScrollDirection, pages _: Int) throws
    -> ActionInputResult {
        throw self.error
    }

    func trySetText(element _: AutomationElement, text _: String, replace _: Bool) throws
    -> ActionInputResult {
        throw self.error
    }

    func tryHotkey(application _: NSRunningApplication, keys _: [String]) throws
    -> ActionInputResult {
        throw self.error
    }

    func trySetValue(element _: AutomationElement, value _: UIElementValue) throws
    -> ActionInputResult {
        throw self.error
    }

    func tryPerformAction(element _: AutomationElement, actionName _: String) throws
    -> ActionInputResult {
        throw self.error
    }
}
