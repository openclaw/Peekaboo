import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct WindowStateMutationPolicyTests {
    private let identity = WindowMutationIdentity(
        windowID: 924,
        ownerProcessIdentifier: 42,
        ownerProcessStartIdentity: 7,
        capturedBounds: CGRect(x: 30, y: 40, width: 900, height: 700))

    @Test
    func `minimize identity accepts exact AX window after CG disappearance`() {
        #expect(pinnedWindowMinimizeIdentityMatches(
            expectedIdentity: self.identity,
            currentProcessStartIdentity: 7,
            currentWindowID: 924,
            currentBounds: self.identity.capturedBounds))
    }

    @Test
    func `minimize postcondition rejects process generation reuse`() {
        #expect(!pinnedWindowMinimizeIdentityMatches(
            expectedIdentity: self.identity,
            currentProcessStartIdentity: 8,
            currentWindowID: 924,
            currentBounds: self.identity.capturedBounds))
    }

    @Test
    func `minimize accepts transient AX window ID loss when WindowServer receipt remains exact`() {
        #expect(pinnedWindowMinimizeIdentityMatches(
            expectedIdentity: self.identity,
            currentProcessStartIdentity: 7,
            currentWindowID: nil,
            currentBounds: nil,
            windowServerIdentityMatches: true))
        #expect(!pinnedWindowMinimizeIdentityMatches(
            expectedIdentity: self.identity,
            currentProcessStartIdentity: 7,
            currentWindowID: 925,
            currentBounds: self.identity.capturedBounds,
            windowServerIdentityMatches: true))
    }

    @Test
    func `minimize postcondition rejects changed capture-time bounds`() {
        #expect(!pinnedWindowMinimizeIdentityMatches(
            expectedIdentity: self.identity,
            currentProcessStartIdentity: 7,
            currentWindowID: 924,
            currentBounds: CGRect(x: 50, y: 60, width: 700, height: 500)))
    }

    @Test
    func `restore completion preserves the captured exact window receipt`() {
        #expect(pinnedWindowRestoreIdentityMatches(
            expectedIdentity: self.identity,
            currentProcessStartIdentity: 7,
            currentWindowID: 924,
            currentBounds: self.identity.capturedBounds))
    }

    @Test
    func `restore completion rejects process window ID and bounds reuse`() {
        #expect(!pinnedWindowRestoreIdentityMatches(
            expectedIdentity: self.identity,
            currentProcessStartIdentity: 8,
            currentWindowID: 924,
            currentBounds: self.identity.capturedBounds))
        #expect(!pinnedWindowRestoreIdentityMatches(
            expectedIdentity: self.identity,
            currentProcessStartIdentity: 7,
            currentWindowID: 925,
            currentBounds: self.identity.capturedBounds))
        #expect(!pinnedWindowRestoreIdentityMatches(
            expectedIdentity: self.identity,
            currentProcessStartIdentity: 7,
            currentWindowID: 924,
            currentBounds: CGRect(x: 50, y: 60, width: 700, height: 500)))
    }

    @Test
    func `minimized close treats a surviving AX window as present`() {
        #expect(pinnedWindowClosePresenceDisposition(
            windowServerEntryPresent: false,
            minimizedAXPresence: .present,
            expectedMinimized: true) == .present)
    }

    @Test
    func `minimized close treats verified AX absence as missing`() {
        #expect(pinnedWindowClosePresenceDisposition(
            windowServerEntryPresent: false,
            minimizedAXPresence: .missing,
            expectedMinimized: true) == .missing)
    }

    @Test
    func `minimized close fails closed when AX presence is unavailable`() {
        #expect(pinnedWindowClosePresenceDisposition(
            windowServerEntryPresent: false,
            minimizedAXPresence: nil,
            expectedMinimized: true) == .unverifiable)
    }

    @Test
    func `successful minimized close accepts complete AX disappearance scan`() {
        let presence = pinnedMinimizedWindowAXPresence(
            expectedIdentity: self.identity,
            processStartIdentityBeforeScan: 7,
            processStartIdentityAfterScan: 7,
            scan: PinnedMinimizedWindowAXScan(matchingWindowBounds: [], isComplete: true))
        let disposition = pinnedWindowClosePresenceDisposition(
            windowServerEntryPresent: false,
            minimizedAXPresence: presence,
            expectedMinimized: true)
        var verification = PinnedWindowCloseVerification()

        #expect(presence == .missing)
        #expect(verification.observe(disposition, elapsed: .zero) == .pending)
        #expect(verification.observe(disposition, elapsed: .seconds(4)) == .succeeded)
    }

    @Test
    func `incomplete minimized AX scan cannot prove disappearance`() {
        let presence = pinnedMinimizedWindowAXPresence(
            expectedIdentity: self.identity,
            processStartIdentityBeforeScan: 7,
            processStartIdentityAfterScan: 7,
            scan: PinnedMinimizedWindowAXScan(matchingWindowBounds: [], isComplete: false))

        #expect(presence == .unverifiable)
    }

    @Test
    func `same ID minimized replacement is not accepted as the captured window`() {
        let presence = pinnedMinimizedWindowAXPresence(
            expectedIdentity: self.identity,
            processStartIdentityBeforeScan: 7,
            processStartIdentityAfterScan: 7,
            scan: PinnedMinimizedWindowAXScan(
                matchingWindowBounds: [CGRect(x: 50, y: 60, width: 640, height: 480)],
                isComplete: true))

        #expect(presence == .replacement)
        #expect(pinnedWindowClosePresenceDisposition(
            windowServerEntryPresent: false,
            minimizedAXPresence: presence,
            expectedMinimized: true) == .replacement)
    }

    @Test
    func `minimized AX scan rejects owner process reuse before or during scan`() {
        let completeAbsence = PinnedMinimizedWindowAXScan(matchingWindowBounds: [], isComplete: true)

        #expect(pinnedMinimizedWindowAXPresence(
            expectedIdentity: self.identity,
            processStartIdentityBeforeScan: 8,
            processStartIdentityAfterScan: 8,
            scan: completeAbsence) == .replacement)
        #expect(pinnedMinimizedWindowAXPresence(
            expectedIdentity: self.identity,
            processStartIdentityBeforeScan: 7,
            processStartIdentityAfterScan: 8,
            scan: completeAbsence) == .replacement)
    }

    @Test
    func `failed minimized close restores private minimized state`() {
        #expect(shouldRestoreMinimizedWindowAfterCloseFailure(
            wasMinimized: true,
            closeCompleted: false))
        #expect(!shouldRestoreMinimizedWindowAfterCloseFailure(
            wasMinimized: false,
            closeCompleted: false))
        #expect(!shouldRestoreMinimizedWindowAfterCloseFailure(
            wasMinimized: true,
            closeCompleted: true))
    }

    @Test
    func `minimized close accepts validated AX identity without CG metadata`() {
        #expect(hasSufficientMetadataForPinnedClose(
            hasWindowServerMetadata: false,
            expectedMinimized: true))
        #expect(!hasSufficientMetadataForPinnedClose(
            hasWindowServerMetadata: false,
            expectedMinimized: false))
    }

    @Test
    func `exact offscreen lookup carries AX minimized state into mutation receipt`() throws {
        let originalBounds = CGRect(x: 10, y: 20, width: 800, height: 600)
        let refreshedBounds = CGRect(x: 30, y: 40, width: 900, height: 700)
        let originalIdentity = WindowMutationIdentity(
            windowID: 924,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 7,
            capturedBounds: originalBounds,
            isMinimized: false)
        let cgWindow = ServiceWindowInfo(
            windowID: 924,
            title: "",
            bounds: originalBounds,
            isOffScreen: true,
            isOnScreen: false,
            mutationIdentity: originalIdentity)

        let enriched = cgWindow.withExactAXState(
            title: "Fixture",
            bounds: refreshedBounds,
            isMinimized: true)

        #expect(enriched.title == "Fixture")
        #expect(enriched.bounds == refreshedBounds)
        #expect(enriched.isMinimized)
        #expect(!enriched.isOnScreen)
        let enrichedIdentity = try #require(enriched.mutationIdentity)
        #expect(enrichedIdentity.capturedBounds == refreshedBounds)
        #expect(enrichedIdentity.isMinimized == true)
        #expect(enrichedIdentity.processIdentity == originalIdentity.processIdentity)
        try DesktopTargetPlanning.WindowCandidateSelector.validate(
            enriched,
            expectedOwner: originalIdentity.processIdentity)
    }

    @Test
    func `AX fallback rejects same window ID after scan-time PID generation reuse`() {
        let snapshot = BoundedAXWindowIdentitySnapshot(
            windowID: 924,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 7,
            title: "Fixture",
            bounds: CGRect(x: 30, y: 40, width: 900, height: 700),
            isMinimized: true)

        #expect(BoundedAXWindowIdentityScanner.validatedSnapshot(
            snapshot,
            expectedReceipt: BoundedAXWindowScanReceipt(
                windowID: 924,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 7),
            liveProcessStartIdentity: 8) == nil)
        #expect(BoundedAXWindowIdentityScanner.validatedSnapshot(
            snapshot,
            expectedReceipt: BoundedAXWindowScanReceipt(
                windowID: 924,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 7),
            liveProcessStartIdentity: 7) == snapshot)
    }

    @Test
    func `minimized restoration rejects a sibling with identical bounds`() {
        #expect(!exactMinimizedRestoreCandidateIsValid(
            expectedIdentity: self.identity.withMinimizedState(true),
            liveProcessStartIdentity: 7,
            candidateWindowID: 925,
            candidateBounds: self.identity.capturedBounds,
            candidateIsMinimized: true))
    }

    @Test
    func `minimized restoration rejects a candidate without an exact window ID`() {
        #expect(!exactMinimizedRestoreCandidateIsValid(
            expectedIdentity: self.identity.withMinimizedState(true),
            liveProcessStartIdentity: 7,
            candidateWindowID: nil,
            candidateBounds: self.identity.capturedBounds,
            candidateIsMinimized: true))
    }

    @Test
    func `exact minimized restoration accepts matching ID generation and bounds`() {
        #expect(exactMinimizedRestoreCandidateIsValid(
            expectedIdentity: self.identity.withMinimizedState(true),
            liveProcessStartIdentity: 7,
            candidateWindowID: 924,
            candidateBounds: self.identity.capturedBounds,
            candidateIsMinimized: true))
    }

    @Test
    @MainActor
    func `restore accepts exact same ID reappearance after asynchronous AX state reflection`() async throws {
        let expected = self.identity.withMinimizedState(true)
        let restored = self.identity.withMinimizedState(false)
        let synchronousAXStillReportedMinimized = true

        let result = try await completePinnedMinimizedWindowRestore(
            expectedIdentity: expected,
            dispatch: {
                #expect(synchronousAXStillReportedMinimized)
                return true
            },
            repin: { receipt, bounds in
                #expect(receipt == expected)
                #expect(bounds == expected.capturedBounds)
                return restored
            })

        #expect(result == restored)
    }

    @Test
    @MainActor
    func `restore rejects ambiguous reappearance ownership generation and bounds`() async {
        let expected = self.identity.withMinimizedState(true)
        let ambiguousCandidates = [
            WindowMutationIdentity(
                windowID: 925,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 7,
                capturedBounds: expected.capturedBounds,
                isMinimized: false),
            WindowMutationIdentity(
                windowID: 924,
                ownerProcessIdentifier: 43,
                ownerProcessStartIdentity: 7,
                capturedBounds: expected.capturedBounds,
                isMinimized: false),
            WindowMutationIdentity(
                windowID: 924,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 8,
                capturedBounds: expected.capturedBounds,
                isMinimized: false),
            WindowMutationIdentity(
                windowID: 924,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 7,
                capturedBounds: CGRect(x: 50, y: 60, width: 700, height: 500),
                isMinimized: false),
            expected,
        ]

        for candidate in ambiguousCandidates {
            await #expect(throws: PeekabooError.self) {
                try await completePinnedMinimizedWindowRestore(
                    expectedIdentity: expected,
                    dispatch: { true },
                    repin: { _, _ in candidate })
            }
        }
    }

    @Test
    func `minimized restoration rejects process generation change`() {
        #expect(!exactMinimizedRestoreCandidateIsValid(
            expectedIdentity: self.identity.withMinimizedState(true),
            liveProcessStartIdentity: 8,
            candidateWindowID: 924,
            candidateBounds: self.identity.capturedBounds,
            candidateIsMinimized: true))
    }

    @Test
    func `AX-only minimized inventory carries owner generation mutation receipt`() throws {
        let window = ServiceWindowInfo(
            windowID: 924,
            title: "Fixture",
            bounds: CGRect(x: 30, y: 40, width: 900, height: 700),
            isMinimized: true,
            isOffScreen: true,
            isOnScreen: false)

        let enriched = window.withMutationIdentity(self.identity.withMinimizedState(true))

        let receipt = try #require(enriched.mutationIdentity)
        #expect(receipt.windowID == 924)
        #expect(receipt.ownerProcessIdentifier == 42)
        #expect(receipt.ownerProcessStartIdentity == 7)
        #expect(receipt.isMinimized == true)
    }

    @Test
    func `edited minimized windows fail before temporary restore`() {
        #expect(!shouldAttemptUnminimizedClose(isEdited: true))
        #expect(shouldAttemptUnminimizedClose(isEdited: false))
        #expect(shouldAttemptUnminimizedClose(isEdited: nil))
    }

    @Test
    func `minimized close requires explicit foreground fallback`() {
        #expect(minimizedCloseRequiresForegroundFallback(isMinimized: true))
        #expect(!minimizedCloseRequiresForegroundFallback(isMinimized: false))
    }

    @Test
    func `foreground close focus allows exact target Space switching`() {
        let options = foregroundCloseFocusOptions()

        #expect(options.switchSpace)
        #expect(!options.bringToCurrentSpace)
    }

    @Test
    @MainActor
    func `minimized foreground close accounts exact unminimize before focus`() async throws {
        let minimized = self.identity.withMinimizedState(true)
        let restored = self.identity.withMinimizedState(false)
        var events: [String] = []
        var sequence = DesktopActionSequenceAccumulator()

        let focusIdentity = try await prepareForegroundCloseIdentity(
            expectedIdentity: minimized,
            restoreMinimized: {
                events.append("unminimize")
                ForegroundCloseRecoveryAccounting.recordAcceptedDispatch(in: &sequence)
                return restored
            })
        events.append("focus")

        #expect(events == ["unminimize", "focus"])
        #expect(focusIdentity == restored)
        #expect(sequence.mutationDisposition == .definite(unitCount: .one))
        #expect(sequence.successResolution().outcome?.delivery ==
            WindowManagementActionOutcome.backgroundValueDelivery)
    }

    @Test
    func `foreground close rejects same-process sibling key window`() {
        let readiness = pinnedForegroundCloseReadiness(
            focusSucceeded: true,
            expectedIdentity: self.identity,
            currentProcessStartIdentity: 7,
            frontmostProcessIdentifier: 42,
            keyWindow: ExactKeyWindowSnapshot(
                processIdentifier: 42,
                windowID: 925,
                isSheet: false,
                hasAttachedSheet: false))

        #expect(readiness == .wrongKeyWindow(actualWindowID: 925))
    }

    @Test
    func `foreground close rejects a sheet on the pinned window`() {
        let readiness = pinnedForegroundCloseReadiness(
            focusSucceeded: true,
            expectedIdentity: self.identity,
            currentProcessStartIdentity: 7,
            frontmostProcessIdentifier: 42,
            keyWindow: ExactKeyWindowSnapshot(
                processIdentifier: 42,
                windowID: 924,
                isSheet: false,
                hasAttachedSheet: true))

        #expect(readiness == .sheetPresented)
    }

    @Test
    func `foreground close rejects a pinned key window that is itself a sheet`() {
        let readiness = pinnedForegroundCloseReadiness(
            focusSucceeded: true,
            expectedIdentity: self.identity,
            currentProcessStartIdentity: 7,
            frontmostProcessIdentifier: 42,
            keyWindow: ExactKeyWindowSnapshot(
                processIdentifier: 42,
                windowID: 924,
                isSheet: true,
                hasAttachedSheet: false))

        #expect(readiness == .sheetPresented)
    }

    @Test
    @MainActor
    func `foreground close resamples frontmost application after detached key window read`() async {
        let race = ForegroundCloseReadinessRace()

        let readiness = await readPinnedForegroundCloseReadiness(
            focusSucceeded: true,
            expectedIdentity: self.identity,
            keyWindowReader: {
                await Task.detached {
                    await race.switchFrontmostApplication()
                    return ExactKeyWindowSnapshot(
                        processIdentifier: 42,
                        windowID: 924,
                        isSheet: false,
                        hasAttachedSheet: false)
                }.value
            },
            processStartIdentityReader: {
                #expect(race.keyWindowReadCompleted)
                #expect(race.identityValidationCompleted)
                return 7
            },
            frontmostProcessIdentifierReader: {
                #expect(race.keyWindowReadCompleted)
                #expect(race.identityValidationCompleted)
                return race.frontmostProcessIdentifier
            },
            windowIdentityValidator: {
                #expect(race.keyWindowReadCompleted)
                race.completeIdentityValidation()
                return true
            })

        #expect(readiness == .appNotFrontmost)
    }

    @Test
    func `failed focus and hotkey paths restore a formerly minimized target`() async {
        let restoration = RestorationProbe()

        await #expect(throws: ForegroundCloseTestError.self) {
            try await withMinimizedWindowFailureRecovery(
                wasMinimized: true,
                restore: { restoration.record() },
                operation: { throw ForegroundCloseTestError.focus })
        }
        await #expect(throws: ForegroundCloseTestError.self) {
            try await withMinimizedWindowFailureRecovery(
                wasMinimized: true,
                restore: { restoration.record() },
                operation: { throw ForegroundCloseTestError.hotkey })
        }

        #expect(restoration.count == 2)
    }

    @Test
    func `predispatch minimized cancellation has zero mutation and skips recovery`() {
        let sequence = DesktopActionSequenceAccumulator()

        #expect(!ForegroundCloseRecoveryAccounting.shouldRecover(
            wasMinimized: true,
            sequence: sequence))
        #expect(sequence.mutationDisposition == .none)
        #expect(sequence.cancellationFailure(
            fallbackRoute: .local,
            message: "cancelled",
            hint: "none",
            causeDescription: "predispatch") == nil)
    }

    @Test
    func `post-setup cancellation accounts accepted minimized recovery`() throws {
        let focusDelivery = DesktopActionOutcome.Delivery(
            mechanism: .accessibilityAction,
            mode: .foreground)
        var sequence = DesktopActionSequenceAccumulator()
        sequence.record(.dispatched(
            route: .local,
            delivery: focusDelivery,
            unitCount: .one))

        #expect(ForegroundCloseRecoveryAccounting.shouldRecover(
            wasMinimized: true,
            sequence: sequence))
        ForegroundCloseRecoveryAccounting.recordAcceptedDispatch(in: &sequence)
        let failure = try #require(sequence.cancellationFailure(
            fallbackRoute: .local,
            message: "cancelled",
            hint: "observe",
            causeDescription: "post-setup"))

        #expect(failure.outcome.state == .indeterminate)
        #expect(failure.outcome.evidence == .completionUnknown)
        #expect(failure.outcome.delivery == .init(mechanism: .composite, mode: .foreground))
        #expect(failure.outcome.dispatchState.unitCount == DesktopActionOutcome.DispatchUnitCount(2))
    }

    @Test
    func `sheet failure restores a formerly minimized target before returning error`() async {
        let restoration = RestorationProbe()
        let readiness = pinnedForegroundCloseReadiness(
            focusSucceeded: true,
            expectedIdentity: self.identity,
            currentProcessStartIdentity: 7,
            frontmostProcessIdentifier: 42,
            keyWindow: ExactKeyWindowSnapshot(
                processIdentifier: 42,
                windowID: 924,
                isSheet: false,
                hasAttachedSheet: true))

        await #expect(throws: ForegroundCloseTestError.self) {
            try await withMinimizedWindowFailureRecovery(
                wasMinimized: true,
                restore: { restoration.record() },
                operation: {
                    guard readiness == .ready else { throw ForegroundCloseTestError.sheet }
                })
        }

        #expect(restoration.count == 1)
    }

    @Test
    func `exact state mutation keeps the requested ID without another lookup`() throws {
        let windowID = try exactWindowIDForStateMutation(
            target: .windowId(924),
            resolvedWindows: [])

        #expect(windowID == 924)
    }

    @Test
    func `exact WindowServer lookup does not accept the first unrelated window`() throws {
        let windows: [[String: Any]] = [
            [kCGWindowNumber as String: 111],
            [kCGWindowNumber as String: 924],
        ]

        let match = try #require(WindowIdentityService.exactWindowDictionary(
            windowID: 924,
            in: windows))

        #expect(match[kCGWindowNumber as String] as? Int == 924)
        #expect(WindowIdentityService.exactWindowDictionary(windowID: 999, in: windows) == nil)
    }

    @Test
    func `broad state mutation pins the resolved window ID`() throws {
        let windowID = try exactWindowIDForStateMutation(
            target: .application("Safari"),
            resolvedWindows: [ServiceWindowInfo(
                windowID: 924,
                title: "Fixture",
                bounds: CGRect(x: 100, y: 100, width: 800, height: 600))])

        #expect(windowID == 924)
    }

    @Test
    func `broad state mutation fails when exact identity cannot be proven`() {
        #expect(throws: PeekabooError.self) {
            _ = try exactWindowIDForStateMutation(
                target: .application("Safari"),
                resolvedWindows: [])
        }
    }

    @Test
    func `accepted background close fails when the exact window remains`() {
        #expect(throws: OperationError.self) {
            try validateBackgroundCloseOutcome(dispatchSucceeded: true, disappeared: false)
        }
    }

    @Test
    func `close outcome keeps unavailable verification distinct from observed no op`() {
        #expect(pinnedWindowCloseAttemptDisposition(for: .succeeded) == .disappeared)
        #expect(pinnedWindowCloseAttemptDisposition(for: .retryClose) == .remained)
        #expect(pinnedWindowCloseAttemptDisposition(for: .pending) == .unverifiable)
        #expect(pinnedWindowCloseAttemptDisposition(for: .unverifiable) == .unverifiable)
    }

    @Test
    func `background close succeeds only after exact disappearance`() throws {
        try validateBackgroundCloseOutcome(dispatchSucceeded: true, disappeared: true)
    }

    @Test
    func `controlled AX close succeeds after one exact disappearance check`() async throws {
        var checks = 0
        try await verifyBackgroundClose(dispatchSucceeded: true) {
            checks += 1
            return true
        }

        #expect(checks == 1)
    }

    @Test
    func `failed AX close skips disappearance polling`() async {
        var checks = 0
        await #expect(throws: OperationError.self) {
            try await verifyBackgroundClose(dispatchSucceeded: false) {
                checks += 1
                return true
            }
        }

        #expect(checks == 0)
    }

    @Test
    func `delayed same identity reappearance cannot produce early close success`() {
        var verification = PinnedWindowCloseVerification()

        #expect(verification.observe(.missing, elapsed: .zero) == .pending)
        #expect(verification.observe(.missing, elapsed: .seconds(2)) == .pending)
        #expect(verification.observe(.present, elapsed: .milliseconds(2900)) == .pending)
        #expect(verification.observe(.present, elapsed: .milliseconds(3700)) == .retryClose)
    }

    @Test
    func `stable disappearance succeeds only at the full observation horizon`() {
        var verification = PinnedWindowCloseVerification()

        #expect(verification.observe(.missing, elapsed: .zero) == .pending)
        #expect(verification.observe(.missing, elapsed: .seconds(2)) == .pending)
        #expect(verification.observe(.missing, elapsed: .milliseconds(3999)) == .pending)
        #expect(verification.observe(.missing, elapsed: .seconds(4)) == .succeeded)
    }

    @Test
    func `unverifiable close presence fails closed immediately`() {
        var verification = PinnedWindowCloseVerification()

        #expect(verification.observe(.unverifiable, elapsed: .zero) == .unverifiable)
    }

    @Test
    func `maximize chooses the screen with greatest window overlap`() throws {
        let left = CGRect(x: -1728, y: 0, width: 1728, height: 1080)
        let primary = CGRect(x: 0, y: 25, width: 1512, height: 930)
        let spanningWindow = CGRect(x: -300, y: 120, width: 1100, height: 700)

        let selected = try #require(maximizedVisibleFrame(
            windowBounds: spanningWindow,
            screenVisibleFramesTopLeft: [left, primary]))

        #expect(selected == primary)
    }

    @Test
    func `maximize has no target without a display`() {
        #expect(maximizedVisibleFrame(
            windowBounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            screenVisibleFramesTopLeft: []) == nil)
    }

    @Test
    func `maximize chooses the nearest screen for an offscreen window`() throws {
        let left = CGRect(x: -1728, y: 0, width: 1728, height: 1080)
        let primary = CGRect(x: 0, y: 25, width: 1512, height: 930)
        let offscreenRight = CGRect(x: 1900, y: 200, width: 500, height: 400)

        let selected = try #require(maximizedVisibleFrame(
            windowBounds: offscreenRight,
            screenVisibleFramesTopLeft: [left, primary]))

        #expect(selected == primary)
    }

    @Test
    func `maximize dispatch accepts asynchronous final geometry for the pinned window`() {
        #expect(backgroundGeometryDispatchRemainsPinned(
            expectedIdentity: self.identity,
            positionSetSucceeded: true,
            sizeSetSucceeded: true,
            liveProcessStartIdentity: 7,
            candidateWindowID: 924))
    }

    @Test
    func `maximize dispatch rejects AX failure or identity replacement`() {
        #expect(!backgroundGeometryDispatchRemainsPinned(
            expectedIdentity: self.identity,
            positionSetSucceeded: false,
            sizeSetSucceeded: true,
            liveProcessStartIdentity: 7,
            candidateWindowID: 924))
        #expect(!backgroundGeometryDispatchRemainsPinned(
            expectedIdentity: self.identity,
            positionSetSucceeded: true,
            sizeSetSucceeded: false,
            liveProcessStartIdentity: 7,
            candidateWindowID: 924))
        #expect(!backgroundGeometryDispatchRemainsPinned(
            expectedIdentity: self.identity,
            positionSetSucceeded: true,
            sizeSetSucceeded: true,
            liveProcessStartIdentity: 8,
            candidateWindowID: 924))
        #expect(!backgroundGeometryDispatchRemainsPinned(
            expectedIdentity: self.identity,
            positionSetSucceeded: true,
            sizeSetSucceeded: true,
            liveProcessStartIdentity: 7,
            candidateWindowID: 925))
    }
}

private enum ForegroundCloseTestError: Error {
    case focus
    case hotkey
    case sheet
}

@MainActor
private final class ForegroundCloseReadinessRace {
    private(set) var frontmostProcessIdentifier: pid_t? = 42
    private(set) var keyWindowReadCompleted = false
    private(set) var identityValidationCompleted = false

    func switchFrontmostApplication() {
        self.frontmostProcessIdentifier = 99
        self.keyWindowReadCompleted = true
    }

    func completeIdentityValidation() {
        self.identityValidationCompleted = true
    }
}

private final class RestorationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var count: Int {
        self.lock.withLock { self.storage }
    }

    func record() -> Bool {
        self.lock.withLock { self.storage += 1 }
        return true
    }
}
