//
//  ActionVerifierTests.swift
//  CLIAutomationTests
//
//  Tests for ActionVerifier and related types.
//

import CoreGraphics
import Foundation
import Testing
@testable import PeekabooAgentRuntime

struct ActionDescriptorTests {
    @Test
    func `Action descriptor stores all properties`() {
        let point = CGPoint(x: 100, y: 200)
        let timestamp = Date()

        let descriptor = ActionDescriptor(
            toolName: "click",
            arguments: ["element": "Button"],
            targetElement: "Submit Button",
            targetPoint: point,
            timestamp: timestamp
        )

        #expect(descriptor.toolName == "click")
        #expect(descriptor.arguments == ["element": "Button"])
        #expect(descriptor.targetElement == "Submit Button")
        #expect(descriptor.targetPoint == point)
        #expect(descriptor.timestamp == timestamp)
    }

    @Test
    func `Action descriptor with minimal properties`() {
        let descriptor = ActionDescriptor(
            toolName: "press",
            arguments: ["keys": "cmd+c"]
        )

        #expect(descriptor.toolName == "press")
        #expect(descriptor.arguments == ["keys": "cmd+c"])
        #expect(descriptor.targetElement == nil)
        #expect(descriptor.targetPoint == nil)
    }

    @Test
    func `Action descriptor uses current date by default`() {
        let before = Date()
        let descriptor = ActionDescriptor(
            toolName: "type",
            arguments: ["text": "Hello"]
        )
        let after = Date()

        #expect(descriptor.timestamp >= before)
        #expect(descriptor.timestamp <= after)
    }
}

struct VerificationResultTests {
    @Test
    func `Successful verification result`() {
        let result = VerificationResult(
            success: true,
            confidence: 0.95,
            observation: "Button clicked successfully",
            suggestion: nil
        )

        #expect(result.success == true)
        #expect(result.confidence == 0.95)
        #expect(result.observation == "Button clicked successfully")
        #expect(result.suggestion == nil)
        #expect(result.shouldRetry == false)
    }

    @Test
    func `Failed verification with high confidence does not replay dispatched action`() {
        let result = VerificationResult(
            success: false,
            confidence: 0.85,
            observation: "Button not found",
            suggestion: "Try clicking on coordinates instead"
        )

        #expect(result.success == false)
        #expect(result.shouldRetry == false)
    }

    @Test
    func `Failed verification with low confidence does not trigger retry`() {
        let result = VerificationResult(
            success: false,
            confidence: 0.4,
            observation: "Uncertain about result",
            suggestion: nil
        )

        #expect(result.success == false)
        #expect(result.shouldRetry == false)
    }

    @Test
    func `Failed verification never requests automatic replay`() {
        let atThreshold = VerificationResult(
            success: false,
            confidence: 0.6,
            observation: "At threshold",
            suggestion: nil
        )
        #expect(atThreshold.shouldRetry == false)

        let aboveThreshold = VerificationResult(
            success: false,
            confidence: 0.61,
            observation: "Above threshold",
            suggestion: nil
        )
        #expect(aboveThreshold.shouldRetry == false)
    }
}

struct VerificationErrorTests {
    @Test
    func `Image conversion error has correct description`() {
        let error = VerificationError.imageConversionFailed

        #expect(error.errorDescription?.contains("convert screenshot") == true)
    }

    @Test
    func `AI call error includes underlying error`() {
        struct TestError: Error, LocalizedError {
            var errorDescription: String? {
                "Test failure"
            }
        }

        let error = VerificationError.aiCallFailed(underlying: TestError())

        #expect(error.errorDescription?.contains("AI verification") == true)
        #expect(error.errorDescription?.contains("Test failure") == true)
    }

    @Test
    func `Parse error includes response preview`() {
        let error = VerificationError.parseError(response: "Invalid JSON response")

        #expect(error.errorDescription?.contains("parse") == true)
        #expect(error.errorDescription?.contains("Invalid JSON") == true)
    }
}
