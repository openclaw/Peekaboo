import Foundation
import PeekabooFoundation

enum SnapshotPublicationBinding {
    /// Detection-only results still need a correlation identifier, but only a snapshot manager may
    /// mint the canonical `ps1_` authority used for persistence and follow-up actions.
    static func resultIdentifier(
        explicit snapshotId: String?,
        transientPrefix: String? = nil) -> String
    {
        if let snapshotId {
            return snapshotId
        }
        let identifier = UUID().uuidString
        return transientPrefix.map { "\($0)-\(identifier)" } ?? identifier
    }

    static func validate(
        snapshotId: String,
        detectionResult: ElementDetectionResult? = nil,
        captureCoordinateContext: CaptureCoordinateContext? = nil) throws
    {
        guard SnapshotReference(rawValue: snapshotId) != nil else {
            throw SnapshotError.invalidSnapshotReference(snapshotId)
        }
        if let detectionResult, detectionResult.snapshotId != snapshotId {
            throw SnapshotError.storageError(
                "Detection result snapshot '\(detectionResult.snapshotId)' does not match owned snapshot " +
                    "'\(snapshotId)'")
        }
        if let referenceID = captureCoordinateContext?.referenceID,
           referenceID != snapshotId
        {
            throw SnapshotError.storageError(
                "Capture coordinate reference '\(referenceID)' does not match owned snapshot '\(snapshotId)'")
        }
        if let referenceID = detectionResult?.metadata.captureCoordinateContext?.referenceID,
           referenceID != snapshotId
        {
            throw SnapshotError.storageError(
                "Detection coordinate reference '\(referenceID)' does not match owned snapshot '\(snapshotId)'")
        }
    }
}
