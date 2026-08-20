import AppKit
import CoreGraphics
import XCTest
@testable import PeekabooAutomationKit

final class ElementDetectionReadOnlyWindowSelectionTests: XCTestCase {
    func testDetectProjectionOmitsUnrequestedResolvedPaths() {
        let projected = Self.detectProjection(requested: WindowContext(applicationName: "Fixture"))

        XCTAssertNil(projected.bundlePath)
        XCTAssertNil(projected.executablePath)
    }

    func testDetectProjectionPublishesCanonicalPathsForMatchingExplicitConstraints() {
        let projected = Self.detectProjection(requested: WindowContext(
            applicationName: "Fixture",
            applicationBundlePath: Self.bundlePath,
            applicationExecutablePath: Self.executablePath))

        XCTAssertEqual(projected.bundlePath, Self.bundlePath)
        XCTAssertEqual(projected.executablePath, Self.executablePath)
    }

    func testDetectProjectionNeverCopiesContradictoryCallerPathsAsResolvedFacts() {
        let projected = Self.detectProjection(requested: WindowContext(
            applicationName: "Fixture",
            applicationBundlePath: "/Applications/Other.app",
            applicationExecutablePath: "/Applications/Other.app/Contents/MacOS/other"))

        XCTAssertEqual(projected.bundlePath, Self.bundlePath)
        XCTAssertEqual(projected.executablePath, Self.executablePath)
    }

    func testResolvedApplicationAcceptsEveryMatchingSingleSelectorAndCombinedConstraints() {
        let matchingContexts = [
            WindowContext(applicationProcessId: 42),
            WindowContext(applicationBundleId: "dev.peekaboo.fixture"),
            WindowContext(applicationName: "Fixt"),
            WindowContext(applicationName: Self.bundlePath),
            WindowContext(applicationName: Self.executablePath),
            WindowContext(applicationName: "fixture"),
            WindowContext(applicationBundlePath: Self.bundlePath),
            WindowContext(applicationExecutablePath: Self.executablePath),
            WindowContext(
                applicationName: "Fixture",
                applicationBundleId: "dev.peekaboo.fixture",
                applicationBundlePath: Self.bundlePath,
                applicationExecutablePath: Self.executablePath,
                applicationProcessId: 42),
        ]

        for context in matchingContexts {
            XCTAssertNil(ElementDetectionWindowResolver.applicationConstraintMismatch(
                candidate: Self.applicationCandidate,
                context: context))
        }
    }

    func testResolvedApplicationRejectsContradictoryCombinedSelectorsBeforeObservation() {
        let contradictoryContexts = [
            WindowContext(applicationName: "Other", applicationProcessId: 42),
            WindowContext(applicationName: "/Applications/Other.app", applicationProcessId: 42),
            WindowContext(
                applicationName: "Other",
                applicationBundleId: "dev.peekaboo.fixture"),
            WindowContext(
                applicationName: "Fixture",
                applicationBundlePath: "/Applications/Other.app"),
            WindowContext(
                applicationName: "Fixture",
                applicationExecutablePath: "/Applications/Fixture.app/Contents/MacOS/other"),
        ]

        for context in contradictoryContexts {
            XCTAssertNotNil(ElementDetectionWindowResolver.applicationConstraintMismatch(
                candidate: Self.applicationCandidate,
                context: context))
        }
    }

    func testApplicationResolutionAuthorityPrefersUniquePathsOverBroadSelectors() {
        let bundlePathContext = WindowContext(
            applicationName: "Fixt",
            applicationBundleId: "dev.peekaboo.fixture",
            applicationBundlePath: Self.bundlePath)
        XCTAssertEqual(
            ElementDetectionWindowResolver.applicationResolutionAuthority(for: bundlePathContext),
            .identifier(Self.bundlePath, source: .bundlePath))
        XCTAssertNil(ElementDetectionWindowResolver.applicationConstraintMismatch(
            candidate: Self.applicationCandidate,
            context: bundlePathContext))

        let executablePathContext = WindowContext(
            applicationName: "Fixt",
            applicationBundleId: "dev.peekaboo.fixture",
            applicationExecutablePath: Self.executablePath)
        XCTAssertEqual(
            ElementDetectionWindowResolver.applicationResolutionAuthority(for: executablePathContext),
            .identifier(Self.executablePath, source: .executablePath))
        XCTAssertNil(ElementDetectionWindowResolver.applicationConstraintMismatch(
            candidate: Self.applicationCandidate,
            context: executablePathContext))
    }

    func testApplicationResolutionAuthorityPrefersExactWindowOverAmbiguousBroadSelector() {
        let context = WindowContext(
            applicationName: "Fixt",
            applicationBundleId: "dev.peekaboo.fixture",
            windowID: 73)

        XCTAssertEqual(
            ElementDetectionWindowResolver.applicationResolutionAuthority(for: context),
            .exactWindow(73))
        XCTAssertNil(ElementDetectionWindowResolver.applicationConstraintMismatch(
            candidate: Self.applicationCandidate,
            context: context))
    }

    @MainActor
    func testPathOnlySelectorsResolveTheirNonFrontmostApplication() async throws {
        let target = try Self.uniqueNonFrontmostApplication()
        let bundlePath = try XCTUnwrap(target.bundleURL?.standardizedFileURL.path)
        let executablePath = try XCTUnwrap(target.executableURL?.standardizedFileURL.path)
        let applicationService = ApplicationService()
        let bundleMatch = try await applicationService.findApplication(identifier: bundlePath)
        let executableMatch = try await applicationService.findApplication(identifier: executablePath)
        XCTAssertEqual(bundleMatch.processIdentifier, target.processIdentifier)
        XCTAssertEqual(executableMatch.processIdentifier, target.processIdentifier)
        let refreshed = try XCTUnwrap(NSRunningApplication(processIdentifier: target.processIdentifier))
        XCTAssertEqual(
            refreshed.bundleURL?.standardizedFileURL.path,
            bundlePath,
            "original=\(bundlePath) refreshed=\(refreshed.bundleURL?.standardizedFileURL.path ?? "nil")")
        let resolver = ElementDetectionWindowResolver(applicationService: applicationService)

        for context in [
            WindowContext(applicationBundlePath: bundlePath),
            WindowContext(applicationExecutablePath: executablePath),
        ] {
            let resolved = try await resolver.resolveApplication(windowContext: context)
            XCTAssertEqual(resolved.processIdentifier, target.processIdentifier)
        }
    }

    @MainActor
    func testPathResolutionRejectsContradictoryDualPathBeforeObservation() async throws {
        let target = try Self.uniqueNonFrontmostApplication()
        let bundlePath = try XCTUnwrap(target.bundleURL?.standardizedFileURL.path)
        let resolver = ElementDetectionWindowResolver(applicationService: ApplicationService())
        let context = WindowContext(
            applicationBundlePath: bundlePath,
            applicationExecutablePath: bundlePath + "/Contents/MacOS/not-the-target")

        do {
            _ = try await resolver.resolveApplication(windowContext: context)
            XCTFail("Contradictory explicit paths must fail before observation")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("applicationExecutablePath contradicts"))
        }
    }

    func testRequestedTitleSelectsExactSiblingInsteadOfBestWindow() throws {
        let bestWindow = Self.window(
            id: 100,
            title: "Large Dashboard",
            bounds: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            isMainWindow: true,
            index: 0)
        let requestedWindow = Self.window(
            id: 200,
            title: "Private Notes",
            bounds: CGRect(x: 100, y: 100, width: 700, height: 500),
            index: 1)

        let selected = try ElementDetectionService.selectReadOnlyWindow(
            requestedTitle: "Private Notes",
            windows: [bestWindow, requestedWindow],
            applicationIdentifier: "Fixture")

        XCTAssertEqual(selected?.windowID, requestedWindow.windowID)
    }

    func testRequestedTitleUsesUniqueCaseInsensitivePartialMatch() throws {
        let selected = try ElementDetectionService.selectReadOnlyWindow(
            requestedTitle: "notes",
            windows: [
                Self.window(id: 100, title: "Dashboard", index: 0),
                Self.window(id: 200, title: "Private Notes - Edited", index: 1),
            ],
            applicationIdentifier: "Fixture")

        XCTAssertEqual(selected?.windowID, 200)
    }

    func testExactTitleWinsOverPartialSiblingMatch() throws {
        let selected = try ElementDetectionService.selectReadOnlyWindow(
            requestedTitle: "Quarterly Report",
            windows: [
                Self.window(id: 100, title: "Quarterly Report - Copy", index: 0),
                Self.window(id: 200, title: "Quarterly Report", index: 1),
            ],
            applicationIdentifier: "Fixture")

        XCTAssertEqual(selected?.windowID, 200)
    }

    func testRequestedTitleRejectsAmbiguousSiblingWindows() {
        XCTAssertThrowsError(
            try ElementDetectionService.selectReadOnlyWindow(
                requestedTitle: "Quarterly Report",
                windows: [
                    Self.window(id: 100, title: "Quarterly Report - East", index: 0),
                    Self.window(id: 200, title: "Quarterly Report - West", index: 1),
                ],
                applicationIdentifier: "Fixture"))
        { error in
            XCTAssertTrue(error.localizedDescription.contains("is ambiguous"))
            XCTAssertTrue(error.localizedDescription.contains("id=100"))
            XCTAssertTrue(error.localizedDescription.contains("id=200"))
        }
    }

    func testRequestedTitleRejectsDuplicateExactSiblingWindows() {
        XCTAssertThrowsError(
            try ElementDetectionService.selectReadOnlyWindow(
                requestedTitle: "Untitled",
                windows: [
                    Self.window(id: 100, title: "Untitled", index: 0),
                    Self.window(id: 200, title: "Untitled", index: 1),
                ],
                applicationIdentifier: "Fixture"))
        { error in
            XCTAssertTrue(error.localizedDescription.contains("is ambiguous"))
        }
    }

    func testRequestedTitleRejectsMissingWindowInsteadOfChoosingBestWindow() {
        XCTAssertThrowsError(
            try ElementDetectionService.selectReadOnlyWindow(
                requestedTitle: "Missing Document",
                windows: [
                    Self.window(id: 100, title: "Dashboard", index: 0),
                    Self.window(id: 200, title: "Private Notes", index: 1),
                ],
                applicationIdentifier: "Fixture"))
        { error in
            XCTAssertTrue(error.localizedDescription.contains("Missing Document"))
            XCTAssertFalse(error.localizedDescription.contains("ambiguous"))
        }
    }

    func testMissingUntitledWindowDoesNotTreatEmptyTitleAsWildcard() {
        XCTAssertThrowsError(
            try ElementDetectionService.selectReadOnlyWindow(
                requestedTitle: "",
                windows: [Self.window(id: 100, title: "Dashboard", index: 0)],
                applicationIdentifier: "Fixture"))
    }

    func testMissingTitleSelectorUsesBestWindow() throws {
        let smallWindow = Self.window(
            id: 100,
            title: "Small",
            bounds: CGRect(x: 0, y: 0, width: 400, height: 300),
            index: 0)
        let mainWindow = Self.window(
            id: 200,
            title: "Main",
            bounds: CGRect(x: 0, y: 0, width: 1200, height: 900),
            isMainWindow: true,
            index: 1)

        let selected = try ElementDetectionService.selectReadOnlyWindow(
            requestedTitle: nil,
            windows: [smallWindow, mainWindow],
            applicationIdentifier: "Fixture")

        XCTAssertEqual(selected?.windowID, mainWindow.windowID)
    }

    func testMissingCaptureReceiptRemainsReadOnlyAndCannotBecomeActionCapable() throws {
        XCTAssertNil(try ElementDetectionService.validatedExactWindowReceipt(
            windowID: 42,
            processIdentifier: 123,
            capturedBounds: CGRect(x: 1, y: 2, width: 300, height: 200),
            receipt: nil,
            requiresActionCapability: false,
            validator: { _, _ in XCTFail("Missing receipt must not invoke validator"); return false }))

        XCTAssertThrowsError(try ElementDetectionService.validatedExactWindowReceipt(
            windowID: 42,
            processIdentifier: 123,
            capturedBounds: CGRect(x: 1, y: 2, width: 300, height: 200),
            receipt: nil,
            requiresActionCapability: true,
            validator: { _, _ in false }))
        { error in
            XCTAssertTrue(error.localizedDescription.contains("capture-time process-generation receipt"))
        }
    }

    private static let bundlePath = "/Applications/Fixture.app"
    private static let executablePath = bundlePath + "/Contents/MacOS/fixture"
    private static let applicationCandidate = ApplicationIdentifierMatcher.Candidate(
        processIdentifier: 42,
        bundleIdentifier: "dev.peekaboo.fixture",
        name: "Fixture",
        bundlePath: bundlePath,
        executablePath: executablePath,
        allowsFuzzyMatching: true,
        isRegularApplication: true)

    @MainActor
    private static func uniqueNonFrontmostApplication() throws -> NSRunningApplication {
        let frontmostProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let running = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        guard let target = running.first(where: { application in
            guard application.processIdentifier != frontmostProcessIdentifier,
                  let bundlePath = application.bundleURL?.standardizedFileURL.path,
                  let executablePath = application.executableURL?.standardizedFileURL.path
            else { return false }
            return running.count(where: {
                $0.bundleURL?.standardizedFileURL.path == bundlePath
            }) == 1 && running.count(where: {
                $0.executableURL?.standardizedFileURL.path == executablePath
            }) == 1
        }) else {
            throw XCTSkip("No unique non-frontmost application is available for path-only resolution")
        }
        return target
    }

    private static func detectProjection(requested: WindowContext) -> ElementDetectionService
    .ResolvedApplicationIdentity {
        ElementDetectionService.projectedApplicationIdentity(
            canonical: .init(
                name: "Fixture",
                bundleIdentifier: "dev.peekaboo.fixture",
                bundlePath: self.bundlePath,
                executablePath: self.executablePath),
            requested: requested,
            preservesRequestedIdentity: true)
    }

    func testExactReadOnlyObservationCapturesActionableReceiptWhenCallerHasNone() throws {
        let bounds = CGRect(x: 1, y: 2, width: 300, height: 200)
        let receipt = Self.receipt(windowID: 42, processIdentifier: 123, bounds: bounds)
        var captureCount = 0
        var validationCount = 0

        let resolved = try ElementDetectionService.resolveActionableWindowReceipt(
            windowID: 42,
            processIdentifier: 123,
            capturedBounds: nil,
            receipt: nil,
            receiptProvider: { windowID in
                captureCount += 1
                XCTAssertEqual(windowID, 42)
                return receipt
            },
            validator: { candidate, candidateBounds in
                validationCount += 1
                return candidate == receipt && candidateBounds == bounds
            })

        XCTAssertEqual(resolved.identity, receipt)
        XCTAssertEqual(resolved.bounds, bounds)
        XCTAssertEqual(captureCount, 1)
        XCTAssertEqual(validationCount, 1)
    }

    func testExistingReadOnlyObservationReceiptIsPreservedAndRevalidated() throws {
        let bounds = CGRect(x: 1, y: 2, width: 300, height: 200)
        let receipt = Self.receipt(windowID: 42, processIdentifier: 123, bounds: bounds)

        let resolved = try ElementDetectionService.resolveActionableWindowReceipt(
            windowID: 42,
            processIdentifier: 123,
            capturedBounds: bounds,
            receipt: receipt,
            receiptProvider: { _ in
                XCTFail("An existing capture receipt must not be replaced")
                return nil
            },
            validator: { candidate, candidateBounds in
                candidate == receipt && candidateBounds == bounds
            })

        XCTAssertEqual(resolved.identity, receipt)
        XCTAssertEqual(resolved.bounds, bounds)
    }

    func testReadOnlyObservationReceiptDriftFailsClosed() {
        let bounds = CGRect(x: 1, y: 2, width: 300, height: 200)
        let receipt = Self.receipt(windowID: 42, processIdentifier: 123, bounds: bounds)

        XCTAssertThrowsError(try ElementDetectionService.resolveActionableWindowReceipt(
            windowID: 42,
            processIdentifier: 123,
            capturedBounds: bounds,
            receipt: receipt,
            receiptProvider: { _ in receipt },
            validator: { _, _ in false }))
        { error in
            XCTAssertTrue(error.localizedDescription.contains("changed before AX traversal"))
        }
    }

    func testReadOnlyObservationRejectsReceiptForAnotherProcess() {
        let bounds = CGRect(x: 1, y: 2, width: 300, height: 200)
        let receipt = Self.receipt(windowID: 42, processIdentifier: 999, bounds: bounds)

        XCTAssertThrowsError(try ElementDetectionService.resolveActionableWindowReceipt(
            windowID: 42,
            processIdentifier: 123,
            capturedBounds: bounds,
            receipt: nil,
            receiptProvider: { _ in receipt },
            validator: { _, _ in true }))
        { error in
            XCTAssertTrue(error.localizedDescription.contains("changed before AX traversal"))
        }
    }

    func testReadOnlyObservationRejectsLegacyReceiptWithoutEmbeddedBounds() {
        let bounds = CGRect(x: 1, y: 2, width: 300, height: 200)
        let receipt = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 123,
            ownerProcessStartIdentity: 7,
            capturedBounds: nil)

        XCTAssertThrowsError(try ElementDetectionService.resolveActionableWindowReceipt(
            windowID: 42,
            processIdentifier: 123,
            capturedBounds: bounds,
            receipt: receipt,
            receiptProvider: { _ in receipt },
            validator: { _, _ in true }))
        { error in
            XCTAssertTrue(error.localizedDescription.contains("could not capture"))
        }
    }

    func testReadOnlyObservationRejectsZeroProcessGeneration() {
        let bounds = CGRect(x: 1, y: 2, width: 300, height: 200)
        let receipt = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 123,
            ownerProcessStartIdentity: 0,
            capturedBounds: bounds)

        XCTAssertThrowsError(try ElementDetectionService.resolveActionableWindowReceipt(
            windowID: 42,
            processIdentifier: 123,
            capturedBounds: bounds,
            receipt: receipt,
            receiptProvider: { _ in receipt },
            validator: { _, _ in true }))
        { error in
            XCTAssertTrue(error.localizedDescription.contains("could not capture"))
        }
    }

    private static func window(
        id: Int,
        title: String,
        bounds: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600),
        isMainWindow: Bool = false,
        index: Int) -> ServiceWindowInfo
    {
        ServiceWindowInfo(
            windowID: id,
            title: title,
            bounds: bounds,
            isMinimized: false,
            isMainWindow: isMainWindow,
            windowLevel: 0,
            alpha: 1,
            index: index,
            layer: 0,
            isOnScreen: true,
            sharingState: .readOnly,
            isExcludedFromWindowsMenu: false)
    }

    private static func receipt(
        windowID: Int,
        processIdentifier: pid_t,
        bounds: CGRect) -> WindowMutationIdentity
    {
        WindowMutationIdentity(
            windowID: windowID,
            ownerProcessIdentifier: processIdentifier,
            ownerProcessStartIdentity: 7,
            capturedBounds: bounds)
    }
}
