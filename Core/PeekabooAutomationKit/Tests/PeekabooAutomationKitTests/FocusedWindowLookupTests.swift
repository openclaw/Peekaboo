import CoreGraphics
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct FocusedWindowLookupTests {
    @Test
    func `duplicate app names use only the frontmost PID`() async throws {
        let fixture = FocusedWindowFixture()
        #expect(try await fixture.lookup.capture()?.windowID == 201)
        #expect(fixture.applications.listWindowsRequests.map(\.identifier) == ["PID:101"])
        #expect(fixture.focusedPIDs == [101])
    }

    @Test
    func `missing native focus never returns the best ranked window`() async throws {
        let fixture = FocusedWindowFixture()
        fixture.focusedID = nil
        #expect(ObservationTargetResolver.bestWindow(from: fixture.windows)?.windowID == 201)
        #expect(try await fixture.lookup.capture() == nil)
        #expect(fixture.exactIDs.isEmpty)
    }

    @Test
    func `native focus on a sibling wins over inventory ranking`() async throws {
        let fixture = FocusedWindowFixture()
        fixture.focusedID = 202
        #expect(ObservationTargetResolver.bestWindow(from: fixture.windows)?.windowID == 201)
        #expect(try await fixture.lookup.capture()?.windowID == 202)
    }

    @Test(arguments: ["same-owner", "other-owner", "no-owner", "missing", "not-found", "wrong-id"])
    func `missing inventory ID requires an exact window owned by the frontmost process`(result: String) async throws {
        let fixture = FocusedWindowFixture()
        fixture.focusedID = 303
        let owner = AutomationTestFixtures.processIdentity(
            processIdentifier: result == "other-owner" ? 102 : 101)
        fixture.exactWindows = [AutomationTestFixtures.window(
            windowID: result == "wrong-id" ? 304 : 303,
            processIdentity: owner,
            includesMutationIdentity: result != "no-owner")]
        if result == "missing" {
            fixture.exactWindows = []
        } else if result == "not-found" {
            fixture.exactError = PeekabooError.windowNotFound(criteria: "fixture")
        }
        #expect(try await fixture.lookup.capture()?.windowID == (result == "same-owner" ? 303 : nil))
        #expect(fixture.exactIDs == [303])
    }

    @Test(arguments: ["changed", "missing-before", "missing-after", "changed-after-exact"])
    func `unreadable or changed process generation refuses focus`(fault: String) async throws {
        let fixture = FocusedWindowFixture()
        fixture.generation = fault == "missing-before" ? nil : 1001
        fixture.afterInventory = {
            fixture.generation = fault == "missing-after" ? nil : 1002
        }
        if fault == "changed-after-exact" {
            fixture.afterInventory = {}
            fixture.focusedID = 303
            fixture.exactWindows = [AutomationTestFixtures.window(windowID: 303)]
            fixture.afterExact = { fixture.generation = 1002 }
        }
        #expect(try await fixture.lookup.capture() == nil)
    }

    @Test(arguments: ["inventory", "exact", "native"])
    func `real lookup errors propagate`(source: String) async {
        let fixture = FocusedWindowFixture()
        switch source {
        case "inventory": fixture.inventoryError = FocusedWindowFixtureError.unavailable
        case "exact":
            fixture.focusedID = 303
            fixture.exactError = FocusedWindowFixtureError.unavailable
        default: fixture.nativeError = FocusedWindowFixtureError.unavailable
        }
        await #expect(throws: FocusedWindowFixtureError.unavailable) {
            try await fixture.lookup.capture()
        }
    }

    @Test
    func `frontmost listing ranks windows from the exact process`() async throws {
        let fixture = FocusedWindowFixture()
        let service = WindowManagementService(applicationService: fixture.applications)
        #expect(try await service.listWindows(target: .frontmost).map(\.windowID) == [201])
        #expect(fixture.applications.listWindowsRequests.map(\.identifier) == ["PID:101"])
    }

    @Test
    func `title substring lookup lists both same named processes by PID`() async throws {
        let fixture = FocusedWindowFixture()
        let service = WindowManagementService(applicationService: fixture.applications)
        #expect(try await service.listWindows(target: .title("document")).map(\.windowID) == [201, 401])
        #expect(fixture.applications.listWindowsRequests.map(\.identifier) == ["PID:101", "PID:102"])
    }
}

private enum FocusedWindowFixtureError: Error {
    case unavailable
}

@MainActor
private final class FocusedWindowFixture {
    let windows = [
        AutomationTestFixtures.window(windowID: 201, title: "Document", isFrontmost: true),
        AutomationTestFixtures.window(
            windowID: 202, title: "Other", isMainWindow: false, isKeyWindow: false, index: 1),
    ]
    let applications: ScriptedApplicationInventoryService
    var focusedID: Int? = 201
    var generation: UInt64? = 1001
    var exactWindows: [ServiceWindowInfo] = []
    var exactIDs: [Int] = []
    var focusedPIDs: [pid_t] = []
    var inventoryError: (any Error)?
    var exactError: (any Error)?
    var nativeError: (any Error)?
    var afterInventory: () -> Void = {}
    var afterExact: () -> Void = {}

    init() {
        self.applications = ScriptedApplicationInventoryService(
            applications: [
                AutomationTestFixtures.application(
                    name: "Arc", isActive: true, activationPolicy: .regular),
                AutomationTestFixtures.application(
                    processIdentifier: 102, name: "Arc", activationPolicy: .regular),
            ],
            windowsByIdentifier: [
                "PID:101": self.windows,
                "PID:102": [AutomationTestFixtures.window(
                    windowID: 401,
                    title: "Second Document",
                    processIdentity: AutomationTestFixtures.processIdentity(processIdentifier: 102))],
            ])
    }

    var lookup: FocusedWindowLookup {
        FocusedWindowLookup(
            frontmostApplication: { try await self.applications.getFrontmostApplication() },
            listWindows: { identifier in
                if let error = self.inventoryError {
                    throw error
                }
                let windows = try await self.applications.listWindows(for: identifier, timeout: nil).data.windows
                self.afterInventory()
                return windows
            },
            windowByID: { id in
                self.exactIDs.append(id)
                if let error = self.exactError {
                    throw error
                }
                self.afterExact()
                return self.exactWindows
            },
            focusedWindowID: { pid in
                self.focusedPIDs.append(pid)
                if let error = self.nativeError {
                    throw error
                }
                return self.focusedID
            },
            processStartIdentity: { pid in
                #expect(pid == 101)
                return self.generation
            })
    }
}
