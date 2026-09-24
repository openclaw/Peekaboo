import Foundation
import PeekabooBridge
import PeekabooBridgeTestSupport
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct PeekabooBridgeApplicationRunningStateTests {
    @Test(arguments: RunningStateScenario.allCases)
    func `Production running state crosses a real Bridge socket`(scenario: RunningStateScenario) async throws {
        let socketPath = "/tmp/peekaboo-running-state-\(UUID().uuidString).sock"
        let server = await MainActor.run {
            let applications = ApplicationService(
                applicationOpenHandler: { _, _, _ in throw PeekabooError.notImplemented("Unexpected launch") },
                applicationSelectorCandidatesProvider: { scenario.candidates })
            return PeekabooBridgeServer(
                services: StubServices(applications: applications, snapshots: InMemorySnapshotManager()),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [])
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        do {
            let client = BridgeTestFixtures.authenticatedClient(socketPath: socketPath, requestTimeoutSec: 2)
            _ = try await client.handshake(client: .init(
                bundleIdentifier: "dev.peekaboo.running-state-tests",
                teamIdentifier: nil,
                processIdentifier: getpid()))
            let remote = await MainActor.run { RemoteApplicationService(client: client) }

            if let expected = scenario.expectedRunning {
                #expect(try await remote.isApplicationRunning(identifier: scenario.identifier) == expected)
            } else {
                do {
                    _ = try await remote.isApplicationRunning(identifier: scenario.identifier)
                    Issue.record("Lookup failure must cross Bridge as an error, not a Boolean")
                } catch let error as PeekabooBridgeErrorEnvelope {
                    #expect(error.code == .internalError)
                    #expect(!error.operationMayHaveCompleted)
                    if scenario == .ambiguous {
                        #expect(error.message.contains("Bridge Notes"))
                        #expect(error.message.contains("PID:701"))
                        #expect(error.message.contains("PID:702"))
                        #expect(!error.message.contains("Unrelated"))
                    } else {
                        #expect(error.details?.contains("candidateSetTooLarge(513)") == true)
                    }
                }
            }
        } catch {
            await host.stop()
            throw error
        }
        await host.stop()
        #expect(!FileManager.default.fileExists(atPath: socketPath))
    }
}

enum RunningStateScenario: CaseIterable, Sendable {
    case unique
    case missing
    case ambiguous
    case resolutionFailure

    var identifier: String {
        switch self {
        case .unique: "PID:701"
        case .missing: "Missing"
        case .ambiguous, .resolutionFailure: "Bridge Notes"
        }
    }

    var expectedRunning: Bool? {
        switch self {
        case .unique: true
        case .missing: false
        case .ambiguous, .resolutionFailure: nil
        }
    }

    var candidates: [ApplicationIdentifierMatcher.Candidate] {
        let first = ApplicationIdentifierMatcher.Candidate(
            processIdentifier: 701,
            bundleIdentifier: "com.example.bridge-notes",
            name: "Bridge Notes")
        switch self {
        case .unique, .missing:
            return [first]
        case .ambiguous:
            return [
                first,
                .init(processIdentifier: 702, bundleIdentifier: "com.example.bridge-notes", name: "Bridge Notes"),
                .init(processIdentifier: 703, bundleIdentifier: "com.example.unrelated", name: "Unrelated"),
            ]
        case .resolutionFailure:
            return Array(repeating: first, count: ApplicationIdentifierMatcher.maximumProofCandidateCount + 1)
        }
    }
}
