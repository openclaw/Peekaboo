//
//  ErrorHandlingTests.swift
//  PeekabooCLI
//

import Foundation
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
    func `bridge screen recording permission maps to screen recording error`() {
        let envelope = PeekabooBridgeErrorEnvelope(
            code: .permissionDenied,
            message: "Operation captureScreen is not allowed with current permissions",
            permission: .screenRecording
        )

        #expect(errorCode(for: envelope) == .PERMISSION_ERROR_SCREEN_RECORDING)
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
