import AppKit
import Darwin
import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable @_spi(Testing) import PeekabooAutomationKit

@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["RUN_AUTOMATION_ACTIONS"]?.lowercased() == "true"))
struct SameProcessWindowCloseTests {
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func `native unresolved census refuses before injected capture and lifecycle backends`() async throws {
        let fixture = try NativeSelectorFixture(executable: Self.fixtureExecutable)
        var failure: (any Error)?
        do {
            let applications = try await fixture.launchAndQualify()
            try await self.verifyNativeSelectorBoundaries(fixture: fixture, applications: applications)
        } catch { failure = error }
        try await fixture.removeOwnedChildrenAndBundles()
        if let failure {
            throw failure
        }
    }

    private static var fixtureExecutable: URL {
        Bundle(for: FixtureBundleAnchor.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("HostWindowCloseFixture")
    }

    @MainActor
    private func verifyNativeSelectorBoundaries(
        fixture: NativeSelectorFixture, applications: [NSRunningApplication]) async throws
    {
        let pid = try #require(fixture.receipts.last?.pid)
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: fixture.root
            .appendingPathComponent("lanes"))
        for action in SelectorCensusMutationAction.allCases {
            try fixture.checkDeadline()
            var dispatches = 0
            let service = ApplicationService(
                operationLaneCoordinator: coordinator,
                applicationOpenHandler: { _, _, _ in throw PeekabooError.notImplemented("Unused fixture launch") },
                applicationQuitHandler: { _, _ in dispatches += 1; return false },
                applicationHiddenProvider: { _ in action == .unhide },
                applicationVisibilityHandler: { _, _ in dispatches += 1; return false },
                runningApplicationsProvider: { applications })
            do {
                try await action.invoke(service, identifier: fixture.displayName)
                Issue.record("Native ambiguous selector unexpectedly completed")
            } catch let error as PeekabooError {
                guard case let .ambiguousAppIdentifier(_, suggestions) = error else { throw error }
                #expect(suggestions.count == 3)
            }
            #expect(dispatches == 0)
            await #expect(throws: DesktopActionFailure.self) {
                try await action.invoke(service, identifier: "PID:\(pid)")
            }
            #expect(dispatches == 1)
            if action == .quit {
                let listing = try await service.listApplications()
                let inventory = try await service.applicationMutationInventory()
                #expect(listing.summary.status == .partial)
                #expect(listing.summary.counts["omittedApplications"] == 2)
                #expect(listing.data.applications.map(\.processIdentifier) == [pid])
                #expect(!inventory.isComplete)
                #expect(inventory.items.map(\.processIdentifier) == [pid])
            }
        }
        let backend = SelectorCensusCaptureOperator()
        let capture = ScreenCaptureService(loggingService: MockLoggingService(), dependencies: .init(
            feedbackClient: NoopAutomationFeedbackClient(),
            permissionEvaluator: SelectorCensusCapturePermission(),
            fallbackRunner: ScreenCaptureFallbackRunner(apis: [.legacy]),
            applicationResolver: PeekabooApplicationResolver(runningApplicationsProvider: { applications }),
            makeFrameSource: { _ in SelectorCensusFrameSource() },
            makeModernOperator: { _, _ in backend },
            makeLegacyOperator: { _ in backend },
            screenLockProbe: { false }))
        let captureDirectory = fixture.root.appendingPathComponent("capture")
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        try await ScreenCaptureService.withIsolatedCaptureCoordination(directory: captureDirectory) {
            do {
                _ = try await capture.captureWindow(appIdentifier: fixture.displayName, windowIndex: nil)
                Issue.record("Native ambiguity unexpectedly reached capture")
            } catch let error as PeekabooError {
                guard case .ambiguousAppIdentifier = error else { throw error }
            }
            #expect(backend.attempts == 0)
            await #expect(throws: PeekabooError.self) {
                _ = try await capture.captureWindow(appIdentifier: "PID:\(pid)", windowIndex: nil)
            }
            #expect(backend.attempts == 1)
        }
        let application = try await ApplicationService(
            applicationOpenHandler: { _, _, _ in throw PeekabooError.notImplemented("Unused fixture launch") },
            runningApplicationsProvider: { applications }).findApplication(identifier: "PID:\(pid)")
        let identity = try #require(application.processIdentity)
        let reads = AutomationTestLockedValue(0)
        var dispatches = 0
        let raced = ApplicationService(
            operationLaneCoordinator: coordinator,
            applicationOpenHandler: { _, _, _ in throw PeekabooError.notImplemented("Unused fixture launch") },
            processStartIdentityProvider: { target in
                let generation = SystemIdentityResolver.processStartIdentity(target)
                reads.value += 1
                // Inject only the final validation mismatch after establishing the real native identity.
                // This is a provider race, never evidence of actual native PID reuse.
                return reads.value == 1 ? generation : generation.map { $0 &+ 1 }
            },
            applicationQuitHandler: { _, _ in dispatches += 1; return false })
        do {
            _ = try await raced.quitApplicationWithOwnedLane(
                request: .init(identifier: "PID:\(pid)", expectedIdentity: identity),
                resolvedApplication: application,
                expectedIdentity: identity)
            Issue.record("Injected final-generation race unexpectedly dispatched")
        } catch let error as PeekabooError {
            guard case .commandFailed = error else { throw error }
        }
        #expect(reads.value == 2)
        #expect(dispatches == 0)
        try fixture.verifyOwnedIdentities()
        try fixture.checkDeadline()
        print(
            "NATIVE_SELECTOR_BOUNDARIES_PASSED capture=0/1 lifecycle=0/1 " +
                "injected_generation_race=0 native_actuation=false")
    }

    @Test
    func `background close keeps host callbacks on MainActor and preserves sibling windows`() throws {
        let fixtureURL = Bundle(for: FixtureBundleAnchor.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("HostWindowCloseFixture")
        try #require(FileManager.default.isExecutableFile(atPath: fixtureURL.path))

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-host-window-close-\(UUID().uuidString).log")
        try #require(FileManager.default.createFile(atPath: outputURL.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }

        let process = Process()
        process.executableURL = fixtureURL
        process.standardOutput = output
        process.standardError = output
        try process.run()
        try DockService.waitForProcessExit(process, timeoutSeconds: 25)

        let diagnostics = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(process.terminationReason == .exit, "\(diagnostics)")
        #expect(process.terminationStatus == 0, "\(diagnostics)")
        #expect(
            diagnostics.split(separator: "\n").contains("HOST_WINDOW_CLOSE_FIXTURE_COMPLETED"),
            "The AppKit child must finish its assertions before exiting. \(diagnostics)")
    }
}

private final class FixtureBundleAnchor: NSObject {}

/// Owns fresh bundles and only the process generations attested by their private launch receipts.
@MainActor
private final class NativeSelectorFixture {
    struct Receipt: Decodable {
        let nonce: String
        let pid: pid_t
        let generation: UInt64
    }

    @MainActor
    final class Launch {
        let receiptURL: URL
        let executableURL: URL
        let nonce = UUID().uuidString
        var completed = false
        var failed = false
        var receipt: Receipt?

        init(root: URL, executableURL: URL) {
            self.executableURL = executableURL
            self.receiptURL = root.appendingPathComponent("\(self.nonce).json")
        }
    }

    let root: URL
    let displayName = "SelectorProof-\(UUID().uuidString)"
    private let rootIdentity: UInt64
    private let deadline = ContinuousClock.now.advanced(by: .seconds(20))
    private var launches: [Launch] = []
    private var bundles: [URL] = []
    var receipts: [Receipt] {
        self.launches.compactMap(\.receipt)
    }

    init(executable: URL) throws {
        try #require(FileManager.default.isExecutableFile(atPath: executable.path))
        var template = Array("/tmp/pb-native-selector-XXXXXX".utf8CString)
        let root = try template.withUnsafeMutableBufferPointer {
            guard let path = mkdtemp($0.baseAddress) else { throw POSIXError(.EIO) }
            return URL(fileURLWithPath: String(cString: path), isDirectory: true).resolvingSymlinksInPath()
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        let rootIdentity = try #require(attributes[.systemFileNumber] as? NSNumber).uint64Value
        self.root = root
        self.rootIdentity = rootIdentity
        do {
            for name in ["Unresolved", "Readable"] {
                let bundle = self.root.appendingPathComponent("\(name).app")
                self.bundles.append(bundle)
                let directory = bundle.appendingPathComponent("Contents/MacOS")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for binary in ["Launcher", "Payload"] {
                    try FileManager.default.copyItem(at: executable, to: directory.appendingPathComponent(binary))
                }
                let plist: [String: Any] = [
                    "CFBundleIdentifier": "com.example.peekaboo.selector.\(UUID().uuidString.lowercased())",
                    "CFBundleName": self.displayName, "CFBundleDisplayName": self.displayName,
                    "CFBundleExecutable": "Launcher", "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
                ]
                try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                    .write(to: bundle.appendingPathComponent("Contents/Info.plist"), options: .withoutOverwriting)
            }
        } catch {
            try self.removeRoot()
            throw error
        }
    }

    func checkDeadline() throws {
        try #require(ContinuousClock.now < self.deadline, "Native selector proof exceeded its 20-second budget")
    }

    func launchAndQualify() async throws -> [NSRunningApplication] {
        try await self.launch(bundle: self.bundles[0], reexec: true)
        try await self.launch(bundle: self.bundles[0], reexec: true)
        try await self.launch(bundle: self.bundles[1], reexec: false)
        let deadline = min(self.deadline, ContinuousClock.now.advanced(by: .seconds(5)))
        repeat {
            let applications = NSWorkspace.shared.runningApplications.filter {
                self.bundles.contains($0.bundleURL?.resolvingSymlinksInPath() ?? URL(fileURLWithPath: "/"))
            }
            if applications.count == 3,
               applications.allSatisfy({ !$0.isTerminated && $0.localizedName == self.displayName }),
               applications.filter({ $0.processIdentifier == -1 }).count == 2,
               applications.filter({ $0.processIdentifier > 0 }).map(\.processIdentifier) == [self.receipts[2].pid],
               applications.filter({ $0.processIdentifier == -1 }).allSatisfy({
                   $0.bundleURL?.resolvingSymlinksInPath() == self.bundles[0] &&
                       RunningApplicationProcessIdentity.resolve($0) == nil
               }),
               self.receipts.allSatisfy({ receipt in
                   SystemIdentityResolver.processStartIdentity(receipt.pid) == receipt.generation &&
                       !SystemIdentityResolver.windowIdentities(ownerProcessIdentifier: receipt.pid).isEmpty
               })
            {
                let unresolved = applications.filter { $0.processIdentifier == -1 }
                try #require(!unresolved[0].isEqual(unresolved[1]))
                let metadata = RunningApplicationProcessIdentity.Metadata(unresolved[0])
                try #require(RunningApplicationProcessIdentity.Metadata(unresolved[1]) == metadata)
                try #require(self.receipts.prefix(2).allSatisfy {
                    NSRunningApplication(processIdentifier: $0.pid).map(RunningApplicationProcessIdentity.Metadata.init)
                        == metadata
                })
                try self.verifyOwnedIdentities()
                print("NATIVE_SELECTOR_CENSUS_QUALIFIED unresolved=2 readable=1 default_recovery=true")
                return applications
            }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        throw NativeSelectorFailure("Native AppKit two-unresolved/one-readable precondition was not observed")
    }

    private func launch(bundle: URL, reexec: Bool) async throws {
        try self.checkDeadline()
        let launch = Launch(root: self.root, executableURL: bundle.appendingPathComponent(
            "Contents/MacOS/\(reexec ? "Payload" : "Launcher")"))
        self.launches.append(launch)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        configuration.arguments = [
            reexec ? "--selector-launch" : "--selector-plain",
            launch.nonce,
            launch.receiptURL.path,
        ]
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, error in
            let failed = error != nil
            Task { @MainActor in
                launch.failed = failed
                launch.completed = true
            }
        }
        let deadline = min(self.deadline, ContinuousClock.now.advanced(by: .seconds(5)))
        repeat {
            try self.readReceipt(for: launch)
            if launch.completed, launch.receipt != nil, !launch.failed {
                return
            }
            if launch.failed {
                throw NativeSelectorFailure("Owned fixture launch failed")
            }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        throw NativeSelectorFailure("Owned fixture launch did not qualify within five seconds")
    }

    private func readReceipt(for launch: Launch) throws {
        guard launch.receipt == nil, FileManager.default.fileExists(atPath: launch.receiptURL.path) else { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: launch.receiptURL.path)
        try #require(attributes[.type] as? FileAttributeType == .typeRegular)
        try #require(((attributes[.size] as? NSNumber)?.intValue ?? .max) < 1024)
        let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: launch.receiptURL))
        try #require(receipt.nonce == launch.nonce && receipt.pid > 0 && receipt.pid != getpid())
        try #require(SystemIdentityResolver.processStartIdentity(receipt.pid) == receipt.generation)
        try #require(Self.executablePath(receipt.pid) == launch.executableURL.path)
        try #require(!self.receipts.contains { $0.pid == receipt.pid })
        launch.receipt = receipt
    }

    func verifyOwnedIdentities() throws {
        for launch in self.launches {
            let receipt = try #require(launch.receipt)
            try #require(SystemIdentityResolver.processStartIdentity(receipt.pid) == receipt.generation)
            try #require(Self.executablePath(receipt.pid) == launch.executableURL.path)
        }
    }

    func removeOwnedChildrenAndBundles() async throws {
        for launch in self.launches {
            try self.readReceipt(for: launch)
            let receipt = try #require(launch.receipt, "Unproven launch ownership; retaining fixture bundles")
            if SystemIdentityResolver.processStartIdentityObservation(receipt.pid) == .absent {
                continue
            }
            try #require(SystemIdentityResolver.processStartIdentity(receipt.pid) == receipt.generation)
            try #require(Self.executablePath(receipt.pid) == launch.executableURL.path)
            // Cooperative self-exit avoids a PID-reuse race between a generation check and kill(2).
            // The nonce belongs to one child; no signal or application action reaches an ambient process.
            try Data(launch.nonce.utf8).write(
                to: launch.receiptURL.deletingPathExtension().appendingPathExtension("stop"),
                options: .withoutOverwriting)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while self.receipts.contains(where: {
            SystemIdentityResolver.processStartIdentityObservation($0.pid) != .absent
        }) {
            try #require(ContinuousClock.now < deadline, "Owned fixture did not exit; retaining its bundle")
            try await Task.sleep(for: .milliseconds(20))
        }
        let allLaunchesCompleted = self.launches.allSatisfy(\.completed)
        try #require(allLaunchesCompleted, "Pending launch; retaining fixture bundles")
        try self.removeRoot()
    }

    private func removeRoot() throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: self.root.path)
        try #require(attributes[.type] as? FileAttributeType == .typeDirectory)
        try #require((attributes[.systemFileNumber] as? NSNumber)?.uint64Value == self.rootIdentity)
        try FileManager.default.removeItem(at: self.root)
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else { return nil }
        return String(
            bytes: buffer.prefix(Int(count)).prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            encoding: .utf8)
    }
}

private struct NativeSelectorFailure: Error {
    let message: String
    init(_ message: String) {
        self.message = message
    }
}
