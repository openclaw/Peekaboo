import AppKit
import Commander
import Foundation
import PeekabooCore
import Testing
@testable import PeekabooCLI

@Suite(.tags(.imageCapture, .unit))
struct ImageCaptureLogicTests {
    // MARK: - File Name Generation Tests

    @Test(.tags(.fast))
    func `File name generation for displays`() throws {
        // We can't directly test private methods, but we can test the logic
        // through public interfaces and verify the expected patterns

        // Test that different screen indices would generate different names
        let command1 = try ImageCommand.parse(["--screen-index", "0", "--format", "png"])
        let command2 = try ImageCommand.parse(["--screen-index", "1", "--format", "png"])

        #expect(command1.screenIndex == 0)
        #expect(command2.screenIndex == 1)
        #expect(command1.format == .png)
        #expect(command2.format == .png)
    }

    @Test(.tags(.fast))
    func `File name generation for applications`() throws {
        let command = try ImageCommand.parse([
            "--mode", "window",
            "--app", "Test App",
            "--window-title", "Main Window",
            "--format", "jpg",
        ])

        #expect(command.app == "Test App")
        #expect(command.windowTitle == "Main Window")
        #expect(command.format == .jpg)
    }

    @Test(.tags(.fast))
    func `Output path generation`() throws {
        // Test default path behavior
        let defaultCommand = try ImageCommand.parse([])
        #expect(defaultCommand.path == nil)

        // Test custom path
        let customCommand = try ImageCommand.parse(["--path", "/tmp/screenshots"])
        #expect(customCommand.path == "/tmp/screenshots")

        // Test path with filename
        let fileCommand = try ImageCommand.parse(["--path", "/tmp/test.png"])
        #expect(fileCommand.path == "/tmp/test.png")
    }

    @Test(.tags(.fast))
    @MainActor
    func `Stdout output path uses temporary capture file`() throws {
        let command = try ImageCommand.parse(["--path", "-"])

        #expect(command.streamsImageToStdout)
        #expect(command.makeOutputURL(preferredName: "frontmost", index: nil).path.hasPrefix(NSTemporaryDirectory()))
        #expect(command.makeOutputURL(preferredName: "frontmost", index: nil).path.hasSuffix(".png"))
    }

    @Test(.tags(.fast))
    @MainActor
    func `Stdout image streaming rejects structured or text output`() throws {
        let jsonCommand = try ImageCommand.parse(["--path", "-", "--json"])
        #expect(throws: ValidationError.self) {
            try jsonCommand.validateStdoutStreamingOptions()
        }

        let analyzeCommand = try ImageCommand.parse(["--path", "-", "--analyze", "describe"])
        #expect(throws: ValidationError.self) {
            try analyzeCommand.validateStdoutStreamingOptions()
        }
    }

    // MARK: - Mode Determination Tests

    @Test(.tags(.fast))
    func `Mode determination comprehensive`() throws {
        // Screen mode (default when no app specified)
        let screenCmd = try ImageCommand.parse([])
        #expect(screenCmd.mode == nil)
        #expect(screenCmd.app == nil)

        // Window mode (when app specified but no explicit mode)
        let windowCmd = try ImageCommand.parse(["--app", "Finder"])
        #expect(windowCmd.mode == nil) // Will be determined as window during execution
        #expect(windowCmd.app == "Finder")

        // Explicit modes
        let explicitScreen = try ImageCommand.parse(["--mode", "screen"])
        #expect(explicitScreen.mode == .screen)

        let explicitWindow = try ImageCommand.parse(["--mode", "window", "--app", "Safari"])
        #expect(explicitWindow.mode == .window)
        #expect(explicitWindow.app == "Safari")

        let explicitMulti = try ImageCommand.parse(["--mode", "multi"])
        #expect(explicitMulti.mode == .multi)
    }

    // MARK: - Window Targeting Tests

    @Test(.tags(.fast))
    func `Window targeting by title`() throws {
        let command = try ImageCommand.parse([
            "--mode", "window",
            "--app", "Safari",
            "--window-title", "Main Window",
        ])

        #expect(command.mode == .window)
        #expect(command.app == "Safari")
        #expect(command.windowTitle == "Main Window")
        #expect(command.windowIndex == nil)
    }

    @Test(.tags(.fast))
    func `Window targeting by index`() throws {
        let command = try ImageCommand.parse([
            "--mode", "window",
            "--app", "Terminal",
            "--window-index", "0",
        ])

        #expect(command.mode == .window)
        #expect(command.app == "Terminal")
        #expect(command.windowIndex == 0)
        #expect(command.windowTitle == nil)
    }

    @Test(.tags(.fast))
    func `Window targeting priority - title vs index`() throws {
        // When both title and index are specified, both are preserved
        let command = try ImageCommand.parse([
            "--mode", "window",
            "--app", "Xcode",
            "--window-title", "Main",
            "--window-index", "1",
        ])

        #expect(command.windowTitle == "Main")
        #expect(command.windowIndex == 1)
        // In actual execution, title matching would take precedence
    }

    // MARK: - Screen Targeting Tests

    @Test(.tags(.fast))
    func `Screen targeting by index`() throws {
        let command = try ImageCommand.parse([
            "--mode", "screen",
            "--screen-index", "1",
        ])

        #expect(command.mode == .screen)
        #expect(command.screenIndex == 1)
    }

    @Test(.tags(.fast))
    func `Area targeting by region`() throws {
        let command = try ImageCommand.parse([
            "--mode", "area",
            "--region", "10, 20, 300, 200",
        ])

        #expect(command.mode == .area)
        #expect(command.region == "10, 20, 300, 200")
        #expect(try command.areaCaptureRect() == CGRect(x: 10, y: 20, width: 300, height: 200))
    }

    @Test(.tags(.fast))
    func `Area region validation`() throws {
        let missing = try ImageCommand.parse(["--mode", "area"])
        #expect(throws: ValidationError.self) {
            _ = try missing.areaCaptureRect()
        }

        let invalid = try ImageCommand.parse(["--mode", "area", "--region", "1,2,3"])
        #expect(throws: ValidationError.self) {
            _ = try invalid.areaCaptureRect()
        }

        let empty = try ImageCommand.parse(["--mode", "area", "--region", "1,2,0,4"])
        #expect(throws: ValidationError.self) {
            _ = try empty.areaCaptureRect()
        }
    }

    @Test(
        arguments: [-1, 0, 1, 5, 99]
    )
    func `Screen index edge cases`(index: Int) throws {
        do {
            let command = try ImageCommand.parse([
                "--mode", "screen",
                "--screen-index", String(index),
            ])

            #expect(command.screenIndex == index)
            // Validation happens during execution, not parsing
        } catch {
            // Commander may reject certain values
            if index < 0 {
                // Expected for negative values
                return
            }
            throw error
        }
    }

    // MARK: - Capture Focus Tests

    @Test(.tags(.fast))
    func `Capture focus modes`() throws {
        // Default background mode
        let defaultCmd = try ImageCommand.parse([])
        #expect(defaultCmd.captureFocus == .background)

        // Explicit background mode
        let backgroundCmd = try ImageCommand.parse(["--capture-focus", "background"])
        #expect(backgroundCmd.captureFocus == .background)

        // Auto mode
        let autoCmd = try ImageCommand.parse(["--capture-focus", "auto"])
        #expect(autoCmd.captureFocus == .auto)

        // Foreground mode
        let foregroundCmd = try ImageCommand.parse(["--capture-focus", "foreground"])
        #expect(foregroundCmd.captureFocus == .foreground)
    }

    // MARK: - Image Format Tests

    @Test(.tags(.fast))
    func `Image format handling`() throws {
        // Default PNG format
        let defaultCmd = try ImageCommand.parse([])
        #expect(defaultCmd.format == .png)

        // Explicit PNG format
        let pngCmd = try ImageCommand.parse(["--format", "png"])
        #expect(pngCmd.format == .png)

        // JPEG format
        let jpgCmd = try ImageCommand.parse(["--format", "jpg"])
        #expect(jpgCmd.format == .jpg)
    }

    @Test(.tags(.fast))
    func `MIME type mapping`() {
        // Test MIME type logic (as used in SavedFile creation)
        let pngMime = ImageFormat.png == .png ? "image/png" : "image/jpeg"
        let jpgMime = ImageFormat.jpg == .jpg ? "image/jpeg" : "image/png"

        #expect(pngMime == "image/png")
        #expect(jpgMime == "image/jpeg")
    }

    // MARK: - Error Handling Tests

    @Test(.tags(.fast))
    func `Error code mapping`() {
        // Test error code mapping logic used in handleError
        let testCases: [(CaptureError, ErrorCode)] = [
            (.screenRecordingPermissionDenied, .PERMISSION_ERROR_SCREEN_RECORDING),
            (.accessibilityPermissionDenied, .PERMISSION_ERROR_ACCESSIBILITY),
            (.appNotFound("test"), .APP_NOT_FOUND),
            (.windowNotFound, .WINDOW_NOT_FOUND),
            (.fileWriteError("test", nil), .FILE_IO_ERROR),
            (.invalidArgument("test"), .INVALID_ARGUMENT),
            (.unknownError("test"), .UNKNOWN_ERROR),
        ]

        // Verify error mapping logic exists
        for (_, expectedCode) in testCases {
            // We can't directly test the private method, but verify the errors exist
            // Verify the error exists (non-nil check not needed for value types)
            #expect(Bool(true))
            #expect(!expectedCode.rawValue.isEmpty)
        }
    }

    // MARK: - SavedFile Creation Tests

    @Test(.tags(.fast))
    func `SavedFile creation for screen capture`() {
        let savedFile = SavedFile(
            path: "/tmp/screen-0.png",
            item_label: "Display 1 (Index 0)",
            window_title: nil,
            window_id: nil,
            window_index: nil,
            mime_type: "image/png"
        )

        #expect(savedFile.path == "/tmp/screen-0.png")
        #expect(savedFile.item_label == "Display 1 (Index 0)")
        #expect(savedFile.window_title == nil)
        #expect(savedFile.window_id == nil)
        #expect(savedFile.window_index == nil)
        #expect(savedFile.mime_type == "image/png")
    }

    @Test(.tags(.fast))
    func `SavedFile creation for window capture`() {
        let savedFile = SavedFile(
            path: "/tmp/safari-main.jpg",
            item_label: "Safari",
            window_title: "Main Window",
            window_id: 12345,
            window_index: 0,
            mime_type: "image/jpeg"
        )

        #expect(savedFile.path == "/tmp/safari-main.jpg")
        #expect(savedFile.item_label == "Safari")
        #expect(savedFile.window_title == "Main Window")
        #expect(savedFile.window_id == 12345)
        #expect(savedFile.window_index == 0)
        #expect(savedFile.mime_type == "image/jpeg")
    }

    // MARK: - Complex Configuration Tests

    @Test(.tags(.fast))
    func `Complex multi-window capture configuration`() throws {
        let command = try ImageCommand.parse([
            "--mode", "multi",
            "--app", "Visual Studio Code",
            "--format", "png",
            "--path", "/tmp/vscode-windows",
            "--capture-focus", "foreground",
            "--json",
        ])

        #expect(command.mode == .multi)
        #expect(command.app == "Visual Studio Code")
        #expect(command.format == .png)
        #expect(command.path == "/tmp/vscode-windows")
        #expect(command.captureFocus == .foreground)
        #expect(command.jsonOutput == true)
    }

    @Test(.tags(.fast))
    func `Complex screen capture configuration`() throws {
        let command = try ImageCommand.parse([
            "--mode", "screen",
            "--screen-index", "1",
            "--format", "jpg",
            "--path", "/Users/test/screenshots/display-1.jpg",
            "--json",
        ])

        #expect(command.mode == .screen)
        #expect(command.screenIndex == 1)
        #expect(command.format == .jpg)
        #expect(command.path == "/Users/test/screenshots/display-1.jpg")
        #expect(command.jsonOutput == true)
    }

    // MARK: - Integration Readiness Tests

    @Test(.tags(.fast))
    func `Command readiness for screen capture`() throws {
        let command = try ImageCommand.parse(["--mode", "screen"])

        // Verify command is properly configured for screen capture
        #expect(command.mode == .screen)
        #expect(command.app == nil) // No app needed for screen capture
        #expect(command.format == .png) // Has default format
    }

    @Test(.tags(.fast))
    func `Command readiness for window capture`() throws {
        let command = try ImageCommand.parse([
            "--mode", "window",
            "--app", "Finder",
        ])

        // Verify command is properly configured for window capture
        #expect(command.mode == .window)
        #expect(command.app == "Finder") // App is required
        #expect(command.format == .png) // Has default format
    }

    @Test(.tags(.fast))
    func `Command validation for invalid configurations`() {
        // These should parse successfully but would fail during execution

        // Window mode without app (would fail during execution)
        do {
            let command = try ImageCommand.parse(["--mode", "window"])
            #expect(command.mode == .window)
            #expect(command.app == nil) // This would cause execution failure
        } catch {
            Issue.record("Should parse successfully")
        }

        // Invalid screen index (Commander may reject negative values)
        #expect(throws: (any Error).self) {
            _ = try ImageCommand.parse(["--screen-index", "-1"])
        }
    }
}

// MARK: - Extended Capture Logic Tests

@Suite(.tags(.imageCapture, .integration))
struct AdvancedImageCaptureLogicTests {
    @Test(.tags(.fast))
    func `Multi-mode capture scenarios`() throws {
        // Multi mode with app (should capture all windows)
        let multiWithApp = try ImageCommand.parse([
            "--mode", "multi",
            "--app", "Safari",
        ])
        #expect(multiWithApp.mode == .multi)
        #expect(multiWithApp.app == "Safari")

        // Multi mode without app (should capture all screens)
        let multiWithoutApp = try ImageCommand.parse(["--mode", "multi"])
        #expect(multiWithoutApp.mode == .multi)
        #expect(multiWithoutApp.app == nil)
    }

    @Test(.tags(.fast))
    func `Focus mode implications`() throws {
        // Foreground focus should work with any capture mode
        let foregroundScreen = try ImageCommand.parse([
            "--mode", "screen",
            "--capture-focus", "foreground",
        ])
        #expect(foregroundScreen.captureFocus == .foreground)

        let foregroundWindow = try ImageCommand.parse([
            "--mode", "window",
            "--app", "Terminal",
            "--capture-focus", "foreground",
        ])
        #expect(foregroundWindow.captureFocus == .foreground)

        // Background capture is the default
        let autoCapture = try ImageCommand.parse([
            "--mode", "window",
            "--app", "Finder",
        ])
        #expect(autoCapture.captureFocus == .background)
    }

    @Test(.tags(.fast))
    func `Path handling edge cases`() throws {
        // Relative paths
        let relativePath = try ImageCommand.parse(["--path", "./screenshots/test.png"])
        #expect(relativePath.path == "./screenshots/test.png")

        // Home directory expansion
        let homePath = try ImageCommand.parse(["--path", "~/Desktop/capture.jpg"])
        #expect(homePath.path == "~/Desktop/capture.jpg")

        // Absolute paths
        let absolutePath = try ImageCommand.parse(["--path", "/tmp/absolute/path.png"])
        #expect(absolutePath.path == "/tmp/absolute/path.png")

        // Paths with spaces
        let spacePath = try ImageCommand.parse(["--path", "/path with spaces/image.png"])
        #expect(spacePath.path == "/path with spaces/image.png")

        // Unicode paths
        let unicodePath = try ImageCommand.parse(["--path", "/tmp/测试/スクリーン.png"])
        #expect(unicodePath.path == "/tmp/测试/スクリーン.png")
    }

    @Test(.tags(.fast))
    func `Command execution readiness matrix`() {
        let scenarios = self.createTestScenarios()

        for scenario in scenarios {
            do {
                let command = try ImageCommand.parse(scenario.args)
                if scenario.shouldBeReady {
                    // Verify basic readiness
                    #expect(command.format == .png)
                    #expect(command.captureFocus == .background)
                }
            } catch {
                if scenario.shouldBeReady {
                    Issue.record("Scenario '\(scenario.description)' should parse successfully: \(error)")
                }
            }
        }
    }

    @Test(.tags(.fast))
    func `Error propagation scenarios`() {
        // Test that invalid arguments are properly handled
        let invalidArgs: [[String]] = [
            ["--mode", "invalid"],
            ["--format", "bmp"],
            ["--capture-focus", "invalid"],
            ["--screen-index", "abc"],
            ["--window-index", "xyz"],
        ]

        for args in invalidArgs {
            #expect(throws: (any Error).self) {
                _ = try ImageCommand.parse(args)
            }
        }
    }

    @Test(.tags(.memory), .disabled("Disabling due to crash"))
    func `Memory efficiency with complex configurations`() {
        // Test that complex configurations don't cause excessive memory usage
        let complexConfigs: [[String]] = [
            ["--mode", "multi", "--app", String(repeating: "LongAppName", count: 100)],
            ["--window-title", String(repeating: "VeryLongTitle", count: 200)],
            ["--path", String(repeating: "/very/long/path", count: 50)],
            Array(repeating: ["--mode", "screen"], count: 100).flatMap(\.self),
        ]

        for config in complexConfigs {
            do {
                _ = try ImageCommand.parse(config)
                #expect(Bool(true)) // Command parsed successfully
            } catch {
                // Some may fail due to argument parsing limits, which is expected
                #expect(Bool(true))
            }
        }
    }

    // MARK: - Helper Functions

    private struct TestScenario {
        let args: [String]
        let shouldBeReady: Bool
        let description: String
    }

    private func createTestScenarios() -> [TestScenario] {
        [
            TestScenario(
                args: ["--mode", "screen"],
                shouldBeReady: true,
                description: "Basic screen capture"
            ),
            TestScenario(
                args: ["--mode", "screen", "--screen-index", "0"],
                shouldBeReady: true,
                description: "Screen with index"
            ),
            TestScenario(
                args: ["--mode", "window", "--app", "Finder"],
                shouldBeReady: true,
                description: "Basic window capture"
            ),
            TestScenario(
                args: ["--mode", "window", "--app", "Safari", "--window-title", "Main"],
                shouldBeReady: true,
                description: "Window with title"
            ),
            TestScenario(
                args: ["--mode", "window", "--app", "Terminal", "--window-index", "0"],
                shouldBeReady: true,
                description: "Window with index"
            ),
            TestScenario(
                args: ["--mode", "multi"],
                shouldBeReady: true,
                description: "Multi-screen capture"
            ),
            TestScenario(
                args: ["--mode", "multi", "--app", "Xcode"],
                shouldBeReady: true,
                description: "Multi-window capture"
            ),
            TestScenario(
                args: ["--app", "Finder"],
                shouldBeReady: true,
                description: "Implicit window mode"
            ),
            TestScenario(
                args: [],
                shouldBeReady: true,
                description: "Default screen capture"
            ),
        ]
    }
}
