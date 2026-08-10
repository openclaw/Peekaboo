import CoreGraphics
import Testing
@testable @_spi(Testing) import PeekabooAutomationKit

struct ScreenCapturePlannerTests {
    @Test
    func `desktop independent logical window capture cannot become a display canvas`() {
        let size = ScreenCapturePlanner.desktopIndependentWindowPixelSize(
            filterContentRect: CGRect(x: 420, y: 180, width: 935, height: 598),
            fallbackWindowFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            pointPixelScale: 2,
            fallbackNativeScale: 2,
            useNativeScale: false)

        #expect(size.width == 935)
        #expect(size.height == 598)
        #expect(ScreenCapturePlanner.matchesExpectedWindowPixelSize(
            imageWidth: 935,
            imageHeight: 598,
            expected: size))
        #expect(!ScreenCapturePlanner.matchesExpectedWindowPixelSize(
            imageWidth: 1920,
            imageHeight: 1080,
            expected: size))
    }

    @Test
    func `desktop independent native capture uses filter scale`() {
        let size = ScreenCapturePlanner.desktopIndependentWindowPixelSize(
            filterContentRect: CGRect(x: -900, y: 80, width: 935, height: 598),
            fallbackWindowFrame: CGRect(x: -900, y: 80, width: 1920, height: 1080),
            pointPixelScale: 2,
            fallbackNativeScale: 1,
            useNativeScale: true)

        #expect(size.width == 1870)
        #expect(size.height == 1196)
    }

    @Test
    func `desktop independent capture falls back from unusable filter geometry and scale`() {
        let size = ScreenCapturePlanner.desktopIndependentWindowPixelSize(
            filterContentRect: .zero,
            fallbackWindowFrame: CGRect(x: 400, y: 200, width: 935, height: 598),
            pointPixelScale: .nan,
            fallbackNativeScale: 2,
            useNativeScale: true)

        #expect(size.width == 1870)
        #expect(size.height == 1196)
    }
}
