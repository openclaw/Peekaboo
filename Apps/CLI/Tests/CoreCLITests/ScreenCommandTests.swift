import CoreGraphics
import Foundation
import PeekabooCore
import Testing
@testable import PeekabooCLI

struct ScreenCommandTests {
    private struct ProjectionCase: Sendable {
        let frame: CGRect
        let visibleFrame: CGRect
        let expectedBounds: [String: Int]
        let expectedVisibleBounds: [String: Int]
        var isPrimary = true
        var scale: CGFloat = 1
    }

    private nonisolated static let cases: [ProjectionCase] = [
        .init(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 52, width: 1920, height: 998),
            expectedBounds: ["x": 0, "y": 0, "width": 1920, "height": 1080],
            expectedVisibleBounds: ["x": 0, "y": 30, "width": 1920, "height": 998]
        ),
        .init(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 64, y: 0, width: 1856, height: 1050),
            expectedBounds: ["x": 0, "y": 0, "width": 1920, "height": 1080],
            expectedVisibleBounds: ["x": 64, "y": 30, "width": 1856, "height": 1050]
        ),
        .init(
            frame: CGRect(x: 0, y: 1080, width: 1600, height: 900),
            visibleFrame: CGRect(x: 0, y: 1100, width: 1600, height: 850),
            expectedBounds: ["x": 0, "y": -900, "width": 1600, "height": 900],
            expectedVisibleBounds: ["x": 0, "y": -870, "width": 1600, "height": 850],
            isPrimary: false
        ),
        .init(
            frame: CGRect(x: -100, y: -900, width: 1600, height: 900),
            visibleFrame: CGRect(x: -100, y: -880, width: 1600, height: 850),
            expectedBounds: ["x": -100, "y": 1080, "width": 1600, "height": 900],
            expectedVisibleBounds: ["x": -100, "y": 1110, "width": 1600, "height": 850],
            isPrimary: false
        ),
        .init(
            frame: CGRect(x: -1600, y: 0, width: 1600, height: 900),
            visibleFrame: CGRect(x: -1536, y: 0, width: 1536, height: 870),
            expectedBounds: ["x": -1600, "y": 180, "width": 1600, "height": 900],
            expectedVisibleBounds: ["x": -1536, "y": 210, "width": 1536, "height": 870],
            isPrimary: false
        ),
        .init(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 52, width: 1920, height: 998),
            expectedBounds: ["x": 0, "y": 0, "width": 1920, "height": 1080],
            expectedVisibleBounds: ["x": 0, "y": 30, "width": 1920, "height": 998],
            scale: 2
        ),
        .init(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            expectedBounds: ["x": 0, "y": 0, "width": 1920, "height": 1080],
            expectedVisibleBounds: ["x": 0, "y": 0, "width": 1920, "height": 1080]
        ),
    ]

    @Test(arguments: Self.cases)
    @MainActor
    private func `Screen JSON retains legacy fields and exposes global logical visible bounds`(
        fixture: ProjectionCase
    ) throws {
        let screen = ScreenInfo(
            index: fixture.isPrimary ? 0 : 1,
            name: "Synthetic display",
            frame: fixture.frame,
            visibleFrame: fixture.visibleFrame,
            isPrimary: fixture.isPrimary,
            scaleFactor: fixture.scale,
            displayID: 42
        )
        let primary = ScreenInfo(
            index: 0,
            name: "Primary",
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 52, width: 1920, height: 998),
            isPrimary: true,
            scaleFactor: 1,
            displayID: 1
        )
        let screens = fixture.isPrimary ? [screen] : [screen, primary]
        let data = ScreenCommand.ListSubcommand().buildScreenListData(from: screens)
        let encoded = try JSONEncoder().encode(data)
        let decoded = try JSONDecoder().decode(Inventory.self, from: encoded)
        let projected = try #require(decoded.screens.first)

        #expect(decoded.primaryIndex == (fixture.isPrimary ? 0 : 1))
        #expect(projected.index == screen.index)
        #expect(projected.name == screen.name)
        #expect(projected.displayID == 42)
        #expect(projected.isPrimary == fixture.isPrimary)
        #expect(projected.scaleFactor == fixture.scale)
        #expect(projected.bounds == fixture.expectedBounds)
        #expect(projected.visibleBounds == fixture.expectedVisibleBounds)
        let expectedX = try #require(fixture.expectedBounds["x"])
        let expectedY = try #require(fixture.expectedBounds["y"])
        #expect(projected.position == ["x": expectedX, "y": expectedY])
        #expect(projected.resolution == ["width": Int(fixture.frame.width), "height": Int(fixture.frame.height)])
        #expect(projected.visibleArea == [
            "width": Int(fixture.visibleFrame.width),
            "height": Int(fixture.visibleFrame.height),
        ])
    }

    @Test
    @MainActor
    func `Empty display inventory stays empty`() throws {
        let data = ScreenCommand.ListSubcommand().buildScreenListData(from: [])
        let decoded = try JSONDecoder().decode(Inventory.self, from: JSONEncoder().encode(data))
        #expect(decoded.screens.isEmpty)
        #expect(decoded.primaryIndex == nil)
    }

    private struct Inventory: Decodable {
        let screens: [Display]
        let primaryIndex: Int?
    }

    private struct Display: Decodable {
        let index: Int
        let name: String
        let displayID: Int
        let isPrimary: Bool
        let scaleFactor: CGFloat
        let bounds: [String: Int]
        let visibleBounds: [String: Int]
        let position: [String: Int]
        let resolution: [String: Int]
        let visibleArea: [String: Int]
    }
}
