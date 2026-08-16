import AppKit
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct ApplicationLifecyclePathResolutionTests {
    @Test
    func `explicit application path variants bind against the canonical resolved bundle URL`() async throws {
        let fileManager = FileManager.default
        let applicationURL = try #require(
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder"))
        let runningApplication = try #require(
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        let canonicalApplicationURL = applicationURL.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalPath = canonicalApplicationURL.path
        let parentURL = canonicalApplicationURL.deletingLastPathComponent()

        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("peekaboo-lifecycle-\(UUID().uuidString)", isDirectory: true)
        let temporaryLinkURL = temporaryDirectory.appendingPathComponent("Finder Link.app", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: temporaryLinkURL, withDestinationURL: canonicalApplicationURL)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        let homeFixtureName = ".peekaboo-lifecycle-\(UUID().uuidString)"
        let homeFixtureURL = homeDirectory.appendingPathComponent(homeFixtureName, isDirectory: true)
        let homeLinkURL = homeFixtureURL.appendingPathComponent("Finder Link.app", isDirectory: true)
        try fileManager.createDirectory(at: homeFixtureURL, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: homeLinkURL, withDestinationURL: canonicalApplicationURL)
        defer { try? fileManager.removeItem(at: homeFixtureURL) }

        let pathVariants = [
            canonicalPath + "/",
            parentURL.path + "/./" + canonicalApplicationURL.lastPathComponent,
            temporaryLinkURL.path,
            "~/\(homeFixtureName)/\(homeLinkURL.lastPathComponent)",
        ]
        let processStartIdentity = try #require(
            SystemIdentityResolver.processStartIdentity(runningApplication.processIdentifier))
        let candidate = ApplicationIdentifierMatcher.Candidate(
            processIdentifier: runningApplication.processIdentifier,
            bundleIdentifier: runningApplication.bundleIdentifier,
            name: runningApplication.localizedName ?? "Finder",
            bundlePath: canonicalPath,
            executablePath: runningApplication.executableURL?.path,
            isRegularApplication: true)
        let recorder = ApplicationPathOpenRecorder(runningApplication: runningApplication)
        let service = ApplicationService(
            applicationOpenHandler: recorder.open,
            applicationSelectorCandidatesProvider: { [candidate] },
            applicationActiveProvider: { _ in true },
            processStartIdentityProvider: { _ in processStartIdentity })

        for pathVariant in pathVariants {
            let result = try await service.launchApplicationResult(request: ApplicationLaunchRequest(
                applicationIdentifier: pathVariant,
                activates: true,
                waitUntilReady: false))
            let proof = try #require(result.payload.selectorResolutionProofs?.first)

            #expect(proof.matchKind == .bundlePath)
            #expect(proof.normalizedSelector == canonicalPath)
        }

        #expect(recorder.calls.count == pathVariants.count)
        #expect(recorder.calls.allSatisfy { !$0.allowsRunningApplicationSubstitution })
        #expect(recorder.calls.allSatisfy {
            $0.applicationURL.standardizedFileURL.resolvingSymlinksInPath().path == canonicalPath
        })
    }
}

@MainActor
private final class ApplicationPathOpenRecorder {
    struct Call {
        let applicationURL: URL
        let allowsRunningApplicationSubstitution: Bool
    }

    private(set) var calls: [Call] = []
    private let runningApplication: NSRunningApplication

    init(runningApplication: NSRunningApplication) {
        self.runningApplication = runningApplication
    }

    func open(
        applicationURL: URL,
        openURLs _: [URL],
        configuration: NSWorkspace.OpenConfiguration) async throws -> NSRunningApplication
    {
        self.calls.append(Call(
            applicationURL: applicationURL,
            allowsRunningApplicationSubstitution: configuration.allowsRunningApplicationSubstitution))
        return self.runningApplication
    }
}
