import CoreGraphics
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct WindowCandidateSelectorTests {
    @Test
    func `unique exact title wins before partial while duplicate exact refuses deterministically`() throws {
        let windows = AutomationTestFixtures.duplicateTitleWindows()
        let selected = try DesktopTargetPlanning.WindowCandidateSelector.select(
            candidates: windows,
            selector: .title("Shared Document"),
            policy: .explicit)
        #expect(selected.windowID == 201)

        let duplicate = AutomationTestFixtures.window(windowID: 203, title: "shared document", index: 2)
        let candidates = windows + [duplicate]
        let expected = DesktopTargetPlanningError.ambiguousWindow(
            selector: "title 'Shared Document'",
            candidateWindowIDs: [201, 203])
        #expect(throws: expected) {
            _ = try DesktopTargetPlanning.WindowCandidateSelector.select(
                candidates: candidates,
                selector: .title("Shared Document"),
                policy: .explicit)
        }
        #expect(throws: expected) {
            _ = try DesktopTargetPlanning.WindowCandidateSelector.select(
                candidates: candidates.reversed(),
                selector: .title("Shared Document"),
                policy: .explicit)
        }
    }

    @Test
    func `multiple partial titles refuse with sorted candidate IDs`() {
        let windows = Array(AutomationTestFixtures.duplicateTitleWindows().reversed())
        #expect(throws: DesktopTargetPlanningError.ambiguousWindow(
            selector: "title containing 'Shared'",
            candidateWindowIDs: [201, 202]))
        {
            _ = try DesktopTargetPlanning.WindowCandidateSelector.select(
                candidates: windows,
                selector: .title("Shared"),
                policy: .explicit)
        }
    }

    @Test
    func `normalized index is authoritative and never falls back to inventory position`() throws {
        let first = AutomationTestFixtures.window(windowID: 201, index: 4)
        let second = AutomationTestFixtures.window(windowID: 202, index: 7)

        #expect(try DesktopTargetPlanning.WindowCandidateSelector.select(
            candidates: [first, second],
            selector: .index(7),
            policy: .explicit).windowID == 202)
        #expect(throws: DesktopTargetPlanningError.self) {
            _ = try DesktopTargetPlanning.WindowCandidateSelector.select(
                candidates: [first, second],
                selector: .index(0),
                policy: .explicit)
        }
    }

    @Test
    func `automatic selection requires an explicit mutation policy`() throws {
        let windows = AutomationTestFixtures.duplicateTitleWindows()
        #expect(throws: DesktopTargetPlanningError.self) {
            _ = try DesktopTargetPlanning.WindowCandidateSelector.select(
                candidates: windows,
                selector: nil,
                policy: .explicit)
        }
        #expect(try DesktopTargetPlanning.WindowCandidateSelector.select(
            candidates: windows,
            selector: nil,
            policy: .preferredMutationWindow(.general)).windowID == 201)
    }

    @Test
    func `automatic mutation selection retains minimized and offscreen exact windows`() throws {
        let minimized = AutomationTestFixtures.window(
            windowID: 301,
            title: "Minimized",
            isMinimized: true)
        let offscreenBounds = CGRect(x: -2000, y: 100, width: 640, height: 480)
        let offscreen = ServiceWindowInfo(
            windowID: 302,
            title: "Offscreen",
            bounds: offscreenBounds,
            isOffScreen: true,
            isOnScreen: false,
            mutationIdentity: AutomationTestFixtures.windowIdentity(
                windowID: 302,
                bounds: offscreenBounds))

        #expect(try DesktopTargetPlanning.WindowCandidateSelector.select(
            candidates: [minimized],
            selector: nil,
            policy: .preferredMutationWindow(.general)).windowID == minimized.windowID)
        #expect(try DesktopTargetPlanning.WindowCandidateSelector.select(
            candidates: [offscreen],
            selector: nil,
            policy: .preferredMutationWindow(.general)).windowID == offscreen.windowID)
    }

    @Test
    func `restore intent prefers a minimized window over a visible sibling`() throws {
        let visible = AutomationTestFixtures.window(windowID: 303, title: "Visible", isMinimized: false)
        let minimized = AutomationTestFixtures.window(windowID: 304, title: "Minimized", isMinimized: true)

        #expect(try DesktopTargetPlanning.WindowCandidateSelector.select(
            candidates: [visible, minimized],
            selector: nil,
            policy: .preferredMutationWindow(.restore)).windowID == minimized.windowID)
    }

    @Test
    func `automatic mutation ranking prefers normal window level`() throws {
        let bounds = CGRect(x: 10, y: 20, width: 640, height: 480)
        let normal = ServiceWindowInfo(
            windowID: 305,
            title: "Normal",
            bounds: bounds,
            windowLevel: 0,
            mutationIdentity: AutomationTestFixtures.windowIdentity(windowID: 305, bounds: bounds))
        let elevated = ServiceWindowInfo(
            windowID: 306,
            title: "Elevated",
            bounds: bounds,
            windowLevel: 10,
            mutationIdentity: AutomationTestFixtures.windowIdentity(windowID: 306, bounds: bounds))

        #expect(try DesktopTargetPlanning.WindowCandidateSelector.select(
            candidates: [elevated, normal],
            selector: nil,
            policy: .preferredMutationWindow(.general)).windowID == normal.windowID)
    }

    @Test
    func `identity validation refuses missing bounds wrong IDs and wrong owners`() {
        let process = AutomationTestFixtures.processIdentity()
        let missing = AutomationTestFixtures.window(includesMutationIdentity: false)
        #expect(throws: DesktopTargetPlanningError.missingWindowIdentity(windowID: missing.windowID)) {
            _ = try DesktopTargetPlanning.WindowCandidateSelector.select(
                candidates: [missing],
                selector: .id(missing.windowID),
                policy: .explicit)
        }

        let noBounds = ServiceWindowInfo(
            windowID: 201,
            title: "No Bounds Receipt",
            bounds: CGRect(x: 1, y: 2, width: 3, height: 4),
            mutationIdentity: AutomationTestFixtures.windowIdentity(bounds: nil))
        #expect(throws: DesktopTargetPlanningError.incompleteWindowIdentity(windowID: 201)) {
            _ = try DesktopTargetPlanning.WindowCandidateSelector.select(
                candidates: [noBounds],
                selector: .id(201),
                policy: .explicit)
        }

        let window = AutomationTestFixtures.window(processIdentity: process)
        let other = AutomationTestFixtures.processIdentity(processIdentifier: 202, processStartIdentity: 2002)
        #expect(throws: DesktopTargetPlanningError.windowOwnerMismatch(windowID: 201, expected: other)) {
            _ = try DesktopTargetPlanning.WindowCandidateSelector.select(
                candidates: [window],
                selector: .id(201),
                policy: .explicit,
                expectedOwner: other)
        }
    }

    @Test
    func `duplicate rows with the same stable receipt coalesce across minimized state`() throws {
        let visible = AutomationTestFixtures.window(isMinimized: false)
        let minimized = AutomationTestFixtures.window(isMinimized: true)
        let selected = try DesktopTargetPlanning.WindowCandidateSelector.select(
            candidates: [minimized, visible],
            selector: .id(visible.windowID),
            policy: .explicit)
        #expect(!selected.isMinimized)
    }

    @Test
    func `conflicting duplicate titles refuse before title filtering independent of row order`() {
        let matching = AutomationTestFixtures.window(title: "Target Document")
        let conflicting = AutomationTestFixtures.window(title: "Different Document")
        let expected = DesktopTargetPlanningError.conflictingWindowEntries(windowID: matching.windowID)

        for candidates in [[matching, conflicting], [conflicting, matching]] {
            #expect(throws: expected) {
                _ = try DesktopTargetPlanning.WindowCandidateSelector.select(
                    candidates: candidates,
                    selector: .title(matching.title),
                    policy: .explicit)
            }
        }
    }

    @Test
    func `conflicting duplicate indices refuse before index filtering independent of row order`() {
        let matching = AutomationTestFixtures.window(index: 3)
        let conflicting = AutomationTestFixtures.window(index: 7)
        let expected = DesktopTargetPlanningError.conflictingWindowEntries(windowID: matching.windowID)

        for candidates in [[matching, conflicting], [conflicting, matching]] {
            #expect(throws: expected) {
                _ = try DesktopTargetPlanning.WindowCandidateSelector.select(
                    candidates: candidates,
                    selector: .index(matching.index),
                    policy: .explicit)
            }
        }
    }

    @Test
    func `title and index refuse window IDs outside the WindowServer range`() {
        let oversizedID = Int(UInt32.max) + 1
        let oversized = AutomationTestFixtures.window(windowID: oversizedID, title: "Oversized", index: 3)

        for selector: InteractionTargetSelector.WindowSelector in [.title("Oversized"), .index(3)] {
            #expect(throws: DesktopTargetPlanningError.incompleteWindowIdentity(windowID: oversizedID)) {
                _ = try DesktopTargetPlanning.WindowCandidateSelector.select(
                    candidates: [oversized],
                    selector: selector,
                    policy: .explicit)
            }
        }
    }

    @Test
    func `duplicate rows refuse missing receipts and external bounds conflicts`() {
        let valid = AutomationTestFixtures.window()
        let missing = AutomationTestFixtures.window(includesMutationIdentity: false)
        #expect(throws: DesktopTargetPlanningError.conflictingWindowEntries(windowID: valid.windowID)) {
            _ = try DesktopTargetPlanning.WindowCandidateSelector.select(
                candidates: [valid, missing],
                selector: .id(valid.windowID),
                policy: .explicit)
        }

        let mismatchedBounds = ServiceWindowInfo(
            windowID: valid.windowID,
            title: valid.title,
            bounds: valid.bounds.offsetBy(dx: 1, dy: 0),
            mutationIdentity: valid.mutationIdentity)
        #expect(throws: DesktopTargetPlanningError.conflictingWindowEntries(windowID: valid.windowID)) {
            _ = try DesktopTargetPlanning.WindowCandidateSelector.select(
                candidates: [valid, mismatchedBounds],
                selector: .id(valid.windowID),
                policy: .explicit)
        }
    }
}
