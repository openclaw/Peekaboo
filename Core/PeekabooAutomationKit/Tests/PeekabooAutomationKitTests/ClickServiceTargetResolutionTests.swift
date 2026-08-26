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

@Suite(.serialized)
struct ClickServiceTargetResolutionTests {
    private static let snapshotID = SnapshotReferenceFixtures.first.rawValue

    @Test
    @MainActor
    func `generation-pinned click rejects recycled PID before dispatch`() async throws {
        let identity = ApplicationProcessIdentity(processIdentifier: getpid(), processStartIdentity: 71)
        let action = ClickSuccessfulActionInputDriver()
        let service = UIAutomationService(
            inputPolicy: UIInputPolicy(defaultStrategy: .actionOnly),
            actionInputDriver: action,
            automationElementResolver: ClickFixedAutomationElementResolver(),
            processStartIdentityProvider: { _ in 72 })

        await #expect(throws: PeekabooError.self) {
            try await service.click(
                target: .query("Button"),
                clickType: .single,
                snapshotId: nil,
                expectedProcessIdentity: identity)
        }
        #expect(action.performedActionNames.isEmpty)
    }

    @Test
    @MainActor
    func `generation-pinned click revalidates after element resolution before dispatch`() async throws {
        let generation = ClickLockedGeneration(71)
        let identity = ApplicationProcessIdentity(processIdentifier: getpid(), processStartIdentity: 71)
        let action = ClickSuccessfulActionInputDriver()
        let detection = ElementDetectionResult(
            snapshotId: Self.snapshotID,
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(buttons: [DetectedElement(
                id: "B1",
                type: .button,
                label: "Button",
                bounds: CGRect(x: 20, y: 30, width: 100, height: 40))]),
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: 1,
                method: "test",
                windowContext: WindowContext(
                    applicationProcessId: identity.processIdentifier,
                    windowID: 42,
                    windowBounds: Self.testWindowBounds,
                    windowMutationIdentity: WindowMutationIdentity(
                        windowID: 42,
                        ownerProcessIdentifier: identity.processIdentifier,
                        ownerProcessStartIdentity: identity.processStartIdentity,
                        capturedBounds: Self.testWindowBounds))))
        let service = try await UIAutomationService(
            snapshotManager: InMemorySnapshotManager.containing(detection),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionOnly),
            actionInputDriver: action,
            automationElementResolver: ClickFixedAutomationElementResolver(
                afterResolve: { generation.value = 72 }),
            exactWindowIdentityValidator: { _, _ in true },
            processStartIdentityProvider: { _ in generation.value })

        await #expect(throws: PeekabooError.self) {
            try await service.click(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: Self.snapshotID,
                expectedProcessIdentity: identity)
        }
        #expect(action.performedActionNames.isEmpty)
    }

    @Test
    @MainActor
    func `generation-pinned click reports post-dispatch drift as retry unsafe`() async throws {
        let generation = ClickLockedGeneration(73)
        let identity = ApplicationProcessIdentity(processIdentifier: getpid(), processStartIdentity: 73)
        let action = ClickSuccessfulActionInputDriver(afterAction: { generation.value = 74 })
        let tracker = ClickWindowTracker(bounds: Self.testWindowBounds)
        try await WindowMovementTrackingProviderScope.withProvider(tracker) {
            let detection = ElementDetectionResult(
                snapshotId: Self.snapshotID,
                screenshotPath: "/tmp/shot.png",
                elements: DetectedElements(buttons: [DetectedElement(
                    id: "B1",
                    type: .button,
                    label: "Button",
                    bounds: CGRect(x: 20, y: 30, width: 100, height: 40))]),
                metadata: DetectionMetadata(
                    detectionTime: 0,
                    elementCount: 1,
                    method: "test",
                    windowContext: WindowContext(
                        applicationProcessId: identity.processIdentifier,
                        windowID: 42,
                        windowBounds: Self.testWindowBounds,
                        windowMutationIdentity: WindowMutationIdentity(
                            windowID: 42,
                            ownerProcessIdentifier: identity.processIdentifier,
                            ownerProcessStartIdentity: identity.processStartIdentity,
                            capturedBounds: Self.testWindowBounds))))
            let service = try await UIAutomationService(
                snapshotManager: InMemorySnapshotManager.containing(detection),
                inputPolicy: UIInputPolicy(defaultStrategy: .actionOnly),
                actionInputDriver: action,
                automationElementResolver: ClickFixedAutomationElementResolver(),
                exactWindowIdentityValidator: { _, _ in true },
                processStartIdentityProvider: { _ in generation.value })

            do {
                try await service.click(
                    target: .elementId("B1"),
                    clickType: .single,
                    snapshotId: Self.snapshotID,
                    expectedProcessIdentity: identity)
                Issue.record("Expected post-dispatch process drift")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome.state == .dispatchedUnverified)
                #expect(failure.outcome.retrySafety == .unsafe)
                #expect(failure.causeDescription?.contains("generation") == true)
            }
            #expect(action.performedActionNames == [AXActionNames.kAXPressAction])
        }
    }

    @Test
    @MainActor
    func `post-click focus failure preserves dispatched outcome for id and query targets`() async throws {
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Post Validation Target",
            bounds: CGRect(x: 20, y: 30, width: 100, height: 40),
            attributes: ["identifier": "peekaboo-post-validation-never-focused"])
        let detection = ElementDetectionResult(
            snapshotId: Self.snapshotID,
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(buttons: [element]),
            metadata: DetectionMetadata(detectionTime: 0, elementCount: 1, method: "test"))

        for target in [ClickTarget.elementId("B1"), .query("Post Validation Target")] {
            let synthetic = ClickRecordingSyntheticInputDriver(failGlobalClickAt: 2)
            let service = try await ClickService(
                snapshotManager: InMemorySnapshotManager.containing(detection),
                inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
                syntheticInputDriver: synthetic)

            do {
                _ = try await service.click(target: target, clickType: .single, snapshotId: Self.snapshotID)
                Issue.record("Expected post-click focus validation failure")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome.state == .dispatchedUnverified)
                #expect(failure.outcome.delivery == .init(mechanism: .globalEvents, mode: .foreground))
                #expect(failure.outcome.retrySafety == .unsafe)
                #expect(failure.causeDescription?.contains("synthetic click failure") == true)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(synthetic.events == [
                .click(point: CGPoint(x: 70, y: 50), button: .left, count: 1),
            ])
        }
    }

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
            snapshotId: Self.snapshotID,
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(other: [element]),
            metadata: DetectionMetadata(detectionTime: 0.01, elementCount: 1, method: "test"))
        let synthetic = ClickRecordingSyntheticInputDriver()
        let service = try await ClickService(
            snapshotManager: InMemorySnapshotManager.containing(detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            syntheticInputDriver: synthetic,
            automationElementResolver: ClickMissingAutomationElementResolver())

        let result = try await service.click(target: .elementId("C1"), clickType: .right, snapshotId: Self.snapshotID)

        #expect(result.path == .synth)
        #expect(result.fallbackReason == .missingElement)
        #expect(synthetic.events == [
            .click(point: CGPoint(x: 120, y: 130), button: .right, count: 1),
        ])
    }

    @Test
    @MainActor
    func `OCR semantic element refuses before exact owner delivery or synthetic fallback`() async throws {
        let pid = getpid()
        let element = DetectedElement(
            id: "ocr_1",
            type: .staticText,
            label: "August 10, 2026",
            bounds: CGRect(x: 100, y: 120, width: 180, height: 24),
            attributes: [
                "description": "ocr",
                "confidence": "0.93",
            ])
        let detectionResult = ElementDetectionResult(
            snapshotId: Self.snapshotID,
            screenshotPath: "/tmp/calendar.png",
            elements: DetectedElements(other: [element]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 1,
                method: "AXorcist+OCR",
                windowContext: Self.exactWindowContext(processIdentifier: pid)))
        let action = ClickSuccessfulActionInputDriver()
        let synthetic = ClickRecordingSyntheticInputDriver()
        let resolver = ClickFixedAutomationElementResolver()
        let service = try await ClickService(
            snapshotManager: InMemorySnapshotManager.containing(detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            actionInputDriver: action,
            syntheticInputDriver: synthetic,
            automationElementResolver: resolver,
            exactWindowIdentityValidator: { _, _ in true })

        do {
            _ = try await service.click(
                target: .elementId("ocr_1"),
                clickType: .single,
                snapshotId: Self.snapshotID,
                targetProcessIdentifier: pid)
            Issue.record("Expected OCR semantic evidence refusal")
        } catch let PeekabooError.invalidInput(message) {
            #expect(message.contains("semantic evidence"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(action.performedActionNames.isEmpty)
        #expect(action.clickCount == 0)
        #expect(synthetic.events.isEmpty)
        #expect(resolver.targetProcessIdentifiers.isEmpty)
    }

    @Test
    @MainActor
    func `query resolution skips OCR when a later ordinary nonactionable match exists`() throws {
        let ocr = DetectedElement(
            id: "ocr_1",
            type: .staticText,
            label: "August",
            bounds: CGRect(x: 10, y: 10, width: 100, height: 20),
            attributes: [
                "description": "ocr",
                "confidence": "0.93",
            ])
        let ordinary = DetectedElement(
            id: "S1",
            type: .staticText,
            label: "August",
            bounds: CGRect(x: 10, y: 40, width: 100, height: 20))
        let result = ElementDetectionResult(
            snapshotId: Self.snapshotID,
            screenshotPath: "/tmp/calendar.png",
            elements: DetectedElements(other: [ocr, ordinary]),
            metadata: DetectionMetadata(detectionTime: 0, elementCount: 2, method: "test"))

        let match = try #require(ClickService.resolveTargetElement(query: "August", in: result))

        #expect(match.id == "S1")
    }

    @Test
    @MainActor
    func `background coordinate click refuses PID only routing`() async {
        let synthetic = ClickRecordingSyntheticInputDriver()
        let service = ClickService(
            snapshotManager: InMemorySnapshotManager(),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            syntheticInputDriver: synthetic)

        await #expect(throws: PeekabooError.self) {
            _ = try await service.click(
                target: .coordinates(CGPoint(x: 10, y: 20)),
                clickType: .single,
                snapshotId: nil,
                targetProcessIdentifier: 12345)
        }
        #expect(synthetic.events.isEmpty)
    }

    @Test
    @MainActor
    func `background coordinate double click refuses PID only routing`() async {
        let synthetic = ClickRecordingSyntheticInputDriver()
        let service = ClickService(
            snapshotManager: InMemorySnapshotManager(),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            syntheticInputDriver: synthetic)

        await #expect(throws: PeekabooError.self) {
            _ = try await service.click(
                target: .coordinates(CGPoint(x: 10, y: 20)),
                clickType: .double,
                snapshotId: nil,
                targetProcessIdentifier: 12345)
        }
        #expect(synthetic.events.isEmpty)
    }

    @Test
    @MainActor
    func `background element double click falls back from AX to exact synthetic routing`() async throws {
        let pid = getpid()
        let tracker = ClickWindowTracker(bounds: Self.testWindowBounds)
        try await WindowMovementTrackingProviderScope.withProvider(tracker) {
            let element = DetectedElement(
                id: "B1",
                type: .button,
                label: "Background Button",
                bounds: .init(x: 20, y: 30, width: 100, height: 40))
            let detectionResult = ElementDetectionResult(
                snapshotId: Self.snapshotID,
                screenshotPath: "/tmp/shot.png",
                elements: DetectedElements(buttons: [element]),
                metadata: DetectionMetadata(
                    detectionTime: 0.01,
                    elementCount: 1,
                    method: "test",
                    windowContext: Self.exactWindowContext(processIdentifier: pid)))
            let action = ClickSuccessfulActionInputDriver()
            let unitCount = try #require(DesktopActionOutcome.DispatchUnitCount(4))
            let expectedOutcome = DesktopActionOutcome.dispatchedUnverified(
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: unitCount)
            let synthetic = ClickRecordingSyntheticInputDriver(targetedClickOutcome: expectedOutcome)
            let service = try await ClickService(
                snapshotManager: InMemorySnapshotManager.containing(detectionResult),
                inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
                actionInputDriver: action,
                syntheticInputDriver: synthetic,
                automationElementResolver: ClickFixedAutomationElementResolver(),
                exactWindowIdentityValidator: { _, _ in true })

            let result = try await service.click(
                target: .elementId("B1"),
                clickType: .double,
                snapshotId: Self.snapshotID,
                targetProcessIdentifier: pid)

            #expect(result.path == .synth)
            #expect(result.fallbackReason == .actionUnsupported)
            #expect(result.outcome == expectedOutcome)
            #expect(result.outcome.dispatchState.unitCount == unitCount)
            #expect(action.performedActionNames.isEmpty)
            #expect(synthetic.events == [
                .targetedClick(
                    point: CGPoint(x: 70, y: 50),
                    button: .left,
                    count: 2,
                    targetProcessIdentifier: pid,
                    targetWindowID: 42),
            ])
        }
    }

    @Test
    @MainActor
    func `background element click uses action first with targeted synthetic fallback`() async throws {
        let pid = getpid()
        let tracker = ClickWindowTracker(bounds: Self.testWindowBounds)
        try await WindowMovementTrackingProviderScope.withProvider(tracker) {
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
                snapshotId: Self.snapshotID,
                screenshotPath: "/tmp/shot.png",
                elements: DetectedElements(buttons: [element]),
                metadata: DetectionMetadata(
                    detectionTime: 0.01,
                    elementCount: 1,
                    method: "test",
                    windowContext: Self.exactWindowContext(processIdentifier: pid)))
            let synthetic = ClickRecordingSyntheticInputDriver()
            let service = try await ClickService(
                snapshotManager: InMemorySnapshotManager.containing(detectionResult),
                inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
                syntheticInputDriver: synthetic,
                exactWindowIdentityValidator: { _, _ in true })

            let result = try await service.click(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: Self.snapshotID,
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
    }

    @Test
    @MainActor
    func `background element click succeeds through AX action without synthesis`() async throws {
        let pid = getpid()
        let tracker = ClickWindowTracker(bounds: Self.testWindowBounds)
        try await WindowMovementTrackingProviderScope.withProvider(tracker) {
            let element = DetectedElement(
                id: "B1",
                type: .button,
                label: "Background Button",
                bounds: .init(x: 20, y: 30, width: 100, height: 40))
            let detectionResult = ElementDetectionResult(
                snapshotId: Self.snapshotID,
                screenshotPath: "/tmp/shot.png",
                elements: DetectedElements(buttons: [element]),
                metadata: DetectionMetadata(
                    detectionTime: 0.01,
                    elementCount: 1,
                    method: "test",
                    windowContext: Self.exactWindowContext(processIdentifier: pid)))
            let action = ClickSuccessfulActionInputDriver()
            let synthetic = ClickRecordingSyntheticInputDriver()
            let resolver = ClickFixedAutomationElementResolver()
            let service = try await ClickService(
                snapshotManager: InMemorySnapshotManager.containing(detectionResult),
                inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
                actionInputDriver: action,
                syntheticInputDriver: synthetic,
                automationElementResolver: resolver,
                exactWindowIdentityValidator: { _, _ in true })

            let result = try await service.click(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: Self.snapshotID,
                targetProcessIdentifier: pid)

            #expect(result.path == .action)
            #expect(result.actionName == "AXPress")
            #expect(action.clickCount == 1)
            #expect(action.performedActionNames == [AXActionNames.kAXPressAction])
            #expect(synthetic.events.isEmpty)
            #expect(resolver.targetProcessIdentifiers == [pid])
        }
    }

    @Test
    @MainActor
    func `background element right click succeeds through AXShowMenu without synthesis`() async throws {
        let pid = getpid()
        let tracker = ClickWindowTracker(bounds: Self.testWindowBounds)
        try await WindowMovementTrackingProviderScope.withProvider(tracker) {
            let element = DetectedElement(
                id: "B1",
                type: .button,
                label: "Background Button",
                bounds: .init(x: 20, y: 30, width: 100, height: 40))
            let detectionResult = ElementDetectionResult(
                snapshotId: Self.snapshotID,
                screenshotPath: "/tmp/shot.png",
                elements: DetectedElements(buttons: [element]),
                metadata: DetectionMetadata(
                    detectionTime: 0.01,
                    elementCount: 1,
                    method: "test",
                    windowContext: Self.exactWindowContext(processIdentifier: pid)))
            let action = ClickSuccessfulActionInputDriver()
            let synthetic = ClickRecordingSyntheticInputDriver()
            let resolver = ClickFixedAutomationElementResolver()
            let service = try await ClickService(
                snapshotManager: InMemorySnapshotManager.containing(detectionResult),
                inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
                actionInputDriver: action,
                syntheticInputDriver: synthetic,
                automationElementResolver: resolver,
                exactWindowIdentityValidator: { _, _ in true })

            let result = try await service.click(
                target: .elementId("B1"),
                clickType: .right,
                snapshotId: Self.snapshotID,
                targetProcessIdentifier: pid)

            #expect(result.path == .action)
            #expect(result.actionName == AXActionNames.kAXShowMenuAction)
            #expect(action.rightClickCount == 1)
            #expect(synthetic.events.isEmpty)
            #expect(resolver.targetProcessIdentifiers == [pid])
        }
    }

    @Test
    @MainActor
    func `background element right click reports synthetic permission when AX fallback fails`() async throws {
        let pid = getpid()
        let tracker = ClickWindowTracker(bounds: Self.testWindowBounds)
        try await WindowMovementTrackingProviderScope.withProvider(tracker) {
            let element = DetectedElement(
                id: "B1",
                type: .button,
                label: "Background Button",
                bounds: .init(x: 20, y: 30, width: 100, height: 40))
            let detectionResult = ElementDetectionResult(
                snapshotId: Self.snapshotID,
                screenshotPath: "/tmp/shot.png",
                elements: DetectedElements(buttons: [element]),
                metadata: DetectionMetadata(
                    detectionTime: 0.01,
                    elementCount: 1,
                    method: "test",
                    windowContext: Self.exactWindowContext(processIdentifier: pid)))
            let synthetic = ClickRecordingSyntheticInputDriver(
                targetedClickError: PeekabooError.permissionDeniedEventSynthesizing)
            let resolver = ClickFixedAutomationElementResolver()
            let service = try await ClickService(
                snapshotManager: InMemorySnapshotManager.containing(detectionResult),
                inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
                actionInputDriver: ClickFailingActionInputDriver(error: .permissionDenied),
                syntheticInputDriver: synthetic,
                automationElementResolver: resolver,
                exactWindowIdentityValidator: { _, _ in true })

            do {
                _ = try await service.click(
                    target: .elementId("B1"),
                    clickType: .right,
                    snapshotId: Self.snapshotID,
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
            snapshotId: Self.snapshotID,
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
        let service = try await ClickService(
            snapshotManager: InMemorySnapshotManager.containing(detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            actionInputDriver: action,
            syntheticInputDriver: synthetic,
            automationElementResolver: resolver)

        await #expect(throws: ActionInputError.self) {
            try await service.click(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: Self.snapshotID,
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
            snapshotId: Self.snapshotID,
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
        let service = try await ClickService(
            snapshotManager: InMemorySnapshotManager.containing(detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            actionInputDriver: action,
            syntheticInputDriver: synthetic,
            automationElementResolver: resolver)

        let result = try await service.click(
            target: .elementId("M1"),
            clickType: .single,
            snapshotId: Self.snapshotID,
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
            snapshotId: Self.snapshotID,
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(buttons: [element]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 1,
                method: "test",
                windowContext: Self.exactWindowContext(processIdentifier: pid)))
        let action = ClickSuccessfulActionInputDriver()
        let resolver = ClickFixedAutomationElementResolver()
        let service = try await ClickService(
            snapshotManager: InMemorySnapshotManager.containing(detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            actionInputDriver: action,
            automationElementResolver: resolver,
            exactWindowIdentityValidator: { _, _ in true })

        let result = try await service.click(
            target: .query("Live Button"),
            clickType: .single,
            snapshotId: Self.snapshotID,
            targetProcessIdentifier: pid)

        #expect(result.path == .action)
        #expect(action.performedActionNames == [AXActionNames.kAXPressAction])
        #expect(resolver.queryWindowIDs == [42])
        #expect(resolver.queryTargetProcessIdentifiers == [pid])
    }

    @Test
    @MainActor
    func `background missing snapshot query never synthesizes outside its window`() async throws {
        let pid = getpid()
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Different Button",
            bounds: .init(x: 20, y: 30, width: 100, height: 40))
        let detectionResult = ElementDetectionResult(
            snapshotId: Self.snapshotID,
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(buttons: [element]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 1,
                method: "test",
                windowContext: Self.exactWindowContext(processIdentifier: pid)))
        let synthetic = ClickRecordingSyntheticInputDriver()
        let resolver = ClickFixedAutomationElementResolver(resolveQueries: false)
        let service = try await ClickService(
            snapshotManager: InMemorySnapshotManager.containing(detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            syntheticInputDriver: synthetic,
            automationElementResolver: resolver,
            exactWindowIdentityValidator: { _, _ in true })

        await #expect(throws: (any Error).self) {
            try await service.click(
                target: .query("Missing Button"),
                clickType: .single,
                snapshotId: Self.snapshotID,
                targetProcessIdentifier: pid)
        }

        #expect(synthetic.events.isEmpty)
        #expect(resolver.queryWindowIDs == [42, 42])
        #expect(resolver.queryTargetProcessIdentifiers == [pid, pid])
    }

    @Test
    @MainActor
    func `background element click rejects vanished window without snapshot bounds`() async throws {
        let pid = getpid()
        let tracker = ClickWindowTracker(bounds: nil)
        try await WindowMovementTrackingProviderScope.withProvider(tracker) {
            let element = DetectedElement(
                id: "B1",
                type: .button,
                label: "Background Button",
                bounds: .init(x: 20, y: 30, width: 100, height: 40))
            let detectionResult = ElementDetectionResult(
                snapshotId: Self.snapshotID,
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
            let service = try await ClickService(
                snapshotManager: InMemorySnapshotManager.containing(detectionResult),
                inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
                actionInputDriver: action,
                syntheticInputDriver: synthetic,
                automationElementResolver: ClickFixedAutomationElementResolver())

            await #expect(throws: (any Error).self) {
                try await service.click(
                    target: .elementId("B1"),
                    clickType: .single,
                    snapshotId: Self.snapshotID,
                    targetProcessIdentifier: pid)
            }

            #expect(action.performedActionNames.isEmpty)
            #expect(synthetic.events.isEmpty)
        }
    }

    @Test
    @MainActor
    func `background AX resolution adjusts the snapshot frame after window movement`() async throws {
        let pid = getpid()
        let tracker = ClickWindowTracker(bounds: CGRect(x: 300, y: 400, width: 300, height: 300))
        try await WindowMovementTrackingProviderScope.withProvider(tracker) {
            let element = DetectedElement(
                id: "B1",
                type: .button,
                label: "Duplicate",
                bounds: CGRect(x: 120, y: 140, width: 80, height: 30))
            let detectionResult = ElementDetectionResult(
                snapshotId: Self.snapshotID,
                screenshotPath: "/tmp/shot.png",
                elements: DetectedElements(buttons: [element]),
                metadata: DetectionMetadata(
                    detectionTime: 0.01,
                    elementCount: 1,
                    method: "test",
                    windowContext: WindowContext(
                        applicationProcessId: pid,
                        windowID: 42,
                        windowBounds: CGRect(x: 100, y: 100, width: 300, height: 300),
                        windowMutationIdentity: Self.windowIdentity(
                            processIdentifier: pid,
                            capturedBounds: CGRect(x: 100, y: 100, width: 300, height: 300)))))
            let resolver = ClickFixedAutomationElementResolver()
            let synthetic = ClickRecordingSyntheticInputDriver()
            let service = try await ClickService(
                snapshotManager: InMemorySnapshotManager.containing(detectionResult),
                inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
                actionInputDriver: ClickSuccessfulActionInputDriver(),
                syntheticInputDriver: synthetic,
                automationElementResolver: resolver,
                exactWindowIdentityValidator: { _, _ in true })

            let result = try await service.click(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: Self.snapshotID,
                targetProcessIdentifier: pid)

            #expect(result.path == .action)
            #expect(resolver.detectedElements.map(\.bounds) == [
                CGRect(x: 320, y: 440, width: 80, height: 30),
            ])
            #expect(resolver.targetProcessIdentifiers == [pid])
            #expect(synthetic.events.isEmpty)
        }
    }

    @Test
    @MainActor
    func `background AX permission denial falls back to targeted synthesis`() async throws {
        let pid = getpid()
        let tracker = ClickWindowTracker(bounds: Self.testWindowBounds)
        try await WindowMovementTrackingProviderScope.withProvider(tracker) {
            let element = DetectedElement(
                id: "B1",
                type: .button,
                label: "Background Button",
                bounds: .init(x: 20, y: 30, width: 100, height: 40))
            let detectionResult = ElementDetectionResult(
                snapshotId: Self.snapshotID,
                screenshotPath: "/tmp/shot.png",
                elements: DetectedElements(buttons: [element]),
                metadata: DetectionMetadata(
                    detectionTime: 0.01,
                    elementCount: 1,
                    method: "test",
                    windowContext: Self.exactWindowContext(processIdentifier: pid)))
            let synthetic = ClickRecordingSyntheticInputDriver()
            let service = try await ClickService(
                snapshotManager: InMemorySnapshotManager.containing(detectionResult),
                inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
                actionInputDriver: ClickFailingActionInputDriver(error: .permissionDenied),
                syntheticInputDriver: synthetic,
                automationElementResolver: ClickFixedAutomationElementResolver(),
                exactWindowIdentityValidator: { _, _ in true })

            let result = try await service.click(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: Self.snapshotID,
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
    }

    @Test
    @MainActor
    func `background element click rejects snapshot from another process`() async throws {
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Background Button",
            bounds: .init(x: 20, y: 30, width: 100, height: 40),
            attributes: ["identifier": "background-button", "role": "AXButton"])
        let detectionResult = ElementDetectionResult(
            snapshotId: Self.snapshotID,
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(buttons: [element]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 1,
                method: "test",
                windowContext: WindowContext(applicationProcessId: 222)))
        let synthetic = ClickRecordingSyntheticInputDriver()
        let service = try await ClickService(
            snapshotManager: InMemorySnapshotManager.containing(detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            syntheticInputDriver: synthetic)

        await #expect(throws: (any Error).self) {
            try await service.click(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: Self.snapshotID,
                targetProcessIdentifier: 333)
        }
        #expect(synthetic.events.isEmpty)
    }

    @Test
    @MainActor
    func `background element click rejects snapshot without process identity`() async throws {
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Background Button",
            bounds: .init(x: 20, y: 30, width: 100, height: 40))
        let detectionResult = ElementDetectionResult(
            snapshotId: Self.snapshotID,
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(buttons: [element]),
            metadata: DetectionMetadata(detectionTime: 0.01, elementCount: 1, method: "test"))
        let synthetic = ClickRecordingSyntheticInputDriver()
        let service = try await ClickService(
            snapshotManager: InMemorySnapshotManager.containing(detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            syntheticInputDriver: synthetic)

        await #expect(throws: (any Error).self) {
            try await service.click(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: Self.snapshotID,
                targetProcessIdentifier: getpid())
        }
        #expect(synthetic.events.isEmpty)
    }

    @Test
    @MainActor
    func `targeted action-only permission denial maps to accessibility permission`() async throws {
        let pid = getpid()
        let tracker = ClickWindowTracker(bounds: Self.testWindowBounds)
        try await WindowMovementTrackingProviderScope.withProvider(tracker) {
            let element = DetectedElement(
                id: "B1",
                type: .button,
                label: "Background Button",
                bounds: .init(x: 20, y: 30, width: 100, height: 40))
            let detectionResult = ElementDetectionResult(
                snapshotId: Self.snapshotID,
                screenshotPath: "/tmp/shot.png",
                elements: DetectedElements(buttons: [element]),
                metadata: DetectionMetadata(
                    detectionTime: 0.01,
                    elementCount: 1,
                    method: "test",
                    windowContext: Self.exactWindowContext(processIdentifier: pid)))
            let service = try await ClickService(
                snapshotManager: InMemorySnapshotManager.containing(detectionResult),
                inputPolicy: UIInputPolicy(defaultStrategy: .actionOnly),
                actionInputDriver: ClickFailingActionInputDriver(error: .permissionDenied),
                automationElementResolver: ClickFixedAutomationElementResolver(),
                exactWindowIdentityValidator: { _, _ in true })

            do {
                try await service.click(
                    target: .elementId("B1"),
                    clickType: .single,
                    snapshotId: Self.snapshotID,
                    targetProcessIdentifier: pid)
                Issue.record("Expected Accessibility permission error")
            } catch PeekabooError.permissionDeniedAccessibility {
                // Expected.
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
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
    func `background synth only click rejects snapshot from another process`() async throws {
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Background Button",
            bounds: .init(x: 20, y: 30, width: 100, height: 40))
        let detectionResult = ElementDetectionResult(
            snapshotId: Self.snapshotID,
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(buttons: [element]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 1,
                method: "test",
                windowContext: WindowContext(applicationProcessId: 222)))
        let synthetic = ClickRecordingSyntheticInputDriver()
        let service = try await ClickService(
            snapshotManager: InMemorySnapshotManager.containing(detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            syntheticInputDriver: synthetic)

        await #expect(throws: (any Error).self) {
            try await service.click(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: Self.snapshotID,
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
            snapshotId: Self.snapshotID,
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
            snapshotId: Self.snapshotID,
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(textFields: [higher, lower]),
            metadata: DetectionMetadata(detectionTime: 0.01, elementCount: 2, method: "test"))

        #expect(ClickService.resolveTargetElement(query: "basic-text-field", in: detectionResult)?.id == "T_LOW")
    }

    private static func exactWindowContext(
        processIdentifier: pid_t,
        bounds: CGRect = Self.testWindowBounds) -> WindowContext
    {
        WindowContext(
            applicationProcessId: processIdentifier,
            windowID: 42,
            windowBounds: bounds,
            windowMutationIdentity: self.windowIdentity(
                processIdentifier: processIdentifier,
                capturedBounds: bounds))
    }

    private static func windowIdentity(
        processIdentifier: pid_t,
        capturedBounds: CGRect = Self.testWindowBounds) -> WindowMutationIdentity
    {
        WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: processIdentifier,
            ownerProcessStartIdentity: 1,
            capturedBounds: capturedBounds)
    }

    private static let testWindowBounds = CGRect(x: 0, y: 0, width: 800, height: 600)
}

extension ClickServiceTargetResolutionTests {
    @Test
    @MainActor
    func `accepted tab press with unchanged selection never falls back to synthetic click`() async throws {
        let pid = getpid()
        let tracker = ClickWindowTracker(bounds: Self.testWindowBounds)
        try await WindowMovementTrackingProviderScope.withProvider(tracker) {
            let element = DetectedElement(
                id: "TAB1",
                type: .button,
                label: "Settings",
                bounds: .init(x: 20, y: 30, width: 100, height: 40))
            let detectionResult = ElementDetectionResult(
                snapshotId: Self.snapshotID,
                screenshotPath: "/tmp/shot.png",
                elements: DetectedElements(buttons: [element]),
                metadata: DetectionMetadata(
                    detectionTime: 0.01,
                    elementCount: 1,
                    method: "test",
                    windowContext: Self.exactWindowContext(processIdentifier: pid)))
            let action = ClickSuccessfulActionInputDriver()
            let synthetic = ClickRecordingSyntheticInputDriver()
            let service = try await ClickService(
                snapshotManager: InMemorySnapshotManager.containing(detectionResult),
                inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
                actionInputDriver: action,
                syntheticInputDriver: synthetic,
                automationElementResolver: ClickFixedAutomationElementResolver(),
                exactWindowIdentityValidator: { _, _ in true },
                tabSelectionVerifier: { _, _ in true })

            do {
                _ = try await service.click(
                    target: .elementId("TAB1"),
                    clickType: .single,
                    snapshotId: Self.snapshotID,
                    targetProcessIdentifier: pid)
                Issue.record("Expected an indeterminate accepted tab press")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome.state == .indeterminate)
                #expect(failure.outcome.delivery == .init(mechanism: .accessibilityAction, mode: .background))
                #expect(failure.outcome.dispatchState.unitCount == .one)
                #expect(failure.outcome.retrySafety == .unsafe)
            }

            #expect(action.clickCount == 1)
            #expect(synthetic.events.isEmpty)
        }
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

@MainActor
private final class ClickFixedAutomationElementResolver: AutomationElementResolving {
    private let element = AutomationElement(Element(AXUIElementCreateApplication(getpid())))
    private let resolveQueries: Bool
    private let afterResolve: (() -> Void)?
    private(set) var targetProcessIdentifiers: [pid_t?] = []
    private(set) var detectedElements: [DetectedElement] = []
    private(set) var queryWindowIDs: [Int?] = []
    private(set) var queryTargetProcessIdentifiers: [pid_t?] = []

    init(resolveQueries: Bool = true, afterResolve: (() -> Void)? = nil) {
        self.resolveQueries = resolveQueries
        self.afterResolve = afterResolve
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
        self.afterResolve?()
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
        self.afterResolve?()
        return self.resolveQueries ? self.element : nil
    }
}

@MainActor
private struct ClickMissingAutomationElementResolver: AutomationElementResolving {
    func resolve(
        detectedElement _: DetectedElement,
        windowContext _: WindowContext?,
        targetProcessIdentifier _: pid_t?) -> AutomationElement?
    {
        nil
    }

    func resolve(
        query _: String,
        windowContext _: WindowContext?,
        targetProcessIdentifier _: pid_t?,
        requireTextInput _: Bool) -> AutomationElement?
    {
        nil
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
    private let afterAction: (() -> Void)?
    private(set) var clickCount = 0
    private(set) var rightClickCount = 0
    private(set) var performedActionNames: [String] = []

    init(afterAction: (() -> Void)? = nil) {
        self.afterAction = afterAction
    }

    func tryClick(element _: AutomationElement) throws -> UIInputExecutionResult.Action {
        self.clickCount += 1
        self.performedActionNames.append(AXActionNames.kAXPressAction)
        self.afterAction?()
        return AutomationTestFixtures.uiActionReceipt(
            actionName: AXActionNames.kAXPressAction,
            anchorPoint: CGPoint(x: 70, y: 50),
            elementRole: "AXButton")
    }

    func tryRightClick(element _: any AutomationElementRepresenting) async throws
        -> UIInputExecutionResult.Action
    {
        self.rightClickCount += 1
        return AutomationTestFixtures.uiActionReceipt(
            actionName: AXActionNames.kAXShowMenuAction,
            anchorPoint: CGPoint(x: 70, y: 50),
            elementRole: "AXButton")
    }

    func tryScroll(element _: AutomationElement, direction _: ScrollDirection, pages _: Int) throws
    -> UIInputExecutionResult.Action {
        AutomationTestFixtures.uiActionReceipt()
    }

    func trySetText(element _: AutomationElement, text _: String, replace _: Bool) throws
    -> UIInputExecutionResult.Action {
        AutomationTestFixtures.uiActionReceipt()
    }

    func tryHotkey(application _: NSRunningApplication, keys _: [String]) throws
    -> UIInputExecutionResult.Action {
        AutomationTestFixtures.uiActionReceipt()
    }

    func trySetValue(element _: AutomationElement, value _: UIElementValue) throws
    -> UIInputExecutionResult.Action {
        AutomationTestFixtures.uiActionReceipt()
    }

    func tryPerformAction(element _: AutomationElement, actionName: String) throws
    -> UIInputExecutionResult.Action {
        self.performedActionNames.append(actionName)
        self.afterAction?()
        return AutomationTestFixtures.uiActionReceipt(
            actionName: actionName,
            anchorPoint: CGPoint(x: 70, y: 50),
            elementRole: "AXButton")
    }
}

private final class ClickLockedGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: UInt64?

    init(_ value: UInt64?) {
        self.storedValue = value
    }

    var value: UInt64? {
        get { self.lock.withLock { self.storedValue } }
        set { self.lock.withLock { self.storedValue = newValue } }
    }
}

@MainActor
private final class ClickFailingActionInputDriver: ActionInputDriving {
    let error: ActionInputError

    init(error: ActionInputError) {
        self.error = error
    }

    func tryClick(element _: AutomationElement) throws -> UIInputExecutionResult.Action {
        throw self.error
    }

    func tryRightClick(element _: any AutomationElementRepresenting) async throws
        -> UIInputExecutionResult.Action
    {
        throw self.error
    }

    func tryScroll(element _: AutomationElement, direction _: ScrollDirection, pages _: Int) throws
    -> UIInputExecutionResult.Action {
        throw self.error
    }

    func trySetText(element _: AutomationElement, text _: String, replace _: Bool) throws
    -> UIInputExecutionResult.Action {
        throw self.error
    }

    func tryHotkey(application _: NSRunningApplication, keys _: [String]) throws
    -> UIInputExecutionResult.Action {
        throw self.error
    }

    func trySetValue(element _: AutomationElement, value _: UIElementValue) throws
    -> UIInputExecutionResult.Action {
        throw self.error
    }

    func tryPerformAction(element _: AutomationElement, actionName _: String) throws
    -> UIInputExecutionResult.Action {
        throw self.error
    }
}
