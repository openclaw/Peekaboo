import CoreGraphics
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomation
@testable import PeekabooCore
@testable import PeekabooVisualizer

@Suite(.tags(.models, .unit))
struct ApplicationModelsTests {
    // MARK: - Model Structure Tests

    @Test(.tags(.fast))
    func `WindowBounds initialization and properties`() {
        let bounds = WindowBounds(x: 100, y: 200, width: 1200, height: 800)

        #expect(bounds.x == 100)
        #expect(bounds.y == 200)
        #expect(bounds.width == 1200)
        #expect(bounds.height == 800)
    }

    @Test(.tags(.fast))
    func `WindowInfo initialization`() {
        let bounds = WindowBounds(x: 100, y: 200, width: 1200, height: 800)
        let windowInfo = WindowInfo(
            window_title: "Safari - Main Window",
            window_id: 12345,
            window_index: 0,
            bounds: bounds,
            is_on_screen: true)

        #expect(windowInfo.window_title == "Safari - Main Window")
        #expect(windowInfo.window_id == 12345)
        #expect(windowInfo.window_index == 0)
        #expect(windowInfo.bounds != nil)
        #expect(windowInfo.bounds?.x == 100)
        #expect(windowInfo.bounds?.y == 200)
        #expect(windowInfo.bounds?.width == 1200)
        #expect(windowInfo.bounds?.height == 800)
        #expect(windowInfo.is_on_screen == true)
    }

    @Test(.tags(.fast))
    func `target application info`() {
        let targetApp = TargetApplicationInfo(
            app_name: "Safari",
            bundle_id: "com.apple.Safari",
            pid: 1234)

        #expect(targetApp.app_name == "Safari")
        #expect(targetApp.bundle_id == "com.apple.Safari")
        #expect(targetApp.pid == 1234)
    }

    // MARK: - Collection Data Tests

    @Test(.tags(.fast))
    func `WindowListData with target application`() {
        let bounds = WindowBounds(x: 100, y: 100, width: 1200, height: 800)
        let window = WindowInfo(
            window_title: "Safari - Main Window",
            window_id: 12345,
            window_index: 0,
            bounds: bounds,
            is_on_screen: true)

        let targetApp = TargetApplicationInfo(
            app_name: "Safari",
            bundle_id: "com.apple.Safari",
            pid: 1234)

        let windowListData = WindowListData(
            windows: [window],
            target_application_info: targetApp)

        #expect(windowListData.windows.count == 1)
        #expect(windowListData.windows[0].window_title == "Safari - Main Window")
        #expect(windowListData.target_application_info.app_name == "Safari")
        #expect(windowListData.target_application_info.bundle_id == "com.apple.Safari")
        #expect(windowListData.target_application_info.pid == 1234)
    }
}
