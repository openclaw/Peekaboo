import CoreGraphics
import Foundation

@MainActor
func waitForWindowDisappearance(
    timeoutSeconds: TimeInterval,
    stabilitySeconds: TimeInterval = 0.8,
    pollNanoseconds: UInt64 = 100_000_000,
    isPresent: () async -> Bool) async throws -> Bool
{
    try Task.checkCancellation()

    let deadline = Date().addingTimeInterval(max(0.0, timeoutSeconds))
    var missingSince: Date?

    while Date() < deadline {
        try Task.checkCancellation()
        let windowIsPresent = await isPresent()
        try Task.checkCancellation()

        if !windowIsPresent {
            let now = Date()
            missingSince = missingSince ?? now
            if let missingSince, now.timeIntervalSince(missingSince) >= stabilitySeconds {
                return true
            }
        } else {
            missingSince = nil
        }

        try await Task.sleep(nanoseconds: pollNanoseconds)
    }

    try Task.checkCancellation()
    return false
}
