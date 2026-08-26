import AppKit
import ApplicationServices
import AXorcist
import PeekabooFoundation
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooAutomationKit

struct ActionInputDriverTests {
    @Test
    func `classifies unsupported AX action as fallback-eligible`() {
        let error = ActionInputDriver.classify(AccessibilitySystemError(.actionUnsupported))

        #expect(error == .unsupported(.actionUnsupported))
    }

    @Test
    func `classifies unsupported AX attribute as fallback-eligible`() {
        let error = ActionInputDriver.classify(AccessibilitySystemError(.attributeUnsupported))

        #expect(error == .unsupported(.attributeUnsupported))
    }

    @Test
    func `classifies invalid AX element as stale element`() {
        let error = ActionInputDriver.classify(AccessibilitySystemError(.invalidUIElement))

        #expect(error == .staleElement)
    }

    @Test
    func `classifies disabled AX API as permission denied`() {
        let error = ActionInputDriver.classify(AccessibilitySystemError(.apiDisabled))

        #expect(error == .permissionDenied)
    }

    @Test
    func `menu hotkey chord normalizes command character shortcuts`() throws {
        let chord = try ActionInputDriver.menuHotkeyChordForTesting(["command", "shift", "S"])

        #expect(chord.key == "s")
        #expect(chord.modifiers == ["cmd", "shift"])
    }

    @Test
    func `menu hotkey chord supports punctuation shortcuts`() throws {
        let chord = try ActionInputDriver.menuHotkeyChordForTesting(["cmd", "comma"])

        #expect(chord.key == ",")
        #expect(chord.modifiers == ["cmd"])
    }

    @Test
    func `menu hotkey chord rejects non menu backed keys`() throws {
        do {
            _ = try ActionInputDriver.menuHotkeyChordForTesting(["cmd", "escape"])
            Issue.record("Expected escape to be unsupported for menu hotkey resolution")
        } catch let error as ActionInputError {
            #expect(error == .unsupported(.menuShortcutUnavailable))
        }
    }

    @Test
    func `menu item modifier bits map to normalized modifier names`() {
        let modifiers = ActionInputDriver.menuHotkeyModifiersForTesting((1 << 0) | (1 << 2))

        #expect(modifiers == ["cmd", "shift", "ctrl"])
    }

    @Test
    func `menu item no command bit suppresses implicit command modifier`() {
        let modifiers = ActionInputDriver.menuHotkeyModifiersForTesting((1 << 3) | (1 << 1))

        #expect(modifiers == ["alt"])
    }

    @Test
    func `set value rejects secure text fields even when settable`() {
        let reason = ActionInputDriver.setValueRejectionReasonForTesting(
            role: "AXSecureTextField",
            isValueSettable: true)

        #expect(reason == .secureValueNotAllowed)
    }

    @Test
    func `set value rejects secure text fields by subrole`() {
        let reason = ActionInputDriver.setValueRejectionReasonForTesting(
            role: "AXTextField",
            subrole: "AXSecureTextField",
            isValueSettable: true)

        #expect(reason == .secureValueNotAllowed)
    }

    @Test
    func `set value rejects elements without settable values`() {
        let reason = ActionInputDriver.setValueRejectionReasonForTesting(
            role: "AXTextField",
            isValueSettable: false)

        #expect(reason == .valueNotSettable)
    }

    @MainActor
    @Test
    func `set value predispatch refusal never acquires dispatch semantics`() {
        let element = MockAutomationElement(
            role: "AXSecureTextField",
            value: "secret",
            isValueSettable: true)

        do {
            _ = try ActionInputDriver().trySetValueForTesting(element: element, value: .string("replacement"))
            Issue.record("Expected secure value mutation to be refused")
        } catch let error as ActionInputError {
            #expect(error == .unsupported(.secureValueNotAllowed))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(element.setValues.isEmpty)
    }

    @Test
    func `ambiguous scroll action failure is not fallback eligible`() {
        #expect(!ActionInputDriver.shouldContinueTryingScrollActionForTesting(after: .targetUnavailable))
        #expect(ActionInputDriver.scrollFallbackErrorForTesting(from: .targetUnavailable) == .targetUnavailable)
    }

    @Test
    func `scroll action keeps stale and permission errors as hard failures`() {
        #expect(!ActionInputDriver.shouldContinueTryingScrollActionForTesting(after: .staleElement))
        #expect(!ActionInputDriver.shouldContinueTryingScrollActionForTesting(after: .permissionDenied))
        #expect(ActionInputDriver.scrollFallbackErrorForTesting(from: .staleElement) == .staleElement)
    }

    @MainActor
    @Test
    func `directional scroll ignores scroll to visible action`() {
        let element = MockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            actionNames: ["AXScrollToVisible"])

        do {
            _ = try ActionInputDriver().tryScrollForTesting(element: element, direction: .down, pages: 1)
            Issue.record("Expected scroll-to-visible-only element to fall back")
        } catch let error as ActionInputError {
            #expect(error == .unsupported(.actionUnsupported))
            #expect(element.performedActions.isEmpty)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @MainActor
    @Test
    func `directional scroll performs page scroll action`() throws {
        let element = MockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            actionNames: ["AXScrollDownByPage"])

        let result = try ActionInputDriver().tryScrollForTesting(element: element, direction: .down, pages: 1)

        #expect(result.actionName == "AXScrollDownByPage")
        #expect(result.outcome.state == .dispatchedUnverified)
        #expect(result.outcome.evidence == .deliveryAccepted)
        #expect(result.outcome.delivery == .init(mechanism: .accessibilityAction, mode: .background))
        #expect(result.outcome.dispatchState.unitCount == .one)
        #expect(element.performedActions == ["AXScrollDownByPage"])
    }

    @MainActor
    @Test
    func `multi page scroll reports every accepted page unit`() throws {
        let element = MockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            actionNames: ["AXScrollDownByPage"])

        let result = try ActionInputDriver().tryScrollForTesting(element: element, direction: .down, pages: 3)

        #expect(result.outcome.state == .dispatchedUnverified)
        #expect(result.outcome.dispatchState.unitCount?.rawValue == 3)
        #expect(element.performedActions == Array(repeating: "AXScrollDownByPage", count: 3))
    }

    @MainActor
    @Test
    func `accepted page prefix stops before scrollbar fallback`() {
        let scrollBar = MockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 300, y: 0, width: 16, height: 400),
            value: 0.2,
            isValueSettable: true)
        let scrollArea = MockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            actionNames: ["AXScrollDownByPage"],
            children: [scrollBar],
            actionFailureAfterSuccesses: 1,
            sequencedActionFailure: AccessibilitySystemError(.actionUnsupported))

        do {
            _ = try ActionInputDriver().tryScrollForTesting(element: scrollArea, direction: .down, pages: 3)
            Issue.record("Expected a typed partial page-scroll failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .partial)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 1)
            #expect(failure.outcome.retrySafety == .unsafe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(scrollArea.performedActions == ["AXScrollDownByPage"])
        #expect(scrollBar.setValues.isEmpty)
    }

    @MainActor
    @Test
    func `ambiguous page failure counts the possible unit and stops fallback`() {
        let scrollBar = MockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 300, y: 0, width: 16, height: 400),
            value: 0.2,
            isValueSettable: true)
        let scrollArea = MockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            actionNames: ["AXScrollDownByPage"],
            children: [scrollBar],
            actionFailureAfterSuccesses: 1,
            sequencedActionFailure: AccessibilitySystemError(.cannotComplete))

        do {
            _ = try ActionInputDriver().tryScrollForTesting(element: scrollArea, direction: .down, pages: 3)
            Issue.record("Expected a typed indeterminate page-scroll failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 2)
            #expect(failure.outcome.retrySafety == .unsafe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(scrollArea.performedActions == ["AXScrollDownByPage"])
        #expect(scrollBar.setValues.isEmpty)
    }

    @MainActor
    @Test
    func `directional scroll reports fallback page action that actually ran`() throws {
        let element = MockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            actionNames: ["AXPageDown"])

        let result = try ActionInputDriver().tryScrollForTesting(element: element, direction: .down, pages: 1)

        #expect(result.actionName == "AXPageDown")
        #expect(element.performedActions == ["AXPageDown"])
    }

    @MainActor
    @Test
    func `directional scroll mutates a standard descendant scroll bar`() throws {
        let scrollBar = MockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 300, y: 0, width: 16, height: 400),
            value: 0.2,
            isValueSettable: true)
        let scrollArea = MockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            children: [scrollBar])

        let result = try ActionInputDriver().tryScrollForTesting(
            element: scrollArea,
            direction: .down,
            pages: 3)

        #expect(result.actionName == "AXSetValue")
        #expect(result.elementRole == AXRoleNames.kAXScrollBarRole)
        #expect(result.outcome.dispatchState.unitCount == .one)
        #expect(scrollBar.setValues == [.double(0.5)])
    }

    @MainActor
    @Test
    func `horizontal scroll selects the horizontal descendant scroll bar`() throws {
        let vertical = MockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 300, y: 0, width: 16, height: 400),
            value: 0.2,
            isValueSettable: true)
        let horizontal = MockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 0, y: 400, width: 300, height: 16),
            value: 0.7,
            isValueSettable: true)
        let scrollArea = MockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            children: [vertical, horizontal])

        _ = try ActionInputDriver().tryScrollForTesting(
            element: scrollArea,
            direction: .left,
            pages: 2)

        #expect(vertical.setValues.isEmpty)
        guard case let .double(value) = horizontal.setValues.first else {
            Issue.record("Expected a direct numeric scroll-bar update")
            return
        }
        #expect(abs(value - 0.5) < 1e-9)
    }

    @MainActor
    @Test
    func `scroll chooses the requested area bar before a nested area bar`() throws {
        let nestedBar = MockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 280, y: 20, width: 16, height: 120),
            value: 0.3,
            isValueSettable: true)
        let nestedArea = MockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            children: [nestedBar])
        let targetBar = MockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 300, y: 0, width: 16, height: 400),
            value: 0.1,
            isValueSettable: true)
        let targetArea = MockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            children: [
                MockAutomationElement(role: AXRoleNames.kAXGroupRole, children: [nestedArea]),
                targetBar,
            ])

        _ = try ActionInputDriver().tryScrollForTesting(
            element: targetArea,
            direction: .down,
            pages: 1)

        #expect(targetBar.setValues == [.double(0.2)])
        #expect(nestedBar.setValues.isEmpty)
    }

    @MainActor
    @Test
    func `scroll does not borrow a nested area bar when the target has none`() {
        let nestedBar = MockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 280, y: 20, width: 16, height: 120),
            value: 0.3,
            isValueSettable: true)
        let targetArea = MockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            children: [
                MockAutomationElement(
                    role: AXRoleNames.kAXGroupRole,
                    children: [MockAutomationElement(
                        role: AXRoleNames.kAXScrollAreaRole,
                        children: [nestedBar])]),
            ])

        do {
            _ = try ActionInputDriver().tryScrollForTesting(
                element: targetArea,
                direction: .down,
                pages: 1)
            Issue.record("Expected a target without its own vertical scroll bar to fail")
        } catch let error as ActionInputError {
            #expect(error == .unsupported(.actionUnsupported))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(nestedBar.setValues.isEmpty)
    }

    @MainActor
    @Test
    func `scroll bar advertised increment action remains action first`() throws {
        let scrollBar = MockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 300, y: 0, width: 16, height: 400),
            value: 0.2,
            actionNames: [AXActionNames.kAXIncrementAction],
            isValueSettable: true)
        let scrollArea = MockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            children: [scrollBar])

        let result = try ActionInputDriver().tryScrollForTesting(
            element: scrollArea,
            direction: .down,
            pages: 2)

        #expect(result.actionName == AXActionNames.kAXIncrementAction)
        #expect(result.outcome.dispatchState.unitCount?.rawValue == 2)
        #expect(scrollBar.performedActions == [AXActionNames.kAXIncrementAction, AXActionNames.kAXIncrementAction])
        #expect(scrollBar.setValues.isEmpty)
    }

    @MainActor
    @Test
    func `accepted scrollbar prefix never retries through AXValue`() {
        let scrollBar = MockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 300, y: 0, width: 16, height: 400),
            value: 0.2,
            actionNames: [AXActionNames.kAXIncrementAction],
            isValueSettable: true,
            actionFailureAfterSuccesses: 1,
            sequencedActionFailure: AccessibilitySystemError(.actionUnsupported))
        let scrollArea = MockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            children: [scrollBar])

        do {
            _ = try ActionInputDriver().tryScrollForTesting(element: scrollArea, direction: .down, pages: 3)
            Issue.record("Expected a typed partial scrollbar failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .partial)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 1)
            #expect(failure.outcome.retrySafety == .unsafe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(scrollBar.performedActions == [AXActionNames.kAXIncrementAction])
        #expect(scrollBar.setValues.isEmpty)
    }

    @MainActor
    @Test
    func `accepted AXValue without readback is indeterminate and retry unsafe`() {
        let scrollBar = MockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 300, y: 0, width: 16, height: 400),
            value: 0.2,
            isValueSettable: true,
            valueSetterDoesNotChange: true)
        let scrollArea = MockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            children: [scrollBar])

        do {
            _ = try ActionInputDriver().tryScrollForTesting(element: scrollArea, direction: .down, pages: 3)
            Issue.record("Expected a typed indeterminate AXValue failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.delivery == .init(mechanism: .accessibilityValue, mode: .background))
            #expect(failure.outcome.dispatchState.unitCount == .one)
            #expect(failure.outcome.retrySafety == .unsafe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(scrollBar.setValues == [.double(0.5)])
    }

    @MainActor
    @Test
    func `targeted scroll never mutates a sibling scroll area`() {
        let targetArea = MockAutomationElement(role: AXRoleNames.kAXScrollAreaRole)
        let siblingBar = MockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 300, y: 0, width: 16, height: 400),
            value: 0.2,
            isValueSettable: true)
        _ = MockAutomationElement(
            role: AXRoleNames.kAXGroupRole,
            children: [
                targetArea,
                MockAutomationElement(role: AXRoleNames.kAXScrollAreaRole, children: [siblingBar]),
            ])

        do {
            _ = try ActionInputDriver().tryScrollForTesting(
                element: targetArea,
                direction: .down,
                pages: 1)
            Issue.record("Expected the target without a native scroll control to fail")
        } catch let error as ActionInputError {
            #expect(error == .unsupported(.actionUnsupported))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(siblingBar.setValues.isEmpty)
    }

    @Test
    func `action input errors have user-readable descriptions`() {
        let error = ActionInputError.unsupported(.secureValueNotAllowed)

        #expect(error.localizedDescription.contains("secure text fields"))
    }

    @Test
    func `only unselected tab presses require selection confirmation`() {
        #expect(ActionInputDriver.tabPressDidNotSelectForTesting(
            subrole: "AXTabButton",
            valueBefore: 0,
            valueAfter: 0))
        #expect(!ActionInputDriver.tabPressDidNotSelectForTesting(
            subrole: "AXTabButton",
            valueBefore: 0,
            valueAfter: 1))
        #expect(!ActionInputDriver.tabPressDidNotSelectForTesting(
            subrole: "AXTabButton",
            valueBefore: 1,
            valueAfter: 1))
        #expect(!ActionInputDriver.tabPressDidNotSelectForTesting(
            subrole: "AXRadioButton",
            valueBefore: 0,
            valueAfter: 0))
    }

    @Test
    func `unsupported action message includes advertised action names`() {
        let message = UIAutomationService.unsupportedActionMessage(
            actionName: "AXIncrement",
            target: "S1 slider: Volume",
            advertisedActions: ["AXPress", "AXShowMenu"])

        #expect(message.contains("AXIncrement"))
        #expect(message.contains("S1 slider: Volume"))
        #expect(message.contains("AXPress, AXShowMenu"))
    }

    @Test
    func `unsupported set value message includes target and reason`() {
        let message = UIAutomationService.unsupportedSetValueMessage(
            target: "elem_2 other: scroll area",
            reason: "Accessibility value is not settable")

        #expect(message.contains("elem_2 other: scroll area"))
        #expect(message.contains("Accessibility value is not settable"))
    }

    @MainActor
    @Test
    func `element actions require a snapshot before target resolution or dispatch`() async throws {
        let service = UIAutomationService(
            snapshotManager: InMemorySnapshotManager(),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionOnly),
            actionInputDriver: RecordingActionInputDriver(),
            automationElementResolver: FixedActionAutomationElementResolver {
                Issue.record("Snapshotless element action reached target resolution")
            })

        do {
            _ = try await service.setValue(target: "Delete", value: .string("yes"), snapshotId: nil)
            Issue.record("Expected snapshotless setValue to fail")
        } catch let PeekabooError.snapshotNotAvailable(message) {
            #expect(message.contains("require a current UI snapshot"))
        }

        do {
            _ = try await service.performAction(target: "Delete", actionName: "AXPress", snapshotId: nil)
            Issue.record("Expected snapshotless performAction to fail")
        } catch let PeekabooError.snapshotNotAvailable(message) {
            #expect(message.contains("require a current UI snapshot"))
        }
    }

    @MainActor
    @Test
    func `element actions reject missing explicit snapshot instead of live lookup`() async throws {
        let service = UIAutomationService(
            snapshotManager: InMemorySnapshotManager(),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionOnly),
            actionInputDriver: RecordingActionInputDriver(),
            automationElementResolver: AutomationElementResolver())

        do {
            _ = try await service.setValue(target: "Delete", value: .string("yes"), snapshotId: "missing-snapshot")
            Issue.record("Expected missing explicit snapshot to fail")
        } catch let error as PeekabooError {
            if case .snapshotNotFound("missing-snapshot") = error {
                return
            }
            Issue.record("Expected snapshotNotFound('missing-snapshot'), got \(error)")
        }
    }

    @MainActor
    @Test
    func `element action facade normalizes stale action driver failures`() async throws {
        let snapshotID = SnapshotReferenceFixtures.first.rawValue
        let detected = DetectedElement(
            id: "B1",
            type: .button,
            label: "Save",
            bounds: CGRect(x: 10, y: 10, width: 80, height: 24))
        let detectionResult = ElementDetectionResult(
            snapshotId: snapshotID,
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(buttons: [detected]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 1,
                method: "test",
                windowContext: WindowContext(applicationProcessId: getpid())))
        let service = try await UIAutomationService(
            snapshotManager: InMemorySnapshotManager.containing(detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionOnly),
            actionInputDriver: RecordingActionInputDriver(elementActionError: .staleElement),
            automationElementResolver: FixedActionAutomationElementResolver())

        do {
            _ = try await service.setValue(target: "B1", value: .string("hello"), snapshotId: snapshotID)
            Issue.record("Expected stale snapshot error from setValue")
        } catch let PeekabooError.snapshotStale(reason) {
            #expect(reason.contains("no longer available"))
        }

        do {
            _ = try await service.performAction(target: "B1", actionName: "AXPress", snapshotId: snapshotID)
            Issue.record("Expected stale snapshot error from performAction")
        } catch let PeekabooError.snapshotStale(reason) {
            #expect(reason.contains("no longer available"))
        }
    }

    @MainActor
    @Test
    func `owner pinned element actions refuse OCR evidence before resolution or dispatch`() async throws {
        let snapshotID = SnapshotReferenceFixtures.second.rawValue
        let processIdentifier = getpid()
        let processStartIdentity: UInt64 = 99
        let bounds = CGRect(x: 100, y: 100, width: 800, height: 600)
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: processIdentifier,
            ownerProcessStartIdentity: processStartIdentity,
            capturedBounds: bounds)
        let detected = DetectedElement(
            id: "ocr_1",
            type: .staticText,
            label: "August",
            bounds: CGRect(x: 120, y: 140, width: 100, height: 20),
            attributes: [
                "description": "ocr",
                "confidence": "0.93",
            ])
        let detectionResult = ElementDetectionResult(
            snapshotId: snapshotID,
            screenshotPath: "/tmp/calendar.png",
            elements: DetectedElements(other: [detected]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 1,
                method: "AXorcist+OCR",
                windowContext: WindowContext(
                    applicationProcessId: processIdentifier,
                    windowID: 42,
                    windowBounds: bounds,
                    windowMutationIdentity: identity)))
        let service = try await UIAutomationService(
            snapshotManager: InMemorySnapshotManager.containing(detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionOnly),
            actionInputDriver: RecordingActionInputDriver(),
            automationElementResolver: FixedActionAutomationElementResolver {
                Issue.record("OCR action reached target resolution")
            },
            exactWindowIdentityValidator: { actual, actualBounds in
                actual == identity && actualBounds == bounds
            },
            processStartIdentityProvider: { _ in processStartIdentity })

        for operation in [
            { try await service.performAction(target: "ocr_1", actionName: "AXPress", snapshotId: snapshotID) },
            { try await service.setValue(target: "ocr_1", value: .string("unsafe"), snapshotId: snapshotID) },
        ] {
            do {
                _ = try await operation()
                Issue.record("Expected OCR semantic evidence refusal")
            } catch let PeekabooError.invalidInput(message) {
                #expect(message.contains("semantic evidence"))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @MainActor
    @Test
    func `exact snapshot element mutations wait only for their process observation frame`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-element-mutation-process-lane-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let firstProcess = ApplicationProcessIdentity(processIdentifier: 610, processStartIdentity: 11)
        let secondProcess = ApplicationProcessIdentity(processIdentifier: 611, processStartIdentity: 12)
        let frameStarted = ActionLaneLatch()
        let frameRelease = ActionLaneLatch()
        let firstResolved = ActionLaneLatch()
        let secondResolved = ActionLaneLatch()
        let firstSnapshotID = SnapshotReferenceFixtures.first.rawValue
        let secondSnapshotID = SnapshotReferenceFixtures.second.rawValue
        let firstIdentity = self.windowIdentity(windowID: 301, process: firstProcess)
        let secondIdentity = self.windowIdentity(windowID: 302, process: secondProcess)
        let firstService = try await self.makeScopedElementMutationService(
            snapshotID: firstSnapshotID,
            identity: firstIdentity,
            coordinator: coordinator,
            currentGeneration: { pid in
                pid == firstProcess.processIdentifier
                    ? firstProcess.processStartIdentity
                    : secondProcess.processStartIdentity
            },
            onResolve: { Task { await firstResolved.open() } })
        let secondService = try await self.makeScopedElementMutationService(
            snapshotID: secondSnapshotID,
            identity: secondIdentity,
            coordinator: coordinator,
            currentGeneration: { pid in
                pid == firstProcess.processIdentifier
                    ? firstProcess.processStartIdentity
                    : secondProcess.processStartIdentity
            },
            onResolve: { Task { await secondResolved.open() } })

        let frame = Task {
            try await coordinator.run(scope: .window(firstIdentity), access: .read) {
                await frameStarted.open()
                await frameRelease.wait()
            }
        }
        await frameStarted.wait()
        let firstMutation = Task {
            try? await firstService.setValue(target: "B1", value: .string("one"), snapshotId: firstSnapshotID)
        }
        let secondMutation = Task {
            try? await secondService.performAction(target: "B1", actionName: "AXPress", snapshotId: secondSnapshotID)
        }

        let secondOverlapped = await secondResolved.opensWithin(.seconds(1))
        let firstOverlapped = await firstResolved.opensWithin(.milliseconds(100))
        #expect(secondOverlapped)
        #expect(!firstOverlapped)
        await frameRelease.open()

        try await frame.value
        _ = await firstMutation.value
        _ = await secondMutation.value
        let firstEventuallyResolved = await firstResolved.isOpen
        #expect(firstEventuallyResolved)
    }

    @MainActor
    @Test
    func `exact snapshot element mutations reject process generation reuse before resolution`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-element-mutation-generation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let process = ApplicationProcessIdentity(processIdentifier: 612, processStartIdentity: 13)
        let identity = self.windowIdentity(windowID: 303, process: process)
        let snapshotID = SnapshotReferenceFixtures.third.rawValue
        let service = try await self.makeScopedElementMutationService(
            snapshotID: snapshotID,
            identity: identity,
            coordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            currentGeneration: { _ in process.processStartIdentity + 1 },
            onResolve: { Issue.record("Stale element mutation reached target resolution") })

        do {
            _ = try await service.performAction(target: "B1", actionName: "AXPress", snapshotId: snapshotID)
            Issue.record("Expected reused process generation to refuse action")
        } catch let PeekabooError.snapshotStale(reason) {
            #expect(reason.contains("process generation"))
        }

        do {
            _ = try await service.setValue(target: "B1", value: .string("new"), snapshotId: snapshotID)
            Issue.record("Expected reused process generation to refuse set-value")
        } catch let PeekabooError.snapshotStale(reason) {
            #expect(reason.contains("process generation"))
        }
    }

    @MainActor
    @Test
    func `mock element can exercise action click without live AX`() throws {
        let element = MockAutomationElement(
            role: AXRoleNames.kAXButtonRole,
            frame: CGRect(x: 10, y: 20, width: 30, height: 40),
            actionNames: [AXActionNames.kAXPressAction])

        let result = try ActionInputDriver().tryClickForTesting(element: element)

        #expect(element.performedActions == [AXActionNames.kAXPressAction])
        #expect(result.outcome.state == .dispatchedUnverified)
        #expect(result.outcome.evidence == .deliveryAccepted)
        #expect(result.anchorPoint == CGPoint(x: 25, y: 40))
        #expect(result.elementRole == AXRoleNames.kAXButtonRole)
    }

    @MainActor
    @Test
    func `right click target unavailable becomes fallback eligible`() async throws {
        let element = MockAutomationElement(
            role: AXRoleNames.kAXButtonRole,
            actionNames: [AXActionNames.kAXShowMenuAction],
            actionErrors: [AXActionNames.kAXShowMenuAction: AccessibilitySystemError(.cannotComplete)])

        do {
            _ = try await ActionInputDriver().tryRightClick(element: element)
            Issue.record("Expected right-click action to request synthetic fallback")
        } catch let error as ActionInputError {
            #expect(error == .unsupported(.actionUnsupported))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @MainActor
    @Test
    func `right click performs show menu action`() async throws {
        let element = MockAutomationElement(
            role: AXRoleNames.kAXButtonRole,
            actionNames: [AXActionNames.kAXShowMenuAction])

        let result = try await ActionInputDriver().tryRightClick(element: element)

        #expect(element.performedActions == [AXActionNames.kAXShowMenuAction])
        #expect(result.actionName == AXActionNames.kAXShowMenuAction)
        #expect(result.elementRole == AXRoleNames.kAXButtonRole)
    }

    @MainActor
    @Test
    func `text field action click focuses when press is unavailable`() throws {
        let element = MockAutomationElement(
            role: AXRoleNames.kAXTextFieldRole,
            frame: CGRect(x: 10, y: 20, width: 30, height: 40),
            isValueSettable: true,
            isFocusedSettable: true)

        let result = try ActionInputDriver().tryClickForTesting(element: element)

        #expect(element.performedActions.isEmpty)
        #expect(element.setFocusedValues == [true])
        #expect(result.actionName == AXAttributeNames.kAXFocusedAttribute)
        #expect(result.anchorPoint == CGPoint(x: 25, y: 40))
        #expect(result.elementRole == AXRoleNames.kAXTextFieldRole)
        #expect(result.outcome.state == .confirmedChange)
        #expect(result.focusedElement?.identifier == nil)
    }

    @MainActor
    @Test
    func `text field click without negotiated value delivery refuses before focus write`() throws {
        let element = MockAutomationElement(
            role: AXRoleNames.kAXTextFieldRole,
            frame: CGRect(x: 10, y: 20, width: 30, height: 40),
            isValueSettable: true,
            isFocusedSettable: true)

        #expect(throws: ActionInputError.self) {
            _ = try ActionInputDriver().tryClickForTesting(
                element: element,
                allowAccessibilityValueFallback: false)
        }
        #expect(element.performedActions.isEmpty)
        #expect(element.setFocusedValues.isEmpty)
    }

    @MainActor
    @Test
    func `legacy action driver opt out refuses before invoking an unknown click implementation`() throws {
        let driver = RecordingActionInputDriver()
        let element = AutomationElement(Element(AXUIElementCreateApplication(getpid())))

        #expect(throws: ActionInputError.self) {
            _ = try driver.tryClick(element: element, allowAccessibilityValueFallback: false)
        }
        #expect(driver.clickCallCount == 0)
    }

    @MainActor
    @Test
    func `exact semantic focus returns confirmed receipt without redispatch when already focused`() throws {
        let frame = CGRect(x: 10, y: 20, width: 30, height: 40)
        let element = MockAutomationElement(
            identifier: "editor",
            role: AXRoleNames.kAXTextFieldRole,
            frame: frame,
            isFocusedSettable: true,
            isFocused: true)

        let result = try ActionInputDriver().tryFocus(element: element)

        #expect(element.setFocusedValues.isEmpty)
        #expect(result.outcome.state == .confirmedNoChange)
        #expect(result.focusedElement == FocusedElementIdentity(
            processIdentifier: 777,
            windowID: 42,
            role: AXRoleNames.kAXTextFieldRole,
            identifier: "editor",
            frame: frame))
    }

    @MainActor
    @Test
    func `exact semantic focus refuses an unsettable field before mutation`() {
        let element = MockAutomationElement(
            role: AXRoleNames.kAXTextFieldRole,
            frame: CGRect(x: 10, y: 20, width: 30, height: 40))

        #expect(throws: FocusedElementReceiptError.focusedAttributeNotSettable) {
            _ = try ActionInputDriver().tryFocus(element: element)
        }
        #expect(element.setFocusedValues.isEmpty)
    }

    @MainActor
    @Test
    func `exact semantic focus reports retry unsafe when accepted setter cannot be confirmed`() {
        let element = MockAutomationElement(
            role: AXRoleNames.kAXTextFieldRole,
            frame: CGRect(x: 10, y: 20, width: 30, height: 40),
            isFocusedSettable: true,
            focusSetterDoesNotChange: true)

        do {
            _ = try ActionInputDriver().tryFocus(element: element)
            Issue.record("Expected unconfirmed native focus to fail")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState.mutationDispatched)
            #expect(failure.outcome.retrySafety == .unsafe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(element.setFocusedValues == [true])
    }

    @MainActor
    @Test
    func `focus click target classification is limited to focusable inputs`() {
        #expect(ActionInputDriver.canFocusForClickForTesting(
            role: AXRoleNames.kAXTextFieldRole,
            isValueSettable: true,
            isFocusedSettable: true))
        #expect(!ActionInputDriver.canFocusForClickForTesting(
            role: AXRoleNames.kAXButtonRole,
            isValueSettable: false,
            isFocusedSettable: true))
        #expect(!ActionInputDriver.canFocusForClickForTesting(
            role: AXRoleNames.kAXTextFieldRole,
            isValueSettable: true,
            isFocusedSettable: false))
    }

    @MainActor
    @Test
    func `numeric slider coerces CLI text to a floating point AX value`() throws {
        let element = MockAutomationElement(
            role: AXRoleNames.kAXSliderRole,
            value: 50.0,
            isValueSettable: true)

        let result = try ActionInputDriver().trySetValueForTesting(element: element, value: .string("0.75"))

        #expect(element.setValues == [.double(0.75)])
        #expect((element.value as? Double) == 0.75)
        #expect(result.outcome.state == .confirmedChange)
        #expect(result.outcome.evidence == .verifiedChange)
        #expect(result.actionName == AXActionNames.kAXSetValueAction)
    }

    @MainActor
    @Test
    func `boolean selected attribute is set and verified`() throws {
        let element = MockAutomationElement(
            role: AXRoleNames.kAXRowRole,
            isSelectedSettable: true,
            selectedValue: false)

        let result = try ActionInputDriver().trySetValueForTesting(element: element, value: .string("true"))

        #expect(element.setSelectedValues == [true])
        #expect(element.selectedValue == true)
        #expect(result.outcome.state == .confirmedChange)
        #expect(result.actionName == kAXSelectedAttribute as String)
    }

    @MainActor
    @Test
    func `numeric-looking text field value remains a string`() throws {
        let element = MockAutomationElement(
            role: AXRoleNames.kAXTextFieldRole,
            value: "123",
            isValueSettable: true)

        _ = try ActionInputDriver().trySetValueForTesting(element: element, value: .string("456"))

        #expect(element.setValues == [.string("456")])
        #expect((element.value as? String) == "456")
    }

    @MainActor
    @Test
    func `idempotent set succeeds without writing the attribute`() throws {
        let element = MockAutomationElement(
            role: AXRoleNames.kAXSliderRole,
            value: 0.75,
            isValueSettable: true)

        let result = try ActionInputDriver().trySetValueForTesting(element: element, value: .string("0.75"))

        #expect(element.setValues.isEmpty)
        #expect(result.outcome.state == .confirmedNoChange)
        #expect(result.outcome.dispatchState == .none)
        #expect(result.actionName == AXActionNames.kAXSetValueAction)
    }

    @MainActor
    @Test
    func `accepted value setter with unconfirmed readback is retry unsafe`() {
        let element = MockAutomationElement(
            role: AXRoleNames.kAXSliderRole,
            value: 50.0,
            isValueSettable: true,
            valueSetterDoesNotChange: true)

        do {
            _ = try ActionInputDriver().trySetValueForTesting(element: element, value: .string("0.75"))
            Issue.record("Expected unchanged value to fail verification")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.evidence == .completionUnknown)
            #expect(failure.outcome.delivery == .init(mechanism: .accessibilityValue, mode: .background))
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: .one))
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.projection.requiresFreshObservation)
            #expect(failure.hint?.contains("Observe the exact target") == true)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(element.setValues == [.double(0.75)])
    }

    @MainActor
    @Test
    func `unreadable post-dispatch value is indeterminate instead of a raw driver error`() {
        let element = MockAutomationElement(
            role: AXRoleNames.kAXSliderRole,
            isValueSettable: true,
            valueSetterDoesNotChange: true)

        do {
            _ = try ActionInputDriver().trySetValueForTesting(element: element, value: .double(0.75))
            Issue.record("Expected unverifiable value to fail")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: .one))
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.targetReceipt == nil)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(element.setValues == [.double(0.75)])
    }

    @MainActor
    @Test
    func `mock menu tree can exercise hotkey menu resolution without live AX`() throws {
        let saveItem = MockAutomationElement(
            role: AXRoleNames.kAXMenuItemRole,
            actionNames: [AXActionNames.kAXPressAction],
            stringAttributes: ["AXMenuItemCmdChar": "s"],
            intAttributes: ["AXMenuItemCmdModifiers": 1 << 0])
        let fileMenu = MockAutomationElement(role: AXRoleNames.kAXMenuRole, children: [saveItem])
        let fileMenuBarItem = MockAutomationElement(role: AXRoleNames.kAXMenuBarItemRole, children: [fileMenu])
        let menuBar = MockAutomationElement(role: AXRoleNames.kAXMenuBarRole, children: [fileMenuBarItem])

        let result = try ActionInputDriver().tryHotkeyForTesting(keys: ["cmd", "shift", "s"], menuBar: menuBar)

        #expect(saveItem.performedActions == [AXActionNames.kAXPressAction])
        #expect(result.elementRole == AXRoleNames.kAXMenuItemRole)
    }

    @MainActor
    @Test
    func `mock element unsupported action classifies as fallback eligible`() {
        let element = MockAutomationElement(role: AXRoleNames.kAXButtonRole)

        do {
            _ = try ActionInputDriver().tryClickForTesting(element: element)
            Issue.record("Expected unsupported mock action to throw")
        } catch let error as ActionInputError {
            #expect(error == .unsupported(.actionUnsupported))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @MainActor
    @Test
    func `non-advertised action is rejected before a phantom-success AX invocation`() {
        let element = PhantomSuccessAutomationElement(role: AXRoleNames.kAXButtonRole)

        do {
            _ = try ActionInputDriver().tryPerformActionForTesting(
                element: element,
                actionName: AXActionNames.kAXPressAction)
            Issue.record("Expected non-advertised action to be rejected")
        } catch let error as ActionInputError {
            #expect(error == .unsupported(.actionUnsupported))
            #expect(element.performedActions.isEmpty)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @MainActor
    private func makeScopedElementMutationService(
        snapshotID: String,
        identity: WindowMutationIdentity,
        coordinator: DesktopOperationLaneCoordinator,
        currentGeneration: @escaping @Sendable (pid_t) -> UInt64?,
        onResolve: @escaping @MainActor () -> Void) async throws -> UIAutomationService
    {
        let detected = DetectedElement(
            id: "B1",
            type: .textField,
            label: "Value",
            bounds: CGRect(x: 10, y: 10, width: 80, height: 24))
        let context = WindowContext(
            applicationProcessId: identity.ownerProcessIdentifier,
            windowID: identity.windowID,
            windowBounds: identity.capturedBounds,
            windowMutationIdentity: identity)
        let detectionResult = ElementDetectionResult(
            snapshotId: snapshotID,
            screenshotPath: "/tmp/\(snapshotID).png",
            elements: DetectedElements(textFields: [detected]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 1,
                method: "test",
                windowContext: context))
        return try await UIAutomationService(
            snapshotManager: InMemorySnapshotManager.containing(detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionOnly),
            actionInputDriver: RecordingActionInputDriver(elementActionError: .staleElement),
            automationElementResolver: FixedActionAutomationElementResolver(onResolve: onResolve),
            exactWindowIdentityValidator: { _, _ in true },
            processStartIdentityProvider: currentGeneration,
            operationLaneCoordinator: coordinator)
    }

    private func windowIdentity(
        windowID: Int,
        process: ApplicationProcessIdentity) -> WindowMutationIdentity
    {
        WindowMutationIdentity(
            windowID: windowID,
            ownerProcessIdentifier: process.processIdentifier,
            ownerProcessStartIdentity: process.processStartIdentity,
            capturedBounds: CGRect(x: 1, y: 2, width: 300, height: 200))
    }
}

struct ActionInputDriverOutcomeTests {
    @MainActor
    @Test
    func `unknown pre-action value remains dispatched but unverified`() throws {
        let element = MockAutomationElement(
            role: AXRoleNames.kAXTextFieldRole,
            isValueSettable: true)
        let result = try ActionInputDriver().trySetValueForTesting(element: element, value: .string("hello"))

        #expect(element.setValues == [.string("hello")])
        #expect(result.outcome.state == .dispatchedUnverified)
        #expect(result.outcome.evidence == .deliveryAccepted)
        #expect(result.outcome.retrySafety == .unsafe)
        #expect(result.outcome.delivery == .init(mechanism: .accessibilityValue, mode: .background))
        #expect(result.actionName == AXActionNames.kAXSetValueAction)
    }

    @MainActor
    @Test
    func `unknown pre-action selected state remains dispatched but unverified`() throws {
        let element = MockAutomationElement(
            role: AXRoleNames.kAXRowRole,
            isSelectedSettable: true)
        let result = try ActionInputDriver().trySetValueForTesting(element: element, value: .string("true"))

        #expect(element.setSelectedValues == [true])
        #expect(element.selectedValue == true)
        #expect(result.outcome.state == .dispatchedUnverified)
        #expect(result.outcome.evidence == .deliveryAccepted)
        #expect(result.outcome.retrySafety == .unsafe)
    }
}

@MainActor
private final class PhantomSuccessAutomationElement: AutomationElementRepresenting, @unchecked Sendable {
    let name: String? = nil
    let label: String? = nil
    let roleDescription: String? = nil
    let identifier: String? = nil
    let role: String?
    let subrole: String? = nil
    let frame: CGRect? = nil
    let value: Any? = nil
    let stringValue: String? = nil
    let actionNames: [String] = []
    let isValueSettable = false
    let isFocusedSettable = false
    let isEnabled = true
    let isFocused = false
    let isOffscreen = false
    let anchorPoint: CGPoint? = nil
    let automationChildren: [any AutomationElementRepresenting] = []
    var performedActions: [String] = []

    init(role: String?) {
        self.role = role
    }

    func performAutomationAction(_ actionName: String) throws {
        self.performedActions.append(actionName)
    }

    func setAutomationValue(_: UIElementValue) throws {}

    func setAutomationFocused(_: Bool) throws {}

    func stringAttribute(_: String) -> String? {
        nil
    }

    func intAttribute(_: String) -> Int? {
        nil
    }
}

@MainActor
private final class RecordingActionInputDriver: ActionInputDriving {
    private let elementActionError: ActionInputError?
    private(set) var clickCallCount = 0

    init(elementActionError: ActionInputError? = nil) {
        self.elementActionError = elementActionError
    }

    func tryClick(element _: AutomationElement) throws -> UIInputExecutionResult.Action {
        self.clickCallCount += 1
        Issue.record("Action driver should not be called")
        return UIInputExecutionResult.Action(outcome: .confirmedNoChange())
    }

    func tryRightClick(element _: any AutomationElementRepresenting) async throws -> UIInputExecutionResult.Action {
        Issue.record("Action driver should not be called")
        return UIInputExecutionResult.Action(outcome: .confirmedNoChange())
    }

    func tryScroll(
        element _: AutomationElement,
        direction _: PeekabooFoundation.ScrollDirection,
        pages _: Int) throws -> UIInputExecutionResult.Action
    {
        Issue.record("Action driver should not be called")
        return UIInputExecutionResult.Action(outcome: .confirmedNoChange())
    }

    func trySetText(element _: AutomationElement, text _: String, replace _: Bool) throws
    -> UIInputExecutionResult.Action {
        Issue.record("Action driver should not be called")
        return UIInputExecutionResult.Action(outcome: .confirmedNoChange())
    }

    func tryHotkey(application _: NSRunningApplication, keys _: [String]) throws
    -> UIInputExecutionResult.Action {
        Issue.record("Action driver should not be called")
        return UIInputExecutionResult.Action(outcome: .confirmedNoChange())
    }

    func trySetValue(element _: AutomationElement, value _: UIElementValue) throws
    -> UIInputExecutionResult.Action {
        if let elementActionError {
            throw elementActionError
        }
        Issue.record("Action driver should not be called")
        return UIInputExecutionResult.Action(outcome: .confirmedNoChange())
    }

    func tryPerformAction(element _: AutomationElement, actionName _: String) throws
    -> UIInputExecutionResult.Action {
        if let elementActionError {
            throw elementActionError
        }
        Issue.record("Action driver should not be called")
        return UIInputExecutionResult.Action(outcome: .confirmedNoChange())
    }
}

@MainActor
private final class FixedActionAutomationElementResolver: AutomationElementResolving {
    private let element = AutomationElement(Element(AXUIElementCreateApplication(getpid())))
    private let onResolve: @MainActor () -> Void

    init(onResolve: @escaping @MainActor () -> Void = {}) {
        self.onResolve = onResolve
    }

    func resolve(detectedElement _: DetectedElement, windowContext _: WindowContext?) -> AutomationElement? {
        self.onResolve()
        return self.element
    }

    func resolve(
        detectedElement _: DetectedElement,
        windowContext _: WindowContext?,
        targetProcessIdentifier _: pid_t?) -> AutomationElement?
    {
        self.onResolve()
        return self.element
    }

    func resolve(query _: String, windowContext _: WindowContext?, requireTextInput _: Bool) -> AutomationElement? {
        self.onResolve()
        return self.element
    }

    func resolve(
        query _: String,
        windowContext _: WindowContext?,
        targetProcessIdentifier _: pid_t?,
        requireTextInput _: Bool) -> AutomationElement?
    {
        self.onResolve()
        return self.element
    }
}

private actor ActionLaneLatch {
    private var opened = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var isOpen: Bool {
        self.opened
    }

    func open() {
        guard !self.opened else { return }
        self.opened = true
        let pending = self.continuations
        self.continuations.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        guard !self.opened else { return }
        await withCheckedContinuation { self.continuations.append($0) }
    }

    func opensWithin(_ duration: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: duration)
        while !self.opened, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return self.opened
    }
}

@MainActor
private final class MockAutomationElement: AutomationElementRepresenting, @unchecked Sendable {
    let name: String?
    let label: String?
    let roleDescription: String?
    let identifier: String?
    let role: String?
    let subrole: String?
    let frame: CGRect?
    var value: Any?
    var stringValue: String? {
        self.value as? String
    }

    let actionNames: [String]
    let isValueSettable: Bool
    let isFocusedSettable: Bool
    let isSelectedSettable: Bool
    var selectedValue: Bool?
    let isEnabled: Bool
    var isFocused: Bool
    let focusedElementIdentity: FocusedElementIdentity?
    let isOffscreen: Bool
    var anchorPoint: CGPoint? {
        self.frame.map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    private let children: [MockAutomationElement]
    private let stringAttributes: [String: String]
    private let intAttributes: [String: Int]
    private let doubleAttributes: [String: Double]
    private let actionErrors: [String: any Error]
    private let actionFailureAfterSuccesses: Int?
    private let sequencedActionFailure: (any Error)?
    private let valueSetterDoesNotChange: Bool
    private let focusSetterDoesNotChange: Bool
    var performedActions: [String] = []
    var attemptedActions: [String] = []
    var setValues: [UIElementValue] = []
    var setFocusedValues: [Bool] = []
    var setSelectedValues: [Bool] = []

    var automationChildren: [any AutomationElementRepresenting] {
        self.children
    }

    init(
        name: String? = nil,
        label: String? = nil,
        roleDescription: String? = nil,
        identifier: String? = nil,
        role: String? = nil,
        subrole: String? = nil,
        frame: CGRect? = nil,
        value: Any? = nil,
        actionNames: [String] = [],
        isValueSettable: Bool = false,
        isFocusedSettable: Bool = false,
        isSelectedSettable: Bool = false,
        selectedValue: Bool? = nil,
        isEnabled: Bool = true,
        isFocused: Bool = false,
        focusedElementIdentity: FocusedElementIdentity? = nil,
        isOffscreen: Bool = false,
        children: [MockAutomationElement] = [],
        stringAttributes: [String: String] = [:],
        intAttributes: [String: Int] = [:],
        doubleAttributes: [String: Double] = [:],
        actionErrors: [String: any Error] = [:],
        actionFailureAfterSuccesses: Int? = nil,
        sequencedActionFailure: (any Error)? = nil,
        valueSetterDoesNotChange: Bool = false,
        focusSetterDoesNotChange: Bool = false)
    {
        self.name = name
        self.label = label
        self.roleDescription = roleDescription
        self.identifier = identifier
        self.role = role
        self.subrole = subrole
        self.frame = frame
        self.value = value
        self.actionNames = actionNames
        self.isValueSettable = isValueSettable
        self.isFocusedSettable = isFocusedSettable
        self.isSelectedSettable = isSelectedSettable
        self.selectedValue = selectedValue
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.focusedElementIdentity = focusedElementIdentity ?? role.flatMap { role in
            frame.map { frame in
                FocusedElementIdentity(
                    processIdentifier: 777,
                    windowID: 42,
                    role: role,
                    identifier: identifier,
                    frame: frame)
            }
        }
        self.isOffscreen = isOffscreen
        self.children = children
        self.stringAttributes = stringAttributes
        self.intAttributes = intAttributes
        self.doubleAttributes = doubleAttributes
        self.actionErrors = actionErrors
        self.actionFailureAfterSuccesses = actionFailureAfterSuccesses
        self.sequencedActionFailure = sequencedActionFailure
        self.valueSetterDoesNotChange = valueSetterDoesNotChange
        self.focusSetterDoesNotChange = focusSetterDoesNotChange
    }

    func performAutomationAction(_ actionName: String) throws {
        self.attemptedActions.append(actionName)
        if let error = self.actionErrors[actionName] {
            throw error
        }
        if let actionFailureAfterSuccesses,
           self.performedActions.count >= actionFailureAfterSuccesses,
           let sequencedActionFailure
        {
            throw sequencedActionFailure
        }
        guard self.actionNames.contains(actionName) else {
            throw AccessibilitySystemError(.actionUnsupported)
        }
        self.performedActions.append(actionName)
    }

    func setAutomationValue(_ value: UIElementValue) throws {
        guard self.isValueSettable else {
            throw AccessibilitySystemError(.attributeUnsupported)
        }
        self.setValues.append(value)
        guard !self.valueSetterDoesNotChange else { return }
        switch value {
        case let .bool(value):
            self.value = value
        case let .int(value):
            self.value = value
        case let .double(value):
            self.value = value
        case let .string(value):
            self.value = value
        }
    }

    func setAutomationFocused(_ focused: Bool) throws {
        guard self.isFocusedSettable else {
            throw AccessibilitySystemError(.attributeUnsupported)
        }
        self.setFocusedValues.append(focused)
        guard !self.focusSetterDoesNotChange else { return }
        self.isFocused = focused
    }

    func setAutomationSelected(_ selected: Bool) throws {
        guard self.isSelectedSettable else {
            throw AccessibilitySystemError(.attributeUnsupported)
        }
        self.setSelectedValues.append(selected)
        self.selectedValue = selected
    }

    func stringAttribute(_ name: String) -> String? {
        self.stringAttributes[name]
    }

    func intAttribute(_ name: String) -> Int? {
        self.intAttributes[name]
    }

    func doubleAttribute(_ name: String) -> Double? {
        self.doubleAttributes[name]
    }
}
