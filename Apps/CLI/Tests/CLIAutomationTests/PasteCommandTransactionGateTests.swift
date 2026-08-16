import Darwin
import Foundation
import PeekabooCore
import Testing
@testable import PeekabooCLI

@MainActor
extension PasteCommandTests {
    func holdPasteTransactionLock() async throws -> Int32 {
        let fd = try self.openPasteTransactionLock()
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else {
                let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                close(fd)
                throw error
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return fd
    }

    func openPasteTransactionLock() throws -> Int32 {
        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let directory = applicationSupport.appendingPathComponent("Peekaboo", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("clipboard-paste-transaction.lock").path
        let fd = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return fd
    }

    func makeTransactionGateContext(processIdentifier: pid_t = 2468) -> (
        services: PeekabooServices,
        automation: OutcomeStubAutomationService,
        clipboard: StubClipboardService,
        applications: StubApplicationService
    ) {
        let app = ServiceApplicationInfo(
            processIdentifier: processIdentifier,
            processStartIdentity: 71,
            bundleIdentifier: "com.apple.TextEdit",
            name: "TextEdit"
        )
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .processTargetedEvents, mode: .background),
            unitCount: .one
        )
        let clipboard = StubClipboardService()
        let applications = StubApplicationService(applications: [app])
        clipboard.current = ClipboardReadResult(
            utiIdentifier: "public.utf8-plain-text",
            data: Data("prior".utf8),
            textPreview: "prior"
        )
        let services = TestServicesFactory.makePeekabooServices(
            applications: applications,
            clipboard: clipboard,
            automation: automation
        )
        return (services, automation, clipboard, applications)
    }
}
