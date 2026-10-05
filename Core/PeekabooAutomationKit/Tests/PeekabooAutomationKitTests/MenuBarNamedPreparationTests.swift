import ApplicationServices
import CoreGraphics
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct MenuBarNamedPreparationTests {
    @Test
    func `ordinary listing preserves CG items and never starts named AX discovery`() async throws {
        let fixture = Fixture()
        fixture.snapshotsError = MenuExtraAXReader.incomplete
        let extras = try await fixture.service.listMenuExtras()
        #expect(fixture.reads == 0)
        #expect(extras.count == 1)
        #expect(extras[0].windowID == 700)
        #expect(extras[0].ownerPID == 10)
    }

    @Test
    func `named preparation replaces a proxy with complete AX owner evidence`() async throws {
        let fixture = Fixture()
        let item = try await fixture.service.prepareMenuBarItem(named: "  Fíxture  ")
        let evidence = try #require(item.selectionEvidence)
        #expect(fixture.submissions == 0)
        #expect(item.rawOwnerPID == 42)
        #expect(item.rawWindowID == nil)
        #expect(item.bundleIdentifier == "dev.fixture")
        #expect(evidence.selectedProcessIdentity == fixture.owner)
        #expect(evidence.selectedTargetReceipt.windowID == nil)
        #expect(evidence.selectedFrame == fixture.frame)
        #expect(evidence.normalizedSelector == "fixture")
    }

    @Test
    func `existing displayed CG name requests retain their window route without AX preparation`() async throws {
        let fixture = Fixture()
        fixture.snapshotsError = MenuExtraAXReader.incomplete
        let items = try await fixture.service.listMenuBarItems(includeRaw: true)
        let evidence = try #require(items.first?.selectionEvidence).selecting(
            normalizedSelector: "fixture", matchKind: .exact)
        let selection = try await fixture.service.displayedMenuBarSelection(
            named: "Fixture",
            expectedEvidence: evidence)
        #expect(selection?.candidate.value.rawWindowID == 700)
        #expect(selection?.candidate.value.rawOwnerPID == 10)
        #expect(fixture.reads == 0)
    }

    @Test
    func `same-owner CG records keep their exact window receipt`() async throws {
        let fixture = Fixture()
        fixture.windows = [fixture.window(owner: 42, bundle: "dev.fixture")]
        let item = try await fixture.service.prepareMenuBarItem(named: "Fixture")
        #expect(item.rawWindowID == 700)
        #expect(item.selectionEvidence?.selectedTargetReceipt.windowID == 700)
        #expect(item.selectionEvidence?.selectedProcessIdentity == fixture.owner)
    }

    @Test
    func `different AX owners with the same title remain ambiguous`() async throws {
        let fixture = Fixture()
        fixture.snapshots.append(fixture.snapshot(pid: 43, raw: 953_002))
        do {
            _ = try await fixture.service.prepareMenuBarItem(named: "Fixture")
            Issue.record("Expected ambiguous owner refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.refusalReason == .invalidRequest)
        }
        #expect(fixture.submissions == 0)
    }

    @Test
    func `incomplete AX inventory cannot fall through to a CG name match`() async throws {
        let fixture = Fixture()
        fixture.snapshotsError = MenuExtraAXReader.incomplete
        await #expect(throws: PeekabooError.self) { try await fixture.service.prepareMenuBarItem(named: "Fixture") }
        #expect(fixture.submissions == 0)
    }

    @Test
    func `prepared AX request dispatches once with the same process-only receipt`() async throws {
        let fixture = Fixture()
        let item = try await fixture.service.prepareMenuBarItem(named: "Fíxture")
        let evidence = try #require(item.selectionEvidence)
        let result = try await fixture.service.clickMenuBarItemActionResult(request: .init(
            named: "Fíxture", expectedLeafEvidence: evidence))
        #expect(fixture.submissions == 1)
        #expect(result.targetIdentity?.processIdentity == fixture.owner)
        #expect(result.targetIdentity?.exactWindow == nil)
        #expect(result.selectedLeafEvidence?.first?.hasSameResolvedLeaf(as: evidence) == true)
        #expect(result.outcome?.delivery == .init(mechanism: .accessibilityAction, mode: .foreground))
    }

    @Test
    func `changed owner refuses the retained request before submission`() async throws {
        let fixture = Fixture()
        let item = try await fixture.service.prepareMenuBarItem(named: "Fixture")
        let evidence = try #require(item.selectionEvidence)
        fixture.snapshots = [fixture.snapshot(pid: 43, raw: 953_002)]
        await #expect(throws: DesktopActionFailure.self) {
            try await fixture.service.clickMenuBarItemActionResult(request: .init(
                named: "Fixture", expectedLeafEvidence: evidence))
        }
        #expect(fixture.submissions == 0)
    }

    @Test
    func `replaced native leaf between resolution and dispatch refuses despite matching metadata`() async throws {
        let fixture = Fixture()
        let item = try await fixture.service.prepareMenuBarItem(named: "Fixture")
        let evidence = try #require(item.selectionEvidence)
        fixture.replaceLeafOnRead = 3
        await #expect(throws: DesktopActionFailure.self) {
            try await fixture.service.clickMenuBarItemActionResult(request: .init(
                named: "Fixture", expectedLeafEvidence: evidence))
        }
        #expect(fixture.submissions == 0)
    }

    @Test
    func `indeterminate AX submission keeps owner evidence and never retries another route`() async throws {
        let fixture = Fixture()
        fixture.submissionFails = true
        do {
            _ = try await fixture.service.clickMenuBarItemActionResult(named: "Fixture")
            Issue.record("Expected indeterminate submission")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.targetReceipt?.processIdentifier == 42)
            #expect(failure.selectedLeafEvidence?.first?.selectedTargetReceipt.windowID == nil)
        }
        #expect(fixture.submissions == 1)
    }

    @MainActor
    private final class Fixture {
        let owner = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 99)
        let frame = CGRect(x: 100, y: 5, width: 20, height: 20)
        var snapshots: [MenuExtraAXSnapshot] = []
        var windows: [MenuExtraInfo] = []
        var snapshotsError: PeekabooError?
        var replaceLeafOnRead: Int?
        var submissionFails = false
        var reads = 0
        var submissions = 0
        lazy var service: MenuService = {
            var readers = MenuExtraDiscoveryReaders()
            readers.snapshots = {
                self.reads += 1
                if let error = self.snapshotsError {
                    throw error
                }
                if self.reads == self.replaceLeafOnRead {
                    self.snapshots = [self.snapshot(raw: 953_002)]
                }
                return self.snapshots
            }
            readers.windowExtras = { self.windows }
            readers.windowIdentity = { id in
                guard let item = self.windows.first(where: { $0.windowID == id }), let pid = item.ownerPID else {
                    return nil
                }
                return WindowMutationIdentity(
                    windowID: Int(id),
                    ownerProcessIdentifier: pid,
                    ownerProcessStartIdentity: 99,
                    capturedBounds: self.frame)
            }
            readers.processGeneration = { _ in 99 }
            readers.application = { _ in ("Fixture", "dev.fixture") }
            readers.displayBounds = { [CGRect(x: 0, y: 0, width: 1000, height: 800)] }
            readers.submit = { _, _ in
                self.submissions += 1
                if self.submissionFails {
                    throw MenuExtraAXReader.incomplete
                }
            }
            return MenuService(operationLaneCoordinator: .init(), menuExtraReaders: readers)
        }()

        init() {
            self.snapshots = [self.snapshot()]
            self.windows = [self.window()]
        }

        func snapshot(pid: pid_t = 42, raw: pid_t = 953_001) -> MenuExtraAXSnapshot {
            MenuExtraAXSnapshot(
                identity: .init(element: AXUIElementCreateApplication(raw)),
                processIdentity: .init(processIdentifier: pid, processStartIdentity: 99),
                title: "Fixture",
                help: nil,
                description: nil,
                identifier: "dev.fixture.status",
                role: "AXMenuBarItem",
                subrole: nil,
                frame: self.frame,
                actions: ["AXPress"])
        }

        func window(owner: pid_t = 10, bundle: String = "com.apple.controlcenter") -> MenuExtraInfo {
            MenuExtraInfo(
                title: "Fixture",
                bundleIdentifier: bundle,
                ownerName: "Fixture",
                position: CGPoint(x: self.frame.midX, y: self.frame.midY),
                windowID: 700,
                ownerPID: owner,
                source: "cgs")
        }
    }
}
