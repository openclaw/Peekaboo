import ApplicationServices
import CoreGraphics
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct MenuBarScopedPreparationTests {
    @Test
    func `displayed CG listing and named resolution never start AX owner discovery`() async throws {
        let fixture = Fixture()
        fixture.snapshotsError = MenuExtraAXReader.incomplete
        let items = try await fixture.service.listMenuBarItems(includeRaw: true)
        let selected = try await fixture.service.displayedMenuBarSelection(named: "Fixture")
        #expect(items.count == 1)
        #expect(selected.candidate.value.rawWindowID == 700)
        #expect(selected.candidate.value.selectionEvidence?.selectedTargetReceipt.windowID == 700)
        #expect(fixture.scopes.isEmpty && fixture.readOwners.isEmpty)
    }

    @Test
    func `ambiguous and stale CG requests refuse without attempting AX`() async throws {
        let fixture = Fixture()
        let selected = try await fixture.service.displayedMenuBarSelection(named: "Fixture")
        let evidence = try #require(selected.candidate.value.selectionEvidence)
        fixture.windows.append(fixture.window(id: 701, pid: 11))
        await #expect(throws: DesktopActionFailure.self) {
            try await fixture.service.clickMenuBarItemActionResult(request: .init(
                named: "Fixture", expectedLeafEvidence: evidence))
        }
        fixture.windows = [fixture.window(id: 701, pid: 10)]
        await #expect(throws: DesktopActionFailure.self) {
            try await fixture.service.clickMenuBarItemActionResult(request: .init(
                named: "Fixture", expectedLeafEvidence: evidence))
        }
        #expect(fixture.scopes.isEmpty && fixture.readOwners.isEmpty)
        #expect(fixture.submissions == 0)
    }

    @Test(arguments: [false, true])
    func `app and PID preparation query only the explicit owner without any CG reads`(usePID: Bool) async throws {
        let fixture = Fixture()
        let request = try fixture.request(name: "  Fíxture  ", usePID: usePID)
        let item = try await fixture.service.prepareMenuBarItem(request)
        let evidence = try #require(item.selectionEvidence)
        #expect(fixture.scopes == [request.applicationScope])
        #expect(fixture.readOwners == [fixture.owner])
        #expect(fixture.windowReads == 0)
        #expect(fixture.submissions == 0)
        #expect(item.rawOwnerPID == 42 && item.rawWindowID == nil)
        #expect(item.bundleIdentifier == "dev.fixture")
        #expect(evidence.selectedProcessIdentity == fixture.owner)
        #expect(evidence.selectedTargetReceipt.windowID == nil)
        #expect(evidence.selectedFrame == fixture.frame)
        #expect(evidence.normalizedSelector == "fixture")
    }

    @Test
    func `scoped AX errors never fall through to an available CG name`() async throws {
        let fixture = Fixture()
        fixture.snapshotsError = MenuExtraAXReader.incomplete
        await #expect(throws: PeekabooError.self) {
            try await fixture.service.prepareMenuBarItem(fixture.request())
        }
        #expect(fixture.windowReads == 0 && fixture.submissions == 0)
    }

    @Test(arguments: ["Fixture App", "App", "dev.fixture", "dev."])
    func `scoped item matching never uses application labels`(query: String) async throws {
        let fixture = Fixture()
        fixture.snapshots = [fixture.snapshot(identifier: "native.clock")]
        await #expect(throws: PeekabooError.self) {
            try await fixture.service.prepareMenuBarItem(fixture.request(name: query))
        }
        #expect(fixture.windowReads == 0 && fixture.submissions == 0)
    }

    @Test
    func `scope resolution rejects another app and fuzzy names before any AX lookup`() async throws {
        let fixture = Fixture()
        let fuzzy = try MenuBarItemPreparationRequest(
            name: "Fixture", applicationScope: .init(applicationIdentifier: "Fixture A"))
        await #expect(throws: DesktopActionFailure.self) { try await fixture.service.prepareMenuBarItem(fuzzy) }
        fixture.resolvedPID = 73
        await #expect(throws: DesktopActionFailure.self) {
            try await fixture.service.prepareMenuBarItem(fixture.request(usePID: true))
        }
        #expect(fixture.readOwners.isEmpty && fixture.windowReads == 0 && fixture.submissions == 0)
    }

    @Test
    func `foreign AX leaves and duplicate names within the selected owner refuse`() async throws {
        let fixture = Fixture()
        fixture.snapshots = [fixture.snapshot(pid: 43, raw: 953_002)]
        await #expect(throws: DesktopActionFailure.self) {
            try await fixture.service.prepareMenuBarItem(fixture.request())
        }
        fixture.snapshots = [fixture.snapshot(), fixture.snapshot(raw: 953_002, identifier: "other")]
        do {
            _ = try await fixture.service.prepareMenuBarItem(fixture.request())
            Issue.record("Duplicate status items should remain ambiguous")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.refusalReason == .invalidRequest)
        }
        #expect(fixture.windowReads == 0 && fixture.submissions == 0)
    }

    @Test(arguments: [false, true])
    func `scoped requests retain original owner scope and dispatch exactly once`(usePID: Bool) async throws {
        let fixture = Fixture()
        let preparation = try fixture.request(name: "Fíxture", usePID: usePID)
        let item = try await fixture.service.prepareMenuBarItem(preparation)
        let evidence = try #require(item.selectionEvidence)
        let action = try MenuBarItemActionRequest(
            named: preparation.name, expectedLeafEvidence: evidence, applicationScope: preparation.applicationScope)
        let result = try await fixture.service.clickMenuBarItemActionResult(request: action)
        #expect(fixture.submissions == 1)
        #expect(fixture.windowReads == 0)
        #expect(fixture.scopes == Array(repeating: preparation.applicationScope, count: 3))
        #expect(fixture.readOwners == Array(repeating: fixture.owner, count: 3))
        #expect(result.targetIdentity?.processIdentity == fixture.owner && result.targetIdentity?.exactWindow == nil)
        #expect(result.selectedLeafEvidence?.first?.hasSameResolvedLeaf(as: evidence) == true)
        #expect(result.outcome?.delivery == .init(mechanism: .accessibilityAction, mode: .foreground))
    }

    @Test
    func `replacement generation application name and native leaf refuse before scoped submission`() async throws {
        for replacement in ["generation", "name", "leaf"] {
            let fixture = Fixture()
            let preparation = try fixture.request()
            let item = try await fixture.service.prepareMenuBarItem(preparation)
            let evidence = try #require(item.selectionEvidence)
            if replacement == "generation" {
                fixture.resolvedGeneration = 100
            } else if replacement == "name" {
                fixture.resolvedName = "Different App"
            } else {
                fixture.replaceLeafOnRead = 3
            }
            await #expect(throws: DesktopActionFailure.self) {
                try await fixture.service.clickMenuBarItemActionResult(request: .init(
                    named: preparation.name,
                    expectedLeafEvidence: evidence,
                    applicationScope: preparation.applicationScope))
            }
            #expect(fixture.submissions == 0 && fixture.windowReads == 0)
        }
    }

    @Test
    func `uncertain scoped submission keeps owner evidence and never retries globally`() async throws {
        let fixture = Fixture()
        fixture.submissionFails = true
        let preparation = try fixture.request()
        let item = try await fixture.service.prepareMenuBarItem(preparation)
        let evidence = try #require(item.selectionEvidence)
        do {
            _ = try await fixture.service.clickMenuBarItemActionResult(request: .init(
                named: preparation.name,
                expectedLeafEvidence: evidence,
                applicationScope: preparation.applicationScope))
            Issue.record("Expected indeterminate submission")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.targetReceipt?.processIdentifier == 42)
            #expect(failure.selectedLeafEvidence?.first?.selectedTargetReceipt.windowID == nil)
        }
        #expect(fixture.submissions == 1 && fixture.windowReads == 0)
    }

    @MainActor
    private final class Fixture {
        let owner = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 99)
        let frame = CGRect(x: 100, y: 5, width: 20, height: 20)
        var resolvedPID: pid_t = 42
        var resolvedGeneration: UInt64 = 99
        var resolvedName = "Fixture App"
        var snapshots: [MenuExtraAXSnapshot] = []
        var windows: [MenuExtraInfo] = []
        var snapshotsError: PeekabooError?
        var replaceLeafOnRead: Int?
        var submissionFails = false
        var scopes: [MenuBarApplicationScope] = []
        var readOwners: [ApplicationProcessIdentity] = []
        var windowReads = 0
        var submissions = 0
        lazy var service: MenuService = {
            var readers = MenuExtraDiscoveryReaders()
            readers.resolveOwner = { scope, _, _ in
                self.scopes.append(scope)
                return ServiceApplicationInfo(
                    processIdentifier: self.resolvedPID,
                    processStartIdentity: self.resolvedGeneration,
                    bundleIdentifier: "dev.fixture",
                    name: self.resolvedName)
            }
            readers.snapshots = { owner, _ in
                self.readOwners.append(owner)
                if let error = self.snapshotsError {
                    throw error
                }
                if self.readOwners.count == self.replaceLeafOnRead {
                    self.snapshots = [self.snapshot(raw: 953_002)]
                }
                return self.snapshots
            }
            readers.windowExtras = { self.windowReads += 1; return self.windows }
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

        func request(name: String = "Fixture", usePID: Bool = false) throws -> MenuBarItemPreparationRequest {
            let scope: MenuBarApplicationScope = if usePID {
                try .init(processIdentifier: 42)
            } else {
                try .init(applicationIdentifier: "Fixture App")
            }
            return try .init(name: name, applicationScope: scope)
        }

        func snapshot(pid: pid_t = 42, raw: pid_t = 953_001, identifier: String = "dev.fixture.status")
            -> MenuExtraAXSnapshot
        {
            MenuExtraAXSnapshot(
                identity: .init(element: AXUIElementCreateApplication(raw)),
                processIdentity: .init(processIdentifier: pid, processStartIdentity: 99),
                title: "Fixture",
                help: nil,
                description: nil,
                identifier: identifier,
                role: "AXMenuBarItem",
                subrole: nil,
                frame: self.frame,
                actions: ["AXPress"])
        }

        func window(id: CGWindowID = 700, pid: pid_t = 10) -> MenuExtraInfo {
            MenuExtraInfo(
                title: "Fixture",
                bundleIdentifier: "dev.cg",
                ownerName: "CG Owner",
                position: CGPoint(x: self.frame.midX, y: self.frame.midY),
                windowID: id,
                ownerPID: pid,
                source: "cgs")
        }
    }
}
