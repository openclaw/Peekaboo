import Foundation
import PeekabooFoundation

// MARK: - Retry Policy

/// Configuration for retry behavior
public struct RetryPolicy: Sendable {
    public let maxAttempts: Int
    public let initialDelay: TimeInterval
    public let delayMultiplier: Double
    public let maxDelay: TimeInterval
    public let retryableErrors: Set<StandardErrorCode>

    public init(
        maxAttempts: Int = 3,
        initialDelay: TimeInterval = 0.1,
        delayMultiplier: Double = 2.0,
        maxDelay: TimeInterval = 5.0,
        retryableErrors: Set<StandardErrorCode> = Self.defaultRetryableErrors)
    {
        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
        self.delayMultiplier = delayMultiplier
        self.maxDelay = maxDelay
        self.retryableErrors = retryableErrors
    }

    /// Default set of retryable errors
    public static let defaultRetryableErrors: Set<StandardErrorCode> = [
        .timeout,
        .captureFailed,
        .interactionFailed,
        .fileIOError,
        .aiProviderUnavailable,
    ]

    /// Standard retry policies
    public static let standard = RetryPolicy()
    public static let aggressive = RetryPolicy(maxAttempts: 5, initialDelay: 0.05)
    public static let conservative = RetryPolicy(maxAttempts: 2, initialDelay: 0.5)
    public static let noRetry = RetryPolicy(maxAttempts: 1)
}

// MARK: - Retry Handler

/// Handles retry logic for operations
public enum RetryHandler {
    /// Execute an operation with retry logic
    public static func withRetry<T>(
        policy: RetryPolicy = .standard,
        operation: @Sendable () async throws -> T) async throws -> T
    {
        // Execute an operation with retry logic
        var lastError: (any Error)?
        var delay = policy.initialDelay

        for attempt in 1...policy.maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error

                // Check if error is retryable
                let standardized = ErrorStandardizer.standardize(error)
                guard policy.retryableErrors.contains(standardized.code),
                      attempt < policy.maxAttempts
                else {
                    throw error
                }

                // Wait before retry
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                // Increase delay for next attempt
                delay = min(delay * policy.delayMultiplier, policy.maxDelay)
            }
        }

        throw lastError ?? PeekabooError
            .operationError(message: "Operation failed after \(policy.maxAttempts) attempts")
    }

    /// Execute an operation with custom retry logic
    public static func withCustomRetry<T>(
        maxAttempts: Int = 3,
        shouldRetry: @Sendable (any Error, Int) -> Bool,
        delayForAttempt: @Sendable (Int) -> TimeInterval,
        operation: @Sendable () async throws -> T) async throws -> T
    {
        // Execute an operation with custom retry logic
        var lastError: (any Error)?

        for attempt in 1...maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error

                guard attempt < maxAttempts,
                      shouldRetry(error, attempt)
                else {
                    throw error
                }

                let delay = delayForAttempt(attempt)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }

        throw lastError ?? PeekabooError.operationError(message: "Operation failed after \(maxAttempts) attempts")
    }
}
