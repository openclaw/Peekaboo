import CoreGraphics
import Foundation
import PeekabooFoundation
import UniformTypeIdentifiers
import XCTest
@testable import PeekabooAutomationKit

@available(macOS 14.0, *)
@MainActor
final class ProcessServiceInteractionScriptTests: XCTestCase {
    func testMenuGenericParametersCombineMenuAndItemPath() async throws {
        let menuService = RecordingMenuService()
        let processService = ProcessService(
            applicationService: UnusedApplicationService(),
            screenCaptureService: UnusedScreenCaptureService(),
            snapshotManager: UnusedSnapshotManager(),
            uiAutomationService: UnusedUIAutomationService(),
            windowManagementService: UnusedWindowManagementService(),
            menuService: menuService,
            dockService: UnusedDockService(),
            clipboardService: UnusedClipboardService())

        _ = try await processService.executeStep(
            ScriptStep(stepId: "menu", comment: nil, command: "menu", params: .generic([
                "app": "Finder",
                "menu": "File",
                "item": "New Finder Window",
            ])),
            snapshotId: nil)

        XCTAssertEqual(menuService.clicks, [
            RecordingMenuService.Click(app: "Finder", itemPath: "File > New Finder Window"),
        ])
    }

    func testMenuGenericParametersPreserveMenuPathWithoutItem() async throws {
        let menuService = RecordingMenuService()
        let processService = ProcessService(
            applicationService: UnusedApplicationService(),
            screenCaptureService: UnusedScreenCaptureService(),
            snapshotManager: UnusedSnapshotManager(),
            uiAutomationService: UnusedUIAutomationService(),
            windowManagementService: UnusedWindowManagementService(),
            menuService: menuService,
            dockService: UnusedDockService(),
            clipboardService: UnusedClipboardService())

        _ = try await processService.executeStep(
            ScriptStep(stepId: "menu", comment: nil, command: "menu", params: .generic([
                "app": "Finder",
                "menu": "File > New Finder Window",
            ])),
            snapshotId: nil)

        XCTAssertEqual(menuService.clicks, [
            RecordingMenuService.Click(app: "Finder", itemPath: "File > New Finder Window"),
        ])
    }

    func testHotkeyGenericParametersParseModifiersList() async throws {
        let automation = RecordingInteractionUIAutomationService()
        let processService = ProcessService(
            applicationService: UnusedApplicationService(),
            screenCaptureService: UnusedScreenCaptureService(),
            snapshotManager: UnusedSnapshotManager(),
            uiAutomationService: automation,
            windowManagementService: UnusedWindowManagementService(),
            menuService: UnusedMenuService(),
            dockService: UnusedDockService(),
            clipboardService: UnusedClipboardService())

        _ = try await processService.executeStep(
            ScriptStep(stepId: "hotkey", comment: nil, command: "hotkey", params: .generic([
                "key": "p",
                "modifiers": "command,shift",
                "pid": "4242",
            ])),
            snapshotId: nil)

        XCTAssertEqual(automation.hotkeys, [])
        XCTAssertEqual(automation.targetedHotkeys, [
            RecordingInteractionUIAutomationService.TargetedHotkeyCall(keys: "cmd,shift,p", pid: 4242),
        ])
    }

    func testHotkeyGenericParametersAcceptStandaloneKeysChordSchema() async throws {
        let automation = RecordingInteractionUIAutomationService()
        let processService = self.makeProcessService(automation: automation)

        _ = try await processService.executeStep(
            ScriptStep(stepId: "hotkey", comment: nil, command: "hotkey", params: .generic([
                "keys": "cmd+shift+p",
                "pid": "4242",
            ])),
            snapshotId: nil)

        XCTAssertEqual(automation.targetedHotkeys, [
            RecordingInteractionUIAutomationService.TargetedHotkeyCall(keys: "cmd,shift,p", pid: 4242),
        ])
    }

    func testScriptSnapshotReferencesResolveLatestAndPriorStepId() throws {
        let processService = self.makeProcessService(automation: RecordingInteractionUIAutomationService())
        let step = ScriptStep(
            stepId: "click",
            comment: nil,
            command: "click",
            params: .click(.init(label: "Search", snapshot: "observe")))

        let named = try processService.resolvingScriptSnapshotReference(
            in: step,
            currentSnapshotId: "newer-snapshot",
            snapshotIdsByStepId: ["observe": "named-snapshot"])
        guard case let .click(namedParams) = named.params else {
            return XCTFail("Expected click parameters")
        }
        XCTAssertEqual(namedParams.snapshot, "named-snapshot")

        let latestStep = ScriptStep(
            stepId: "type",
            comment: nil,
            command: "type",
            params: .type(.init(text: "hello", snapshot: "latest")))
        let latest = try processService.resolvingScriptSnapshotReference(
            in: latestStep,
            currentSnapshotId: "newer-snapshot",
            snapshotIdsByStepId: ["observe": "named-snapshot"])
        guard case let .type(latestParams) = latest.params else {
            return XCTFail("Expected type parameters")
        }
        XCTAssertEqual(latestParams.snapshot, "newer-snapshot")
    }

    func testScriptLatestSnapshotReferenceRequiresPrecedingObservation() {
        let processService = self.makeProcessService(automation: RecordingInteractionUIAutomationService())
        let step = ScriptStep(
            stepId: "click",
            comment: nil,
            command: "click",
            params: .click(.init(label: "Search", snapshot: "latest")))

        XCTAssertThrowsError(try processService.resolvingScriptSnapshotReference(
            in: step,
            currentSnapshotId: nil,
            snapshotIdsByStepId: [:]))
        { error in
            XCTAssertTrue(error.localizedDescription.contains("No preceding script step"))
        }
    }

    func testTypeGenericParametersParseCamelCaseControlFlags() async throws {
        let automation = RecordingInteractionUIAutomationService()
        let processService = ProcessService(
            applicationService: UnusedApplicationService(),
            screenCaptureService: UnusedScreenCaptureService(),
            snapshotManager: UnusedSnapshotManager(),
            uiAutomationService: automation,
            windowManagementService: UnusedWindowManagementService(),
            menuService: UnusedMenuService(),
            dockService: UnusedDockService(),
            clipboardService: UnusedClipboardService())

        _ = try await processService.executeStep(
            ScriptStep(stepId: "type", comment: nil, command: "type", params: .generic([
                "text": "hello",
                "field": "Search",
                "clearFirst": "true",
                "pressEnter": "true",
                "pid": "4242",
            ])),
            snapshotId: nil)

        XCTAssertEqual(automation.targetedClickPIDs, [4242])
        XCTAssertEqual(automation.typeActionCounts, [3])
        XCTAssertEqual(automation.targetedTypePIDs, [4242])
    }

    func testSwipeWithoutExplicitStartUsesPrimaryScreenServiceCenter() async throws {
        let automation = RecordingInteractionUIAutomationService()
        let processService = ProcessService(
            applicationService: UnusedApplicationService(),
            screenCaptureService: UnusedScreenCaptureService(),
            snapshotManager: UnusedSnapshotManager(),
            uiAutomationService: automation,
            windowManagementService: UnusedWindowManagementService(),
            menuService: UnusedMenuService(),
            dockService: UnusedDockService(),
            clipboardService: UnusedClipboardService(),
            screenService: StaticScreenService(frame: CGRect(x: 100, y: 50, width: 600, height: 400)))

        _ = try await processService.executeStep(
            ScriptStep(stepId: "swipe", comment: nil, command: "swipe", params: .generic([
                "direction": "left",
                "distance": "40",
                "duration": "0.25",
                "foreground": "true",
            ])),
            snapshotId: nil)

        XCTAssertEqual(automation.swipes.count, 1)
        XCTAssertEqual(automation.swipes[0].from, CGPoint(x: 400, y: 250))
        XCTAssertEqual(automation.swipes[0].to, CGPoint(x: 360, y: 250))
        XCTAssertEqual(automation.swipes[0].duration, 250)
    }

    func testDragGenericParametersParseModifiersList() async throws {
        let automation = RecordingInteractionUIAutomationService()
        let processService = ProcessService(
            applicationService: UnusedApplicationService(),
            screenCaptureService: UnusedScreenCaptureService(),
            snapshotManager: UnusedSnapshotManager(),
            uiAutomationService: automation,
            windowManagementService: UnusedWindowManagementService(),
            menuService: UnusedMenuService(),
            dockService: UnusedDockService(),
            clipboardService: UnusedClipboardService())

        _ = try await processService.executeStep(
            ScriptStep(stepId: "drag", comment: nil, command: "drag", params: .generic([
                "from-x": "10",
                "from-y": "20",
                "to-x": "30",
                "to-y": "40",
                "modifiers": "command,shift",
                "foreground": "true",
            ])),
            snapshotId: nil)

        XCTAssertEqual(automation.drags, [
            RecordingInteractionUIAutomationService.DragCall(
                from: CGPoint(x: 10, y: 20),
                to: CGPoint(x: 30, y: 40),
                modifiers: "cmd,shift"),
        ])
    }

    func testTargetlessHotkeyRequiresExplicitForeground() async throws {
        let automation = RecordingInteractionUIAutomationService()
        let processService = self.makeProcessService(automation: automation)

        do {
            _ = try await processService.executeStep(
                ScriptStep(
                    stepId: "hotkey",
                    comment: nil,
                    command: "hotkey",
                    params: .hotkey(.init(key: "p", modifiers: ["command"]))),
                snapshotId: nil)
            XCTFail("Expected targetless background hotkey to fail")
        } catch let PeekabooError.invalidInput(message) {
            XCTAssertTrue(message.contains("foreground"))
            XCTAssertTrue(message.contains("foreground: true"))
        }
        XCTAssertTrue(automation.hotkeys.isEmpty)
        XCTAssertTrue(automation.targetedHotkeys.isEmpty)
    }

    func testExplicitForegroundHotkeyUsesGlobalDelivery() async throws {
        let automation = RecordingInteractionUIAutomationService()
        let processService = self.makeProcessService(automation: automation)

        _ = try await processService.executeStep(
            ScriptStep(
                stepId: "hotkey",
                comment: nil,
                command: "hotkey",
                params: .hotkey(.init(key: "p", modifiers: ["command"], foreground: true))),
            snapshotId: nil)

        XCTAssertEqual(automation.hotkeys, ["cmd,p"])
        XCTAssertTrue(automation.targetedHotkeys.isEmpty)
    }

    func testInteractionWindowAliasesRejectSnapshotFromDifferentExactWindow() async throws {
        let automation = RecordingInteractionUIAutomationService()
        let snapshotId = "sibling-window-snapshot"
        let snapshots = InMemorySnapshotManager(detectionResult: Self.windowScopedDetectionResult(
            snapshotId: snapshotId))
        let processService = self.makeProcessService(automation: automation, snapshots: snapshots)
        let siblingWindowID = 888_888
        let steps = [
            ScriptStep(
                stepId: "click",
                comment: nil,
                command: "click",
                params: .generic([
                    "query": "Search",
                    "snapshot": snapshotId,
                    "windowId": String(siblingWindowID),
                ])),
            ScriptStep(
                stepId: "type",
                comment: nil,
                command: "type",
                params: .generic([
                    "field": "Search",
                    "snapshotId": snapshotId,
                    "text": "must-not-dispatch",
                    "window-id": String(siblingWindowID),
                ])),
            ScriptStep(
                stepId: "hotkey",
                comment: nil,
                command: "hotkey",
                params: .generic([
                    "key": "p",
                    "modifiers": "command",
                    "snapshot-id": snapshotId,
                    "window_id": String(siblingWindowID),
                ])),
        ]

        for step in steps {
            do {
                _ = try await processService.executeStep(step, snapshotId: nil)
                XCTFail("Expected \(step.command) to reject a snapshot from a sibling window")
            } catch let PeekabooError.invalidInput(message) {
                XCTAssertTrue(message.contains("windowId \(siblingWindowID)"))
                XCTAssertTrue(message.contains("snapshot window 999999"))
            }
        }

        XCTAssertEqual(automation.globalClickCount, 0)
        XCTAssertTrue(automation.targetedClickPIDs.isEmpty)
        XCTAssertTrue(automation.hotkeys.isEmpty)
        XCTAssertTrue(automation.targetedHotkeys.isEmpty)
        XCTAssertTrue(automation.typeActionCounts.isEmpty)
        XCTAssertTrue(automation.targetedTypePIDs.isEmpty)
    }

    func testBackgroundTypeAndHotkeyRejectExplicitWindowInsteadOfCollapsingToPID() async throws {
        let automation = RecordingInteractionUIAutomationService()
        let processService = self.makeProcessService(automation: automation)

        let steps = [
            ScriptStep(
                stepId: "type",
                comment: nil,
                command: "type",
                params: .type(.init(text: "hello", pid: 4242, windowId: 999_999))),
            ScriptStep(
                stepId: "hotkey",
                comment: nil,
                command: "hotkey",
                params: .hotkey(.init(key: "p", modifiers: ["command"], pid: 4242, windowId: 999_999))),
        ]

        for step in steps {
            do {
                _ = try await processService.executeStep(step, snapshotId: nil)
                XCTFail("Expected background window-targeted keyboard input to fail")
            } catch let PeekabooError.invalidInput(message) {
                XCTAssertTrue(message.contains("cannot safely target a specific window"))
                XCTAssertTrue(message.contains("foreground: true"))
            }
        }

        XCTAssertTrue(automation.hotkeys.isEmpty)
        XCTAssertTrue(automation.targetedHotkeys.isEmpty)
        XCTAssertTrue(automation.typeActionCounts.isEmpty)
        XCTAssertTrue(automation.targetedTypePIDs.isEmpty)
    }

    func testBackgroundTypeAndHotkeyRejectWindowScopedSnapshotInsteadOfCollapsingToPID() async throws {
        let automation = RecordingInteractionUIAutomationService()
        let snapshotId = "window-scoped-snapshot"
        let snapshots = InMemorySnapshotManager(detectionResult: Self.windowScopedDetectionResult(
            snapshotId: snapshotId))
        let processService = self.makeProcessService(automation: automation, snapshots: snapshots)

        let steps = [
            ScriptStep(
                stepId: "type",
                comment: nil,
                command: "type",
                params: .type(.init(text: "hello", snapshot: snapshotId))),
            ScriptStep(
                stepId: "hotkey",
                comment: nil,
                command: "hotkey",
                params: .hotkey(.init(key: "p", modifiers: ["command"], snapshot: snapshotId))),
        ]

        for step in steps {
            do {
                _ = try await processService.executeStep(step, snapshotId: nil)
                XCTFail("Expected background snapshot-window keyboard input to fail")
            } catch let PeekabooError.invalidInput(message) {
                XCTAssertTrue(message.contains("cannot safely target a specific window"))
                XCTAssertTrue(message.contains("foreground: true"))
            }
        }

        XCTAssertTrue(automation.hotkeys.isEmpty)
        XCTAssertTrue(automation.targetedHotkeys.isEmpty)
        XCTAssertTrue(automation.typeActionCounts.isEmpty)
        XCTAssertTrue(automation.targetedTypePIDs.isEmpty)
    }

    func testStaleSnapshotProcessGenerationNeverRebindsSamePIDAndWindowID() async throws {
        let automation = RecordingInteractionUIAutomationService()
        let snapshotId = "reused-pid-window-snapshot"
        let processService = self.makeProcessService(
            automation: automation,
            snapshots: InMemorySnapshotManager(detectionResult: Self.windowScopedDetectionResult(
                snapshotId: snapshotId)),
            currentWindowMutationIdentity: WindowMutationIdentity(
                windowID: 999_999,
                ownerProcessIdentifier: 4242,
                ownerProcessStartIdentity: 2))

        do {
            _ = try await processService.executeStep(
                ScriptStep(
                    stepId: "click",
                    comment: nil,
                    command: "click",
                    params: .click(.init(label: "Search", snapshot: snapshotId))),
                snapshotId: nil)
            XCTFail("Expected the capture-time process generation to fail closed")
        } catch let PeekabooError.invalidInput(message) {
            XCTAssertTrue(message.contains("capture a fresh snapshot"))
        }
        XCTAssertTrue(automation.targetedClickPIDs.isEmpty)
    }

    func testBackgroundWindowScopedFieldTypeRequiresAndUsesFocusedElementProof() async throws {
        let automation = RecordingInteractionUIAutomationService()
        automation.focusedElement = Self.focusedElementInWindow()
        let snapshotId = "window-scoped-field-snapshot"
        let snapshots = InMemorySnapshotManager(detectionResult: Self.windowScopedDetectionResult(
            snapshotId: snapshotId))
        let processService = self.makeProcessService(automation: automation, snapshots: snapshots)

        _ = try await processService.executeStep(
            ScriptStep(
                stepId: "type",
                comment: nil,
                command: "type",
                params: .type(.init(text: "hello", snapshot: snapshotId, field: "Search"))),
            snapshotId: nil)

        XCTAssertEqual(automation.targetedClickPIDs, [4242])
        XCTAssertEqual(automation.targetedTypePIDs, [4242])
    }

    func testBackgroundWindowScopedKeyboardFailsClosedWithoutAtomicCapability() async throws {
        let automation = RecordingInteractionUIAutomationService()
        automation.supportsExactWindowTargetedKeyboard = false
        automation.focusedElement = Self.focusedElementInWindow()
        let snapshotId = "window-scoped-no-atomic"
        let snapshots = InMemorySnapshotManager(detectionResult: Self.windowScopedDetectionResult(
            snapshotId: snapshotId))
        let processService = self.makeProcessService(automation: automation, snapshots: snapshots)

        do {
            _ = try await processService.executeStep(
                ScriptStep(
                    stepId: "type",
                    comment: nil,
                    command: "type",
                    params: .type(.init(text: "must-not-dispatch", snapshot: snapshotId, field: "Search"))),
                snapshotId: nil)
            XCTFail("Expected exact-window typing to require the atomic capability")
        } catch let PeekabooError.serviceUnavailable(message) {
            XCTAssertTrue(message.contains("atomic focus validation"))
        }
        XCTAssertTrue(automation.targetedTypePIDs.isEmpty)
    }

    func testScriptImmediateExactWindowClickProvesTypeAndHotkeyDestination() async throws {
        let snapshotId = "window-scoped-click-proof"
        let keyboardSteps: [ScriptStep] = [
            ScriptStep(
                stepId: "type",
                comment: nil,
                command: "type",
                params: .type(.init(text: "hello", snapshot: snapshotId))),
            ScriptStep(
                stepId: "hotkey",
                comment: nil,
                command: "hotkey",
                params: .hotkey(.init(key: "a", modifiers: ["command"], snapshot: snapshotId))),
        ]

        for keyboardStep in keyboardSteps {
            let automation = RecordingInteractionUIAutomationService()
            automation.focusedElement = Self.focusedElementInWindow()
            let snapshots = InMemorySnapshotManager(detectionResult: Self.windowScopedDetectionResult(
                snapshotId: snapshotId))
            let processService = self.makeProcessService(automation: automation, snapshots: snapshots)
            let results = try await processService.executeScript(
                PeekabooScript(description: nil, steps: [
                    ScriptStep(
                        stepId: "click",
                        comment: nil,
                        command: "click",
                        params: .click(.init(label: "Search", snapshot: snapshotId))),
                    keyboardStep,
                ]),
                failFast: true,
                verbose: false)

            XCTAssertEqual(results.count, 2)
            XCTAssertTrue(results.allSatisfy(\.success))
            XCTAssertEqual(automation.focusedElementReadCount, 2)
        }
    }

    func testExactSeeClickCarriesOneShotProofIntoTypeAndHotkey() async throws {
        let keyboardSteps: [ScriptStep] = [
            ScriptStep(
                stepId: "type",
                comment: nil,
                command: "type",
                params: .type(.init(text: "hello", snapshot: "observe"))),
            ScriptStep(
                stepId: "hotkey",
                comment: nil,
                command: "hotkey",
                params: .hotkey(.init(key: "a", modifiers: ["command"], snapshot: "observe"))),
        ]

        for keyboardStep in keyboardSteps {
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("peekaboo-exact-script-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: outputURL) }
            let automation = RecordingInteractionUIAutomationService()
            automation.focusedElement = Self.focusedElementInWindow()
            let processService = self.makeProcessService(
                automation: automation,
                snapshots: InMemorySnapshotManager(),
                captures: ExactWindowScriptCaptureService())

            let results = try await processService.executeScript(
                PeekabooScript(description: nil, steps: [
                    ScriptStep(
                        stepId: "observe",
                        comment: nil,
                        command: "see",
                        params: .screenshot(.init(
                            path: outputURL.path,
                            mode: "frontmost",
                            annotate: true))),
                    ScriptStep(
                        stepId: "focus",
                        comment: nil,
                        command: "click",
                        params: .click(.init(label: "Search", snapshot: "observe"))),
                    keyboardStep,
                ]),
                failFast: true,
                verbose: false)

            XCTAssertEqual(results.count, 3)
            XCTAssertTrue(results.allSatisfy(\.success))
            XCTAssertEqual(automation.targetedClickPIDs, [4242])
            XCTAssertEqual(automation.focusedElementReadCount, 2)
            if keyboardStep.command == "type" {
                XCTAssertEqual(automation.targetedTypePIDs, [4242])
            } else {
                XCTAssertEqual(automation.targetedHotkeys, [
                    RecordingInteractionUIAutomationService.TargetedHotkeyCall(keys: "cmd,a", pid: 4242),
                ])
            }
        }
    }

    func testImmediateClickProofRejectsFocusChangeBeforeWindowScopedKeyboardDispatch() async throws {
        let snapshotId = "window-scoped-stolen-focus"
        let automation = RecordingInteractionUIAutomationService()
        automation.focusedElementSequence = [
            Self.focusedElementInWindow(),
            UIFocusInfo(
                role: "AXTextField",
                title: "Sibling",
                value: nil,
                frame: CGRect(x: 150, y: 250, width: 300, height: 30),
                applicationName: "Editor",
                bundleIdentifier: "com.example.editor",
                processId: 4242,
                windowID: 999_999,
                identifier: "sibling"),
        ]
        let snapshots = InMemorySnapshotManager(detectionResult: Self.windowScopedDetectionResult(
            snapshotId: snapshotId))
        let processService = self.makeProcessService(automation: automation, snapshots: snapshots)

        let results = try await processService.executeScript(
            PeekabooScript(description: nil, steps: [
                ScriptStep(
                    stepId: "click",
                    comment: nil,
                    command: "click",
                    params: .click(.init(label: "Search", snapshot: snapshotId))),
                ScriptStep(
                    stepId: "type",
                    comment: nil,
                    command: "type",
                    params: .type(.init(text: "must-not-dispatch", snapshot: snapshotId))),
            ]),
            failFast: true,
            verbose: false)

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results[0].success)
        XCTAssertFalse(results[1].success)
        XCTAssertEqual(automation.focusedElementReadCount, 2)
        XCTAssertTrue(automation.targetedTypePIDs.isEmpty)
    }

    func testNonFocusableClickDoesNotReusePriorSiblingFocusAsKeyboardProof() async throws {
        let snapshotId = "window-scoped-nonfocusable-click"
        let automation = RecordingInteractionUIAutomationService()
        automation.focusedElement = Self.focusedElementInWindow()
        let button = DetectedElement(
            id: "B1",
            type: .button,
            label: "No Focus",
            bounds: CGRect(x: 500, y: 400, width: 100, height: 30),
            attributes: ["role": "AXButton", "identifier": "no-focus"])
        let detection = ElementDetectionResult(
            snapshotId: snapshotId,
            screenshotPath: "/tmp/window-scoped.png",
            elements: DetectedElements(buttons: [button]),
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: 1,
                method: "test",
                windowContext: WindowContext(
                    applicationName: "Editor",
                    applicationProcessId: 4242,
                    windowTitle: "Document",
                    windowID: 999_999,
                    windowBounds: CGRect(x: 100, y: 100, width: 800, height: 600),
                    windowMutationIdentity: WindowMutationIdentity(
                        windowID: 999_999,
                        ownerProcessIdentifier: 4242,
                        ownerProcessStartIdentity: 1))))
        let processService = self.makeProcessService(
            automation: automation,
            snapshots: InMemorySnapshotManager(detectionResult: detection))

        let results = try await processService.executeScript(
            PeekabooScript(description: nil, steps: [
                ScriptStep(
                    stepId: "click",
                    comment: nil,
                    command: "click",
                    params: .click(.init(label: "No Focus", snapshot: snapshotId))),
                ScriptStep(
                    stepId: "type",
                    comment: nil,
                    command: "type",
                    params: .type(.init(text: "must-not-dispatch", snapshot: snapshotId))),
            ]),
            failFast: true,
            verbose: false)

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results[0].success)
        XCTAssertFalse(results[1].success)
        XCTAssertEqual(automation.focusedElementReadCount, 1)
        XCTAssertTrue(automation.targetedTypePIDs.isEmpty)
    }

    func testExplicitForegroundTypeAndHotkeyPreserveWindowScopedSnapshotFocus() async throws {
        let automation = RecordingInteractionUIAutomationService()
        let windows = RecordingFocusWindowService()
        let snapshotId = "foreground-window-snapshot"
        let snapshots = InMemorySnapshotManager(detectionResult: Self.windowScopedDetectionResult(
            snapshotId: snapshotId))
        let processService = self.makeProcessService(
            automation: automation,
            snapshots: snapshots,
            windows: windows)

        _ = try await processService.executeStep(
            ScriptStep(
                stepId: "type",
                comment: nil,
                command: "type",
                params: .type(.init(text: "hello", snapshot: snapshotId, foreground: true))),
            snapshotId: nil)
        _ = try await processService.executeStep(
            ScriptStep(
                stepId: "hotkey",
                comment: nil,
                command: "hotkey",
                params: .hotkey(.init(
                    key: "p",
                    modifiers: ["command"],
                    snapshot: snapshotId,
                    foreground: true))),
            snapshotId: nil)

        let focusTargetDescriptions = await windows.focusTargetDescriptions()
        XCTAssertEqual(focusTargetDescriptions, ["windowId(999999)", "windowId(999999)"])
        XCTAssertEqual(automation.typeActionCounts, [1])
        XCTAssertTrue(automation.targetedTypePIDs.isEmpty)
        XCTAssertEqual(automation.hotkeys, ["cmd,p"])
        XCTAssertTrue(automation.targetedHotkeys.isEmpty)
    }

    func testBackgroundQueryClickUsesPIDTargetedAPI() async throws {
        let automation = RecordingInteractionUIAutomationService()
        let processService = self.makeProcessService(automation: automation)

        _ = try await processService.executeStep(
            ScriptStep(
                stepId: "click",
                comment: nil,
                command: "click",
                params: .click(.init(label: "Save", pid: 4242))),
            snapshotId: "unrelated-inherited-snapshot")

        XCTAssertEqual(automation.targetedClickPIDs, [4242])
        XCTAssertEqual(automation.globalClickCount, 0)
    }

    func testBackgroundCoordinateClickUsesPIDTargetedAXRoute() async throws {
        let automation = RecordingInteractionUIAutomationService()
        let processService = self.makeProcessService(automation: automation)

        _ = try await processService.executeStep(
            ScriptStep(
                stepId: "click",
                comment: nil,
                command: "click",
                params: .click(.init(x: 10, y: 20, pid: 4242))),
            snapshotId: nil)

        XCTAssertEqual(automation.globalClickCount, 0)
        XCTAssertEqual(automation.targetedClickPIDs, [4242])
    }

    func testTargetlessCoordinateClickFailsWithoutGlobalInput() async throws {
        let automation = RecordingInteractionUIAutomationService()
        let processService = self.makeProcessService(automation: automation)

        do {
            _ = try await processService.executeStep(
                ScriptStep(
                    stepId: "click",
                    comment: nil,
                    command: "click",
                    params: .click(.init(x: 10, y: 20))),
                snapshotId: nil)
            XCTFail("Expected targetless coordinate click to require foreground")
        } catch let PeekabooError.invalidInput(message) {
            XCTAssertTrue(message.contains("foreground: true"))
        }

        XCTAssertEqual(automation.globalClickCount, 0)
        XCTAssertTrue(automation.targetedClickPIDs.isEmpty)
    }

    func testBackgroundScrollForwardsActionOnlyDelivery() async throws {
        let automation = RecordingInteractionUIAutomationService()
        let snapshotId = "scroll-snapshot"
        let snapshots = InMemorySnapshotManager(detectionResult: ElementDetectionResult(
            snapshotId: snapshotId,
            screenshotPath: "/tmp/scroll.png",
            elements: DetectedElements(),
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: 0,
                method: "test",
                windowContext: WindowContext(
                    applicationName: "Test",
                    applicationProcessId: 4242),
                truncationInfo: nil)))
        let processService = ProcessService(
            applicationService: UnusedApplicationService(),
            screenCaptureService: UnusedScreenCaptureService(),
            snapshotManager: snapshots,
            uiAutomationService: automation,
            windowManagementService: UnusedWindowManagementService(),
            menuService: UnusedMenuService(),
            dockService: UnusedDockService(),
            clipboardService: UnusedClipboardService())

        _ = try await processService.executeStep(
            ScriptStep(
                stepId: "scroll",
                comment: nil,
                command: "scroll",
                params: .scroll(.init(direction: "down", target: "Results"))),
            snapshotId: snapshotId)

        XCTAssertEqual(automation.scrollRequests.count, 1)
        XCTAssertFalse(automation.scrollRequests[0].foreground)
        XCTAssertEqual(automation.scrollRequests[0].snapshotId, snapshotId)
        XCTAssertEqual(automation.scrollRequests[0].target, "Results")
        XCTAssertEqual(automation.scrollRequests[0].delay, 0)
    }

    func testForegroundScrollForwardsSyntheticConsent() async throws {
        let automation = RecordingInteractionUIAutomationService()
        let processService = self.makeProcessService(automation: automation)

        _ = try await processService.executeStep(
            ScriptStep(
                stepId: "scroll",
                comment: nil,
                command: "scroll",
                params: .scroll(.init(direction: "down", foreground: true))),
            snapshotId: nil)

        XCTAssertEqual(automation.scrollRequests.count, 1)
        XCTAssertTrue(automation.scrollRequests[0].foreground)
        XCTAssertNil(automation.scrollRequests[0].target)
    }

    private func makeProcessService(
        automation: RecordingInteractionUIAutomationService,
        snapshots: any SnapshotManagerProtocol = UnusedSnapshotManager(),
        windows: any WindowManagementServiceProtocol = UnusedWindowManagementService(),
        captures: any ScreenCaptureServiceProtocol = UnusedScreenCaptureService(),
        currentWindowMutationIdentity: WindowMutationIdentity = WindowMutationIdentity(
            windowID: 999_999,
            ownerProcessIdentifier: 4242,
            ownerProcessStartIdentity: 1)) -> ProcessService
    {
        ProcessService(
            applicationService: UnusedApplicationService(),
            screenCaptureService: captures,
            snapshotManager: snapshots,
            uiAutomationService: automation,
            windowManagementService: windows,
            menuService: UnusedMenuService(),
            dockService: UnusedDockService(),
            clipboardService: UnusedClipboardService(),
            screenService: ScreenService(),
            systemWindowIdentityProvider: { windowID in
                SystemWindowIdentity(
                    windowID: windowID,
                    ownerProcessIdentifier: 4242,
                    title: "Document",
                    bounds: CGRect(x: 100, y: 100, width: 800, height: 600),
                    layer: 0,
                    alpha: 1,
                    isOnScreen: true,
                    sharingState: .readOnly)
            },
            windowMutationIdentityProvider: { windowID in
                guard Int(windowID) == currentWindowMutationIdentity.windowID else { return nil }
                return currentWindowMutationIdentity
            })
    }

    private static func windowScopedDetectionResult(snapshotId: String) -> ElementDetectionResult {
        let search = DetectedElement(
            id: "T1",
            type: .textField,
            label: "Search",
            bounds: CGRect(x: 150, y: 150, width: 300, height: 30),
            attributes: ["role": "AXTextField", "identifier": "search"])
        return ElementDetectionResult(
            snapshotId: snapshotId,
            screenshotPath: "/tmp/window-scoped.png",
            elements: DetectedElements(textFields: [search]),
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: 0,
                method: "test",
                windowContext: WindowContext(
                    applicationName: "Editor",
                    applicationProcessId: 4242,
                    windowTitle: "Document",
                    windowID: 999_999,
                    windowBounds: CGRect(x: 100, y: 100, width: 800, height: 600),
                    windowMutationIdentity: WindowMutationIdentity(
                        windowID: 999_999,
                        ownerProcessIdentifier: 4242,
                        ownerProcessStartIdentity: 1))))
    }

    private static func focusedElementInWindow() -> UIFocusInfo {
        UIFocusInfo(
            role: "AXTextField",
            title: "Search",
            value: nil,
            frame: CGRect(x: 150, y: 150, width: 300, height: 30),
            applicationName: "Editor",
            bundleIdentifier: "com.example.editor",
            processId: 4242,
            windowID: 999_999,
            identifier: "search")
    }
}

@available(macOS 14.0, *)
private actor RecordingFocusWindowService: WindowManagementServiceProtocol {
    private var focusTargets: [WindowTarget] = []

    func focusWindow(target: WindowTarget) async throws {
        self.focusTargets.append(target)
    }

    func focusTargetDescriptions() -> [String] {
        self.focusTargets.map(\.description)
    }

    func closeWindow(target _: WindowTarget) async throws {
        fatalError("unused")
    }

    func minimizeWindow(target _: WindowTarget) async throws {
        fatalError("unused")
    }

    func maximizeWindow(target _: WindowTarget) async throws {
        fatalError("unused")
    }

    func moveWindow(target _: WindowTarget, to _: CGPoint) async throws {
        fatalError("unused")
    }

    func resizeWindow(target _: WindowTarget, to _: CGSize) async throws {
        fatalError("unused")
    }

    func setWindowBounds(target _: WindowTarget, bounds _: CGRect) async throws {
        fatalError("unused")
    }

    func listWindows(target _: WindowTarget) async throws -> [ServiceWindowInfo] {
        fatalError("unused")
    }

    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        fatalError("unused")
    }
}

@available(macOS 14.0, *)
@MainActor
private final class RecordingMenuService: MenuServiceProtocol {
    struct Click: Equatable {
        let app: String
        let itemPath: String
    }

    var clicks: [Click] = []

    func clickMenuItem(app: String, itemPath: String) async throws {
        self.clicks.append(Click(app: app, itemPath: itemPath))
    }

    func listMenus(for _: String) async throws -> MenuStructure {
        fatalError("unused")
    }

    func listFrontmostMenus() async throws -> MenuStructure {
        fatalError("unused")
    }

    func clickMenuItemByName(app _: String, itemName _: String) async throws {
        fatalError("unused")
    }

    func clickMenuExtra(title _: String) async throws {
        fatalError("unused")
    }

    func isMenuExtraMenuOpen(title _: String, ownerPID _: pid_t?) async throws -> Bool {
        fatalError("unused")
    }

    func menuExtraOpenMenuFrame(title _: String, ownerPID _: pid_t?) async throws -> CGRect? {
        fatalError("unused")
    }

    func listMenuExtras() async throws -> [MenuExtraInfo] {
        fatalError("unused")
    }

    func listMenuBarItems(includeRaw _: Bool) async throws -> [MenuBarItemInfo] {
        fatalError("unused")
    }

    func clickMenuBarItem(named _: String) async throws -> ClickResult {
        fatalError("unused")
    }

    func clickMenuBarItem(at _: Int) async throws -> ClickResult {
        fatalError("unused")
    }
}

@available(macOS 14.0, *)
@MainActor
private final class UnusedClipboardService: ClipboardServiceProtocol {
    func get(prefer _: UTType?) throws -> ClipboardReadResult? {
        fatalError("unused")
    }

    func set(_: ClipboardWriteRequest) throws -> ClipboardReadResult {
        fatalError("unused")
    }

    func clear() {
        fatalError("unused")
    }

    func save(slot _: String) throws {
        fatalError("unused")
    }

    func restore(slot _: String) throws -> ClipboardReadResult {
        fatalError("unused")
    }
}

@available(macOS 14.0, *)
@MainActor
private final class ExactWindowScriptCaptureService: ScreenCaptureServiceProtocol {
    private let result = CaptureResult(
        imageData: Data("exact-window-script".utf8),
        metadata: CaptureMetadata(
            size: CGSize(width: 800, height: 600),
            mode: .window,
            applicationInfo: ServiceApplicationInfo(
                processIdentifier: 4242,
                bundleIdentifier: "com.example.editor",
                name: "Editor",
                windowCount: 1),
            windowInfo: ServiceWindowInfo(
                windowID: 999_999,
                title: "Document",
                bounds: CGRect(x: 100, y: 100, width: 800, height: 600),
                isMinimized: false,
                isMainWindow: true,
                windowLevel: 0,
                alpha: 1,
                index: 0,
                layer: 0,
                isOnScreen: true,
                sharingState: .readOnly,
                isExcludedFromWindowsMenu: false,
                mutationIdentity: WindowMutationIdentity(
                    windowID: 999_999,
                    ownerProcessIdentifier: 4242,
                    ownerProcessStartIdentity: 1))))

    func captureScreen(
        displayIndex _: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        self.result
    }

    func captureWindow(
        appIdentifier _: String,
        windowIndex _: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        self.result
    }

    func captureFrontmost(
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        self.result
    }

    func captureArea(
        _: CGRect,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        self.result
    }

    func hasScreenRecordingPermission() async -> Bool {
        true
    }
}

@available(macOS 14.0, *)
@MainActor
private final class StaticScreenService: ScreenServiceProtocol {
    private let screen: ScreenInfo

    init(frame: CGRect) {
        self.screen = ScreenInfo(
            index: 0,
            name: "Test Display",
            frame: frame,
            visibleFrame: frame,
            isPrimary: true,
            scaleFactor: 2,
            displayID: 1)
    }

    func listScreens() -> [ScreenInfo] {
        [self.screen]
    }

    func screenContainingWindow(bounds: CGRect) -> ScreenInfo? {
        self.screen.frame.intersects(bounds) ? self.screen : nil
    }

    func screen(at index: Int) -> ScreenInfo? {
        index == 0 ? self.screen : nil
    }

    var primaryScreen: ScreenInfo? {
        self.screen
    }
}

@available(macOS 14.0, *)
@MainActor
private final class RecordingInteractionUIAutomationService:
    ExactWindowTargetedClickServiceProtocol,
    TargetedHotkeyServiceProtocol,
    TargetedTypeServiceProtocol,
    TargetedFocusedElementServiceProtocol,
    ExactWindowTargetedKeyboardServiceProtocol
{
    var supportsExactWindowTargetedKeyboard = true
    let exactWindowTargetedKeyboardUnavailableReason: String? = nil
    struct SwipeCall {
        let from: CGPoint
        let to: CGPoint
        let duration: Int
    }

    var swipes: [SwipeCall] = []
    var hotkeys: [String] = []
    var targetedHotkeys: [TargetedHotkeyCall] = []
    var typedText: [TypeCall] = []
    var typeActionCounts: [Int] = []
    var targetedTypePIDs: [pid_t] = []
    var globalClickCount = 0
    var targetedClickPIDs: [pid_t] = []
    var scrollRequests: [ScrollRequest] = []
    var drags: [DragCall] = []
    var focusedElement: UIFocusInfo?
    var focusedElementSequence: [UIFocusInfo] = []
    private(set) var focusedElementReadCount = 0

    struct TargetedHotkeyCall: Equatable {
        let keys: String
        let pid: pid_t
    }

    struct TypeCall: Equatable {
        let text: String
        let target: String?
        let clearExisting: Bool
        let snapshotId: String?
    }

    struct DragCall: Equatable {
        let from: CGPoint
        let to: CGPoint
        let modifiers: String?
    }

    func hotkey(keys: String, holdDuration _: Int) async throws {
        self.hotkeys.append(keys)
    }

    func hotkey(keys: String, holdDuration _: Int, targetProcessIdentifier: pid_t) async throws {
        self.targetedHotkeys.append(.init(keys: keys, pid: targetProcessIdentifier))
    }

    func type(text: String, target: String?, clearExisting: Bool, typingDelay _: Int, snapshotId: String?)
        async throws
    {
        self.typedText.append(TypeCall(
            text: text,
            target: target,
            clearExisting: clearExisting,
            snapshotId: snapshotId))
    }

    func typeActions(
        _ actions: [TypeAction],
        cadence _: TypingCadence,
        snapshotId _: String?) async throws -> TypeResult
    {
        self.typeActionCounts.append(actions.count)
        return TypeResult(totalCharacters: 0, keyPresses: actions.count)
    }

    /// Protocol witness mirrors the production exact-window atomic keyboard boundary.
    func typeActions(
        _ actions: [TypeAction],
        cadence _: TypingCadence,
        snapshotId _: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws -> TypeResult
    {
        try await self.requireExactFocus(
            pid: expectedWindowIdentity.ownerProcessIdentifier,
            windowID: expectedWindowIdentity.windowID,
            bounds: expectedWindowBounds)
        self.typeActionCounts.append(actions.count)
        self.targetedTypePIDs.append(expectedWindowIdentity.ownerProcessIdentifier)
        return TypeResult(totalCharacters: 0, keyPresses: actions.count)
    }

    func typeActions(
        _ actions: [TypeAction],
        cadence _: TypingCadence,
        snapshotId _: String?,
        targetProcessIdentifier: pid_t) async throws -> TypeResult
    {
        self.typeActionCounts.append(actions.count)
        self.targetedTypePIDs.append(targetProcessIdentifier)
        return TypeResult(totalCharacters: 0, keyPresses: actions.count)
    }

    func swipe(from: CGPoint, to: CGPoint, duration: Int, steps _: Int, profile _: MouseMovementProfile) async throws {
        self.swipes.append(SwipeCall(from: from, to: to, duration: duration))
    }

    func detectElements(in _: Data, snapshotId: String?, windowContext: WindowContext?) async throws
        -> ElementDetectionResult
    {
        let snapshotId = try XCTUnwrap(snapshotId)
        return ElementDetectionResult(
            snapshotId: snapshotId,
            screenshotPath: "/tmp/exact-window-script.png",
            elements: DetectedElements(textFields: [DetectedElement(
                id: "T1",
                type: .textField,
                label: "Search",
                bounds: CGRect(x: 150, y: 150, width: 300, height: 30),
                attributes: ["role": "AXTextField", "identifier": "search"])]),
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: 0,
                method: "test",
                windowContext: windowContext))
    }

    func click(target _: ClickTarget, clickType _: ClickType, snapshotId _: String?) async throws {
        self.globalClickCount += 1
    }

    func click(
        target _: ClickTarget,
        clickType _: ClickType,
        snapshotId _: String?,
        targetProcessIdentifier: pid_t) async throws
    {
        self.targetedClickPIDs.append(targetProcessIdentifier)
    }

    func click(
        target _: ClickTarget,
        clickType _: ClickType,
        snapshotId _: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds _: CGRect) async throws
    {
        self.targetedClickPIDs.append(expectedWindowIdentity.ownerProcessIdentifier)
    }

    func scroll(_ request: ScrollRequest) async throws {
        self.scrollRequests.append(request)
    }

    func hasAccessibilityPermission() async -> Bool {
        fatalError("unused")
    }

    func waitForElement(target _: ClickTarget, timeout _: TimeInterval, snapshotId _: String?) async throws
        -> WaitForElementResult
    {
        fatalError("unused")
    }

    func drag(_ request: DragOperationRequest) async throws {
        self.drags.append(DragCall(
            from: request.from,
            to: request.to,
            modifiers: request.modifiers))
    }

    func moveMouse(to _: CGPoint, duration _: Int, steps _: Int, profile _: MouseMovementProfile) async throws {
        fatalError("unused")
    }

    func getFocusedElement() -> UIFocusInfo? {
        UIFocusInfo(
            role: "AXTextField",
            title: "Foreground user app",
            value: nil,
            frame: CGRect(x: 10, y: 10, width: 100, height: 30),
            applicationName: "Foreground",
            bundleIdentifier: "com.example.foreground",
            processId: 7777)
    }

    func getFocusedElement(targetProcessIdentifier _: pid_t) async -> UIFocusInfo? {
        self.nextFocusedElement()
    }

    func hotkey(
        keys: String,
        holdDuration _: Int,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws
    {
        try await self.requireExactFocus(
            pid: expectedWindowIdentity.ownerProcessIdentifier,
            windowID: expectedWindowIdentity.windowID,
            bounds: expectedWindowBounds)
        self.targetedHotkeys.append(.init(keys: keys, pid: expectedWindowIdentity.ownerProcessIdentifier))
    }

    func typeActions(
        _ actions: [TypeAction],
        cadence _: TypingCadence,
        snapshotId _: String?,
        target: ExactWindowKeyboardTarget) async throws -> TypeResult
    {
        try await self.requireExactFocus(
            pid: target.windowIdentity.ownerProcessIdentifier,
            windowID: target.windowIdentity.windowID,
            bounds: target.windowBounds,
            expectedFocusedElement: target.focusedElement)
        self.typeActionCounts.append(actions.count)
        self.targetedTypePIDs.append(target.windowIdentity.ownerProcessIdentifier)
        return TypeResult(totalCharacters: 0, keyPresses: actions.count)
    }

    func hotkey(
        keys: String,
        holdDuration _: Int,
        target: ExactWindowKeyboardTarget) async throws
    {
        try await self.requireExactFocus(
            pid: target.windowIdentity.ownerProcessIdentifier,
            windowID: target.windowIdentity.windowID,
            bounds: target.windowBounds,
            expectedFocusedElement: target.focusedElement)
        self.targetedHotkeys.append(.init(keys: keys, pid: target.windowIdentity.ownerProcessIdentifier))
    }

    private func requireExactFocus(
        pid: pid_t,
        windowID: Int,
        bounds: CGRect,
        expectedFocusedElement: FocusedElementIdentity? = nil) async throws
    {
        let focused = self.nextFocusedElement()
        guard let focused,
              focused.processId == Int(pid),
              focused.windowID == windowID,
              bounds.contains(CGPoint(x: focused.frame.midX, y: focused.frame.midY)),
              expectedFocusedElement == nil || FocusedElementIdentity(focused) == expectedFocusedElement
        else {
            throw PeekabooError.invalidInput("exact focus mismatch")
        }
    }

    private func nextFocusedElement() -> UIFocusInfo? {
        self.focusedElementReadCount += 1
        return if !self.focusedElementSequence.isEmpty {
            self.focusedElementSequence.removeFirst()
        } else {
            self.focusedElement
        }
    }

    func findElement(matching _: UIElementSearchCriteria, in _: String?) async throws -> DetectedElement {
        fatalError("unused")
    }
}
