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
            permission: .screenRecording)

        #expect(errorCode(for: envelope) == .PERMISSION_ERROR_SCREEN_RECORDING)
    }

    @Test
    func `bridge envelope message uses actionable bridge message`() {
        let envelope = PeekabooBridgeErrorEnvelope(
            code: .permissionDenied,
            message: "Operation captureArea is not allowed with current permissions",
            permission: .screenRecording)

        #expect(errorMessage(for: envelope) == "Operation captureArea is not allowed with current permissions")
        #expect(!errorMessage(for: envelope).contains("PeekabooBridgeErrorEnvelope error"))
    }

    @Test
    func `bridge envelope details preserve bridge details and permission`() {
        let envelope = PeekabooBridgeErrorEnvelope(
            code: .internalError,
            message: "Bridge operation failed",
            details: "Screen capture service rejected the request",
            permission: .screenRecording)

        let details = errorDetails(for: envelope)
        #expect(details?.contains("Screen capture service rejected the request") == true)
        #expect(details?.contains("permission: screenRecording") == true)
    }

    @Test
    func `POSIX timeout maps to TIMEOUT`() {
        let code = errorCode(for: POSIXError(.ETIMEDOUT))
        #expect(code == .TIMEOUT)
    }
}
