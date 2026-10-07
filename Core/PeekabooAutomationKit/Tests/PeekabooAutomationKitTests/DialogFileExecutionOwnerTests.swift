import ApplicationServices
import AXorcist
import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct DialogFileExecutionOwnerTests {
    @Test
    func `file execution retains the parent selector while expansion refreshes only its geometry`() throws {
        let fixture = try FileExecutionOwnerFixture()
        let selector = try DialogTargetSelector(applicationIdentifier: "Fixture", windowTitle: "Parent Document")
        let request = try DialogFileExecutionRequest(target: selector)
        let execution = try DialogService.FileExecution(request: request, resolution: fixture.resolution())
        let expanded = try FileExecutionOwnerFixture.target(bounds: CGRect(x: 10, y: 20, width: 600, height: 500))
        execution.resolution = try fixture.resolution(target: expanded, title: "Changed after planning")

        let evidence = try execution.resolvedTarget()

        #expect(execution.request == request)
        #expect(execution.window == fixture.parent)
        #expect(execution.resolution.element == fixture.panel)
        #expect(execution.window != execution.resolution.element)
        #expect(execution.selectorEvidence == fixture.evidence)
        #expect(evidence.target == expanded)
        #expect(evidence.windowTitle == "Parent Document")
        #expect(evidence.windowIndex == 2)
        #expect(evidence.applicationBundleIdentifier == "dev.peekaboo.fixture")
        #expect(evidence.applicationName == "Fixture")
        #expect(evidence.matches(selector))
        let proof = try #require(evidence.selectorResolutionProofs?.first)
        #expect(proof.selectedWindowIdentity == expanded.identity)
        #expect(proof.normalizedSelector == fixture.evidence.selectorResolutionProofs?.first?.normalizedSelector)
    }

    @Test
    func `file execution refuses missing parent or selector evidence before dispatch`() throws {
        let fixture = try FileExecutionOwnerFixture()
        var missingParent = try fixture.resolution()
        missingParent.window = nil
        var missingEvidence = try fixture.resolution()
        missingEvidence.resolvedTarget = nil

        for resolution in [missingParent, missingEvidence] {
            self.expectPlanningRefusal {
                _ = try DialogService.FileExecution(request: fixture.request, resolution: resolution)
            }
        }
    }

    @Test
    func `file execution refuses evidence for a different exact parent or caller selector`() throws {
        let fixture = try FileExecutionOwnerFixture()
        var mismatched = try fixture.resolution()
        let otherTarget = try FileExecutionOwnerFixture.target(windowID: 701)
        mismatched.resolvedTarget = try FileExecutionOwnerFixture.evidence(target: otherTarget)
        self.expectPlanningRefusal {
            _ = try DialogService.FileExecution(request: fixture.request, resolution: mismatched)
        }

        let selectors = try [
            DialogTargetSelector(processIdentifier: 43, windowID: 700),
            DialogTargetSelector(processIdentifier: 42, windowID: 701),
            DialogTargetSelector(applicationIdentifier: "Other Fixture", windowTitle: "Parent Document"),
            DialogTargetSelector(processIdentifier: 42, windowTitle: "Another Document"),
            DialogTargetSelector(processIdentifier: 42, windowIndex: 3),
        ]
        for selector in selectors {
            self.expectPlanningRefusal {
                _ = try DialogService.FileExecution(
                    request: DialogFileExecutionRequest(target: selector),
                    resolution: fixture.resolution())
            }
        }
    }

    @Test
    func `resolved file evidence cannot migrate to another parent or process generation`() throws {
        let fixture = try FileExecutionOwnerFixture()
        let execution = try fixture.execution()
        let targets = try [
            FileExecutionOwnerFixture.target(windowID: 701),
            FileExecutionOwnerFixture.target(generation: 9002),
        ]
        for target in targets {
            execution.resolution = try fixture.resolution(target: target)
            #expect(throws: DesktopSelectedLeafEvidenceError.invalidEvidence) {
                try execution.resolvedTarget()
            }
        }
    }

    @Test
    func `file focus forwards exact parent sheet and policy and counts accepted callbacks`() async throws {
        let policy = DialogForegroundFocusPolicy(
            timeout: 1.25, retryCount: 7, switchSpace: true, bringToCurrentSpace: true)
        let fixture = try FileExecutionOwnerFixture(focus: policy)
        let focus = FileExecutionOwnerFocusStub()
        focus.records = [
            .accepted(.init(mechanism: .accessibilityAction, mode: .foreground)),
            .accepted(.init(mechanism: .accessibilityValue, mode: .foreground)),
        ]

        let outcome = try await fixture.service(focus: focus).focusFileExecution(fixture.execution())

        let call = try #require(focus.focusCalls.first)
        #expect(focus.focusCalls.count == 1)
        #expect(focus.requireCalls.isEmpty)
        #expect(call.target == fixture.target)
        #expect(call.window == fixture.parent)
        #expect(call.dialog == fixture.panel)
        #expect(call.options.timeout == policy.timeout)
        #expect(call.options.retryCount == policy.retryCount)
        #expect(call.options.switchSpace == policy.switchSpace)
        #expect(call.options.bringToCurrentSpace == policy.bringToCurrentSpace)
        #expect(outcome.state == .confirmedChange)
        #expect(outcome.delivery == .init(mechanism: .composite, mode: .foreground))
        #expect(outcome.dispatchState == .dispatched(unitCount: .init(2)))
    }

    @Test
    func `successful file focus without a callback does not invent a mutation`() async throws {
        let fixture = try FileExecutionOwnerFixture()
        let focus = FileExecutionOwnerFocusStub()

        let outcome = try await fixture.service(focus: focus).focusFileExecution(fixture.execution())

        #expect(focus.focusCalls.count == 1)
        #expect(outcome.state == .confirmedNoChange)
        #expect(outcome.dispatchState == .none)
    }

    @Test
    func `no auto focus only requires the exact parent sheet and preserves no change`() async throws {
        let fixture = try FileExecutionOwnerFixture(focus: .init(
            autoFocus: false, timeout: 2.75, retryCount: 4, switchSpace: true, bringToCurrentSpace: true))
        let focus = FileExecutionOwnerFocusStub()

        let outcome = try await fixture.service(focus: focus).focusFileExecution(fixture.execution())

        let call = try #require(focus.requireCalls.first)
        #expect(focus.requireCalls.count == 1)
        #expect(focus.focusCalls.isEmpty)
        #expect(call.target == fixture.target)
        #expect(call.window == fixture.parent)
        #expect(call.dialog == fixture.panel)
        #expect(call.timeout == 2.75)
        #expect(outcome.state == .confirmedNoChange)
        #expect(outcome.dispatchState == .none)
    }

    @Test(arguments: [false, true])
    func `uncertain file focus callbacks remain retry unsafe even if focus returns`(
        throwsAfterDispatch: Bool) async throws
    {
        let fixture = try FileExecutionOwnerFixture()
        let focus = FileExecutionOwnerFocusStub()
        focus.records = [
            .accepted(.init(mechanism: .accessibilityValue, mode: .foreground)),
            .mayHaveDispatched(.init(mechanism: .accessibilityAction, mode: .foreground)),
        ]
        focus.failsAfterDispatch = throwsAfterDispatch
        let outcome: DesktopActionOutcome
        do {
            outcome = try await fixture.service(focus: focus).focusFileExecution(fixture.execution())
            #expect(!throwsAfterDispatch)
        } catch let failure as DesktopActionFailure {
            #expect(throwsAfterDispatch)
            outcome = failure.outcome
        }

        #expect(focus.focusCalls.count == 1)
        #expect(outcome.state == .indeterminate)
        #expect(outcome.delivery == .init(mechanism: .composite, mode: .foreground))
        #expect(outcome.dispatchState == .mayHaveDispatched(unitCount: .init(2)))
        #expect(outcome.retrySafety == .unsafe)
    }

    @Test
    func `bounded file controls never enter nested sheets or foreign application roots`() async throws {
        let fixture = try FileExecutionOwnerFixture()
        let field = FileExecutionOwnerFixture.element(11)
        let textArea = FileExecutionOwnerFixture.element(12)
        let nested = FileExecutionOwnerFixture.element(13)
        let application = FileExecutionOwnerFixture.element(14)
        let forbidden = FileExecutionOwnerFixture.element(15)
        fixture.add(fixture.panel, role: "AXSheet", children: [field, nested, application, textArea, field])
        fixture.add(field, role: "AXTextField", children: [fixture.panel])
        fixture.add(textArea, role: "AXTextArea")
        fixture.add(nested, role: "AXSheet", children: [forbidden])
        fixture.add(application, role: "AXApplication", children: [forbidden])
        let budget = try DialogOperationDeadline.bounded(timeoutSeconds: 5, operationName: "file controls test")

        let controls = try await DialogOperationDeadline.$current.withValue(budget) {
            try await fixture.service().fileDialogControls(
                in: fixture.panel, execution: fixture.execution(), role: "AXTextField")
        }

        #expect(controls == [field, textArea])
        #expect(fixture.visited == [fixture.panel, field, nested, application, textArea])
        #expect(fixture.deadlines.allSatisfy { $0 == budget.deadline })
        #expect(fixture.owners.allSatisfy { $0 == fixture.target.identity.processIdentity })
    }

    @Test
    func `bounded file controls propagate incomplete hierarchy instead of returning a partial list`() async throws {
        let fixture = try FileExecutionOwnerFixture()
        let field = FileExecutionOwnerFixture.element(11)
        let unreadable = FileExecutionOwnerFixture.element(12)
        fixture.add(fixture.panel, role: "AXSheet", children: [field, unreadable])
        fixture.add(field, role: "AXTextField")

        await #expect(throws: FileExecutionOwnerTestError.missingNode) {
            try await fixture.service().fileDialogControls(
                in: fixture.panel, execution: fixture.execution(), role: "AXTextField")
        }
        #expect(fixture.visited == [fixture.panel, field, unreadable])
    }

    @Test(arguments: [0, 2])
    func `navigation sheet admission rejects absent or multiple nested sheets`(count: Int) async throws {
        let fixture = try FileExecutionOwnerFixture()
        let sheets = (0..<count).map { FileExecutionOwnerFixture.element(Int32(20 + $0)) }
        fixture.add(fixture.panel, role: "AXSheet", children: sheets)
        for sheet in sheets {
            fixture.add(sheet, role: "AXSheet")
        }

        await self.expectNavigationRefusal(fixture)

        #expect(fixture.visited == [fixture.panel] + sheets)
    }

    @Test(arguments: [0, 2])
    func `navigation sheet admission rejects absent or ambiguous enabled fields`(count: Int) async throws {
        let fixture = try FileExecutionOwnerFixture()
        let sheet = FileExecutionOwnerFixture.element(20)
        let fields = (0..<count).map { FileExecutionOwnerFixture.element(Int32(30 + $0)) }
        fixture.add(fixture.panel, role: "AXSheet", children: [sheet])
        fixture.add(sheet, role: "AXSheet", children: fields)
        for field in fields {
            fixture.add(field, role: "AXTextField")
        }

        await self.expectNavigationRefusal(fixture)
    }

    @Test
    func `navigation retains nested sheet and field without replacing the file panel`() async throws {
        let fixture = try FileExecutionOwnerFixture()
        let group = FileExecutionOwnerFixture.element(19)
        let sheet = FileExecutionOwnerFixture.element(20)
        let enabled = FileExecutionOwnerFixture.element(30)
        let disabled = FileExecutionOwnerFixture.element(31, enabled: false)
        fixture.add(fixture.panel, role: "AXSheet", children: [group])
        fixture.add(group, role: "AXGroup", children: [sheet, sheet, fixture.panel])
        fixture.add(sheet, role: "AXSheet", children: [enabled, disabled, enabled])
        fixture.add(enabled, role: "AXTextArea")
        fixture.add(disabled, role: "AXTextField")
        let execution = try fixture.execution()
        let budget = try DialogOperationDeadline.bounded(timeoutSeconds: 5, operationName: "navigation test")

        let navigation = try await DialogOperationDeadline.$current.withValue(budget) {
            try await fixture.service().resolveFileNavigationSheet(execution)
        }

        #expect(navigation.dialog == sheet)
        #expect(navigation.field == enabled)
        #expect(execution.window == fixture.parent)
        #expect(execution.resolution.element == fixture.panel)
        #expect(execution.target == fixture.target)
        #expect(fixture.visited == [fixture.panel, group, sheet, sheet, enabled, disabled])
        #expect(fixture.deadlines.allSatisfy { $0 == budget.deadline })
        #expect(fixture.owners.allSatisfy { $0 == fixture.target.identity.processIdentity })
    }

    @Test
    func `navigation sheet cannot borrow another parent window or application descendant`() async throws {
        let fixture = try FileExecutionOwnerFixture()
        let otherWindow = FileExecutionOwnerFixture.element(21)
        let otherApplication = FileExecutionOwnerFixture.element(22)
        let forbiddenSheet = FileExecutionOwnerFixture.element(23)
        fixture.add(fixture.panel, role: "AXSheet", children: [otherWindow, otherApplication])
        fixture.add(otherWindow, role: "AXWindow", children: [forbiddenSheet])
        fixture.add(otherApplication, role: "AXApplication", children: [forbiddenSheet])

        await self.expectNavigationRefusal(fixture)

        #expect(fixture.visited == [fixture.panel, otherWindow, otherApplication])
    }

    @Test
    func `one readable navigation sheet does not hide an unreadable sibling`() async throws {
        let fixture = try FileExecutionOwnerFixture()
        let sheet = FileExecutionOwnerFixture.element(20)
        let unreadable = FileExecutionOwnerFixture.element(21)
        fixture.add(fixture.panel, role: "AXSheet", children: [sheet, unreadable])
        fixture.add(sheet, role: "AXSheet")

        await #expect(throws: FileExecutionOwnerTestError.missingNode) {
            try await fixture.service().resolveFileNavigationSheet(fixture.execution())
        }
        #expect(fixture.visited == [fixture.panel, sheet, unreadable])
    }

    private func expectPlanningRefusal(_ operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("Expected file owner planning refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        } catch {
            Issue.record(error)
        }
    }

    private func expectNavigationRefusal(_ fixture: FileExecutionOwnerFixture) async {
        do {
            _ = try await fixture.service().resolveFileNavigationSheet(fixture.execution())
            Issue.record("Expected nested file navigation refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(failure.outcome.dispatchState == .none)
        } catch {
            Issue.record(error)
        }
    }
}

private enum FileExecutionOwnerTestError: Error, Equatable {
    case missingNode
    case focusFailed
    case unexpectedFocusPath
}

@MainActor
private final class FileExecutionOwnerFixture {
    let parent = FileExecutionOwnerFixture.element(1)
    let panel = FileExecutionOwnerFixture.element(2)
    let target: UIAutomationTarget.ExactWindow
    let evidence: ResolvedDialogTargetEvidence
    let request: DialogFileExecutionRequest
    var nodes: [Element: DialogHierarchyNode] = [:]
    var visited: [Element] = []
    var deadlines: [ContinuousClock.Instant] = []
    var owners: [ApplicationProcessIdentity] = []

    init(focus: DialogForegroundFocusPolicy = .init()) throws {
        self.target = try Self.target()
        self.evidence = try Self.evidence(target: self.target)
        self.request = try DialogFileExecutionRequest(
            target: DialogTargetSelector(processIdentifier: 42, windowID: 700), focus: focus)
    }

    func resolution(
        target: UIAutomationTarget.ExactWindow? = nil,
        title: String = "Parent Document") throws -> DialogService.FileDialogElementResolution
    {
        let target = target ?? self.target
        return try DialogService.FileDialogElementResolution(
            element: self.panel,
            dialogIdentifier: "save-panel",
            foundVia: "targeted_dialog",
            target: target,
            window: self.parent,
            resolvedTarget: Self.evidence(target: target, title: title))
    }

    func execution() throws -> DialogService.FileExecution {
        try DialogService.FileExecution(request: self.request, resolution: self.resolution())
    }

    func add(_ element: Element, role: String, children: [Element] = []) {
        self.nodes[element] = DialogHierarchyNode(
            evidence: DialogElementEvidence(
                role: role, subrole: "", roleDescription: "", identifier: "", title: ""),
            children: children)
    }

    func service(focus: FileExecutionOwnerFocusStub = FileExecutionOwnerFocusStub()) -> DialogService {
        var readers = DialogDiscoveryReaders()
        readers.hierarchyNode = { element, owner, budget in
            self.visited.append(element)
            self.deadlines.append(budget.deadline)
            self.owners.append(owner)
            guard let node = self.nodes[element] else { throw FileExecutionOwnerTestError.missingNode }
            return node
        }
        return DialogService(
            syntheticInputDriver: SyntheticInputDriver(),
            discoveryReaders: readers,
            focusService: focus)
    }

    static func element(_ identity: Int32, enabled: Bool = true) -> Element {
        Element(
            AXUIElementCreateApplication(-identity),
            attributes: ["AXEnabled": .bool(enabled)],
            children: [],
            actions: [])
    }

    static func target(
        windowID: Int = 700,
        generation: UInt64 = 9001,
        bounds: CGRect = CGRect(x: 10, y: 20, width: 300, height: 200)) throws -> UIAutomationTarget.ExactWindow
    {
        try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: windowID,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: generation,
                capturedBounds: bounds),
            bounds: bounds)
    }

    static func evidence(
        target: UIAutomationTarget.ExactWindow,
        title: String = "Parent Document") throws -> ResolvedDialogTargetEvidence
    {
        let window = ServiceWindowInfo(
            windowID: target.identity.windowID,
            title: title,
            bounds: target.bounds,
            index: 2,
            mutationIdentity: target.identity)
        let proof = try WindowSelectorResolutionProof.make(
            selection: .title(title),
            candidates: [window],
            selected: window,
            processIdentity: target.identity.processIdentity)
        return try ResolvedDialogTargetEvidence(
            target: target,
            application: ServiceApplicationInfo(
                processIdentifier: 42,
                processStartIdentity: target.identity.ownerProcessStartIdentity,
                bundleIdentifier: "dev.peekaboo.fixture",
                name: "Fixture"),
            window: window,
            windowResolutionProof: proof)
    }
}

@MainActor
private final class FileExecutionOwnerFocusStub: DialogFocusManaging {
    struct FocusCall {
        let target: UIAutomationTarget.ExactWindow
        let window: Element
        let dialog: Element
        let options: FocusManagementService.FocusOptions
    }

    struct RequireCall {
        let target: UIAutomationTarget.ExactWindow
        let window: Element
        let dialog: Element
        let timeout: TimeInterval
    }

    var records: [FocusDispatchRecord] = []
    var failsAfterDispatch = false
    var focusCalls: [FocusCall] = []
    var requireCalls: [RequireCall] = []

    func focusFileDialogWindowWithOwnedLane(
        target: UIAutomationTarget.ExactWindow,
        window: Element,
        dialog: Element,
        options: FocusManagementService.FocusOptions,
        onDispatch: @escaping (FocusDispatchRecord) -> Void) async throws
    {
        self.focusCalls.append(.init(target: target, window: window, dialog: dialog, options: options))
        for record in self.records {
            onDispatch(record)
        }
        if self.failsAfterDispatch {
            throw FileExecutionOwnerTestError.focusFailed
        }
    }

    func requireFileDialogWindowFocusWithOwnedLane(
        target: UIAutomationTarget.ExactWindow,
        window: Element,
        dialog: Element,
        timeout: TimeInterval) async throws
    {
        self.requireCalls.append(.init(target: target, window: window, dialog: dialog, timeout: timeout))
    }

    func focusWindowWithOwnedLane(
        windowID _: CGWindowID,
        options _: FocusManagementService.FocusOptions,
        expectedIdentity _: WindowMutationIdentity?) async throws
    {
        throw FileExecutionOwnerTestError.unexpectedFocusPath
    }

    func focusDialogWindowWithOwnedLane(
        target _: UIAutomationTarget.ExactWindow,
        dialog _: Element,
        options _: FocusManagementService.FocusOptions) async throws
    {
        throw FileExecutionOwnerTestError.unexpectedFocusPath
    }

    func requireDialogWindowFocusWithOwnedLane(
        target _: UIAutomationTarget.ExactWindow,
        dialog _: Element,
        timeout _: TimeInterval) async throws
    {
        throw FileExecutionOwnerTestError.unexpectedFocusPath
    }

    func requireFileDialogDispatchFocus(
        target _: UIAutomationTarget.ExactWindow,
        window _: Element,
        dialog _: Element,
        field _: Element?) throws
    {
        throw FileExecutionOwnerTestError.unexpectedFocusPath
    }

    func requireDialogDispatchFocus(
        target _: UIAutomationTarget.ExactWindow,
        retainedWindow _: Element,
        dialog _: Element,
        field _: Element) throws
    {
        throw FileExecutionOwnerTestError.unexpectedFocusPath
    }

    func requireDialogGlobalKeyboardFocus(
        target _: UIAutomationTarget.ExactWindow,
        retainedWindow _: Element,
        dialog _: Element) throws
    {
        throw FileExecutionOwnerTestError.unexpectedFocusPath
    }
}
