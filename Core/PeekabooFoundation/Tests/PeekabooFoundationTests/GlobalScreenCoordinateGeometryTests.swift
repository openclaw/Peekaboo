import CoreGraphics
import Testing
@testable import PeekabooFoundation

struct GlobalScreenCoordinateGeometryTests {
    @Test
    func `Global and AppKit conversions cover vertical display arrangements`() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)

        #expect(GlobalScreenCoordinateGeometry.appKitPoint(
            fromGlobalDisplay: CGPoint(x: 100, y: 50),
            primaryScreenFrame: primary) == CGPoint(x: 100, y: 850))
        #expect(GlobalScreenCoordinateGeometry.appKitRect(
            fromGlobalDisplay: CGRect(x: 100, y: -1100, width: 200, height: 40),
            primaryScreenFrame: primary) == CGRect(x: 100, y: 1960, width: 200, height: 40))
        #expect(GlobalScreenCoordinateGeometry.appKitRect(
            fromGlobalDisplay: CGRect(x: -300, y: 1000, width: 200, height: 40),
            primaryScreenFrame: primary) == CGRect(x: -300, y: -140, width: 200, height: 40))
    }

    @Test
    func `Rectangle conversion is reversible and preserves logical point size`() {
        let primary = CGRect(x: 0, y: 0, width: 3200, height: 1800)
        let global = CGRect(x: 10, y: 20, width: 320, height: 44)
        let appKit = GlobalScreenCoordinateGeometry.appKitRect(
            fromGlobalDisplay: global,
            primaryScreenFrame: primary)

        #expect(appKit.size == global.size)
        #expect(GlobalScreenCoordinateGeometry.globalDisplayRect(
            fromAppKit: appKit,
            primaryScreenFrame: primary) == global)
    }
}
