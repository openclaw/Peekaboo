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

    @Test(arguments: [false, true], CandidateSource.allCases)
    @MainActor
    func `canonical launch request freezes either native spelling in its proof`(
        nativeCanonical: Bool,
        candidateSource: CandidateSource) async throws
    {
        let root = URL(fileURLWithPath: "/private/tmp/peekaboo-launch-projection-\(UUID().uuidString)")
        let url = root.appendingPathComponent("Fixture.app", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let canonicalPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        #expect(canonicalPath != url.path)
        let application = Self.application(path: nativeCanonical ? canonicalPath : url.path)
        var ambientReads = 0
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in throw FixtureError.unexpectedNativeLaunch },
            applicationSelectorCandidatesProvider: {
                ambientReads += 1
                return switch candidateSource {
                case .ambient: [ApplicationIdentifierMatcher.Candidate(application)]
                case .fallback: []
                case .newInstance: [ApplicationIdentifierMatcher.Candidate(Self.application(
                        path: canonicalPath,
                        pid: 43))]
                }
            })

        let result = try await service.bindSelectorResolution(application, launch: Self.launch(
            path: canonicalPath,
            createsNewInstance: candidateSource == .newInstance))

        let proof = try #require(result.selectorResolutionProofs?.first)
        #expect(ambientReads == (candidateSource == .newInstance ? 0 : 1))
        #expect(result.withSelectorResolutionProofs(nil) == Self.application(
            path: canonicalPath,
            executablePath: application.executablePath))
        #expect(proof.normalizedSelector == canonicalPath)
        #expect(proof.matchKind == .bundlePath)
        #expect(proof.candidateCount == 1)
        #expect(proof.applicationMismatch(
            identifier: canonicalPath,
            selectedCandidate: ApplicationIdentifierMatcher.Candidate(result),
            processIdentity: application.processIdentity) == nil)
    }

    @Test(arguments: [false, true])
    @MainActor
    func `mixed native path spellings remain competing launch winners`(canonicalRequest: Bool) async throws {
        let root = URL(fileURLWithPath: "/private/tmp/peekaboo-launch-tie-\(UUID().uuidString)")
        let url = root.appendingPathComponent("Fixture.app", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let canonicalPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        let selected = Self.application(path: url.path)
        let competing = Self.application(path: canonicalPath, pid: 43)
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in throw FixtureError.unexpectedNativeLaunch },
            applicationSelectorCandidatesProvider: {
                [selected, competing].map(ApplicationIdentifierMatcher.Candidate.init)
            })

        await #expect(throws: (any Error).self) {
            try await service.bindSelectorResolution(
                selected,
                launch: Self.launch(path: canonicalRequest ? canonicalPath : url.path))
        }
    }

    @Test
    @MainActor
    func `canonical launch proof does not substitute an ambient winner`() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/peekaboo-launch-winner-\(UUID().uuidString)")
        let url = root.appendingPathComponent("Fixture.app", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let canonicalPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        let selected = Self.application(path: url.path)
        let competing = Self.application(path: canonicalPath, pid: 43)
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in throw FixtureError.unexpectedNativeLaunch },
            applicationSelectorCandidatesProvider: { [ApplicationIdentifierMatcher.Candidate(competing)] })

        await #expect(throws: (any Error).self) {
            try await service.bindSelectorResolution(selected, launch: Self.launch(path: canonicalPath))
        }
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

    private static func application(
        path: String,
        pid: Int32 = 42,
        executablePath: String? = nil) -> ServiceApplicationInfo
    {
        ServiceApplicationInfo(
            processIdentifier: pid,
            processStartIdentity: 1001,
            bundleIdentifier: "org.example.launch-selector-fixture",
            name: "Fixture",
            bundlePath: path,
            executablePath: executablePath ?? "\(path)/Contents/MacOS/Fixture",
            isActive: true,
            isHidden: true,
            isHiddenKnown: false,
            windowCount: 2,
            windowIDs: [7, 9],
            activationPolicy: .accessory,
            isFinishedLaunching: true,
            metadataWarnings: ["synthetic metadata warning"])
    }

    private static func launch(
        path: String,
        createsNewInstance: Bool = false) -> ApplicationService.PreparedApplicationLaunch
    {
        ApplicationService.PreparedApplicationLaunch(
            applicationURL: URL(fileURLWithPath: path),
            openURLs: [],
            activates: false,
            waitUntilReady: false,
            waitForWindow: false,
            createsNewInstance: createsNewInstance,
            disablesRunningApplicationSubstitution: true,
            requestedRunningApplicationIdentity: nil,
            applicationIdentifier: path)
    }

    private enum FixtureError: Error {
        case unexpectedNativeLaunch
    }

    enum CandidateSource: CaseIterable, Sendable {
        case ambient
        case fallback
        case newInstance
    }
}
