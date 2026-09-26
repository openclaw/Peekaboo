actor NoncooperativeWorkGate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    private var finished: CheckedContinuation<Void, Never>?
    private(set) var hasFinished = false
    private(set) var hasEntered = false
    private(set) var isReleased = false

    func wait() async {
        guard !self.isReleased else { return }
        await withCheckedContinuation { continuation in
            self.hasEntered = true
            self.waiting = continuation
            self.entered?.resume()
            self.entered = nil
        }
    }

    func waitUntilBlocked() async {
        guard self.waiting == nil, !self.isReleased else { return }
        await withCheckedContinuation { self.entered = $0 }
    }

    func release() {
        self.isReleased = true
        self.waiting?.resume()
        self.waiting = nil
        self.entered?.resume()
        self.entered = nil
    }

    func finish() {
        self.hasFinished = true
        self.finished?.resume()
        self.finished = nil
    }

    func waitUntilFinished() async {
        guard !self.hasFinished else { return }
        await withCheckedContinuation { self.finished = $0 }
    }
}
