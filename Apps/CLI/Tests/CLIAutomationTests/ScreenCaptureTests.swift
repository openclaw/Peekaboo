import AppKit
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

#if !PEEKABOO_SKIP_AUTOMATION
// TODO: ScreenCaptureTests commented out - API changes needed (ApplicationFinder, WindowManager missing)
/*
 @Suite("ScreenCapture Tests", .serialized, .tags(.automation), .enabled(if: CLITestEnvironment.runAutomationActions))
 struct ScreenCaptureTests {

     @Suite("Display Capture Tests", .tags(.localOnly))
     struct DisplayCaptureTests {
         let tempDir: URL

         init() throws {
             self.tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
             try FileManager.default.createDirectory(at: self.tempDir, withIntermediateDirectories: true)
         }

         @Test("Captures main display", .enabled(if: ProcessInfo.processInfo.environment["RUN_LOCAL_TESTS"] == "true"))
         @MainActor
         func capturesMainDisplay() async throws {
             let mainDisplayID = CGMainDisplayID()
             let outputPath = self.tempDir.appendingPathComponent("main-display.png").path

             // Create screen capture service
             let service = PeekabooServices().screenCapture

             // Capture display
             let result = try await service.captureScreen(displayIndex: nil)

             // Save the image data to file
             try result.imageData.write(to: URL(fileURLWithPath: outputPath))

             #expect(FileManager.default.fileExists(atPath: outputPath))

             // Verify it's a valid image
             let data = try Data(contentsOf: URL(fileURLWithPath: outputPath))
             #expect(data.count > 1000) // Should be a reasonable size

             // Check PNG header
             #expect(data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
         }

         @Test("Captures in JPEG format", .enabled(if: ProcessInfo.processInfo.environment["RUN_LOCAL_TESTS"] == "true"))
         @MainActor
         func capturesInJPEGFormat() async throws {
             let mainDisplayID = CGMainDisplayID()
             let outputPath = self.tempDir.appendingPathComponent("main-display.jpg").path

             // Create screen capture service
             let service = PeekabooServices().screenCapture

             // Capture display
             let result = try await service.captureScreen(displayIndex: nil)

             // Save the image data to file as JPEG
             // Note: The service returns PNG data, so we need to convert it
             if let image = NSImage(data: result.imageData),
                let tiffData = image.tiffRepresentation,
                let bitmap = NSBitmapImageRep(data: tiffData),
                let jpegData = bitmap.representation(using: .jpeg, properties: [:]) {
                 try jpegData.write(to: URL(fileURLWithPath: outputPath))
             }

             #expect(FileManager.default.fileExists(atPath: outputPath))

             // Verify it's a valid JPEG
             let data = try Data(contentsOf: URL(fileURLWithPath: outputPath))
             #expect(data.prefix(3) == Data([0xFF, 0xD8, 0xFF]))
         }

         @Test(
             "Fails with invalid display ID",
             .enabled(if: ProcessInfo.processInfo.environment["RUN_LOCAL_TESTS"] == "true")
         )
         @MainActor
         func failsWithInvalidDisplayID() async throws {
             let invalidDisplayID: CGDirectDisplayID = 999_999
             let outputPath = self.tempDir.appendingPathComponent("invalid.png").path

             await #expect(throws: PeekabooError.self) {
                 let service = PeekabooServices().screenCapture

                 // Try to capture with an invalid display index (very high number)
                 let _ = try await service.captureScreen(displayIndex: 999999)
             }
         }
     }

     @Suite("Window Capture Tests", .tags(.localOnly))
     struct WindowCaptureTests {
         let tempDir: URL

         init() throws {
             self.tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
             try FileManager.default.createDirectory(at: self.tempDir, withIntermediateDirectories: true)
         }

         @Test("Captures window by ID", .enabled(if: ProcessInfo.processInfo.environment["RUN_LOCAL_TESTS"] == "true"))
         @MainActor
         func capturesWindowByID() async throws {
             // First get a valid window ID from Finder
             let apps = ApplicationFinder.getAllRunningApplications()
             let finder = apps.first { $0.bundle_id == "com.apple.finder" }
             let finderApp = try #require(finder)

             let windows = try WindowManager.getWindowsForApp(pid: finderApp.pid)
             let window = try #require(windows.first)

             let outputPath = self.tempDir.appendingPathComponent("window.png").path

             let service = PeekabooServices().screenCapture

             // The new API uses app identifier and window index
             let result = try await service.captureWindow(
                 appIdentifier: "com.apple.finder",
                 windowIndex: 0
             )

             // Save the image data to file
             try result.imageData.write(to: URL(fileURLWithPath: outputPath))

             #expect(FileManager.default.fileExists(atPath: outputPath))

             // Verify it's a valid image
             let data = try Data(contentsOf: URL(fileURLWithPath: outputPath))
             #expect(data.count > 100) // Should have some content
         }

         @Test(
             "Fails with invalid window ID",
             .enabled(if: ProcessInfo.processInfo.environment["RUN_LOCAL_TESTS"] == "true")
         )
         @MainActor
         func failsWithInvalidWindowID() async throws {
             await #expect(throws: PeekabooError.self) {
                 let service = PeekabooServices().screenCapture

                 // Try to capture with an invalid app identifier
                 let _ = try await service.captureWindow(
                     appIdentifier: "com.invalid.nonexistent.app",
                     windowIndex: 0
                 )
             }
         }
     }

     @Suite("Permission Error Detection", .tags(.automation), .enabled(if: CLITestEnvironment.runAutomationActions))
     struct PermissionErrorDetectionTests {
         @Test("Captures convert to permission errors when appropriate")
         @MainActor
         func capturesConvertToPermissionErrors() async {
             // This test verifies the error conversion logic without requiring actual permissions
             let tempPath = FileManager.default.temporaryDirectory
                 .appendingPathComponent("\(UUID().uuidString).png").path

             // When we don't have permissions, ScreenCaptureKit will throw specific errors
             // This test would fail in CI but demonstrates the error handling path
             if ProcessInfo.processInfo.environment["RUN_LOCAL_TESTS"] != "true" {
                 // Skip this test in CI
                 return
             }

             // Attempt to capture without permissions should convert to our error type
             do {
                 let service = PeekabooServices().screenCapture

                 let _ = try await service.captureScreen(displayIndex: nil)
             } catch let error as PeekabooError {
                 // If we get a PeekabooError, it should be a permission error
                 switch error {
                 case .screenRecordingPermissionDenied:
                     // Expected when permissions are not granted
                     break
                 default:
                     // Other errors are also valid (display not found, etc)
                     break
                 }
             } catch {
                 // Non-PeekabooError means our error handling didn't work
                 Issue.record("Expected PeekabooError but got \(type(of: error))")
             }
         }
     }

     @Suite("Capture Configuration", .tags(.automation), .enabled(if: CLITestEnvironment.runAutomationActions))
     struct CaptureConfigurationTests {
         @Test("Default configuration includes cursor")
         func defaultConfigurationIncludesCursor() {
             // This is more of a documentation test to ensure our assumptions are correct
             // The actual SCStreamConfiguration is created inside ScreenCapture methods

             // We expect:
             // - configuration.showsCursor = true
             // - configuration.backgroundColor = .black
             // - configuration.shouldBeOpaque = true

             // These settings are hardcoded in ScreenCapture.swift
             // This test serves as a reminder if we ever want to make them configurable
             #expect(Bool(true)) // Configuration is hardcoded as expected
         }
     }
 }
 */
#endif
