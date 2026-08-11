enum WatchCaptureActivityPolicy {
    /// Returns true when the capture loop should drop from active to idle cadence.
    /// We leave active mode once change is below half the threshold for at least `quietMs`.
    static func shouldExitActive(
        changePercent: Double,
        threshold: Double,
        lastActivityNs: UInt64,
        quietMs: Int,
        nowNs: UInt64) -> Bool
    {
        guard changePercent < threshold / 2 else { return false }
        let quietNs = UInt64(max(0, quietMs)) * 1_000_000
        let elapsedNs = nowNs >= lastActivityNs ? nowNs - lastActivityNs : 0
        return elapsedNs >= quietNs
    }
}
