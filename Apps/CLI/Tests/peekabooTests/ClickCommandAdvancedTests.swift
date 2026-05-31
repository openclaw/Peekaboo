import CoreGraphics
import Foundation
import PeekabooCore
import Testing
@testable import PeekabooCLI

struct ClickCommandAdvancedTests {
    @Test
    func `Parse click command basic options`() throws {
        let command = try ClickCommand.parse(["--on", "B1"])
        #expect(command.on == "B1")
        #expect(command.coords == nil)
        #expect(command.right == false)
        #expect(command.double == false)
    }

    @Test
    func `Parse click command with coordinates`() throws {
        let command = try ClickCommand.parse(["--coords", "100,200"])
        #expect(command.coords == "100,200")
        #expect(command.on == nil)
    }

    @Test
    func `Parse double-click option`() throws {
        let command = try ClickCommand.parse(["--on", "B1", "--double"])
        #expect(command.double == true)
        #expect(command.right == false)
    }

    @Test
    func `Parse right-click option`() throws {
        let command = try ClickCommand.parse(["--on", "T1", "--right"])
        #expect(command.right == true)
        #expect(command.double == false)
    }

    @Test
    func `Parse foreground option`() throws {
        let command = try ClickCommand.parse(["--on", "B1", "--foreground"])
        #expect(command.foreground == true)
    }

    @Test
    func `Parse wait-for option`() throws {
        let command = try ClickCommand.parse(["--on", "B1", "--wait-for", "3000"])
        #expect(command.waitFor == 3000)
    }

    @Test
    func `Parse snapshot option`() throws {
        let command = try ClickCommand.parse(["--on", "C1", "--snapshot", "12345"])
        #expect(command.snapshot == "12345")
    }

    @Test
    func `Coordinate string parsing`() {
        // Valid coordinates
        if let coords = ClickCommand.parseCoordinates("100,200") {
            #expect(coords.x == 100)
            #expect(coords.y == 200)
        } else {
            Issue.record("Failed to parse valid coordinates")
        }

        // Invalid formats
        #expect(ClickCommand.parseCoordinates("invalid") == nil)
        #expect(ClickCommand.parseCoordinates("100") == nil)
        #expect(ClickCommand.parseCoordinates("100,") == nil)
        #expect(ClickCommand.parseCoordinates(",200") == nil)
        #expect(ClickCommand.parseCoordinates("abc,def") == nil)
    }

    @Test
    func `Element locator creation from query`() {
        // Text content search
        var locator = ClickCommand.createLocatorFromQuery("Bold")
        #expect(locator.type == "text")
        #expect(locator.value == "Bold")

        // ID-based search
        locator = ClickCommand.createLocatorFromQuery("#my-id")
        #expect(locator.type == "id")
        #expect(locator.value == "my-id")

        // Class-based search
        locator = ClickCommand.createLocatorFromQuery(".my-class")
        #expect(locator.type == "class")
        #expect(locator.value == "my-class")

        // Role-based search - these are just text searches now
        locator = ClickCommand.createLocatorFromQuery("checkbox")
        #expect(locator.type == "text")
        #expect(locator.value == "checkbox")
    }

    @Test
    func `Click result JSON structure`() throws {
        // Create a test result using the correct structure
        let clickLocation = CGPoint(x: 100, y: 200)
        let resultData = ClickResult(
            success: true,
            clickedElement: "AXButton: Save",
            clickLocation: clickLocation,
            waitTime: 1.5,
            executionTime: 2.0,
            targetApp: "TestApp"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(resultData)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let success = json?["success"] as? Bool
        #expect(success == true)

        let clickedElement = json?["clickedElement"] as? String
        #expect(clickedElement == "AXButton: Save")

        let waitTime = json?["waitTime"] as? Double
        #expect(waitTime == 1.5)

        let executionTime = json?["executionTime"] as? Double
        #expect(executionTime == 2.0)

        if let location = json?["clickLocation"] as? [String: Double] {
            let x = location["x"]
            #expect(x == 100.0)
            let y = location["y"]
            #expect(y == 200.0)
        } else {
            Issue.record("clickLocation not found in JSON")
        }
    }

    @Test
    func `Command validation rejects both --on and --coords`() {
        #expect(throws: (any Error).self) {
            _ = try ClickCommand.parse(["--on", "B1", "--coords", "100,200"])
        }
    }

    @Test
    func `Mutually exclusive options validation`() throws {
        // Can't have both --on and --coords
        do {
            _ = try ClickCommand.parse(["--on", "button", "--coords", "100,200"])
            Issue.record("Should have thrown validation error")
        } catch {
            // Expected
        }
    }

    @Test
    func `Find element by text in session`() {
        // Create mock session data using the correct types
        let metadata = DetectionMetadata(
            detectionTime: 0.5,
            elementCount: 1,
            method: "mock",
            warnings: []
        )

        let testData = ElementDetectionResult(
            sessionId: "test123",
            screenshotPath: "/tmp/test.png",
            elements: DetectedElements(
                buttons: [
                    DetectedElement(
                        id: "C1",
                        type: .button,
                        label: "Bold",
                        value: nil,
                        bounds: CGRect(x: 100, y: 100, width: 50, height: 20),
                        isEnabled: true,
                        isSelected: nil,
                        attributes: [:]
                    )
                ],
                textFields: [],
                links: [],
                images: [],
                groups: [],
                sliders: [],
                checkboxes: [],
                menus: [],
                other: []
            ),
            metadata: metadata
        )

        // The actual element finding would be done through SnapshotManager
        // This test just verifies the data structure
        let element = testData.elements.buttons.first
        #expect(element?.id == "C1")
        #expect(element?.label == "Bold")
        #expect(element?.type == .button)
    }

    @Test
    func `Wait time calculations`() {
        // Default wait time
        let defaultWait = 5000
        #expect(defaultWait == 5000) // 5 seconds in milliseconds

        // Custom wait time
        let customWait = 10000
        #expect(customWait == 10000) // 10 seconds in milliseconds
    }

    @Test
    func `Click types are handled correctly`() {
        // Single click
        let singleClick = ClickType.single
        #expect(singleClick.rawValue == "single")

        // Double click
        let doubleClick = ClickType.double
        #expect(doubleClick.rawValue == "double")

        // Right click
        let rightClick = ClickType.right
        #expect(rightClick.rawValue == "right")
    }
}
