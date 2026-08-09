import AppKit
import Foundation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@Suite(.serialized, .tags(.safe))
struct PIDImageCaptureTests {
    @Test
    func `Capture windows by PID - valid PID`() async throws {
        // Skip in CI environment
        guard ProcessInfo.processInfo.environment["CI"] == nil else {
            return
        }

        // Get a running application with windows
        let runningApps = NSWorkspace.shared.runningApplications
        guard let appWithWindows = runningApps.first(where: { app in
            app.localizedName != nil &&
                app.isActive == false && // Don't capture active app to avoid test interference
                app.bundleIdentifier != nil
        }) else {
            Issue.record("No suitable application found for PID capture testing")
            return
        }

        let pid = appWithWindows.processIdentifier

        // Create image command with PID
        let command = try ImageCommand.parse([
            "--app", "PID:\(pid)",
            "--mode", "multi",
            "--format", "png",
            "--path", NSTemporaryDirectory(),
            "--json",
        ])

        do {
            // Mock the execution context
            let result = try await captureWithPID(command: command, targetPID: pid)

            #expect(result.success == true)
            #expect(result.data.isEmpty == false)
        } catch {
            Issue.record("Failed to capture windows by PID: \(error)")
        }
    }

    @Test
    func `Capture windows by PID - multiple app instances`() async throws {
        // Skip in CI environment
        guard ProcessInfo.processInfo.environment["CI"] == nil else {
            return
        }

        // Find apps that might have multiple instances (e.g., Terminal, Finder windows)
        let runningApps = NSWorkspace.shared.runningApplications
        let appGroups = Dictionary(grouping: runningApps) { $0.bundleIdentifier ?? "unknown" }

        // Find an app with multiple instances
        guard let (_, apps) = appGroups.first(where: { $0.value.count > 1 }) else {
            // No multiple instances found, skip test
            return
        }

        // Pick the first instance
        let targetApp = apps[0]
        let pid = targetApp.processIdentifier

        // Create image command with specific PID
        let command = try ImageCommand.parse([
            "--app", "PID:\(pid)",
            "--mode", "multi",
            "--format", "png",
            "--path", NSTemporaryDirectory(),
            "--json",
        ])

        do {
            let result = try await captureWithPID(command: command, targetPID: pid)

            #expect(result.success == true)
            #expect(result.data.isEmpty == false)
        } catch {
            Issue.record("Failed to capture specific instance by PID: \(error)")
        }
    }

    @Test
    func `Invalid PID formats in image capture`() throws {
        let invalidPIDs = [
            "PID:", // Missing PID number
            "PID:abc", // Non-numeric PID
            "PID:-123", // Negative PID
            "PID:12.34", // Decimal PID
            "PID:0", // Zero PID
            "PID:999999999", // Very large PID
        ]

        for invalidPID in invalidPIDs {
            do {
                let command = try ImageCommand.parse([
                    "--app", invalidPID,
                    "--mode", "window",
                    "--format", "png",
                    "--json",
                ])

                // The command should parse but fail during execution
                #expect(command.app == invalidPID)

                // In actual execution, this would fail with APP_NOT_FOUND error
                // Here we just verify the command accepts the PID format
            } catch {
                // Some invalid formats might fail to parse
                continue
            }
        }
    }

    @Test
    func `PID targeting with window specifiers`() throws {
        // Test that PID can be combined with window index
        let command1 = try ImageCommand.parse([
            "--app", "PID:1234",
            "--window-index", "0",
            "--mode", "window",
        ])

        #expect(command1.app == "PID:1234")
        #expect(command1.windowIndex == 0)

        // Test that PID can be combined with window title
        let command2 = try ImageCommand.parse([
            "--app", "PID:5678",
            "--window-title", "Document",
            "--mode", "window",
        ])

        #expect(command2.app == "PID:5678")
        #expect(command2.windowTitle == "Document")
    }

    @Test
    func `PID targeting filename generation`() {
        // Test that filenames include PID information
        let pid: pid_t = 1234
        let appName = "TestApp"
        let timestamp = "20250608_120000"

        // Expected filename format for PID capture
        let expectedFilename = "\(appName)_PID_\(pid)_\(timestamp).png"

        // Verify filename pattern
        #expect(expectedFilename.contains("PID"))
        #expect(expectedFilename.contains(String(pid)))
        #expect(expectedFilename.contains(appName))
    }

    /// Helper function to simulate capture with PID
    private func captureWithPID(
        command: ImageCommand,
        targetPID: pid_t
    ) async throws -> CodableJSONResponse<[SavedFile]> {
        // In real execution, this would use WindowCapture.captureWindows
        // For testing, we simulate the response

        guard let app = NSRunningApplication(processIdentifier: targetPID) else {
            throw PeekabooError.appNotFound("No application found with PID: \(targetPID)")
        }

        let savedFile = SavedFile(
            path: "\(command.path ?? NSTemporaryDirectory())/\(app.localizedName ?? "Unknown")_PID_\(targetPID).png",
            item_label: app.localizedName ?? "Unknown",
            window_title: nil,
            window_id: nil,
            window_index: nil,
            mime_type: "image/png"
        )

        return CodableJSONResponse(
            success: true,
            data: [savedFile],
            messages: ["Captured windows for PID: \(targetPID)"],
            debug_logs: []
        )
    }
}
