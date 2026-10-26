import AppKit
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct RunningApplicationProcessIdentityTests {
    @Test
    func `positive PID does not read recovery sources`() {
        let readers = RunningApplicationProcessIdentity.Readers(
            processIdentifiers: { Issue.record("Unexpected process list read"); return nil },
            executablePath: { _ in Issue.record("Unexpected path read"); return nil },
            metadata: { _ in Issue.record("Unexpected metadata read"); return nil },
            startIdentity: { _ in Issue.record("Unexpected generation read"); return nil })
        #expect(RunningApplicationProcessIdentity.resolve(
            processIdentifier: 42, metadata: PIDRecoveryFixture.metadata, readers: readers) == 42)
    }

    @Test
    func `unique live process recovers without windows`() {
        #expect(PIDRecoveryFixture.resolve() == PIDRecoveryFixture.pid)
    }

    @Test(arguments: [[], [pid_t(0), -1], [42]])
    func `no matching candidate fails closed`(pids: [pid_t]) {
        var readers = PIDRecoveryFixture.readers
        readers.processIdentifiers = { pids }
        readers.executablePath = { _ in "/Applications/Other.app/Contents/MacOS/Main" }
        #expect(PIDRecoveryFixture.resolve(readers: readers) == nil)
    }

    @Test
    func `two matching processes are ambiguous`() {
        var readers = PIDRecoveryFixture.readers
        readers.processIdentifiers = { [PIDRecoveryFixture.pid, PIDRecoveryFixture.pid + 1] }
        #expect(PIDRecoveryFixture.resolve(readers: readers) == nil)
    }

    @Test
    func `duplicate PID is not ambiguous`() {
        var readers = PIDRecoveryFixture.readers
        readers.processIdentifiers = { [PIDRecoveryFixture.pid, PIDRecoveryFixture.pid] }
        #expect(PIDRecoveryFixture.resolve(readers: readers) == PIDRecoveryFixture.pid)
    }

    @Test(arguments: ["/Applications/Reexec.app/Contents/MacOS/MainOther", "/other/Main", ""])
    func `executable path must match exactly`(path: String) {
        var readers = PIDRecoveryFixture.readers
        readers.executablePath = { _ in path }
        #expect(PIDRecoveryFixture.resolve(readers: readers) == nil)
    }

    @Test
    func `canonical paths match`() {
        var readers = PIDRecoveryFixture.readers
        readers.executablePath = { _ in "/Applications/Reexec.app/Contents/./MacOS/Main" }
        #expect(PIDRecoveryFixture.resolve(readers: readers) == PIDRecoveryFixture.pid)
    }

    @Test(arguments: [0, 1, 2, 3])
    func `metadata must match every field`(field: Int) {
        let metadata = RunningApplicationProcessIdentity.Metadata(
            bundleIdentifier: field == 0 ? "com.example.other" : PIDRecoveryFixture.metadata.bundleIdentifier,
            bundleURL: field == 1 ? URL(fileURLWithPath: "/Other.app") : PIDRecoveryFixture.metadata.bundleURL,
            executableURL: field == 2 ? URL(fileURLWithPath: "/Other") : PIDRecoveryFixture.metadata.executableURL)
        var readers = PIDRecoveryFixture.readers
        readers.metadata = { _ in field == 3 ? nil : metadata }
        #expect(PIDRecoveryFixture.resolve(readers: readers) == nil)
    }

    @Test(arguments: [0, 1, 2, 3])
    func `unreadable or changing generation fails closed`(mode: Int) {
        let reads = AutomationTestLockedValue(0)
        var readers = PIDRecoveryFixture.readers
        readers.startIdentity = { _ in
            reads.withValue { count in
                defer { count += 1 }
                if mode == 0 || (mode == 1 && count > 0) {
                    return nil
                }
                return count < (mode == 3 ? 2 : 1) ? 10 : 11
            }
        }
        #expect(PIDRecoveryFixture.resolve(readers: readers) == nil)
    }

    @Test
    func `unreadable process list fails closed`() {
        var readers = PIDRecoveryFixture.readers
        readers.processIdentifiers = { nil }
        #expect(PIDRecoveryFixture.resolve(readers: readers) == nil)
    }
}

@MainActor
struct ApplicationPIDRecoveryTests {
    @Test
    func `inventory recovers negative PID reports unrecoverable omission and preserves ordinary row`() async throws {
        let service = Self.service()
        let output = try await service.listApplications()
        let rows = output.data.applications.sorted { $0.processIdentifier < $1.processIdentifier }
        #expect(rows.map(\.processIdentifier) == [PIDRecoveryFixture.pid, PIDRecoveryFixture.ordinaryPID])
        #expect(rows.map(\.name) == ["Reexec", "Ordinary"])
        #expect(rows.allSatisfy { $0.processStartIdentity == 10 && $0.windowCount == 0 })
        #expect(output.summary.status == .partial)
        #expect(output.summary.counts["omittedApplications"] == 1)
        #expect(output.metadata.warnings.contains { $0.contains("lacked a verified process identifier") })
    }

    @Test(arguments: ["PID:64001", "com.example.reexec"])
    func `selectors carry recovered PID`(identifier: String) async throws {
        let application = try await Self.service().getApplicationWithWindowCount(identifier: identifier)
        #expect(application.processIdentifier == PIDRecoveryFixture.pid)
        #expect(application.processStartIdentity == 10)
        #expect(application.name == "Reexec")
    }

    @Test
    func `unresolved name contender prevents selecting a recovered process`() async throws {
        do {
            let application = try await Self.service().findApplication(identifier: "Reexec")
            Issue.record("Ambiguous name unexpectedly selected PID \(application.processIdentifier)")
        } catch let error as PeekabooError {
            guard case let .ambiguousAppIdentifier(_, suggestions) = error else { throw error }
            #expect(suggestions.count == 2)
            #expect(suggestions.contains { $0.contains("PID:64001") })
            #expect(suggestions.contains { $0.contains("process identity unavailable") })
        }
    }

    @Test
    func `unrecoverable selector fails closed`() async {
        await #expect(throws: PeekabooError.self) {
            _ = try await Self.service().findApplication(identifier: "com.example.unrecoverable")
        }
    }

    @Test
    func `positive PID still publishes nil when second generation read changes`() async throws {
        let reads = AutomationTestLockedValue(0)
        let service = Self.service(generation: { _ in
            reads.withValue { count in
                defer { count += 1 }
                return count == 0 ? 10 : 11
            }
        })
        let application = try await service.findApplication(identifier: "PID:64002")
        #expect(application.processIdentifier == PIDRecoveryFixture.ordinaryPID)
        #expect(application.processStartIdentity == nil)
    }

    @Test
    func `resolver uses recovered PID and still rejects contradicting PID`() async throws {
        let resolver = ElementDetectionWindowResolver(
            applicationService: Self.service(),
            runningApplicationProvider: { _ in ReexecRunningApplication() },
            processIdentifierResolver: PIDRecoveryFixture.resolveApplication)
        for context in [
            WindowContext(applicationProcessId: PIDRecoveryFixture.pid),
            WindowContext(applicationBundleId: "com.example.reexec"),
        ] {
            let application = try await resolver.resolveApplication(windowContext: context)
            #expect(application.processIdentifier == PIDRecoveryFixture.pid)
            #expect(application.application.processIdentifier == -1)
        }
        do {
            _ = try await resolver.resolveApplication(windowContext: WindowContext(applicationProcessId: 64003))
            Issue.record("A different requested PID must still be refused")
        } catch let error as PeekabooError {
            guard case let .invalidInput(message) = error else { throw error }
            #expect(message == "Invalid windowContext: applicationProcessId contradicts the resolved application")
        }
    }

    @Test
    func `exact window resolver keeps owner and generation checks`() async throws {
        let resolver = ElementDetectionWindowResolver(
            applicationService: Self.service(),
            exactWindowIdentityProvider: { id in
                SystemWindowIdentity(
                    windowID: id,
                    ownerProcessIdentifier: PIDRecoveryFixture.pid,
                    title: "Fixture",
                    bounds: CGRect(x: 0, y: 0, width: 400, height: 300),
                    layer: 0,
                    alpha: 1,
                    isOnScreen: true,
                    sharingState: nil)
            },
            processStartIdentityProvider: { _ in 10 },
            runningApplicationProvider: { _ in ReexecRunningApplication() },
            processIdentifierResolver: PIDRecoveryFixture.resolveApplication)
        let app = try await resolver.resolveApplication(windowContext: WindowContext(windowID: 123))
        #expect(app.processIdentifier == PIDRecoveryFixture.pid)
    }

    private static func service(
        generation: @escaping ApplicationService.ProcessStartIdentityProvider = { _ in 10 }) -> ApplicationService
    {
        ApplicationService(
            applicationOpenHandler: { _, _, _ in throw PeekabooError.notImplemented("Unused") },
            frontmostProcessIdentifierProvider: { nil },
            processStartIdentityProvider: generation,
            runningApplicationsProvider: {
                [ReexecRunningApplication(), OrdinaryRunningApplication(), UnrecoverableRunningApplication()]
            },
            applicationProcessIdentifierResolver: PIDRecoveryFixture.resolveApplication,
            applicationWindowCatalogProvider: { [] },
            applicationMetadataProvider: { pid, _, _ in
                DetachedApplicationMetadata(
                    bundleIdentifier: pid == PIDRecoveryFixture.pid ? "com.example.reexec" : "com.example.ordinary",
                    name: pid == PIDRecoveryFixture.pid ? "Reexec" : "Ordinary",
                    bundlePath: nil,
                    isHidden: false,
                    activationPolicy: .regular,
                    isFinishedLaunching: true)
            },
            applicationInventoryWorker: DetachedApplicationInventoryWorker())
    }
}

private enum PIDRecoveryFixture {
    static let pid: pid_t = 64001
    static let ordinaryPID: pid_t = 64002
    static let metadata = RunningApplicationProcessIdentity.Metadata(
        bundleIdentifier: "com.example.reexec",
        bundleURL: URL(fileURLWithPath: "/Applications/Reexec.app"),
        executableURL: URL(fileURLWithPath: "/Applications/Reexec.app/Contents/MacOS/Main"))

    static var readers: RunningApplicationProcessIdentity.Readers {
        .init(
            processIdentifiers: { [self.pid] },
            executablePath: { _ in self.metadata.executableURL?.path },
            metadata: { _ in self.metadata },
            startIdentity: { _ in 10 })
    }

    static func resolve(readers: RunningApplicationProcessIdentity.Readers = Self.readers) -> pid_t? {
        RunningApplicationProcessIdentity.resolve(processIdentifier: -1, metadata: self.metadata, readers: readers)
    }

    static func resolveApplication(_ application: NSRunningApplication) -> pid_t? {
        RunningApplicationProcessIdentity.resolve(
            processIdentifier: application.processIdentifier,
            metadata: .init(application),
            readers: self.readers)
    }
}

private class ReexecRunningApplication: NSRunningApplication, @unchecked Sendable {
    override var processIdentifier: pid_t {
        -1
    }

    override var bundleIdentifier: String? {
        "com.example.reexec"
    }

    override var bundleURL: URL? {
        PIDRecoveryFixture.metadata.bundleURL
    }

    override var executableURL: URL? {
        PIDRecoveryFixture.metadata.executableURL
    }

    override var localizedName: String? {
        "Reexec"
    }

    override var isTerminated: Bool {
        false
    }

    override var isActive: Bool {
        false
    }

    override var isHidden: Bool {
        false
    }

    override var isFinishedLaunching: Bool {
        true
    }

    override var activationPolicy: NSApplication.ActivationPolicy {
        .regular
    }
}

private final class OrdinaryRunningApplication: ReexecRunningApplication, @unchecked Sendable {
    override var processIdentifier: pid_t {
        PIDRecoveryFixture.ordinaryPID
    }

    override var bundleIdentifier: String? {
        "com.example.ordinary"
    }

    override var localizedName: String? {
        "Ordinary"
    }
}

private final class UnrecoverableRunningApplication: ReexecRunningApplication, @unchecked Sendable {
    override var bundleIdentifier: String? {
        "com.example.unrecoverable"
    }
}
