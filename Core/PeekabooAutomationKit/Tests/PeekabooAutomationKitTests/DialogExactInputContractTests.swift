import ApplicationServices
import AXorcist
import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
@Suite("Exact dialog input contract")
struct DialogExactInputContractTests {
    @Test
    func `exact dialog text edit stays background and preserves the selected range`() throws {
        #expect(DialogService.backgroundDialogInputDelivery == .init(
            mechanism: .accessibilityValue,
            mode: .background))

        let insertion = try DialogService.backgroundDialogTextEdit(
            currentValue: "hello",
            selectedRange: CFRange(location: 1, length: 3),
            replacement: "i",
            clearExisting: false)
        #expect(insertion.value == "hio")
        #expect(insertion.cursorRange.location == 2)
        #expect(insertion.cursorRange.length == 0)

        let unicodeInsertion = try DialogService.backgroundDialogTextEdit(
            currentValue: "a😀b",
            selectedRange: CFRange(location: 1, length: 2),
            replacement: "x",
            clearExisting: false)
        #expect(unicodeInsertion.value == "axb")
        #expect(unicodeInsertion.cursorRange.location == 2)

        let replacement = try DialogService.backgroundDialogTextEdit(
            currentValue: "old",
            selectedRange: nil,
            replacement: "new",
            clearExisting: true)
        #expect(replacement.value == "new")
        #expect(replacement.cursorRange.location == 3)

        let sameTextWrongCursor = DialogService.backgroundDialogEditDispatchPlan(
            currentValue: "new",
            selectedRange: CFRange(location: 0, length: 0),
            edit: replacement)
        #expect(!sameTextWrongCursor.valueNeedsUpdate)
        #expect(sameTextWrongCursor.cursorNeedsUpdate)
        let sameTextDesiredCursor = DialogService.backgroundDialogEditDispatchPlan(
            currentValue: "new",
            selectedRange: CFRange(location: 3, length: 0),
            edit: replacement)
        #expect(!sameTextDesiredCursor.valueNeedsUpdate)
        #expect(!sameTextDesiredCursor.cursorNeedsUpdate)

        #expect(DialogService.sameDialogTextRange(
            CFRange(location: 1, length: 2),
            CFRange(location: 1, length: 2)))
        #expect(!DialogService.sameDialogTextRange(
            CFRange(location: 1, length: 2),
            CFRange(location: 2, length: 1)))
        #expect(!DialogService.sameDialogTextRange(nil, CFRange(location: 0, length: 0)))

        let encodedRange = try #require(DialogService.dialogTextRangeAXValue(replacement.cursorRange))
        var decodedRange = CFRange()
        #expect(AXValueGetValue(encodedRange, .cfRange, &decodedRange))
        #expect(DialogService.sameDialogTextRange(decodedRange, replacement.cursorRange))
    }

    @Test
    func `background value-only edit skips read-only cursor capability`() throws {
        let edit = try DialogService.backgroundDialogTextEdit(
            currentValue: "old",
            selectedRange: nil,
            replacement: "new",
            clearExisting: true)
        let dispatchPlan = DialogService.backgroundDialogEditDispatchPlan(
            currentValue: "old",
            selectedRange: edit.cursorRange,
            edit: edit)

        #expect(dispatchPlan.valueNeedsUpdate)
        #expect(!dispatchPlan.cursorNeedsUpdate)
        #expect(dispatchPlan.successfulUnitCount == .one)
        var cursorCapabilityChecked = false
        let cursorValue = try DialogService.backgroundDialogCursorDispatchValue(
            dispatchPlan: dispatchPlan,
            cursorRange: edit.cursorRange)
        {
            cursorCapabilityChecked = true
            return false
        }

        #expect(cursorValue == nil)
        #expect(!cursorCapabilityChecked)
    }

    @Test
    func `background cursor edit refuses when selected range is not settable`() throws {
        let edit = try DialogService.backgroundDialogTextEdit(
            currentValue: "new",
            selectedRange: nil,
            replacement: "new",
            clearExisting: true)
        let dispatchPlan = DialogService.backgroundDialogEditDispatchPlan(
            currentValue: "new",
            selectedRange: CFRange(location: 0, length: 0),
            edit: edit)
        #expect(!dispatchPlan.valueNeedsUpdate)
        #expect(dispatchPlan.cursorNeedsUpdate)
        #expect(dispatchPlan.successfulUnitCount == .one)
        var cursorCapabilityChecked = false

        do {
            _ = try DialogService.backgroundDialogCursorDispatchValue(
                dispatchPlan: dispatchPlan,
                cursorRange: edit.cursorRange)
            {
                cursorCapabilityChecked = true
                return false
            }
            Issue.record("Expected a required nonsettable cursor range to refuse before dispatch")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .operationUnsupported)
            #expect(failure.outcome.dispatchState == .none)
        }
        #expect(cursorCapabilityChecked)
    }

    @Test
    func `exact background insertion refuses an unknown or invalid selection`() {
        #expect(throws: DialogService.DialogBackgroundTextEditError.self) {
            try DialogService.backgroundDialogTextEdit(
                currentValue: "hello",
                selectedRange: nil,
                replacement: "!",
                clearExisting: false)
        }
        #expect(throws: DialogService.DialogBackgroundTextEditError.self) {
            try DialogService.backgroundDialogTextEdit(
                currentValue: "hello",
                selectedRange: CFRange(location: 6, length: 0),
                replacement: "!",
                clearExisting: false)
        }
    }

    @Test
    func `missing stale PID is a canonical target refusal before dispatch`() async throws {
        let service = DialogService(applicationService: MissingDialogApplicationService())

        do {
            _ = try await service.targetedDialogCandidates(
                target: DialogTargetSelector(processIdentifier: 42, windowID: 700))
            Issue.record("Expected stale PID lookup to refuse")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(failure.message.contains("Application 'PID:42' not found"))
        }
    }

    @Test
    func `execution request round trips the exact selector and focus policy`() throws {
        let request = try DialogInputExecutionRequest(
            target: DialogTargetSelector(processIdentifier: 42, windowID: 700),
            text: "hello",
            fieldIdentifier: "Name",
            clearExisting: true,
            focus: DialogForegroundFocusPolicy(
                autoFocus: false,
                timeout: 1.75,
                retryCount: 7,
                switchSpace: true,
                bringToCurrentSpace: true))

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(DialogInputExecutionRequest.self, from: data)

        #expect(decoded == request)
        #expect(decoded.target.windowID == 700)
        #expect(decoded.focus.timeout == 1.75)
        #expect(decoded.focus.retryCount == 7)
        #expect(throws: (any Error).self) {
            try DialogInputExecutionRequest(
                target: DialogTargetSelector(processIdentifier: 42),
                text: "hello",
                focus: DialogForegroundFocusPolicy(timeout: 0))
        }
    }

    @Test
    func `window ID selection remains exact while duplicate titles refuse as ambiguous`() throws {
        let service = DialogService()
        let windows = [
            self.window(id: 700, title: "Document", generation: 1234),
            self.window(id: 701, title: "Document", generation: 1234),
        ]

        let exact = try service.filteredDialogWindows(
            windows,
            selector: DialogTargetSelector(processIdentifier: 42, windowID: 701))
        #expect(exact.map(\.windowID) == [701])

        let sameTitle = try service.filteredDialogWindows(
            windows,
            selector: DialogTargetSelector(processIdentifier: 42, windowTitle: "Document"))
        #expect(sameTitle.count == 2)

        let candidates = try sameTitle.map { window in
            let target = try UIAutomationTarget.ExactWindow(window: window)
            return try DialogService.TargetedDialogCandidate(
                target: target,
                resolvedTarget: ResolvedDialogTargetEvidence(
                    target: target,
                    application: .init(
                        processIdentifier: 42,
                        processStartIdentity: 1234,
                        bundleIdentifier: "dev.peekaboo.fixture",
                        name: "Fixture"),
                    window: window),
                window: Element.systemWide(),
                dialog: Element.systemWide())
        }
        let refusal = try service.dialogCandidateRefusal(
            target: DialogTargetSelector(processIdentifier: 42, windowTitle: "Document"),
            candidates: candidates)
        #expect(refusal.outcome.state == .refused)
        #expect(refusal.outcome.refusalReason == .targetUnavailable)
        #expect(refusal.message.contains("ambiguous"))
        #expect(refusal.hint?.contains("700, 701") == true)
    }

    @Test
    func `resolved dialog proof preserves prohibited helper fuzzy eligibility`() throws {
        let window = self.window(id: 700, title: "Helper Dialog", generation: 1234)
        let target = try UIAutomationTarget.ExactWindow(window: window)
        let evidence = try ResolvedDialogTargetEvidence(
            target: target,
            application: .init(
                processIdentifier: 42,
                processStartIdentity: 1234,
                bundleIdentifier: "dev.peekaboo.fixture.helper",
                name: "Fixture Helper",
                bundlePath: "/Applications/Fixture Helper.app",
                executablePath: "/Applications/Fixture Helper.app/Contents/MacOS/fixture-helper",
                activationPolicy: .prohibited),
            window: window)

        let fuzzySelector = try DialogTargetSelector(applicationIdentifier: "Fixture")
        let exactSelector = try DialogTargetSelector(applicationIdentifier: "dev.peekaboo.fixture.helper")
        #expect(!evidence.matches(fuzzySelector))
        #expect(evidence.matches(exactSelector))
    }

    @Test
    func `revalidation rejects wrong parent wrong sheet and stale process generation`() throws {
        let target = try self.target()
        let valid = DialogService.DialogTargetRevalidationObservation(
            applicationIdentity: target.identity.processIdentity,
            windowIdentity: target.identity,
            windowBounds: target.bounds,
            retainedWindowMatches: true,
            hierarchyReadable: true,
            structuralDialogCount: 1,
            retainedDialogMatches: true)
        #expect(DialogService.isValidDialogTargetRevalidation(expected: target, observation: valid))

        let wrongParent = DialogService.DialogTargetRevalidationObservation(
            applicationIdentity: valid.applicationIdentity,
            windowIdentity: WindowMutationIdentity(
                windowID: 701,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 1234,
                capturedBounds: target.bounds),
            windowBounds: valid.windowBounds,
            retainedWindowMatches: false,
            hierarchyReadable: true,
            structuralDialogCount: 1,
            retainedDialogMatches: true)
        #expect(!DialogService.isValidDialogTargetRevalidation(expected: target, observation: wrongParent))

        let wrongSheet = DialogService.DialogTargetRevalidationObservation(
            applicationIdentity: valid.applicationIdentity,
            windowIdentity: valid.windowIdentity,
            windowBounds: valid.windowBounds,
            retainedWindowMatches: true,
            hierarchyReadable: true,
            structuralDialogCount: 1,
            retainedDialogMatches: false)
        #expect(!DialogService.isValidDialogTargetRevalidation(expected: target, observation: wrongSheet))

        let staleGeneration = DialogService.DialogTargetRevalidationObservation(
            applicationIdentity: ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 9999),
            windowIdentity: valid.windowIdentity,
            windowBounds: valid.windowBounds,
            retainedWindowMatches: true,
            hierarchyReadable: true,
            structuralDialogCount: 1,
            retainedDialogMatches: true)
        #expect(!DialogService.isValidDialogTargetRevalidation(expected: target, observation: staleGeneration))
    }

    @Test
    func `focus timeout retry and Space policy map without changing intent`() {
        let policy = DialogForegroundFocusPolicy(
            autoFocus: true,
            timeout: 2.25,
            retryCount: 5,
            switchSpace: true,
            bringToCurrentSpace: true)

        let options = DialogService.dialogInputFocusOptions(policy)

        #expect(options.timeout == 2.25)
        #expect(options.retryCount == 5)
        #expect(options.switchSpace)
        #expect(options.bringToCurrentSpace)
    }

    @Test
    func `final dialog focus rejects a stolen frontmost app and sibling window`() throws {
        let target = try self.target()
        let valid = DialogDispatchFocusObservation(
            currentProcessStartIdentity: target.identity.ownerProcessStartIdentity,
            focusedWindowPID: target.identity.ownerProcessIdentifier,
            frontmostPID: target.identity.ownerProcessIdentifier,
            focusedWindowID: target.identity.windowID,
            retainedParentMatches: true,
            focusedWindowMatchesPreparedDialog: false,
            preparedDialogIsStructural: true,
            preparedDialogAttachedToParent: true,
            focusedElementPID: target.identity.ownerProcessIdentifier,
            focusedElementMatchesRetainedField: true,
            retainedFieldAttachedToDialog: true)
        #expect(FocusManagementService.isVerifiedDialogDispatchFocus(
            expectedParent: target.identity,
            observation: valid))

        let stolenFrontmost = DialogDispatchFocusObservation(
            currentProcessStartIdentity: valid.currentProcessStartIdentity,
            focusedWindowPID: valid.focusedWindowPID,
            frontmostPID: 99,
            focusedWindowID: valid.focusedWindowID,
            retainedParentMatches: true,
            focusedWindowMatchesPreparedDialog: false,
            preparedDialogIsStructural: true,
            preparedDialogAttachedToParent: true,
            focusedElementPID: valid.focusedElementPID,
            focusedElementMatchesRetainedField: true,
            retainedFieldAttachedToDialog: true)
        #expect(!FocusManagementService.isVerifiedDialogDispatchFocus(
            expectedParent: target.identity,
            observation: stolenFrontmost))

        let siblingFocus = DialogDispatchFocusObservation(
            currentProcessStartIdentity: valid.currentProcessStartIdentity,
            focusedWindowPID: valid.focusedWindowPID,
            frontmostPID: valid.frontmostPID,
            focusedWindowID: 701,
            retainedParentMatches: true,
            focusedWindowMatchesPreparedDialog: false,
            preparedDialogIsStructural: true,
            preparedDialogAttachedToParent: true,
            focusedElementPID: valid.focusedElementPID,
            focusedElementMatchesRetainedField: true,
            retainedFieldAttachedToDialog: true)
        #expect(!FocusManagementService.isVerifiedDialogDispatchFocus(
            expectedParent: target.identity,
            observation: siblingFocus))

        let siblingFieldFocus = DialogDispatchFocusObservation(
            currentProcessStartIdentity: valid.currentProcessStartIdentity,
            focusedWindowPID: valid.focusedWindowPID,
            frontmostPID: valid.frontmostPID,
            focusedWindowID: valid.focusedWindowID,
            retainedParentMatches: true,
            focusedWindowMatchesPreparedDialog: false,
            preparedDialogIsStructural: true,
            preparedDialogAttachedToParent: true,
            focusedElementPID: valid.focusedElementPID,
            focusedElementMatchesRetainedField: false,
            retainedFieldAttachedToDialog: true)
        #expect(!FocusManagementService.isVerifiedDialogDispatchFocus(
            expectedParent: target.identity,
            observation: siblingFieldFocus))
    }

    @Test
    func `sibling field focus before the first unit emits no keyboard`() throws {
        let driver = RecordingDialogSyntheticDriver()
        let service = DialogService(syntheticInputDriver: driver)
        let unsafeFailure = DialogService.dialogDispatchFocusFailure(
            focusMutationDispatched: true,
            dispatchedKeyboardUnits: 0,
            cause: DialogError.noActiveDialog)

        do {
            _ = try service.dispatchDialogInput(
                text: "hello",
                clearExisting: true,
                unitFocusValidation: { _ in throw unsafeFailure })
            Issue.record("Expected sibling field focus to stop before keyboard dispatch")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .dispatchedUnverified)
            #expect(failure.outcome.delivery == .init(mechanism: .accessibilityAction, mode: .foreground))
            #expect(failure.outcome.retrySafety == .unsafe)
        }
        #expect(driver.hotkeys.isEmpty)
        #expect(driver.tappedKeys.isEmpty)
        #expect(driver.typedText.isEmpty)
    }

    @Test
    func `focus stolen after select all stops remaining units with actual count`() throws {
        let driver = RecordingDialogSyntheticDriver()
        let service = DialogService(syntheticInputDriver: driver)
        var validationCounts: [Int] = []

        do {
            _ = try service.dispatchDialogInput(
                text: "hello",
                clearExisting: true,
                unitFocusValidation: { dispatchedUnits in
                    validationCounts.append(dispatchedUnits)
                    if dispatchedUnits == 1 {
                        throw DialogService.dialogDispatchFocusFailure(
                            focusMutationDispatched: true,
                            dispatchedKeyboardUnits: dispatchedUnits,
                            cause: DialogError.noActiveDialog)
                    }
                })
            Issue.record("Expected focus loss between select-all and delete")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .dispatchedUnverified)
            #expect(failure.outcome.delivery == DialogService.foregroundKeyboardDelivery)
            #expect(failure.outcome.dispatchState.unitCount == .one)
            #expect(failure.outcome.retrySafety == .unsafe)
        }
        #expect(validationCounts == [0, 1])
        #expect(driver.hotkeys == [["cmd", "a"]])
        #expect(driver.tappedKeys.isEmpty)
        #expect(driver.typedText.isEmpty)
    }

    @Test
    func `exact field validation runs immediately before every keyboard unit`() throws {
        let driver = RecordingDialogSyntheticDriver()
        let service = DialogService(syntheticInputDriver: driver)
        var validationCounts: [Int] = []

        let count = try service.dispatchDialogInput(
            text: "hello",
            clearExisting: true,
            validateEachCharacter: true,
            unitFocusValidation: { validationCounts.append($0) })
        #expect(validationCounts == [0, 1, 2, 3, 3, 3, 3])
        #expect(count?.rawValue == 3)
        #expect(driver.hotkeys == [["cmd", "a"]])
        #expect(driver.tappedKeys == [.delete])
        #expect(driver.typedText == ["h", "e", "l", "l", "o"])
    }

    @Test
    func `cancellation during final focus validation emits no keyboard unit`() async {
        let driver = RecordingDialogSyntheticDriver()
        let service = DialogService(syntheticInputDriver: driver)
        let task = Task { @MainActor in
            try service.dispatchDialogInput(
                text: "hello",
                clearExisting: false,
                unitFocusValidation: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                })
        }

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(driver.typedText.isEmpty)
    }

    @Test
    func `focus stolen after first character stops secure text remainder with one type unit`() throws {
        let driver = RecordingDialogSyntheticDriver()
        let service = DialogService(syntheticInputDriver: driver)
        var validationCounts: [Int] = []

        do {
            _ = try service.dispatchDialogInput(
                text: "secret",
                clearExisting: false,
                validateEachCharacter: true,
                unitFocusValidation: { dispatchedUnits in
                    validationCounts.append(dispatchedUnits)
                    if dispatchedUnits == 1 {
                        throw DialogService.dialogDispatchFocusFailure(
                            focusMutationDispatched: false,
                            dispatchedKeyboardUnits: dispatchedUnits,
                            cause: DialogError.noActiveDialog)
                    }
                })
            Issue.record("Expected focus loss after the first character")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .dispatchedUnverified)
            #expect(failure.outcome.delivery == DialogService.foregroundKeyboardDelivery)
            #expect(failure.outcome.dispatchState.unitCount == .one)
            #expect(failure.outcome.retrySafety == .unsafe)
        }
        #expect(validationCounts == [0, 1])
        #expect(driver.typedText == ["s"])
    }

    @Test
    func `second character driver failure preserves one started type unit`() throws {
        let driver = RecordingDialogSyntheticDriver(failTypeAtCall: 2)
        let service = DialogService(syntheticInputDriver: driver)

        do {
            _ = try service.dispatchDialogInput(
                text: "secret",
                clearExisting: false,
                validateEachCharacter: true,
                unitFocusValidation: { _ in })
            Issue.record("Expected the second character dispatch to fail")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.delivery == DialogService.foregroundKeyboardDelivery)
            #expect(failure.outcome.dispatchState.unitCount == .one)
            #expect(failure.outcome.retrySafety == .unsafe)
        }
        #expect(driver.typedText == ["s"])
    }

    @Test
    func `dialog result target receipt is additive and missing field stays compatible`() throws {
        let target = try self.target()
        let result = DialogActionResult(
            success: true,
            action: .enterText,
            details: ["window_id": "700"],
            outcome: .confirmedNoChange(),
            targetReceipt: DialogService.desktopActionTargetReceipt(target),
            targetWindowIdentity: target.identity,
            targetWindowBounds: target.bounds,
            focusedElement: target.focusedElement)
        let roundTrip = try JSONDecoder().decode(
            DialogActionResult.self,
            from: JSONEncoder().encode(result))
        #expect(roundTrip.targetReceipt == DialogService.desktopActionTargetReceipt(target))
        #expect(roundTrip.targetWindowIdentity == target.identity)
        #expect(roundTrip.targetWindowBounds == target.bounds)
        #expect(roundTrip.focusedElement == target.focusedElement)

        let legacy = try JSONDecoder().decode(
            DialogActionResult.self,
            from: Data(#"{"success":true,"action":"enter_text","details":{}}"#.utf8))
        #expect(legacy.targetReceipt == nil)
        #expect(legacy.targetWindowIdentity == nil)
        #expect(legacy.targetWindowBounds == nil)
        #expect(legacy.focusedElement == nil)
        #expect(legacy.outcome == nil)
    }

    @Test
    func `resolved unsafe dialog failure retains exact target while pre-resolution refusal does not`() throws {
        let target = try self.target()
        let unsafeFailure = DesktopActionFailure.indeterminate(
            delivery: DialogService.foregroundKeyboardDelivery,
            evidence: .completionUnknown,
            unitCount: .one,
            message: "Forced Escape may have started")
        let attributed = DialogService.attributedDialogActionFailure(unsafeFailure, target: target)

        #expect(attributed.outcome.state == .indeterminate)
        #expect(attributed.outcome.retrySafety == .unsafe)
        #expect(attributed.targetReceipt == DesktopActionTargetReceipt(
            processIdentifier: target.identity.ownerProcessIdentifier,
            processStartIdentity: target.identity.ownerProcessStartIdentity,
            windowID: target.identity.windowID))

        let preResolution = DesktopActionFailure.preDispatchRefusal(
            reason: .targetUnavailable,
            message: "The broad selector did not resolve exactly once")
        #expect(preResolution.targetReceipt == nil)
    }

    private func target() throws -> UIAutomationTarget.ExactWindow {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        return try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 700,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 1234,
                capturedBounds: bounds),
            bounds: bounds)
    }

    private func window(id: Int, title: String, generation: UInt64) -> ServiceWindowInfo {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        return ServiceWindowInfo(
            windowID: id,
            title: title,
            bounds: bounds,
            mutationIdentity: WindowMutationIdentity(
                windowID: id,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: generation,
                capturedBounds: bounds))
    }
}

@MainActor
private final class MissingDialogApplicationService: ApplicationServiceProtocol {
    func listApplications() async throws -> UnifiedToolOutput<ServiceApplicationListData> {
        fatalError("unused")
    }

    func findApplication(identifier: String) async throws -> ServiceApplicationInfo {
        throw PeekabooError.appNotFound(identifier)
    }

    func listWindows(for _: String, timeout _: Float?) async throws -> UnifiedToolOutput<ServiceWindowListData> {
        fatalError("unused")
    }

    func getFrontmostApplication() async throws -> ServiceApplicationInfo {
        fatalError("unused")
    }

    func isApplicationRunning(identifier _: String) async -> Bool {
        fatalError("unused")
    }

    func launchApplication(identifier _: String) async throws -> ServiceApplicationInfo {
        fatalError("unused")
    }

    func activateApplication(identifier _: String) async throws {
        fatalError("unused")
    }

    func quitApplication(identifier _: String, force _: Bool) async throws -> Bool {
        fatalError("unused")
    }

    func hideApplication(identifier _: String) async throws {
        fatalError("unused")
    }

    func unhideApplication(identifier _: String) async throws {
        fatalError("unused")
    }

    func hideOtherApplications(identifier _: String) async throws {
        fatalError("unused")
    }

    func showAllApplications() async throws {
        fatalError("unused")
    }
}
