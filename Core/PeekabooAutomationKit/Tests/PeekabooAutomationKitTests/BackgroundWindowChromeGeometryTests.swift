import CoreGraphics
import Testing
@testable import PeekabooAutomationKit

struct BackgroundWindowChromeGeometryTests {
    @Test
    func `recorded standard window chooses blank chrome rather than the title`() throws {
        let geometry = Self.fixture()
        let point = try #require(geometry.candidatePoint())
        #expect(point == CGPoint(x: 517, y: 86))
        #expect(geometry.admits(point))
        #expect(!geometry.admits(CGPoint(x: 322, y: 82)))
        #expect(!geometry.admits(CGPoint(x: 48, y: 86)))
        #expect(!geometry.admits(CGPoint(x: 517, y: 110)))
    }

    @Test
    func `recorded TextEdit titlebar rectangles exclude menu title and document proxy`() throws {
        let geometry = BackgroundWindowChromeGeometry(
            bounds: CGRect(x: 242, y: 106, width: 627, height: 877),
            windowControls: [
                CGRect(x: 250, y: 114, width: 16, height: 16),
                CGRect(x: 273, y: 114, width: 16, height: 16),
                CGRect(x: 296, y: 114, width: 16, height: 16),
            ],
            occupiedFrames: [
                CGRect(x: 323, y: 112, width: 18, height: 18),
                CGRect(x: 342, y: 114, width: 205, height: 16),
                CGRect(x: 546, y: 113, width: 12, height: 18),
                CGRect(x: 242, y: 174, width: 627, height: 809),
            ])
        let point = try #require(geometry.candidatePoint())
        #expect(point.x > 562 && point.x < 865)
        #expect(geometry.admits(CGPoint(x: 810, y: 120)))
        #expect(!geometry.admits(CGPoint(x: 554, y: 122)))
        #expect(!geometry.admits(CGPoint(x: 333, y: 120)))
        #expect(!geometry.admits(CGPoint(x: 400, y: 120)))
    }

    @Test
    func `recorded long title leaves only gaps below the required clearance`() {
        let geometry = BackgroundWindowChromeGeometry(
            bounds: CGRect(x: 32, y: 70, width: 580, height: 392),
            windowControls: [
                CGRect(x: 40, y: 78, width: 16, height: 16),
                CGRect(x: 63, y: 78, width: 16, height: 16),
                CGRect(x: 86, y: 78, width: 16, height: 16),
            ],
            occupiedFrames: [CGRect(x: 114, y: 78, width: 488, height: 16)])
        #expect(geometry.candidatePoint() == nil)
        #expect(!geometry.admits(CGPoint(x: 108, y: 86)))
        #expect(!geometry.admits(CGPoint(x: 607, y: 86)))
    }

    @Test
    func `opaque overlapping chrome leaves no admitted point`() {
        let geometry = Self.fixture(extra: [CGRect(x: 32, y: 70, width: 580, height: 40)])
        #expect(geometry.candidatePoint() == nil)
        #expect(!geometry.admits(CGPoint(x: 517, y: 86)))
    }

    @Test(arguments: [CGRect.zero, CGRect(x: 0, y: 0, width: -1, height: 1), .infinite])
    func `missing or malformed occupied geometry refuses`(frame: CGRect) {
        #expect(Self.fixture(extra: [frame]).candidatePoint() == nil)
    }

    @Test
    func `missing misaligned or outside window controls refuse`() {
        let valid = Self.fixture()
        for controls in [
            Array(valid.windowControls.prefix(2)),
            [valid.windowControls[0], valid.windowControls[1], CGRect(x: 86, y: 100, width: 16, height: 16)],
            [valid.windowControls[0], valid.windowControls[1], CGRect(x: 800, y: 78, width: 16, height: 16)],
        ] {
            #expect(BackgroundWindowChromeGeometry(
                bounds: valid.bounds, windowControls: controls, occupiedFrames: []).candidatePoint() == nil)
        }
    }

    @Test
    func `revalidation rejects a newly occupied retained point`() throws {
        let point = try #require(Self.fixture().candidatePoint())
        let changed = Self.fixture(extra: [CGRect(x: 500, y: 78, width: 34, height: 16)])
        #expect(!changed.admits(point))
        #expect(changed.candidatePoint() != point)
        #expect(!changed.admits(CGPoint(x: CGFloat.nan, y: 86)))
    }

    @Test
    func `revalidation requires the same minimum clearance as initial admission`() {
        let geometry = Self.fixture(extra: [
            CGRect(x: 422, y: 78, width: 89, height: 16),
            CGRect(x: 523, y: 78, width: 89, height: 16),
        ])
        #expect(geometry.candidatePoint() == nil)
        #expect(!geometry.admits(CGPoint(x: 517, y: 86)))
    }

    @Test
    func `finite extreme geometry never returns a nonfinite point`() throws {
        let geometry = BackgroundWindowChromeGeometry(
            bounds: CGRect(x: 1e308, y: 0, width: 1e306, height: 100),
            windowControls: [
                CGRect(x: 1e308, y: 8, width: 1e302, height: 16),
                CGRect(x: 1.00001e308, y: 8, width: 1e302, height: 16),
                CGRect(x: 1.00002e308, y: 8, width: 1e302, height: 16),
            ], occupiedFrames: [])
        let point = try #require(geometry.candidatePoint())
        #expect(point.x.isFinite && point.y.isFinite)
        #expect(geometry.admits(point))
    }

    private static func fixture(extra: [CGRect] = []) -> BackgroundWindowChromeGeometry {
        BackgroundWindowChromeGeometry(
            bounds: CGRect(x: 32, y: 70, width: 580, height: 392),
            windowControls: [
                CGRect(x: 40, y: 78, width: 16, height: 16),
                CGRect(x: 63, y: 78, width: 16, height: 16),
                CGRect(x: 86, y: 78, width: 16, height: 16),
            ],
            occupiedFrames: [
                CGRect(x: 114, y: 78, width: 308, height: 16),
                CGRect(x: 32, y: 102, width: 580, height: 360),
                CGRect(x: 87, y: 79, width: 14, height: 14),
            ] + extra)
    }
}
