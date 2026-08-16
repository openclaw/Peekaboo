import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct ApplicationMutationSelectorTests {
    @Test
    func `mutation selection admits exact PID bundle and localized name through the canonical grammar`() throws {
        let application = AutomationTestFixtures.application()

        #expect(try self.select("PID:101", from: [application]).resolution.matchKind == .processIdentifier)
        #expect(try self.select("com.example.TestApp", from: [application]).resolution.matchKind == .bundleIdentifier)
        #expect(try self.select("test app", from: [application]).resolution.matchKind == .exactName)
    }

    @Test
    func `duplicate exact applications refuse with stable sorted PID guidance`() {
        let applications = AutomationTestFixtures.duplicateApplications()
        let expected = DesktopTargetPlanningError.ambiguousApplication(
            identifier: "com.example.Shared",
            candidatePIDs: [101, 202])

        #expect(throws: expected) {
            _ = try self.select("com.example.Shared", from: applications)
        }
        #expect(throws: expected) {
            _ = try self.select("com.example.Shared", from: applications.reversed())
        }
    }

    @Test
    func `path executable and fuzzy selectors retain read compatibility but cannot authorize mutation`() throws {
        let application = ServiceApplicationInfo(
            processIdentifier: 101,
            processStartIdentity: 1001,
            bundleIdentifier: "com.example.OpenClaw",
            name: "OpenClaw Desktop Test",
            bundlePath: "/Applications/OpenClaw Desktop Test.app",
            executablePath: "/Applications/OpenClaw Desktop Test.app/Contents/MacOS/openclaw-desktop")
        let candidate = ApplicationIdentifierMatcher.Candidate(application)
        let selectors = [
            "/Applications/OpenClaw Desktop Test.app",
            "openclaw-desktop",
            "OpenClaw",
        ]

        for selector in selectors {
            #expect(ApplicationIdentifierMatcher.matches(candidate, identifier: selector))
            #expect(throws: DesktopTargetPlanningError.unsupportedApplicationIdentifier(
                identifier: selector,
                candidatePIDs: [101]))
            {
                _ = try self.select(selector, from: [application])
            }
        }
    }

    @Test
    func `empty malformed and oversized inventories fail closed`() {
        let application = AutomationTestFixtures.application()

        #expect(throws: DesktopTargetPlanningError.invalidSelector(.emptyApplication)) {
            _ = try self.select("  ", from: [application])
        }
        #expect(throws: DesktopTargetPlanningError.invalidSelector(.invalidApplicationProcessIdentifier)) {
            _ = try self.select("PID:0", from: [application])
        }

        let oversized = (0...ApplicationIdentifierMatcher.maximumProofCandidateCount).map { index in
            AutomationTestFixtures.application(
                processIdentifier: Int32(index + 1),
                processStartIdentity: UInt64(index + 1),
                bundleIdentifier: "com.example.\(index)",
                name: "Fixture \(index)")
        }
        #expect(throws: DesktopTargetPlanningError.applicationInventoryUnavailable(identifier: "Fixture")) {
            _ = try self.select("Fixture", from: oversized)
        }
    }

    private func select(
        _ identifier: String,
        from applications: some Sequence<ServiceApplicationInfo>) throws
        -> DesktopTargetPlanning.ApplicationSelection
    {
        try DesktopTargetPlanning.ApplicationMutationSelector.select(
            identifier: identifier,
            applications: Array(applications))
    }
}
