import Foundation
import PeekabooFoundation

/// Adopted by transport errors when the caller cannot know whether remote snapshot work finished.
public protocol PendingSnapshotFailureDispositionProviding: Error {
    var mayCompleteSnapshotWorkAfterFailure: Bool { get }
}

extension DesktopActionFailure: PendingSnapshotFailureDispositionProviding {
    public var mayCompleteSnapshotWorkAfterFailure: Bool {
        self.outcome.dispatchState != .none
    }
}

public enum PendingSnapshotCleanupPolicy {
    /// Pending reservations double as tombstones for work that may outlive its caller.
    /// Definite failures can be removed eagerly; indeterminate failures must age out normally.
    public static func shouldPreserveReservation(after error: any Error) -> Bool {
        if error is CancellationError {
            return true
        }

        if let disposition = error as? any PendingSnapshotFailureDispositionProviding,
           disposition.mayCompleteSnapshotWorkAfterFailure
        {
            return true
        }

        if let posixError = error as? POSIXError {
            switch posixError.code {
            case .ETIMEDOUT, .ECONNRESET, .ECONNABORTED, .EPIPE, .ENOTCONN, .ENETRESET:
                return true
            default:
                break
            }
        }

        if let captureError = error as? CaptureError {
            switch captureError {
            case .detectionTimedOut:
                return true
            case let .captureCreationFailed(underlyingError),
                 let .windowCaptureFailed(underlyingError),
                 let .fileWriteError(_, underlyingError):
                if let underlyingError,
                   self.shouldPreserveReservation(after: underlyingError)
                {
                    return true
                }
            default:
                break
            }
        }

        if let peekabooError = error as? PeekabooError {
            switch peekabooError {
            case .captureTimeout, .timeout:
                return true
            default:
                break
            }
        }

        return false
    }
}
