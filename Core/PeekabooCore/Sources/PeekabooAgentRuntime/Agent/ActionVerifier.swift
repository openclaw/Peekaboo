//
//  ActionVerifier.swift
//  PeekabooCore
//
//  Enhancement #2: Visual Verification Loop
//  Verifies action success by analyzing post-action screenshots with AI.
//

import CoreGraphics
import Foundation
import ImageIO
import os.log
import PeekabooAutomation
import Tachikoma
import UniformTypeIdentifiers

/// Verifies that actions completed successfully by analyzing screenshots.
/// Uses a lightweight AI model to quickly assess visual outcomes.
@available(macOS 14.0, *)
@MainActor
public final class ActionVerifier {
    private let smartCapture: SmartCaptureService
    private let logger = Logger(subsystem: "boo.peekaboo.core", category: "ActionVerifier")

    /// The model to use for verification (should be fast/cheap).
    private let verificationModel: LanguageModel

    public init(
        smartCapture: SmartCaptureService,
        verificationModel: LanguageModel = .openai(.gpt55))
    {
        self.smartCapture = smartCapture
        self.verificationModel = verificationModel
    }

    // MARK: - Verification

    /// Verify that an action completed successfully.
    public func verify(
        action: ActionDescriptor,
        expectedOutcome: String? = nil,
        captureResult providedCaptureResult: SmartCaptureResult? = nil) async throws -> VerificationResult
    {
        // Capture post-action state
        let captureResult: SmartCaptureResult = if let providedCaptureResult {
            providedCaptureResult
        } else {
            try await self.smartCapture.captureAfterAction(
                toolName: action.toolName,
                targetPoint: action.targetPoint)
        }

        guard let screenshot = captureResult.image else {
            // Screen unchanged - might be okay or might be a problem
            return VerificationResult(
                success: false,
                confidence: 0.3,
                observation: "Screen appears unchanged after action",
                suggestion: "The action may not have had any visible effect. Try clicking directly on the element.")
        }

        // Build expected outcome if not provided
        let expected = expectedOutcome ?? self.inferExpectedOutcome(for: action)

        // Ask AI to verify
        let prompt = self.buildVerificationPrompt(action: action, expected: expected)

        do {
            let response = try await analyzeScreenshot(screenshot, prompt: prompt)
            return self.parseVerificationResponse(response)
        } catch {
            self.logger.warning("Verification AI call failed: \(error.localizedDescription)")
            // On AI failure, assume success (don't block on verification errors)
            return VerificationResult(
                success: true,
                confidence: 0.5,
                observation: "Could not verify action (AI unavailable)",
                suggestion: nil)
        }
    }

    /// Check if a tool should be verified based on options.
    public func shouldVerify(
        toolName: String,
        options: AgentEnhancementOptions) -> Bool
    {
        Self.shouldVerify(toolName: toolName, options: options)
    }

    /// Check if a concrete tool invocation should be verified based on options.
    public func shouldVerify(
        toolName: String,
        arguments: [String: String],
        options: AgentEnhancementOptions) -> Bool
    {
        Self.shouldVerify(toolName: toolName, arguments: arguments, options: options)
    }

    /// Check if a tool should be verified based on options without requiring capture dependencies.
    public nonisolated static func shouldVerify(
        toolName: String,
        options: AgentEnhancementOptions) -> Bool
    {
        self.shouldVerify(toolName: toolName, arguments: [:], options: options)
    }

    /// Check if a concrete tool invocation should be verified without requiring capture dependencies.
    public nonisolated static func shouldVerify(
        toolName: String,
        arguments: [String: String],
        options: AgentEnhancementOptions) -> Bool
    {
        guard options.verifyActions else { return false }
        guard let actionType = VerifiableActionType(rawValue: toolName) else {
            return false
        }

        // If specific action types are set, check against them
        if !options.verifyActionTypes.isEmpty {
            return options.verifyActionTypes.contains(actionType)
        }

        // Otherwise, verify the known mutating agent tools only.
        return actionType.isMutating(arguments: arguments)
    }

    // MARK: - Private Helpers

    private func inferExpectedOutcome(for action: ActionDescriptor) -> String {
        switch action.toolName {
        case "click":
            let element = action.targetElement ?? "element"
            return [
                "The \(element) should appear clicked/activated,",
                "possibly showing a new state, opening a menu, or navigating somewhere",
            ].joined(separator: " ")

        case "type":
            let text = action.arguments["text"] ?? ""
            let preview = String(text.prefix(50))
            return "The text '\(preview)' should now be visible in the focused input field"

        case "scroll":
            let direction = action.arguments["direction"] ?? "down"
            return "The content should have scrolled \(direction), showing different content than before"

        case "hotkey":
            let keys = action.arguments["keys"] ?? "keys"
            return "The hotkey '\(keys)' should have triggered an action - look for any visible change"

        case "launch_app":
            let app = action.arguments["app"] ?? action.arguments["name"] ?? "application"
            return "The \(app) application should now be visible, focused, and in the foreground"

        case "app":
            let actionName = action.arguments["action"] ?? "requested app action"
            let app = action.arguments["app"] ?? action.arguments["name"] ?? action.arguments["to"] ?? "application"
            return "The app action '\(actionName)' should have produced the expected visible state for \(app)"

        case "menu":
            let menuPath = action.arguments["path"] ?? "menu item"
            return "The menu action '\(menuPath)' should have been executed"

        case "dialog":
            let button = action.arguments["button"] ?? "button"
            return "The dialog button '\(button)' should have been clicked and the dialog may have closed"

        case "drag":
            return "The dragged element should now be in a new position"

        case "move":
            return "The mouse pointer should now be at the requested screen location or element"

        case "swipe":
            return "The swipe gesture should have moved or changed the visible content"

        case "paste":
            return "The pasted content should now be visible in the focused target"

        case "set_value":
            let value = action.arguments["value"] ?? "the requested value"
            return "The target element should now have the value '\(value)'"

        case "perform_action":
            let actionName = action.arguments["action"] ?? "requested accessibility action"
            return "The accessibility action '\(actionName)' should have completed with the expected UI change"

        case "window":
            let actionName = action.arguments["action"] ?? "requested window action"
            return "The window action '\(actionName)' should have visibly changed the target window"

        case "dock":
            let actionName = action.arguments["action"] ?? "requested Dock action"
            return "The Dock action '\(actionName)' should have produced the expected visible UI change"

        case "space":
            let actionName = action.arguments["action"] ?? "requested Spaces action"
            return "The Spaces action '\(actionName)' should have visibly changed the active Space or window placement"

        case "browser":
            let actionName = action.arguments["action"] ?? "requested browser action"
            return "The browser action '\(actionName)' should have produced the expected page or browser state change"

        default:
            return "The action should have completed successfully with some visible change"
        }
    }

    private func buildVerificationPrompt(action: ActionDescriptor, expected: String) -> String {
        let exampleJSON = [
            #"{"success": true, "confidence": 0.85, "observation": "#,
            #""The button appears pressed and a dropdown menu is visible", "suggestion": null}"#,
        ].joined()

        return """
        I just performed this action on macOS:
        - Tool: \(action.toolName)
        - Target: \(action.targetElement ?? "unspecified")
        - Arguments: \(self.formatArguments(action.arguments))

        Expected outcome: \(expected)

        Looking at the current screen state, please verify:
        1. Did the action succeed? (yes/no/unclear)
        2. How confident are you? (0-100%)
        3. What do you observe on the screen?
        4. If it failed, what should I try instead?

        Respond in this exact JSON format:
        \(exampleJSON)

        Only respond with the JSON, no other text.
        """
    }

    private func formatArguments(_ arguments: [String: String]) -> String {
        let pairs = arguments.map { key, value in
            "\(key): \(value)"
        }
        return pairs.joined(separator: ", ")
    }

    private func analyzeScreenshot(_ image: CGImage, prompt: String) async throws -> String {
        // Encode directly through ImageIO so agent runtime does not depend on AppKit image types.
        let pngBuffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            pngBuffer,
            UTType.png.identifier as CFString,
            1,
            nil)
        else {
            throw VerificationError.imageConversionFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw VerificationError.imageConversionFailed
        }
        let pngData = pngBuffer as Data

        // Create image content for the model
        let base64Image = pngData.base64EncodedString()

        // Use Tachikoma to call the verification model
        let imageContent = ModelMessage.ContentPart.ImageContent(data: base64Image, mimeType: "image/png")
        let messages: [ModelMessage] = [
            ModelMessage(role: .user, content: [
                .image(imageContent),
                .text(prompt),
            ]),
        ]

        let response = try await generateText(
            model: verificationModel,
            messages: messages,
            tools: nil,
            settings: GenerationSettings(maxTokens: 200))

        return response.text
    }

    private func parseVerificationResponse(_ response: String) -> VerificationResult {
        // Try to parse JSON response
        guard let data = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // Fallback: try to extract meaning from text response
            return self.parseTextResponse(response)
        }

        let success = json["success"] as? Bool ?? false
        let confidence = (json["confidence"] as? Double ?? 0.5)
        let observation = json["observation"] as? String ?? "No observation provided"
        let suggestion = json["suggestion"] as? String

        return VerificationResult(
            success: success,
            confidence: Float(confidence),
            observation: observation,
            suggestion: suggestion)
    }

    private func parseTextResponse(_ response: String) -> VerificationResult {
        let lowercased = response.lowercased()

        // Simple heuristics for non-JSON responses
        let success = lowercased.contains("yes") ||
            lowercased.contains("succeeded") ||
            lowercased.contains("successful")

        let failed = lowercased.contains("no") ||
            lowercased.contains("failed") ||
            lowercased.contains("didn't work")

        return VerificationResult(
            success: success && !failed,
            confidence: 0.6,
            observation: response,
            suggestion: failed ? "The action may have failed. Consider retrying or trying a different approach." : nil)
    }
}

// MARK: - Supporting Types

/// Describes an action that was performed.
public struct ActionDescriptor: Sendable {
    public let toolName: String
    public let arguments: [String: String]
    public let targetElement: String?
    public let targetPoint: CGPoint?
    public let timestamp: Date

    public init(
        toolName: String,
        arguments: [String: String],
        targetElement: String? = nil,
        targetPoint: CGPoint? = nil,
        timestamp: Date = Date())
    {
        self.toolName = toolName
        self.arguments = arguments
        self.targetElement = targetElement
        self.targetPoint = targetPoint
        self.timestamp = timestamp
    }
}

/// Result of action verification.
public struct VerificationResult: Sendable {
    /// Whether the action appears to have succeeded.
    public let success: Bool

    /// Confidence level (0.0 - 1.0).
    public let confidence: Float

    /// What was observed on screen.
    public let observation: String

    /// Suggestion for fixing if failed.
    public let suggestion: String?

    public init(success: Bool, confidence: Float, observation: String, suggestion: String?) {
        self.success = success
        self.confidence = confidence
        self.observation = observation
        self.suggestion = suggestion
    }

    /// Whether we should retry based on the result.
    public var shouldRetry: Bool {
        !self.success && self.confidence > 0.6
    }
}

/// Errors during verification.
public enum VerificationError: Error, LocalizedError {
    case imageConversionFailed
    case aiCallFailed(underlying: any Error)
    case parseError(response: String)

    public var errorDescription: String? {
        switch self {
        case .imageConversionFailed:
            "Failed to convert screenshot for verification"
        case let .aiCallFailed(error):
            "AI verification call failed: \(error.localizedDescription)"
        case let .parseError(response):
            "Could not parse verification response: \(response.prefix(100))"
        }
    }
}
