import Foundation
import PeekabooFoundation

/// Short-lived cache for immutable element detection results.
///
/// AX trees are expensive to rebuild, but UI can mutate immediately after automation actions.
/// Keep this cache intentionally small and TTL-based. Callers can also bound reuse with the shared
/// desktop-mutation watermark so an otherwise-live entry cannot outlast a UI change.
@_spi(Testing) public final class ElementDetectionCache {
    public struct Key: Hashable, Sendable {
        public let windowID: Int
        public let processID: pid_t
        public let allowWebFocus: Bool
        public let includeMenuBarElements: Bool

        public init(
            windowID: Int,
            processID: pid_t,
            allowWebFocus: Bool,
            includeMenuBarElements: Bool = false)
        {
            self.windowID = windowID
            self.processID = processID
            self.allowWebFocus = allowWebFocus
            self.includeMenuBarElements = includeMenuBarElements
        }
    }

    public struct CachedElements: Sendable {
        public let elements: [DetectedElement]
        public let truncationInfo: DetectionTruncationInfo?

        public init(elements: [DetectedElement], truncationInfo: DetectionTruncationInfo? = nil) {
            self.elements = elements
            self.truncationInfo = truncationInfo
        }
    }

    private struct Entry {
        let cachedAt: Date
        let result: CachedElements
    }

    private let ttl: TimeInterval
    private let now: () -> Date
    private var entries: [Key: Entry] = [:]

    public init(ttl: TimeInterval = 1.5, now: @escaping () -> Date = Date.init) {
        self.ttl = ttl
        self.now = now
    }

    public func key(
        windowID: Int?,
        processID: pid_t,
        allowWebFocus: Bool,
        includeMenuBarElements: Bool = false) -> Key?
    {
        guard let windowID else { return nil }
        return Key(
            windowID: windowID,
            processID: processID,
            allowWebFocus: allowWebFocus,
            includeMenuBarElements: includeMenuBarElements)
    }

    public func elements(for key: Key, invalidatedThrough: Date? = nil) -> [DetectedElement]? {
        self.result(for: key, invalidatedThrough: invalidatedThrough)?.elements
    }

    public func result(for key: Key, invalidatedThrough: Date? = nil) -> CachedElements? {
        guard let entry = self.entries[key] else { return nil }

        if let invalidatedThrough, entry.cachedAt <= invalidatedThrough {
            self.entries.removeValue(forKey: key)
            return nil
        }

        if self.now().timeIntervalSince(entry.cachedAt) <= self.ttl {
            return entry.result
        }

        self.entries.removeValue(forKey: key)
        return nil
    }

    public func store(_ elements: [DetectedElement], truncationInfo: DetectionTruncationInfo? = nil, for key: Key) {
        if truncationInfo?.deadlineReached == true || truncationInfo?.incompleteAccessibilityRead == true {
            // A retry may use a longer timeout or the target may recover from a transient AX refusal.
            // Remove any older entry too: replaying stale completeness is less honest than recollecting.
            self.entries.removeValue(forKey: key)
            return
        }
        self.entries[key] = Entry(
            cachedAt: self.now(),
            result: CachedElements(elements: elements, truncationInfo: truncationInfo))
    }

    public func removeAll() {
        self.entries.removeAll()
    }
}
