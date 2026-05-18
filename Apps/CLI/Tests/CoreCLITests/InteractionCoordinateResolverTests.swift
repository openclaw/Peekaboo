import CoreGraphics
import PeekabooCore
import Testing
@testable import PeekabooCLI

struct InteractionCoordinateResolverTests {
    @Test
    @MainActor
    func `target window coordinates resolve relative to window origin`() throws {
        let window = Self.makeWindow(
            id: 59620,
            title: "Settings",
            bounds: CGRect(x: 200, y: 260, width: 420, height: 300)
        )
        let app = Self.makeApp(name: "OpenClaw Settings", pid: 12345)

        let resolution = try InteractionCoordinateResolver.resolveTargetWindowCoordinates(
            CGPoint(x: 20, y: 19),
            windowInfo: window,
            targetApplication: app
        )

        #expect(resolution.coordinateSpace == .windowRelative)
        #expect(resolution.screenPoint == CGPoint(x: 220, y: 279))
        #expect(resolution.targetWindowID == 59620)
        #expect(resolution.targetApplicationName == "OpenClaw Settings")
        #expect(resolution.diagnostics.coordinateSpace == "window_relative")
        #expect(resolution.diagnostics.targetWindow?.windowID == 59620)
    }

    @Test
    @MainActor
    func `global coordinates stay global without a target window`() throws {
        let resolution = try InteractionCoordinateResolver.resolveTargetWindowCoordinates(
            CGPoint(x: 20, y: 19),
            windowInfo: nil,
            targetApplication: nil
        )

        #expect(resolution.coordinateSpace == .global)
        #expect(resolution.screenPoint == CGPoint(x: 20, y: 19))
        #expect(resolution.windowInfo == nil)
        #expect(resolution.targetApplication == nil)
    }

    @Test
    @MainActor
    func `explicit global coordinates bypass target window conversion`() throws {
        let window = Self.makeWindow(
            id: 59620,
            title: "Settings",
            bounds: CGRect(x: 200, y: 260, width: 420, height: 300)
        )
        let app = Self.makeApp(name: "OpenClaw Settings", pid: 12345)

        let resolution = try InteractionCoordinateResolver.resolveTargetWindowCoordinates(
            CGPoint(x: 220, y: 279),
            windowInfo: window,
            targetApplication: app,
            forceGlobal: true
        )

        #expect(resolution.coordinateSpace == .global)
        #expect(resolution.screenPoint == CGPoint(x: 220, y: 279))
        #expect(resolution.windowInfo == nil)
    }

    @Test
    @MainActor
    func `out of window coordinates fail before click synthesis`() throws {
        let window = Self.makeWindow(
            id: 59620,
            title: "Settings",
            bounds: CGRect(x: 200, y: 260, width: 420, height: 300)
        )

        #expect(throws: (any Error).self) {
            _ = try InteractionCoordinateResolver.resolveTargetWindowCoordinates(
                CGPoint(x: 421, y: 10),
                windowInfo: window,
                targetApplication: nil
            )
        }

        #expect(throws: (any Error).self) {
            _ = try InteractionCoordinateResolver.resolveTargetWindowCoordinates(
                CGPoint(x: 420, y: 10),
                windowInfo: window,
                targetApplication: nil
            )
        }
    }

    private static func makeApp(name: String, pid: Int32) -> ServiceApplicationInfo {
        ServiceApplicationInfo(
            processIdentifier: pid,
            bundleIdentifier: "com.example.\(name.replacingOccurrences(of: " ", with: "-").lowercased())",
            name: name,
            bundlePath: nil,
            isActive: true,
            isHidden: false,
            windowCount: 1,
            activationPolicy: .regular
        )
    }

    private static func makeWindow(id: Int, title: String, bounds: CGRect) -> ServiceWindowInfo {
        ServiceWindowInfo(
            windowID: id,
            title: title,
            bounds: bounds,
            isMinimized: false,
            isMainWindow: true,
            windowLevel: 0,
            alpha: 1.0,
            index: 0
        )
    }
}
