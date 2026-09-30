import Foundation
import Testing
@testable import PeekabooAutomationKit

struct ApplicationServiceLaunchSelectorProofTests {
    @Test(arguments: [false, true])
    @MainActor
    func `exact launch proof retains the requested raw bundle path`(ambientCandidate: Bool) async throws {
        let root = URL(fileURLWithPath: "/private/tmp/peekaboo-launch-selector-\(UUID().uuidString)")
        let applicationURL = root.appendingPathComponent("Fixture.app", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = applicationURL.path
        #expect(applicationURL.standardizedFileURL.resolvingSymlinksInPath().path != path)
        let application = Self.application(path: path)
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in throw FixtureError.unexpectedNativeLaunch },
            applicationSelectorCandidatesProvider: {
                ambientCandidate ? [ApplicationIdentifierMatcher.Candidate(application)] : []
            })

        let result = try await service.bindSelectorResolution(
            application,
            launch: Self.launch(path: path))

        let proof = try #require(result.selectorResolutionProofs?.first)
        let identity = try #require(application.processIdentity)
        #expect(proof.normalizedSelector == path)
        #expect(proof.matchKind == .bundlePath)
        #expect(proof.selectedProcessIdentity == identity)
        #expect(proof.candidateCount == 1)
        #expect(!proof.hasWinningTie)
        #expect(proof.applicationMismatch(
            identifier: path,
            selectedCandidate: ApplicationIdentifierMatcher.Candidate(result),
            processIdentity: identity) == nil)
        #expect(proof.applicationMismatch(
            identifier: path,
            selectedCandidate: ApplicationIdentifierMatcher.Candidate(result),
            processIdentity: .init(processIdentifier: identity.processIdentifier, processStartIdentity: 1002)) != nil)
    }

    @Test
    @MainActor
    func `local launch proof retains the existing canonical symlink route`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-launch-alias-\(UUID().uuidString)")
        let applicationURL = root.appendingPathComponent("Fixture.app", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.appendingPathComponent("Alias.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: applicationURL)
        let canonicalPath = applicationURL.standardizedFileURL.resolvingSymlinksInPath().path
        let application = Self.application(path: canonicalPath)
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in throw FixtureError.unexpectedNativeLaunch },
            applicationSelectorCandidatesProvider: { [ApplicationIdentifierMatcher.Candidate(application)] })

        let result = try await service.bindSelectorResolution(application, launch: Self.launch(path: alias.path))

        let proof = try #require(result.selectorResolutionProofs?.first)
        #expect(proof.normalizedSelector == canonicalPath)
        #expect(proof.matchKind == .bundlePath)
        #expect(result.processIdentity == application.processIdentity)
    }

    @Test
    @MainActor
    func `exact launch proof rejects another path with the same app name and bundle ID`() async throws {
        let path = "/private/tmp/peekaboo-launch-selector-proof/Fixture.app"
        let application = Self.application(path: "/private/tmp/another-launch-selector/Fixture.app")
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in throw FixtureError.unexpectedNativeLaunch },
            applicationSelectorCandidatesProvider: { [] })

        await #expect(throws: (any Error).self) {
            try await service.bindSelectorResolution(application, launch: Self.launch(path: path))
        }
    }

    @Test
    @MainActor
    func `exact launch proof refuses competing path winners`() async throws {
        let path = "/private/tmp/peekaboo-launch-selector-proof/Fixture.app"
        let application = Self.application(path: path)
        let competing = Self.application(path: path, pid: 43)
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in throw FixtureError.unexpectedNativeLaunch },
            applicationSelectorCandidatesProvider: {
                [application, competing].map(ApplicationIdentifierMatcher.Candidate.init)
            })

        await #expect(throws: (any Error).self) {
            try await service.bindSelectorResolution(application, launch: Self.launch(path: path))
        }
    }

    private static func application(path: String, pid: Int32 = 42) -> ServiceApplicationInfo {
        ServiceApplicationInfo(
            processIdentifier: pid,
            processStartIdentity: 1001,
            bundleIdentifier: "org.example.launch-selector-fixture",
            name: "Fixture",
            bundlePath: path,
            executablePath: "\(path)/Contents/MacOS/Fixture",
            activationPolicy: .accessory)
    }

    private static func launch(path: String) -> ApplicationService.PreparedApplicationLaunch {
        ApplicationService.PreparedApplicationLaunch(
            applicationURL: URL(fileURLWithPath: path),
            openURLs: [],
            activates: false,
            waitUntilReady: false,
            waitForWindow: false,
            createsNewInstance: false,
            disablesRunningApplicationSubstitution: true,
            requestedRunningApplicationIdentity: nil,
            applicationIdentifier: path)
    }

    private enum FixtureError: Error {
        case unexpectedNativeLaunch
    }
}
