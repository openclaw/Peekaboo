import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

/// Fake accessibility window whose size setter clamps to a minimum, mirroring how AppKit
/// constrains AX resize requests for windows with a minimum content size (e.g. SwiftUI
/// `.frame(minWidth:minHeight:)`). AX reports success for such requests, so the CLI must
/// read the frame back and surface the clamp instead of echoing the requested bounds.
@MainActor
private final class ClampingWindowService: WindowManagementServiceProtocol {
    var frame: CGRect
    let minSize: CGSize
    let title: String

    init(frame: CGRect, minSize: CGSize, title: String = "Window Fixture") {
        self.frame = frame
        self.minSize = minSize
        self.title = title
    }

    func closeWindow(target _: WindowTarget) async throws {}
    func minimizeWindow(target _: WindowTarget) async throws {}
    func maximizeWindow(target _: WindowTarget) async throws {}

    @MainActor
    func moveWindow(target _: WindowTarget, to position: CGPoint) async throws {
        self.frame.origin = position
    }

    @MainActor
    func resizeWindow(target _: WindowTarget, to size: CGSize) async throws {
        self.frame.size = self.clamped(size)
    }

    @MainActor
    func setWindowBounds(target _: WindowTarget, bounds: CGRect) async throws {
        self.frame = CGRect(origin: bounds.origin, size: self.clamped(bounds.size))
    }

    func focusWindow(target _: WindowTarget) async throws {}

    @MainActor
    func listWindows(target _: WindowTarget) async throws -> [ServiceWindowInfo] {
        [ServiceWindowInfo(windowID: 1, title: self.title, bounds: self.frame)]
    }

    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        nil
    }

    private func clamped(_ size: CGSize) -> CGSize {
        CGSize(
            width: max(size.width, self.minSize.width),
            height: max(size.height, self.minSize.height)
        )
    }
}

@MainActor
struct WindowGeometryVerificationTests {
    private let target = WindowTarget.application("Playground")

    // MARK: - Command-flow regressions (mutate -> read back -> verify)

    @Test func `clamped resize reports the actual clamped frame with a warning`() async throws {
        let service = ClampingWindowService(
            frame: CGRect(x: 300, y: 200, width: 1500, height: 900),
            minSize: CGSize(width: 1200, height: 800)
        )

        let output = try await self.performResize(service: service, to: CGSize(width: 900, height: 700))

        let bounds = try #require(output.result.new_bounds)
        #expect(bounds.width == 1200)
        #expect(bounds.height == 800)
        #expect(bounds.x == 300)
        #expect(bounds.y == 200)

        let requested = try #require(output.result.requested_bounds)
        #expect(requested.width == 900)
        #expect(requested.height == 700)

        let warning = try #require(output.result.warning)
        #expect(warning.contains("requested size 900x700"))
        #expect(warning.contains("actual size 1200x800"))
        #expect(output.result.success)
    }

    @Test func `fully ignored resize throws instead of claiming success`() async throws {
        // Window already at its minimum: the resize request changes nothing at all.
        let service = ClampingWindowService(
            frame: CGRect(x: 300, y: 200, width: 1200, height: 832),
            minSize: CGSize(width: 1200, height: 832)
        )

        await #expect(throws: WindowGeometryIgnoredError.self) {
            _ = try await self.performResize(service: service, to: CGSize(width: 900, height: 700))
        }
        // The window frame stayed untouched.
        #expect(service.frame == CGRect(x: 300, y: 200, width: 1200, height: 832))
    }

    @Test func `unconstrained resize reports the exact requested bounds without warning`() async throws {
        let service = ClampingWindowService(
            frame: CGRect(x: 300, y: 200, width: 1200, height: 832),
            minSize: CGSize(width: 100, height: 100)
        )

        let output = try await self.performResize(service: service, to: CGSize(width: 900, height: 700))

        let bounds = try #require(output.result.new_bounds)
        #expect(bounds.width == 900)
        #expect(bounds.height == 700)
        #expect(output.result.warning == nil)
        #expect(output.result.success)
    }

    @Test func `set-bounds with clamped size keeps the applied position and warns`() async throws {
        let service = ClampingWindowService(
            frame: CGRect(x: 300, y: 200, width: 1200, height: 832),
            minSize: CGSize(width: 1200, height: 832)
        )
        let requestedBounds = CGRect(x: 100, y: 120, width: 900, height: 700)

        let original = try await WindowServiceBridge.listWindows(windows: service, target: self.target).first
        try await WindowServiceBridge.setWindowBounds(windows: service, target: self.target, bounds: requestedBounds)
        let refreshed = try await WindowServiceBridge.listWindows(windows: service, target: self.target).first

        let output = try verifiedWindowActionResult(
            action: "set-bounds",
            appName: "Playground",
            requested: WindowGeometryExpectation(origin: requestedBounds.origin, size: requestedBounds.size),
            originalInfo: original,
            refreshedInfo: refreshed
        )

        let bounds = try #require(output.result.new_bounds)
        #expect(bounds.x == 100)
        #expect(bounds.y == 120)
        #expect(bounds.width == 1200)
        #expect(bounds.height == 832)

        let warning = try #require(output.result.warning)
        #expect(warning.contains("requested size 900x700"))
        #expect(output.result.success)
    }

    @Test func `move reports the achieved origin without warning`() async throws {
        let service = ClampingWindowService(
            frame: CGRect(x: 300, y: 200, width: 1200, height: 832),
            minSize: CGSize(width: 1200, height: 832)
        )
        let newOrigin = CGPoint(x: 40, y: 60)

        let original = try await WindowServiceBridge.listWindows(windows: service, target: self.target).first
        try await WindowServiceBridge.moveWindow(windows: service, target: self.target, to: newOrigin)
        let refreshed = try await WindowServiceBridge.listWindows(windows: service, target: self.target).first

        let output = try verifiedWindowActionResult(
            action: "move",
            appName: "Playground",
            requested: WindowGeometryExpectation(origin: newOrigin, size: nil),
            originalInfo: original,
            refreshedInfo: refreshed
        )

        let bounds = try #require(output.result.new_bounds)
        #expect(bounds.x == 40)
        #expect(bounds.y == 60)
        #expect(output.result.warning == nil)
    }

    // MARK: - Outcome evaluation

    @Test func `outcome is applied when the achieved frame matches within tolerance`() {
        let outcome = evaluateWindowGeometryOutcome(
            action: "resize",
            requested: WindowGeometryExpectation(origin: nil, size: CGSize(width: 900, height: 700)),
            original: CGRect(x: 0, y: 0, width: 1200, height: 832),
            achieved: CGRect(x: 0, y: 0, width: 900.5, height: 699.5)
        )
        #expect(outcome == .applied)
    }

    @Test func `outcome is constrained when the frame changed but missed the request`() {
        let outcome = evaluateWindowGeometryOutcome(
            action: "resize",
            requested: WindowGeometryExpectation(origin: nil, size: CGSize(width: 900, height: 700)),
            original: CGRect(x: 0, y: 0, width: 1500, height: 900),
            achieved: CGRect(x: 0, y: 0, width: 1200, height: 800)
        )
        guard case let .constrained(warning) = outcome else {
            Issue.record("Expected constrained outcome, got \(outcome)")
            return
        }
        #expect(warning.contains("requested size 900x700"))
        #expect(warning.contains("actual size 1200x800"))
    }

    @Test func `outcome is ignored when the frame did not change at all`() {
        let outcome = evaluateWindowGeometryOutcome(
            action: "resize",
            requested: WindowGeometryExpectation(origin: nil, size: CGSize(width: 900, height: 700)),
            original: CGRect(x: 300, y: 200, width: 1200, height: 832),
            achieved: CGRect(x: 300, y: 200, width: 1200, height: 832)
        )
        guard case let .ignored(reason) = outcome else {
            Issue.record("Expected ignored outcome, got \(outcome)")
            return
        }
        #expect(reason.contains("had no effect"))
        #expect(reason.contains("requested size 900x700"))
    }

    @Test func `outcome is unverified when the frame cannot be read back`() {
        let outcome = evaluateWindowGeometryOutcome(
            action: "move",
            requested: WindowGeometryExpectation(origin: CGPoint(x: 10, y: 10), size: nil),
            original: CGRect(x: 0, y: 0, width: 500, height: 500),
            achieved: nil
        )
        guard case let .unverified(warning) = outcome else {
            Issue.record("Expected unverified outcome, got \(outcome)")
            return
        }
        #expect(warning.contains("Could not read back"))
    }

    @Test func `outcome is ignored when only the unmet component stayed unchanged`() {
        // set-bounds that repeats the current origin while requesting an impossible size:
        // nothing about the frame changed, so this must not count as a partial application.
        let outcome = evaluateWindowGeometryOutcome(
            action: "set-bounds",
            requested: WindowGeometryExpectation(
                origin: CGPoint(x: 300, y: 200),
                size: CGSize(width: 900, height: 700)
            ),
            original: CGRect(x: 300, y: 200, width: 1200, height: 832),
            achieved: CGRect(x: 300, y: 200, width: 1200, height: 832)
        )
        guard case .ignored = outcome else {
            Issue.record("Expected ignored outcome, got \(outcome)")
            return
        }
    }

    // MARK: - Helpers

    private func performResize(
        service: ClampingWindowService,
        to size: CGSize
    ) async throws -> VerifiedWindowActionOutput {
        // Mirrors the ResizeSubcommand flow: mutate via the bridge, read back, verify.
        let original = try await WindowServiceBridge.listWindows(windows: service, target: self.target).first
        try await WindowServiceBridge.resizeWindow(windows: service, target: self.target, to: size)
        let refreshed = try await WindowServiceBridge.listWindows(windows: service, target: self.target).first
        return try verifiedWindowActionResult(
            action: "resize",
            appName: "Playground",
            requested: WindowGeometryExpectation(origin: nil, size: size),
            originalInfo: original,
            refreshedInfo: refreshed
        )
    }
}
