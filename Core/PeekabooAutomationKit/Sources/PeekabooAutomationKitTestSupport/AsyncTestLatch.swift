import Foundation

/// A deterministic, reusable one-shot latch for asynchronous tests.
public actor AsyncTestLatch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public var isOpen: Bool {
        self.opened
    }

    public func wait() async {
        guard !self.opened else { return }
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    public func open() {
        guard !self.opened else { return }
        self.opened = true
        let pending = self.waiters
        self.waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    public func opensWithin(_ duration: Duration) async -> Bool {
        if self.opened {
            return true
        }
        let deadline = ContinuousClock.now.advanced(by: duration)
        while !self.opened, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return self.opened
    }
}
