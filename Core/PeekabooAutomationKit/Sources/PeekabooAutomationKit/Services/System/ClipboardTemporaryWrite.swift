import Foundation
import PeekabooFoundation

public enum ClipboardTemporaryCleanupStatus: String, Sendable {
    case restored
    case preservedNewerContents = "preserved_newer_contents"
    case notNeeded = "not_needed"
}

/// Automatic cleanup of a temporary clipboard payload, distinct from an explicit restore command.
public enum ClipboardTemporaryCleanupResult: Sendable {
    case restored(ClipboardReadResult?)
    case preservedNewerContents
    case notNeeded

    public var status: ClipboardTemporaryCleanupStatus {
        switch self {
        case .restored: .restored
        case .preservedNewerContents: .preservedNewerContents
        case .notNeeded: .notNeeded
        }
    }
}

@MainActor
public protocol ClipboardTemporaryWriteTransaction: AnyObject, Sendable {
    var priorClipboardPresent: Bool { get }
    var didMutate: Bool { get }

    func write(_ request: ClipboardWriteRequest) throws -> ClipboardReadResult
    func cleanup() throws -> ClipboardTemporaryCleanupResult
}

/// A content-free input precondition, not authority to read or restore the clipboard.
public struct GeneralPasteboardWriteClaim: Codable, Equatable, Sendable {
    public let changeCount: Int

    public init?(changeCount: Int) {
        guard changeCount >= 0 else { return nil }
        self.changeCount = changeCount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let changeCount = try container.decode(Int.self, forKey: .changeCount)
        guard let claim = Self(changeCount: changeCount) else {
            throw DecodingError.dataCorruptedError(
                forKey: .changeCount,
                in: container,
                debugDescription: "General pasteboard change count must be nonnegative")
        }
        self = claim
    }
}

public struct ClaimedClipboardWrite: Sendable {
    public let result: ClipboardReadResult
    public let claim: GeneralPasteboardWriteClaim

    public init(result: ClipboardReadResult, claim: GeneralPasteboardWriteClaim) {
        self.result = result
        self.claim = claim
    }
}

/// A guarded paste must require this capability before mutating its temporary payload.
@MainActor
public protocol ClipboardTemporaryWriteClaimProviding: ClipboardTemporaryWriteTransaction {
    func writeWithClaim(_ request: ClipboardWriteRequest) throws -> ClaimedClipboardWrite
}

/// Providers without this capability must refuse automatic temporary clipboard writes.
@MainActor
public protocol ClipboardTemporaryWriteProviding: ClipboardServiceProtocol {
    func prepareTemporaryWrite() throws -> any ClipboardTemporaryWriteTransaction
}

/// Temporary payload setup is retry-unsafe once the clipboard claim has changed it, even before Cmd+V.
public enum ClipboardTemporaryWriteFailure {
    public static func refusedInput(
        _ failure: DesktopActionFailure,
        didMutate: Bool,
        cleanupStatus: ClipboardTemporaryCleanupStatus?,
        cleanupErrorDescription: String?) -> DesktopActionFailure?
    {
        guard !failure.outcome.dispatchState.mutationDispatched, didMutate else { return nil }
        return self.make(
            failure,
            didMutate: true,
            cleanupStatus: cleanupStatus,
            cleanupErrorDescription: cleanupErrorDescription,
            operation: "Paste input")
    }

    public static func make(
        _ primaryError: any Error,
        didMutate: Bool,
        cleanupStatus: ClipboardTemporaryCleanupStatus?,
        cleanupErrorDescription: String? = nil,
        reportedFailure: DesktopActionFailure? = nil,
        standardErrorCode: StandardErrorCode? = nil,
        operation: String = "Paste payload setup") -> DesktopActionFailure
    {
        let reported = reportedFailure ?? (primaryError as? DesktopActionFailure)
        let retainedTargetReceipt = didMutate && reported?.outcome.dispatchState.mutationDispatched != true
            ? nil : reported?.targetReceipt
        let outcome: DesktopActionOutcome = if let reported, reported.outcome.dispatchState.mutationDispatched {
            reported.outcome
        } else if didMutate || cleanupErrorDescription != nil {
            .indeterminate(
                delivery: ClipboardMutationResultSemantics.delivery,
                evidence: .completionUnknown)
        } else {
            reported?.outcome ?? .refused(reason: .invalidRequest)
        }
        let cleanupDetail = if let cleanupErrorDescription {
            "; restoring the prior clipboard also failed: \(cleanupErrorDescription)."
        } else if cleanupStatus == .preservedNewerContents {
            ". A newer clipboard update was preserved; the prior contents were not restored."
        } else {
            "."
        }
        return DesktopActionFailure(
            outcome: outcome,
            message: "\(operation) failed (\(primaryError.localizedDescription))\(cleanupDetail)",
            hint: didMutate || cleanupErrorDescription != nil
                ? "Inspect the clipboard before retrying; no paste input was sent."
                : "Correct the clipboard request before retrying; no paste input was sent.",
            causeDescription: reported?.causeDescription ?? primaryError.localizedDescription,
            standardErrorCode: reported?.standardErrorCode ?? standardErrorCode,
            targetReceipt: retainedTargetReceipt,
            selectedLeafEvidence: reported?.selectedLeafEvidence)!
    }
}

public enum ClipboardTemporaryWriteError: LocalizedError, Sendable {
    case snapshotChanged
    case snapshotUnavailable
    case ownershipChanged
    case transactionAlreadyUsed
    case mutationUnproven
    case generalPasteboardClaimUnavailable

    public var errorDescription: String? {
        switch self {
        case .snapshotChanged:
            "The clipboard changed while preparing a temporary write; no temporary payload was written."
        case .snapshotUnavailable:
            "The complete prior clipboard could not be read; no temporary payload was written."
        case .ownershipChanged:
            "The clipboard changed outside this transaction; automatic writes stopped to preserve newer contents."
        case .transactionAlreadyUsed:
            "This temporary clipboard transaction has already been used."
        case .mutationUnproven:
            "The temporary clipboard write returned without an ownership receipt."
        case .generalPasteboardClaimUnavailable:
            "This transaction cannot provide a General pasteboard input claim; no temporary payload was written."
        }
    }
}

/// The native declaration supplies its generation before any payload write can fail.
@MainActor
struct ClipboardTemporaryWriteAccess {
    let changeCount: () -> Int
    let write: (ClipboardWriteRequest, Int, (Int) -> Void) throws -> ClipboardReadResult
    let restore: (Int) throws -> ClipboardReadResult?
}

@_spi(Testing)
@MainActor
public enum ClipboardTemporaryWriteTesting {
    public static func transaction(
        priorClipboardPresent: Bool,
        originalChangeCount: Int,
        isGeneralPasteboard: Bool = false,
        changeCount: @escaping () -> Int,
        write: @escaping (ClipboardWriteRequest, Int, (Int) -> Void) throws -> ClipboardReadResult,
        restore: @escaping (Int) throws -> ClipboardReadResult?) -> any ClipboardTemporaryWriteTransaction
    {
        OwnedClipboardTemporaryWriteTransaction(
            priorClipboardPresent: priorClipboardPresent,
            originalChangeCount: originalChangeCount,
            isGeneralPasteboard: isGeneralPasteboard,
            access: ClipboardTemporaryWriteAccess(changeCount: changeCount, write: write, restore: restore))
    }
}

/// Local generation checks preserve observed newer writes. NSPasteboard has no atomic compare-and-swap;
/// the check and subsequent declaration cannot exclude every concurrent cross-process write.
@MainActor
final class OwnedClipboardTemporaryWriteTransaction: ClipboardTemporaryWriteClaimProviding {
    let priorClipboardPresent: Bool
    private(set) var didMutate = false

    private let originalChangeCount: Int
    private let access: ClipboardTemporaryWriteAccess
    private let isGeneralPasteboard: Bool
    private var claimedChangeCount: Int?
    private var writeAttempted = false
    private var cleanupResult: Result<ClipboardTemporaryCleanupResult, any Error>?

    init(
        priorClipboardPresent: Bool,
        originalChangeCount: Int,
        isGeneralPasteboard: Bool = false,
        access: ClipboardTemporaryWriteAccess)
    {
        self.priorClipboardPresent = priorClipboardPresent
        self.originalChangeCount = originalChangeCount
        self.isGeneralPasteboard = isGeneralPasteboard
        self.access = access
    }

    func write(_ request: ClipboardWriteRequest) throws -> ClipboardReadResult {
        guard !self.writeAttempted, self.cleanupResult == nil else {
            throw ClipboardTemporaryWriteError.transactionAlreadyUsed
        }
        self.writeAttempted = true
        guard self.access.changeCount() == self.originalChangeCount else {
            throw ClipboardTemporaryWriteError.snapshotChanged
        }
        let result = try self.access.write(request, self.originalChangeCount) { generation in
            self.claimedChangeCount = generation
            self.didMutate = true
        }
        guard let claimedChangeCount = self.claimedChangeCount else {
            throw ClipboardTemporaryWriteError.mutationUnproven
        }
        guard self.access.changeCount() == claimedChangeCount else {
            throw ClipboardTemporaryWriteError.ownershipChanged
        }
        return result
    }

    func writeWithClaim(_ request: ClipboardWriteRequest) throws -> ClaimedClipboardWrite {
        guard self.isGeneralPasteboard else {
            throw ClipboardTemporaryWriteError.generalPasteboardClaimUnavailable
        }
        let result = try self.write(request)
        guard let claimedChangeCount = self.claimedChangeCount,
              let claim = GeneralPasteboardWriteClaim(changeCount: claimedChangeCount)
        else {
            throw ClipboardTemporaryWriteError.mutationUnproven
        }
        return ClaimedClipboardWrite(result: result, claim: claim)
    }

    /// Cleanup deliberately ignores task cancellation and never repeats a failed native restoration.
    func cleanup() throws -> ClipboardTemporaryCleanupResult {
        if let cleanupResult = self.cleanupResult {
            return try cleanupResult.get()
        }
        let result = Result<ClipboardTemporaryCleanupResult, any Error> {
            guard let claimedChangeCount = self.claimedChangeCount else {
                return .notNeeded
            }
            guard self.access.changeCount() == claimedChangeCount else {
                return .preservedNewerContents
            }
            do {
                return try .restored(self.access.restore(claimedChangeCount))
            } catch ClipboardTemporaryWriteError.ownershipChanged {
                return .preservedNewerContents
            }
        }
        self.cleanupResult = result
        return try result.get()
    }
}
