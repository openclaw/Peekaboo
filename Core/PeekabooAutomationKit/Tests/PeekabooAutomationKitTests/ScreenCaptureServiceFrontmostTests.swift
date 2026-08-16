import CoreGraphics
import PeekabooFoundation
import XCTest
@testable @_spi(Testing) import PeekabooAutomationKit

@MainActor
final class ScreenCaptureServiceFrontmostTests: XCTestCase {
    func testExplicitLegacyEngineSelectsOnlyIsolatedLegacyAPI() {
        let runner = ScreenCaptureFallbackRunner(apis: [.modern, .legacy])
        XCTAssertEqual(runner.apis(for: .legacy), [.legacy])
        XCTAssertEqual(runner.apis(for: .modern), [.modern])
    }

    func testCaptureFrontmostUsesApplicationResolverIdentity() async throws {
        let processIdentity = ApplicationProcessIdentity(
            processIdentifier: 1234,
            processStartIdentity: 5678)
        let baseApp = ServiceApplicationInfo(
            processIdentifier: 1234,
            processStartIdentity: 5678,
            bundleIdentifier: "com.example.Frontmost",
            name: "Frontmost",
            bundlePath: "/Applications/Frontmost.app",
            isActive: true,
            isHidden: false,
            windowCount: 1)
        let resolution = try XCTUnwrap(ApplicationIdentifierMatcher.resolution(
            for: "Frontmost",
            in: [ApplicationIdentifierMatcher.Candidate(baseApp)]))
        let app = baseApp.withSelectorResolutionProofs([
            resolution.proof(selectedProcessIdentity: processIdentity),
        ])
        let window = ScreenCaptureService.TestFixtures.Window(
            application: app,
            title: "Frontmost Window",
            bounds: CGRect(x: 10, y: 20, width: 320, height: 200),
            imageData: Data())
        let fixtures = ScreenCaptureService.TestFixtures(
            displays: [
                .init(
                    name: "Built-in",
                    bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
                    scaleFactor: 2,
                    imageSize: CGSize(width: 1600, height: 1200),
                    imageData: Data()),
            ],
            windows: [window],
            frontmostApplication: app)
        let service = ScreenCaptureService.makeTestService(fixtures: fixtures)

        let result = try await service.captureFrontmost(scale: .native)

        XCTAssertEqual(result.metadata.mode, .frontmost)
        XCTAssertEqual(result.metadata.applicationInfo?.processIdentifier, app.processIdentifier)
        XCTAssertEqual(result.metadata.applicationInfo?.bundleIdentifier, app.bundleIdentifier)
        XCTAssertEqual(result.metadata.windowInfo?.title, "Frontmost Window")
        XCTAssertEqual(result.metadata.size, CGSize(width: 640, height: 400))
        XCTAssertEqual(result.metadata.selectorResolutionProofs, app.selectorResolutionProofs)
    }

    func testCaptureFrontmostReportsMissingApplication() async {
        let fixtures = ScreenCaptureService.TestFixtures(
            displays: [
                .init(
                    name: "Built-in",
                    bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
                    scaleFactor: 2,
                    imageSize: CGSize(width: 1600, height: 1200),
                    imageData: Data()),
            ])
        let service = ScreenCaptureService.makeTestService(fixtures: fixtures)

        do {
            _ = try await service.captureFrontmost()
            XCTFail("Expected frontmost capture to fail without a frontmost application")
        } catch let PeekabooError.appNotFound(identifier) {
            XCTAssertEqual(identifier, "frontmost")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
