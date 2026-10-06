import ApplicationServices
import AXorcist
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct DialogSavedFileVerificationTests {
    enum InvalidParentObservation: CaseIterable, Sendable {
        case missingParent, replacedParent, duplicateParent, incompleteInventory
        case missingOwner, changedGeneration, wrongOwnerPID
        case missingReceipt, changedWindowID, changedReceiptGeneration, changedReceiptBounds, changedBoundsSidecar
    }

    enum UnavailableSavedFileParent: CaseIterable, Sendable {
        case absent, replaced, unreadableInventory, unreadableBounds
    }

    @Test
    func `document read uses the fresh retained parent instead of a matching neighboring window`() throws {
        let fixture = SavedFileVerificationFixture(parentDocument: "/stale/report.txt")
        let freshParent = fixture.refreshedParent(document: "file:///owned/report%20draft.txt")
        let neighbor = SavedFileVerificationFixture.element(950_002, document: "/unrelated/report draft.txt")
        fixture.windows = [neighbor, freshParent]

        let path = try fixture.service().documentPathForRetainedFileDialogParent(
            target: fixture.target(),
            retainedParentWindow: fixture.parent)

        #expect(path == "/owned/report draft.txt")
        #expect(fixture.receiptElements == [freshParent])
        #expect(fixture.ownerElements == [freshParent])
        #expect(fixture.applicationReadCount == 1)
        #expect(fixture.inventoryReadCount == 1)
    }

    @Test
    func `missing parent document does not borrow a neighboring document`() throws {
        let fixture = SavedFileVerificationFixture()
        let neighbor = SavedFileVerificationFixture.element(950_002, document: "/unrelated/report.txt")
        fixture.windows = [neighbor, fixture.parent]

        let path = try fixture.service().documentPathForRetainedFileDialogParent(
            target: fixture.target(),
            retainedParentWindow: fixture.parent)

        #expect(path == nil)
        #expect(fixture.receiptElements == [fixture.parent])
        #expect(fixture.ownerElements == [fixture.parent])
    }

    @Test(arguments: InvalidParentObservation.allCases)
    func `parent verification refuses incomplete or replaced identity`(observation: InvalidParentObservation) throws {
        let fixture = SavedFileVerificationFixture(parentDocument: "/owned/report.txt")
        let changedBounds = CGRect(x: 11, y: 20, width: 500, height: 400)
        switch observation {
        case .missingParent:
            fixture.windows = []
        case .replacedParent:
            fixture.windows = [SavedFileVerificationFixture.element(950_002, document: "/owned/report.txt")]
        case .duplicateParent:
            fixture.windows = [fixture.parent, fixture.refreshedParent(document: "/owned/report.txt")]
        case .incompleteInventory:
            fixture.inventoryReadable = false
        case .missingOwner:
            fixture.application = nil
        case .changedGeneration:
            fixture.application = SavedFileVerificationFixture.application(generation: 9002)
        case .wrongOwnerPID:
            fixture.ownerPID = 43
        case .missingReceipt:
            fixture.receipt = nil
        case .changedWindowID:
            fixture.receipt = SavedFileVerificationFixture.receipt(windowID: 701)
        case .changedReceiptGeneration:
            fixture.receipt = SavedFileVerificationFixture.receipt(generation: 9002)
        case .changedReceiptBounds:
            fixture.receipt = SavedFileVerificationFixture.receipt(identityBounds: changedBounds)
        case .changedBoundsSidecar:
            fixture.receipt = SavedFileVerificationFixture.receipt(reportedBounds: changedBounds)
        }

        do {
            _ = try fixture.service().documentPathForRetainedFileDialogParent(
                target: fixture.target(),
                retainedParentWindow: fixture.parent)
            Issue.record("Expected changed or incomplete parent evidence to refuse")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        }
    }

    @Test
    func `typed verification uses the fresh parent document and original modification threshold`() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("report.txt")
        try Data("saved fixture".utf8).write(to: file, options: .withoutOverwriting)
        let startedAt = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes(
            [.modificationDate: startedAt.addingTimeInterval(1)],
            ofItemAtPath: file.path)
        let fixture = SavedFileVerificationFixture(parentDocument: "/stale/report.txt")
        fixture.windows = [fixture.refreshedParent(document: file.absoluteString)]
        let request = try fixture.request(startedAt: startedAt, timeout: 1)

        let result = try await fixture.service().verifySavedFile(request)

        #expect(result.path == file.path)
        #expect(result.foundVia == "document_path")
        #expect(fixture.inventoryReadCount == 1)
    }

    @Test(arguments: UnavailableSavedFileParent.allCases, [false, true])
    func `post action filesystem evidence survives unavailable parent document evidence`(
        parent: UnavailableSavedFileParent,
        exactExpectedFile: Bool) async throws
    {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let requestedDirectory = directory.appendingPathComponent("requested", isDirectory: true)
        let unrelatedDirectory = directory.appendingPathComponent("unrelated", isDirectory: true)
        for child in [requestedDirectory, unrelatedDirectory] {
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        }
        let expectedFile = requestedDirectory.appendingPathComponent("report.txt")
        let savedFile = requestedDirectory.appendingPathComponent(exactExpectedFile ? "report.txt" : "report-2.txt")
        let unrelatedFile = unrelatedDirectory.appendingPathComponent("report.txt")
        let startedAt = Date()
        try Data("saved fixture".utf8).write(to: savedFile, options: .withoutOverwriting)
        try Data("unrelated fixture".utf8).write(to: unrelatedFile, options: .withoutOverwriting)
        let fixture = SavedFileVerificationFixture(parentDocument: unrelatedFile.absoluteString)
        let neighbor = SavedFileVerificationFixture.element(950_002, document: unrelatedFile.absoluteString)
        switch parent {
        case .absent:
            fixture.windows = [neighbor]
        case .replaced:
            fixture.windows = [neighbor, SavedFileVerificationFixture.element(
                950_003, document: unrelatedFile.absoluteString)]
        case .unreadableInventory:
            fixture.windows = [neighbor, fixture.parent]
            fixture.inventoryReadable = false
        case .unreadableBounds:
            fixture.windows = [neighbor, fixture.parent]
            fixture.receipt = nil
        }
        let request = try fixture.request(expectedPath: expectedFile.path, startedAt: startedAt)

        let result = try await fixture.service().verifySavedFile(request)

        #expect(URL(fileURLWithPath: result.path).resolvingSymlinksInPath() == savedFile.resolvingSymlinksInPath())
        #expect(result.foundVia == (exactExpectedFile ? "expected_path" : "expected_directory_scan"))
        #expect(fixture.inventoryReadCount == 1)
        #expect(fixture.receiptElements.allSatisfy { DialogService.sameElement($0, fixture.parent) })
        #expect(fixture.ownerElements.allSatisfy { DialogService.sameElement($0, fixture.parent) })
    }

    @Test
    func `post action document verification retries transient unreadable parent evidence`() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let savedFile = directory.appendingPathComponent("report.txt")
        let startedAt = Date()
        try Data("saved fixture".utf8).write(to: savedFile, options: .withoutOverwriting)
        let fixture = SavedFileVerificationFixture(parentDocument: savedFile.absoluteString)
        var observedAvailability: [Bool] = []
        fixture.beforeInventoryRead = { readCount in
            fixture.inventoryReadable = readCount > 1
            observedAvailability.append(fixture.inventoryReadable)
        }
        defer { fixture.beforeInventoryRead = nil }
        let request = try fixture.request(startedAt: startedAt, timeout: 5)

        let result = try await fixture.service().verifySavedFile(request)

        #expect(result.path == savedFile.path)
        #expect(result.foundVia == "document_path")
        #expect(observedAvailability == [false, true])
        #expect(fixture.receiptElements == [fixture.parent])
    }

    @Test
    func `post action unavailable parent exhausts its budget without global fallback`() async throws {
        let name = "peekaboo-unavailable-parent-\(UUID().uuidString)"
        let unrelatedFile = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(name + ".txt")
        let saveStartedAt = Date()
        try Data("unrelated global fixture".utf8).write(to: unrelatedFile, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: unrelatedFile) }
        let fixture = SavedFileVerificationFixture(parentDocument: unrelatedFile.absoluteString)
        fixture.windows = [
            SavedFileVerificationFixture.element(950_002, document: unrelatedFile.absoluteString),
            fixture.parent,
        ]
        fixture.inventoryReadable = false
        let request = try fixture.request(expectedBaseName: name, startedAt: saveStartedAt, timeout: 0.15)
        let clock = ContinuousClock()
        let startedAt = clock.now

        do {
            _ = try await fixture.service().verifySavedFile(request)
            Issue.record("Expected unavailable parent evidence to exhaust the post-action verification budget")
        } catch let error as DialogError {
            guard case let .fileVerificationFailed(expectedPath) = error else { throw error }
            #expect(expectedPath == "(unknown directory; name prefix: \(name))")
        }

        #expect(clock.now - startedAt >= .milliseconds(150))
        #expect(fixture.inventoryReadCount > 0)
        #expect(fixture.receiptElements.isEmpty)
        #expect(fixture.ownerElements.isEmpty)
        #expect(FileManager.default.fileExists(atPath: unrelatedFile.path))
    }

    @Test
    func `typed verification cannot use global fallback while legacy verification retains it`() async throws {
        let name = "peekaboo-saved-file-\(UUID().uuidString)"
        let file = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(name + ".txt")
        try Data("unrelated fallback fixture".utf8).write(to: file, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: file) }
        let fixture = SavedFileVerificationFixture()
        let startedAt = Date().addingTimeInterval(-1)
        let typedRequest = try fixture.request(expectedBaseName: name, startedAt: startedAt, timeout: 0)
        let service = fixture.service()

        do {
            _ = try await service.verifySavedFile(typedRequest)
            Issue.record("Expected typed verification to reject the unrelated global fallback file")
        } catch let error as DialogError {
            guard case let .fileVerificationFailed(expectedPath) = error else { throw error }
            #expect(expectedPath == "(unknown directory; name prefix: \(name))")
        }

        let legacyRequest = try DialogService.SavedFileVerificationRequest(
            appName: nil,
            priorDocumentPath: nil,
            expectedPath: nil,
            expectedBaseName: name,
            startedAt: startedAt,
            timeout: 0,
            retainedTarget: fixture.target())
        let legacyResult = try await service.verifySavedFile(legacyRequest)

        #expect(legacyResult.path == file.path)
        #expect(legacyResult.foundVia == "fallback_search")
        #expect(fixture.applicationReadCount == 0)
        #expect(fixture.inventoryReadCount == 0)
    }

    @Test
    func `verification gets a fresh timeout after a long running save action`() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("saved-\(UUID().uuidString).txt")
        try Data("explicit saved fixture".utf8).write(to: file, options: .withoutOverwriting)
        let fixture = SavedFileVerificationFixture()
        let request = try fixture.request(
            expectedPath: file.path,
            expectedBaseName: file.deletingPathExtension().lastPathComponent,
            startedAt: Date().addingTimeInterval(-3600),
            timeout: 1)

        let result = try await fixture.service().verifySavedFile(request)

        #expect(result.path == file.path)
        #expect(result.foundVia == "expected_path")
        #expect(fixture.inventoryReadCount == 1)
    }

    @Test
    func `overwrite retry preserves the original parent and save start`() throws {
        let fixture = SavedFileVerificationFixture(parentDocument: "/prior/report.txt")
        let startedAt = Date(timeIntervalSince1970: 1234)
        let request = try DialogService.SavedFileVerificationRequest(
            appName: "Editor",
            priorDocumentPath: "/prior/report.txt",
            expectedPath: "/owned/report.txt",
            expectedBaseName: "report",
            startedAt: startedAt,
            timeout: 5,
            retainedTarget: fixture.target(),
            retainedParentWindow: fixture.parent)
        let refreshedTarget = try UIAutomationTarget.ExactWindow(
            identity: request.retainedTarget.identity.withMinimizedState(true),
            bounds: request.retainedTarget.bounds)

        let retry = request.retryingOverwrite(with: refreshedTarget)

        #expect(retry.appName == request.appName)
        #expect(retry.priorDocumentPath == request.priorDocumentPath)
        #expect(retry.expectedPath == request.expectedPath)
        #expect(retry.expectedBaseName == request.expectedBaseName)
        #expect(retry.startedAt == startedAt)
        #expect(retry.timeout == request.timeout)
        #expect(retry.retainedTarget.identity == refreshedTarget.identity)
        #expect(retry.retainedTarget.bounds == refreshedTarget.bounds)
        let retainedParent = try #require(retry.retainedParentWindow)
        #expect(DialogService.sameElement(retainedParent, fixture.parent))
    }

    @Test
    func `legacy request initializer defaults to no retained parent`() throws {
        let fixture = SavedFileVerificationFixture()
        let request = try DialogService.SavedFileVerificationRequest(
            appName: nil,
            priorDocumentPath: nil,
            expectedPath: nil,
            expectedBaseName: nil,
            startedAt: Date(),
            timeout: 5,
            retainedTarget: fixture.target())

        #expect(request.retainedParentWindow == nil)
    }

    @Test(arguments: [false, true])
    func `saved path diagnostics recognize temporary directory aliases in either direction`(
        actualUsesAlias: Bool) throws
    {
        let filename = "peekaboo-path-equivalence-\(UUID().uuidString).txt"
        let file = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(filename)
        try Data("saved fixture".utf8).write(to: file, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: file) }
        let actualPath = actualUsesAlias ? "/tmp/\(filename)" : file.path
        let expectedPath = actualUsesAlias ? file.path : "/tmp/\(filename)"
        let fixture = SavedFileVerificationFixture()
        let completed = try DialogService.CompletedSavedFileVerification(
            verification: .init(path: actualPath, foundVia: "document_path"),
            overwriteConfirmed: false,
            target: fixture.target())
        var details: [String: String] = [:]

        try fixture.service().recordSavedFileVerification(completed, expectedPath: expectedPath, details: &details)

        #expect(details["saved_path"] == actualPath)
        #expect(details["saved_path_matches_expected"] == "true")
        #expect(details["saved_path_expected"] == nil)
        #expect(details["saved_path_matches_expected_directory"] == "true")
        #expect(details["saved_path_directory"] == details["saved_path_expected_directory"])
    }

    @Test
    func `saved path diagnostics normalize directory symlinks and dot segments`() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let actualDirectory = directory.appendingPathComponent("actual", isDirectory: true)
        let alias = directory.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: actualDirectory, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actualDirectory)
        let file = actualDirectory.appendingPathComponent("report draft.txt")
        try Data("saved fixture".utf8).write(to: file, options: .withoutOverwriting)
        let actualPath = alias.path + "/./report draft.txt"
        let fixture = SavedFileVerificationFixture()
        let completed = try DialogService.CompletedSavedFileVerification(
            verification: .init(path: actualPath, foundVia: "document_path"),
            overwriteConfirmed: false,
            target: fixture.target())
        var details: [String: String] = [:]

        try fixture.service().recordSavedFileVerification(completed, expectedPath: file.path, details: &details)

        #expect(details["saved_path"] == actualPath)
        #expect(details["saved_path_matches_expected"] == "true")
        #expect(details["saved_path_expected"] == nil)
        #expect(details["saved_path_matches_expected_directory"] == "true")
        #expect(details["saved_path_directory"] == details["saved_path_expected_directory"])
    }

    @Test
    func `different saved filenames in the requested directory remain diagnostic only`() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let actualPath = directory.appendingPathComponent("report.rtf").path
        let expectedPath = directory.appendingPathComponent("report.txt").path
        let fixture = SavedFileVerificationFixture()
        let completed = try DialogService.CompletedSavedFileVerification(
            verification: .init(path: actualPath, foundVia: "document_path"),
            overwriteConfirmed: false,
            target: fixture.target())
        var details: [String: String] = [:]

        try fixture.service().recordSavedFileVerification(completed, expectedPath: expectedPath, details: &details)

        #expect(details["saved_path"] == actualPath)
        #expect(details["saved_path_matches_expected"] == "false")
        #expect(details["saved_path_expected"] == expectedPath)
        #expect(details["saved_path_matches_expected_directory"] == "true")
    }

    @Test(arguments: [false, true])
    func `different saved directories still refuse even when a file symlink reaches the expected file`(
        actualIsFileSymlink: Bool) throws
    {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let actualDirectory = directory.appendingPathComponent("actual", isDirectory: true)
        let expectedDirectory = directory.appendingPathComponent("expected", isDirectory: true)
        for child in [actualDirectory, expectedDirectory] {
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        }
        let expectedFile = expectedDirectory.appendingPathComponent("report.txt")
        let actualFile = actualDirectory.appendingPathComponent("report.txt")
        try Data("expected fixture".utf8).write(to: expectedFile, options: .withoutOverwriting)
        if actualIsFileSymlink {
            try FileManager.default.createSymbolicLink(at: actualFile, withDestinationURL: expectedFile)
        } else {
            try Data("actual fixture".utf8).write(to: actualFile, options: .withoutOverwriting)
        }
        let actualPath = actualDirectory.path + "/./report.txt"
        let fixture = SavedFileVerificationFixture()
        let completed = try DialogService.CompletedSavedFileVerification(
            verification: .init(path: actualPath, foundVia: "document_path"),
            overwriteConfirmed: false,
            target: fixture.target())
        var details: [String: String] = [:]
        let canonicalActualDirectory = actualDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let canonicalExpectedDirectory = expectedDirectory.standardizedFileURL.resolvingSymlinksInPath().path

        do {
            try fixture.service().recordSavedFileVerification(
                completed, expectedPath: expectedFile.path, details: &details)
            Issue.record("Expected the saved-file directory contract to reject another parent directory")
        } catch let error as DialogError {
            guard case let .fileSavedToUnexpectedDirectory(expected, actual, path) = error else { throw error }
            #expect(expected == canonicalExpectedDirectory)
            #expect(actual == canonicalActualDirectory)
            #expect(path == actualPath)
        }

        #expect(details["saved_path"] == actualPath)
        #expect(details["saved_path_matches_expected"] == String(actualIsFileSymlink))
        #expect(details["saved_path_expected"] == (actualIsFileSymlink ? nil : expectedFile.path))
        #expect(details["saved_path_matches_expected_directory"] == "false")
        #expect(details["saved_path_expected_directory"] == canonicalExpectedDirectory)
        #expect(details["saved_path_directory"] == canonicalActualDirectory)
    }

    @Test
    func `saved path recording without an expected path preserves its existing diagnostics`() throws {
        let fixture = SavedFileVerificationFixture()
        let completed = try DialogService.CompletedSavedFileVerification(
            verification: .init(path: "/tmp/./report.txt", foundVia: "document_path"),
            overwriteConfirmed: false,
            target: fixture.target())
        var details: [String: String] = [:]

        try fixture.service().recordSavedFileVerification(completed, expectedPath: nil, details: &details)

        #expect(details == [
            "saved_path": "/tmp/./report.txt",
            "saved_path_exists": "true",
            "saved_path_verified": "true",
            "saved_path_found_via": "document_path",
        ])
    }

    private static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-saved-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}

@MainActor
private final class SavedFileVerificationFixture {
    static let bounds = CGRect(x: 10, y: 20, width: 500, height: 400)
    let parent: Element
    var windows: [Element]
    var application: ServiceApplicationInfo? = SavedFileVerificationFixture.application()
    var receipt: ServiceWindowInfo? = SavedFileVerificationFixture.receipt()
    var inventoryReadable = true
    var ownerPID: Int32? = 42
    var applicationReadCount = 0
    var inventoryReadCount = 0
    var beforeInventoryRead: ((Int) -> Void)?
    var ownerElements: [Element] = []
    var receiptElements: [Element] = []

    init(parentDocument: String = "") {
        let parent = Self.element(950_001, document: parentDocument)
        self.parent = parent
        self.windows = [parent]
    }

    func service() -> DialogService {
        var readers = DialogDiscoveryReaders()
        readers.currentApplication = { pid in
            #expect(pid == 42)
            self.applicationReadCount += 1
            return self.application
        }
        readers.windows = { pid in
            #expect(pid == 42)
            self.inventoryReadCount += 1
            self.beforeInventoryRead?(self.inventoryReadCount)
            return (self.windows, self.inventoryReadable)
        }
        readers.ownerPID = { window in
            self.ownerElements.append(window)
            return self.ownerPID
        }
        readers.windowReceipt = { window, _, _ in
            self.receiptElements.append(window)
            return self.receipt
        }
        return DialogService(
            applicationService: UnusedApplicationService(),
            syntheticInputDriver: ClickRecordingSyntheticInputDriver(),
            operationLaneCoordinator: DesktopOperationLaneCoordinator(),
            discoveryReaders: readers,
            focusService: DialogDiscoveryFocusRecorder())
    }

    func target() throws -> UIAutomationTarget.ExactWindow {
        try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 700,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 9001,
                capturedBounds: Self.bounds),
            bounds: Self.bounds)
    }

    func request(
        expectedPath: String? = nil,
        expectedBaseName: String? = "report",
        startedAt: Date = Date(),
        timeout: TimeInterval = 1) throws -> DialogService.SavedFileVerificationRequest
    {
        try DialogService.SavedFileVerificationRequest(
            appName: nil,
            priorDocumentPath: nil,
            expectedPath: expectedPath,
            expectedBaseName: expectedBaseName,
            startedAt: startedAt,
            timeout: timeout,
            retainedTarget: self.target(),
            retainedParentWindow: self.parent)
    }

    func refreshedParent(document: String) -> Element {
        Self.element(raw: self.parent.underlyingElement, document: document)
    }

    static func application(generation: UInt64 = 9001) -> ServiceApplicationInfo {
        ServiceApplicationInfo(
            processIdentifier: 42,
            processStartIdentity: generation,
            bundleIdentifier: "example.saved-file-fixture",
            name: "Editor")
    }

    static func receipt(
        windowID: Int = 700,
        generation: UInt64 = 9001,
        identityBounds: CGRect? = nil,
        reportedBounds: CGRect? = nil) -> ServiceWindowInfo
    {
        ServiceWindowInfo(
            windowID: windowID,
            title: "Report",
            bounds: reportedBounds ?? self.bounds,
            index: 0,
            mutationIdentity: WindowMutationIdentity(
                windowID: windowID,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: generation,
                capturedBounds: identityBounds ?? self.bounds))
    }

    static func element(_ identity: Int32, document: String) -> Element {
        self.element(raw: AXUIElementCreateApplication(-identity), document: document)
    }

    private static func element(raw: AXUIElement, document: String) -> Element {
        Element(
            raw,
            attributes: ["AXDocument": .string(document)],
            children: [],
            actions: [])
    }
}
