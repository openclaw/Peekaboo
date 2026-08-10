//
//  OptimizedAnimationQueue.swift
//  Peekaboo
//
//  Created by Peekaboo on 2025-01-30.
//

import Foundation

/// Optimized animation queue with batching and resource management
actor OptimizedAnimationQueue {
    // MARK: - Properties

    /// Maximum concurrent animations
    private let maxConcurrentAnimations = 5

    /// Animation batch interval (seconds)
    private let batchInterval: TimeInterval = 0.016 // ~60 FPS

    /// Currently running animations
    private var activeAnimations = Set<UUID>()

    /// Queued animations
    private var queuedAnimations: [QueuedAnimation] = []

    /// Batch timer task
    private var batchTimerTask: Task<Void, Never>?

    /// Performance monitor
    private nonisolated func getPerformanceMonitor() async -> PerformanceMonitor {
        await MainActor.run {
            PerformanceMonitor.shared
        }
    }

    /// Animation priorities
    enum Priority: Int, Comparable {
        case low = 0
        case normal = 1
        case high = 2
        case critical = 3

        static func < (lhs: Priority, rhs: Priority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    // MARK: - Public Methods

    /// Enqueue an animation with priority
    func enqueue(
        priority: Priority = .normal,
        animation: @Sendable @escaping () async -> Bool) async -> Bool
    {
        let id = UUID()

        // Check if we can run immediately
        if self.activeAnimations.count < self.maxConcurrentAnimations, self.queuedAnimations.isEmpty {
            return await self.runAnimation(id: id, animation: animation)
        }

        // Otherwise queue it
        let queuedAnimation = QueuedAnimation(
            id: id,
            priority: priority,
            animation: animation)

        self.queuedAnimations.append(queuedAnimation)
        self.queuedAnimations.sort { $0.priority > $1.priority }

        // Start batch timer if needed
        self.startBatchTimerIfNeeded()

        // Wait for completion
        return await queuedAnimation.completion
    }

    /// Get queue status
    func getStatus() -> (active: Int, queued: Int) {
        (self.activeAnimations.count, self.queuedAnimations.count)
    }

    // MARK: - Private Methods

    private func runAnimation(id: UUID, animation: @escaping () async -> Bool) async -> Bool {
        self.activeAnimations.insert(id)

        // Track performance
        let performanceMonitor = await getPerformanceMonitor()
        let tracker = await MainActor.run {
            performanceMonitor.recordAnimationStart(type: "Animation-\(id)")
        }

        let result = await animation()

        // Complete tracking
        await MainActor.run {
            performanceMonitor.recordAnimationComplete(tracker: tracker)
        }

        self.activeAnimations.remove(id)

        // Process next batch
        await self.processNextBatch()

        return result
    }

    private func startBatchTimerIfNeeded() {
        guard self.batchTimerTask == nil else { return }

        self.batchTimerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self.batchInterval))
                if !Task.isCancelled {
                    await self.processBatch()
                }
            }
        }
    }

    private func processBatch() async {
        await self.processNextBatch()
    }

    private func processNextBatch() async {
        let availableSlots = self.maxConcurrentAnimations - self.activeAnimations.count
        guard availableSlots > 0 else { return }

        // Get next animations to run
        let animationsToRun = Array(queuedAnimations.prefix(availableSlots))
        self.queuedAnimations.removeFirst(min(availableSlots, self.queuedAnimations.count))

        // Run animations concurrently
        await withTaskGroup(of: Void.self) { group in
            for queued in animationsToRun {
                group.addTask { [weak self] in
                    guard let self else { return }
                    let result = await self.runAnimation(id: queued.id, animation: queued.animation)
                    queued.complete(with: result)
                }
            }
        }

        // Stop timer if queue is empty
        if self.queuedAnimations.isEmpty, self.activeAnimations.isEmpty {
            self.batchTimerTask?.cancel()
            self.batchTimerTask = nil
        }
    }

    // MARK: - Nested Types

    /// Queued animation data
    private final class QueuedAnimation: @unchecked Sendable {
        let id: UUID
        let priority: Priority
        let animation: @Sendable () async -> Bool
        private var continuation: CheckedContinuation<Bool, Never>?

        init(id: UUID = UUID(), priority: Priority, animation: @Sendable @escaping () async -> Bool) {
            self.id = id
            self.priority = priority
            self.animation = animation
        }

        var completion: Bool {
            get async {
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                }
            }
        }

        func complete(with result: Bool) {
            self.continuation?.resume(returning: result)
        }
    }
}
