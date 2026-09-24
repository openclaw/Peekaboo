import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@Suite(.serialized)
@MainActor
struct ApplicationInventoryAbsenceTests {
    @Test
    func `two native absence observations exclude stale LaunchServices entries from read inventory`() async throws {
        let stalePID: pid_t = 41901
        let reads = AutomationTestLockedValue(0)
        let metadataPIDs = AutomationTestLockedValue<[pid_t]>([])
        let service = Self.service(
            stalePID: stalePID,
            observation: { _ in
                reads.withValue { $0 += 1 }
                return .absent
            },
            metadataPIDs: metadataPIDs)

        let output = try await service.listApplications()

        #expect(output.summary.status == .success)
        #expect(output.metadata.warnings.isEmpty)
        #expect(output.data.applications.map(\.processIdentifier) == [Self.livePID])
        #expect(metadataPIDs.value == [Self.livePID])
        #expect(reads.value == 2)
    }

    @Test
    func `uncertain and changing absence never upgrade an incomplete listing to success`() async throws {
        let transitions: [[SystemIdentityResolver.ProcessStartIdentityObservation]] = [
            [.absent, .identity(92)],
            [.absent, .permissionDenied],
            [.absent, .unavailable],
            [.permissionDenied, .absent],
            [.unavailable, .absent],
        ]
        for observations in transitions {
            let reads = AutomationTestLockedValue(0)
            let service = Self.service(
                stalePID: 41902,
                observation: { _ in
                    reads.withValue { index in
                        defer { index += 1 }
                        return observations[min(index, observations.count - 1)]
                    }
                },
                metadataPIDs: AutomationTestLockedValue([]))

            let output = try await service.listApplications()

            #expect(output.summary.status == .partial)
            #expect(output.metadata.warnings.contains { $0.contains("Process-generation identity was unavailable") })
            #expect(Set(output.data.applications.map(\.processIdentifier)) == [Self.livePID, 41902])
            #expect(reads.value <= 2)
        }
    }

    @Test
    func `a genuinely reaped child cannot poison unrelated read-only verification inventory`() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        let deadPID = child.processIdentifier
        #expect(SystemIdentityResolver.processStartIdentityObservation(deadPID) == .absent)
        let reads = AutomationTestLockedValue(0)
        let service = Self.service(
            stalePID: deadPID,
            observation: { pid in
                reads.withValue { $0 += 1 }
                return SystemIdentityResolver.processStartIdentityObservation(pid)
            },
            metadataPIDs: AutomationTestLockedValue([]))

        let output = try await service.listApplications()

        #expect(output.summary.status == .success)
        #expect(output.metadata.warnings.isEmpty)
        #expect(output.data.applications.map(\.processIdentifier) == [Self.livePID])
        #expect(reads.value == 2)
    }

    private static let livePID: pid_t = 41900

    private static func service(
        stalePID: pid_t,
        observation: @escaping ApplicationService.MutationIdentityObservationProvider,
        metadataPIDs: AutomationTestLockedValue<[pid_t]>) -> ApplicationService
    {
        let livePID = Self.livePID
        return ApplicationService(
            applicationOpenHandler: { _, _, _ in throw FixtureError.unused },
            frontmostProcessIdentifierProvider: { nil },
            processStartIdentityProvider: { $0 == livePID ? 90 : nil },
            mutationIdentityObservationProvider: { pid in
                #expect(pid == stalePID)
                return observation(pid)
            },
            mutationEligibilityProvider: { _ in
                Issue.record("Read inventory absence must not reinterpret a permission denial")
                return nil
            },
            runningApplicationProcessIdentifiersProvider: { [livePID, stalePID] },
            applicationWindowCatalogProvider: { [] },
            applicationMetadataProvider: { pid, _, _ in
                metadataPIDs.withValue { $0.append(pid) }
                return DetachedApplicationMetadata(
                    bundleIdentifier: "com.example.fixture.\(pid)",
                    name: pid == livePID ? "Editor" : "Stale Helper",
                    bundlePath: nil,
                    isHidden: false,
                    activationPolicy: .regular,
                    isFinishedLaunching: true)
            })
    }

    private enum FixtureError: Error {
        case unused
    }
}
