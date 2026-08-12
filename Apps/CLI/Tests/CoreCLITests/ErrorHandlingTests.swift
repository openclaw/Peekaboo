//
//  ErrorHandlingTests.swift
//  PeekabooCLI
//

import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooBridge
@testable import PeekabooCLI
@testable import PeekabooCore

@Suite(.tags(.safe))
struct FocusErrorMappingTests {
    @Test
    func `application not running maps to APP_NOT_FOUND`() {
        let code = errorCode(for: .applicationNotRunning("Finder"))
        #expect(code == .APP_NOT_FOUND)
    }

    @Test
    func `AX element missing maps to WINDOW_NOT_FOUND`() {
        let code = errorCode(for: .axElementNotFound(42))
        #expect(code == .WINDOW_NOT_FOUND)
    }

    @Test
    func `focus verification timeout maps to TIMEOUT`() {
        let code = errorCode(for: .focusVerificationTimeout(100))
        #expect(code == .TIMEOUT)
    }

    @Test
    func `timeout waiting for condition maps to TIMEOUT`() {
        let code = errorCode(for: .timeoutWaitingForCondition)
        #expect(code == .TIMEOUT)
    }

    @Test
    func `bridge timeout maps to TIMEOUT`() {
        let code = errorCode(for: PeekabooBridgeErrorEnvelope(code: .timeout, message: "Timed out"))
        #expect(code == .TIMEOUT)
    }

    @Test
    func `subsecond capture timeout splits into precise message and current hint`() throws {
        let description = try #require(CaptureError.detectionTimedOut(0.2).errorDescription)

        let presentation = splitErrorHint(from: description)

        #expect(presentation.message == "Element detection timed out after 200ms.")
        #expect(presentation.hint?.contains("peekaboo see --timeout 30s") == true)
        #expect(presentation.hint?.contains("--timeout-seconds") == false)
    }

    @Test
    func `bridge screen recording permission maps to screen recording error`() {
        let envelope = PeekabooBridgeErrorEnvelope(
            code: .permissionDenied,
            message: "Operation captureScreen is not allowed with current permissions",
            permission: .screenRecording
        )

        #expect(errorCode(for: envelope) == .PERMISSION_ERROR_SCREEN_RECORDING)
    }

    @Test
    func `legacy AppleScript denial preserves its code but directs users to native hosts`() throws {
        let envelope = PeekabooBridgeErrorEnvelope(
            code: .permissionDenied,
            message: "AppleScript permission is required for automation",
            permission: .appleScript
        )

        #expect(errorCode(for: envelope) == .PERMISSION_ERROR_APPLESCRIPT)
        let message = errorMessage(for: envelope)
        #expect(message.contains("older Peekaboo component"))
        #expect(message.contains("current native Peekaboo CLI and Bridge host"))
        #expect(message.contains("do not grant Automation access"))
        #expect(!message.contains("permission is required"))

        let direct = try #require(CaptureError.appleScriptPermissionDenied.errorDescription)
        #expect(direct == message)
        #expect(CaptureError.appleScriptPermissionDenied.exitCode == 33)

        let presentation = splitErrorHint(from: message)
        #expect(presentation.message == "An older Peekaboo component requested AppleScript Automation permission.")
        #expect(presentation.hint ==
            "Use a current native Peekaboo CLI and Bridge host; do not grant Automation access.")
    }

    @Test
    func `bridge envelope message uses actionable bridge message`() {
        let envelope = PeekabooBridgeErrorEnvelope(
            code: .permissionDenied,
            message: "Operation captureArea is not allowed with current permissions",
            permission: .screenRecording
        )

        #expect(errorMessage(for: envelope) == "Operation captureArea is not allowed with current permissions")
        #expect(!errorMessage(for: envelope).contains("PeekabooBridgeErrorEnvelope error"))
        #expect(envelope.localizedDescription == envelope.message)
    }

    @Test
    func `application launch maps bridge not found to app not found`() {
        let envelope = PeekabooBridgeErrorEnvelope(code: .notFound, message: "Application not found")

        #expect(applicationLaunchErrorCode(for: envelope) == .APP_NOT_FOUND)
        #expect(applicationLaunchErrorCode(for: POSIXError(.ENOENT)) == nil)
    }

    @Test
    func `application lifecycle refusals project identically locally and through Bridge`() throws {
        let direct = ApplicationLifecycleRefusalError.backgroundLaunch("Cold launch refused")
        let remote = PeekabooBridgeErrorEnvelope(
            code: .internalError,
            message: direct.userMessage,
            context: direct.bridgeContext
        )

        #expect(applicationLaunchErrorCode(for: direct) == .INTERACTION_FAILED)
        #expect(applicationLaunchErrorCode(for: remote) == .INTERACTION_FAILED)
        #expect(errorCode(for: remote) == .INTERACTION_FAILED)
        #expect(try #require(applicationLifecycleRefusalProjection(for: direct)).hint == direct.hint)
        #expect(try #require(applicationLifecycleRefusalProjection(for: remote)).hint.contains("--foreground"))
    }

    @Test
    func `read-only lifecycle failures preserve retry-safe zero-dispatch metadata`() throws {
        let direct = ApplicationLifecycleReadOnlyFailureError(.timeout("Window readiness timed out"))
        let remote = PeekabooBridgeErrorEnvelope(
            code: .timeout,
            message: direct.userMessage,
            context: ApplicationLifecycleReadOnlyFailureError.bridgeContext
        )

        let directProjection = try #require(applicationLifecycleFailureProjection(for: direct))
        let remoteProjection = try #require(applicationLifecycleFailureProjection(for: remote))
        #expect(directProjection.effect == .unverifiable)
        #expect(remoteProjection.effect == .unverifiable)
        #expect(directProjection.metadata.retrySafe)
        #expect(remoteProjection.metadata.retrySafe)
        #expect(!directProjection.metadata.mutationDispatched)
        #expect(!remoteProjection.metadata.mutationDispatched)
        #expect(directProjection.metadata.errorCode == .timeout)
        #expect(remoteProjection.metadata.errorCode == .timeout)
    }

    @Test
    func `bridge envelope details preserve bridge details and permission`() {
        let envelope = PeekabooBridgeErrorEnvelope(
            code: .internalError,
            message: "Bridge operation failed",
            details: "Screen capture service rejected the request",
            permission: .screenRecording
        )

        let details = errorDetails(for: envelope)
        #expect(details?.contains("Screen capture service rejected the request") == true)
        #expect(details?.contains("permission: screenRecording") == true)
    }

    @Test
    func `POSIX timeout maps to TIMEOUT`() {
        let code = errorCode(for: POSIXError(.ETIMEDOUT))
        #expect(code == .TIMEOUT)
    }

    @Test
    func `clickFailed maps to INTERACTION_FAILED`() {
        #expect(peekabooAutomationErrorCode(for: .clickFailed("miss")) == .INTERACTION_FAILED)
    }

    @Test
    func `typeFailed maps to INTERACTION_FAILED`() {
        #expect(peekabooAutomationErrorCode(for: .typeFailed("stuck")) == .INTERACTION_FAILED)
    }

    @Test
    func `captureFailed maps to CAPTURE_FAILED`() {
        #expect(peekabooAutomationErrorCode(for: .captureFailed("cam")) == .CAPTURE_FAILED)
        let remote = PeekabooBridgeErrorEnvelope(
            code: .internalError,
            message: "remote capture failed",
            context: PeekabooBridgeErrorEnvelope.standardizedErrorContextPrefix +
                StandardErrorCode.captureFailed.rawValue
        )
        #expect(errorCode(for: remote) == .CAPTURE_FAILED)
    }

    @Test
    func `incomplete Accessibility evidence maps directly and through Bridge`() {
        let error = PeekabooError.accessibilityIncomplete("AX tree incomplete")
        let remote = PeekabooBridgeErrorEnvelope(
            code: .internalError,
            message: "AX tree incomplete",
            context: PeekabooBridgeErrorEnvelope.standardizedErrorContextPrefix +
                StandardErrorCode.accessibilityIncomplete.rawValue
        )

        #expect(peekabooAutomationErrorCode(for: error) == .ACCESSIBILITY_INCOMPLETE)
        #expect(errorCode(for: remote) == .ACCESSIBILITY_INCOMPLETE)
        #expect(remote.standardizedErrorCode == .accessibilityIncomplete)
    }

    @Test
    @MainActor
    func `incomplete Accessibility evidence is retry safe and mutation free`() {
        let command = WindowCommand.WindowListSubcommand()
        let direct = command.readOnlyObservationFailureReceipt(
            for: PeekabooError.accessibilityIncomplete("AX tree incomplete")
        )
        let remote = command.readOnlyObservationFailureReceipt(for: PeekabooBridgeErrorEnvelope(
            code: .internalError,
            message: "AX tree incomplete",
            context: PeekabooBridgeErrorEnvelope.standardizedErrorContextPrefix +
                StandardErrorCode.accessibilityIncomplete.rawValue
        ))

        #expect(direct == CaptureFailureReceipt(retrySafe: true, mutationDispatched: false))
        #expect(remote == direct)
    }

    @Test
    func `ROI errors distinguish invalid stale and capture failures`() {
        #expect(errorCode(for: CaptureROIError.invalidBounds) == .INVALID_ARGUMENT)
        #expect(errorCode(for: CaptureROIError.outOfBounds) == .INVALID_ARGUMENT)
        #expect(errorCode(for: CaptureROIError.missingExactWindowReceipt) == .SNAPSHOT_STALE)
        #expect(errorCode(for: CaptureROIError.hostDidNotApplyROI) == .CAPTURE_FAILED)
        #expect(errorCode(for: PeekabooBridgeErrorEnvelope(
            code: .invalidRequest,
            message: "stale",
            context: "capture_roi:missing_exact_window_receipt"
        )) == .SNAPSHOT_STALE)
        #expect(errorCode(for: PeekabooBridgeErrorEnvelope(
            code: .internalError,
            message: "host mismatch",
            context: "capture_roi:host_did_not_apply_roi"
        )) == .CAPTURE_FAILED)
    }

    @Test
    func `bridge elementNotFound kind maps to ELEMENT_NOT_FOUND`() {
        let envelope = PeekabooBridgeErrorEnvelope(
            code: .notFound,
            message: "No element",
            kind: .elementNotFound,
            context: "btn-1"
        )
        #expect(errorCode(for: envelope) == .ELEMENT_NOT_FOUND)
    }

    @Test
    func `bridge typed notFound kinds map to specific errors`() {
        let cases: [(PeekabooBridgeErrorKind, ErrorCode)] = [
            (.appNotFound, .APP_NOT_FOUND),
            (.windowNotFound, .WINDOW_NOT_FOUND),
            (.elementNotFound, .ELEMENT_NOT_FOUND),
            (.menuNotFound, .MENU_BAR_NOT_FOUND),
            (.menuItemNotFound, .MENU_ITEM_NOT_FOUND),
            (.dockNotFound, .DOCK_NOT_FOUND),
            (.dockListNotFound, .DOCK_LIST_NOT_FOUND),
            (.dockItemNotFound, .DOCK_ITEM_NOT_FOUND),
            (.positionNotFound, .POSITION_NOT_FOUND),
            (.snapshotNotFound, .SNAPSHOT_NOT_FOUND),
        ]
        for (kind, expectedCode) in cases {
            let envelope = PeekabooBridgeErrorEnvelope(code: .notFound, message: "Missing", kind: kind)
            #expect(errorCode(for: envelope) == expectedCode)
        }
    }

    @Test
    func `bridge stale kind wins over invalidRequest transport code`() {
        let envelope = PeekabooBridgeErrorEnvelope(
            code: .invalidRequest,
            message: "Snapshot stale",
            kind: .snapshotStale,
            context: "snap-1"
        )
        #expect(errorCode(for: envelope) == .SNAPSHOT_STALE)
    }

    @Test
    func `bridge unkinded notFound maps to UNKNOWN_ERROR`() {
        let envelope = PeekabooBridgeErrorEnvelope(code: .notFound, message: "Dock item not found")
        #expect(errorCode(for: envelope) == .UNKNOWN_ERROR)
    }

    @Test
    func `generic command errors preserve bridge lookup kinds`() {
        let envelope = PeekabooBridgeErrorEnvelope(
            code: .notFound,
            message: "Dock item not found",
            kind: .dockItemNotFound
        )

        #expect(genericErrorCode(for: envelope) == .DOCK_ITEM_NOT_FOUND)
        #expect(genericErrorCode(for: POSIXError(.ENOENT)) == .UNKNOWN_ERROR)
    }
}
