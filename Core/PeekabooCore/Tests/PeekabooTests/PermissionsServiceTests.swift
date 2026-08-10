import AppKit
import AXorcist
import PeekabooFoundation
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomation
@testable import PeekabooCore
@testable import PeekabooVisualizer

@Suite(.tags(.permissions, .unit))
@MainActor
struct PermissionsServiceTests {
    let permissionsService = PermissionsService()

    // MARK: - Screen Recording Permission Tests

    @Test(.tags(.fast))
    func `Screen recording permission check returns boolean`() {
        // Test screen recording permission check
        let hasPermission = self.permissionsService.checkScreenRecordingPermission()

        // Just verify we got a valid boolean result (the API works)
        // The actual value depends on system permissions
        _ = hasPermission
    }

    @Test(.tags(.fast))
    func `Screen recording permission check is consistent`() {
        // Test that multiple calls return consistent results
        let firstCheck = self.permissionsService.checkScreenRecordingPermission()
        let secondCheck = self.permissionsService.checkScreenRecordingPermission()

        #expect(firstCheck == secondCheck)
    }

    @Test(arguments: 1...5)
    func `Screen recording permission check performance`(iteration: Int) {
        // Permission checks should be fast
        _ = self.permissionsService.checkScreenRecordingPermission()
        // Performance is measured by the test framework's execution time
    }

    // MARK: - Accessibility Permission Tests

    @Test(.tags(.fast))
    func `Accessibility permission check returns boolean`() {
        // Test accessibility permission check
        let hasPermission = self.permissionsService.checkAccessibilityPermission()

        // Just verify we got a valid boolean result (the API works)
        // The actual value depends on system permissions
        _ = hasPermission
    }

    @Test(.tags(.fast))
    func `Accessibility permission matches AXPermissionHelpers`() {
        // Compare our check with the AXorcist helper to ensure parity.
        let isTrusted = AXPermissionHelpers.hasAccessibilityPermissions()
        let hasPermission = self.permissionsService.checkAccessibilityPermission()

        // These should match
        #expect(hasPermission == isTrusted)
    }

    // MARK: - Combined Permission Tests

    @Test(.tags(.fast))
    func `Both permissions return valid results`() {
        // Test both permission checks
        let screenRecording = self.permissionsService.checkScreenRecordingPermission()
        let accessibility = self.permissionsService.checkAccessibilityPermission()

        // Both should return valid boolean values
        _ = screenRecording
        _ = accessibility
    }

    // MARK: - Require Permission Tests

    @Test(.tags(.fast))
    func `Require screen recording permission throws CaptureError when denied`() {
        let hasPermission = self.permissionsService.checkScreenRecordingPermission()

        if hasPermission {
            // Should not throw when permission is granted
            #expect(throws: Never.self) {
                try permissionsService.requireScreenRecordingPermission()
            }
        } else {
            // Should throw specific CaptureError when permission is denied
            do {
                try self.permissionsService.requireScreenRecordingPermission()
                Issue.record("Expected CaptureError.screenRecordingPermissionDenied but no error was thrown")
            } catch let peekabooError as PeekabooError {
                // Should be screenRecordingPermissionDenied
                switch peekabooError {
                case .permissionDeniedScreenRecording:
                    // Expected error - verify error message is helpful
                    #expect(peekabooError.localizedDescription.contains("Screen recording permission"))
                default:
                    Issue.record("Expected PeekabooError.permissionDeniedScreenRecording but got \(peekabooError)")
                }
            } catch {
                Issue.record("Expected CaptureError.screenRecordingPermissionDenied but got \(error)")
            }
        }
    }

    @Test(.tags(.fast))
    func `Require accessibility permission throws CaptureError when denied`() {
        let hasPermission = self.permissionsService.checkAccessibilityPermission()

        if hasPermission {
            // Should not throw when permission is granted
            #expect(throws: Never.self) {
                try permissionsService.requireAccessibilityPermission()
            }
        } else {
            // Should throw specific CaptureError when permission is denied
            do {
                try self.permissionsService.requireAccessibilityPermission()
                Issue.record("Expected CaptureError.accessibilityPermissionDenied but no error was thrown")
            } catch let peekabooError as PeekabooError {
                // Should be accessibilityPermissionDenied
                switch peekabooError {
                case .permissionDeniedAccessibility:
                    // Expected error - verify error message is helpful
                    #expect(peekabooError.localizedDescription.contains("Accessibility permission"))
                default:
                    Issue.record("Expected PeekabooError.permissionDeniedAccessibility but got \(peekabooError)")
                }
            } catch {
                Issue.record("Expected CaptureError.accessibilityPermissionDenied but got \(error)")
            }
        }
    }

    // MARK: - All Permissions Check

    @Test(.tags(.fast))
    func `Check all permissions returns status object`() {
        let status = self.permissionsService.checkAllPermissions()

        // Verify the status object has the expected properties
        _ = status.screenRecording
        _ = status.accessibility

        // The values should match individual checks
        #expect(status.screenRecording == self.permissionsService.checkScreenRecordingPermission())
        #expect(status.accessibility == self.permissionsService.checkAccessibilityPermission())
        #expect(!status.appleScript)
        #expect(!status.missingOptionalPermissions.contains("AppleScript"))
    }

    @Test
    func `Legacy AppleScript permission field still decodes`() throws {
        let data = Data(
            #"{"screenRecording":true,"accessibility":true,"appleScript":true,"postEvent":false}"#.utf8)
        let status = try JSONDecoder().decode(PermissionsStatus.self, from: data)

        #expect(status.appleScript)
        #expect(status.missingOptionalPermissions == ["Event Synthesizing"])
    }
}
