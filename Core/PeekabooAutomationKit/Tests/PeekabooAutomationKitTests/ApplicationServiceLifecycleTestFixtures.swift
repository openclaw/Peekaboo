import AppKit
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
extension ApplicationServiceLifecycleTests {
    func runningApplication() throws -> NSRunningApplication {
        try self.runningApplications(count: 1)[0]
    }

    func runningApplications(count: Int) throws -> [NSRunningApplication] {
        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier > 0 && !$0.isTerminated && $0.isFinishedLaunching
        }
        try #require(applications.count >= count)
        return Array(applications.prefix(count))
    }
}

@MainActor
final class ApplicationOpenRecorder {
    struct Call {
        let applicationURL: URL
        let openURLs: [URL]
        let activates: Bool
        let allowsRunningApplicationSubstitution: Bool
        let createsNewApplicationInstance: Bool
    }

    private(set) var calls: [Call] = []
    let runningApplication: NSRunningApplication

    init() {
        self.runningApplication = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
            .first ?? NSWorkspace.shared.frontmostApplication ?? NSRunningApplication.current
    }

    func open(
        applicationURL: URL,
        openURLs: [URL],
        configuration: NSWorkspace.OpenConfiguration) async throws -> NSRunningApplication
    {
        self.calls.append(Call(
            applicationURL: applicationURL,
            openURLs: openURLs,
            activates: configuration.activates,
            allowsRunningApplicationSubstitution: configuration.allowsRunningApplicationSubstitution,
            createsNewApplicationInstance: configuration.createsNewApplicationInstance))
        return self.runningApplication
    }
}

@MainActor
final class DefaultApplicationOpenRecorder {
    struct Call {
        let targetURL: URL
        let activates: Bool
    }

    private(set) var calls: [Call] = []
    let runningApplication = NSWorkspace.shared.runningApplications.first {
        !$0.isTerminated && $0.isFinishedLaunching
    } ?? NSRunningApplication.current

    func open(
        targetURL: URL,
        configuration: NSWorkspace.OpenConfiguration) async throws -> NSRunningApplication
    {
        self.calls.append(.init(targetURL: targetURL, activates: configuration.activates))
        return self.runningApplication
    }
}

@MainActor
final class RelaunchLifecycleRecorder {
    struct QuitCall: Equatable {
        let identifier: String
        let force: Bool
        let expectedIdentity: ApplicationProcessIdentity?
    }

    private let targetPID: Int32
    private let quitAttempt: ApplicationService.ApplicationQuitAttempt
    private(set) var resolvedIdentifiers: [String] = []
    private(set) var quitCalls: [QuitCall] = []
    private(set) var runningIdentifiers: [String] = []

    init(
        targetPID: Int32,
        quitAttempt: ApplicationService.ApplicationQuitAttempt = .init(
            requestAccepted: true,
            terminated: true))
    {
        self.targetPID = targetPID
        self.quitAttempt = quitAttempt
    }

    func resolve(identifier: String) async throws -> ServiceApplicationInfo {
        self.resolvedIdentifiers.append(identifier)
        return ServiceApplicationInfo(
            processIdentifier: self.targetPID,
            processStartIdentity: 700,
            bundleIdentifier: "com.apple.finder",
            name: "Finder",
            bundlePath: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder")?.path)
    }

    func quit(request: ApplicationQuitRequest) async throws -> ApplicationService.ApplicationQuitAttempt {
        self.quitCalls.append(.init(
            identifier: request.identifier,
            force: request.force,
            expectedIdentity: request.expectedIdentity))
        return self.quitAttempt
    }

    func isRunning(identifier: String) async -> Bool {
        self.runningIdentifiers.append(identifier)
        return false
    }
}

enum ApplicationLifecycleFixtureError: Error {
    case dispatchFailed
}
