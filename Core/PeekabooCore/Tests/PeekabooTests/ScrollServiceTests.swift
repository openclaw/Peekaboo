import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomation
@testable import PeekabooAutomationKit
@testable import PeekabooCore
@testable import PeekabooVisualizer

@Suite(
    .tags(.ui, .automation),
    .enabled(if: TestEnvironment.runInputAutomationScenarios))
@MainActor
struct ScrollServiceTests {
    private func makeRequest(
        direction: ScrollDirection,
        amount: Int,
        target: String? = nil,
        smooth: Bool = false,
        delay: Int = 10,
        snapshotId: String? = nil,
        foreground: Bool = true) -> ScrollRequest
    {
        ScrollRequest(
            direction: direction,
            amount: amount,
            target: target,
            smooth: smooth,
            delay: delay,
            snapshotId: snapshotId,
            foreground: foreground)
    }

    @Test
    func `ScrollService initializes successfully with default configuration`() {
        let service = ScrollService()
        // Service is initialized successfully
        _ = service
    }

    @Test
    func `Scroll executes in all four cardinal directions without errors`() async throws {
        let service = ScrollService()

        // Test scrolling in each direction
        try await service.scroll(self.makeRequest(direction: .up, amount: 5))
        try await service.scroll(self.makeRequest(direction: .down, amount: 5))
        try await service.scroll(self.makeRequest(direction: .left, amount: 5))
        try await service.scroll(self.makeRequest(direction: .right, amount: 5))
    }

    @Test
    func `Scroll amounts`() async throws {
        let service = ScrollService()

        // Test different scroll amounts
        let amounts = [1, 5, 10, 20]

        for amount in amounts {
            try await service.scroll(self.makeRequest(direction: .down, amount: amount))
        }
    }

    @Test
    func `Scroll at coordinates`() async throws {
        let service = ScrollService()

        // Note: ScrollService doesn't support coordinate-based targets directly
        // It expects element IDs or queries
        try await service.scroll(self.makeRequest(direction: .down, amount: 3))
    }

    @Test
    func `Scroll up large amount`() async throws {
        let service = ScrollService()

        // Simulate scroll to top by scrolling up a large amount
        try await service.scroll(self.makeRequest(direction: .up, amount: 50))
    }

    @Test
    func `Scroll down large amount`() async throws {
        let service = ScrollService()

        // Simulate scroll to bottom by scrolling down a large amount
        try await service.scroll(self.makeRequest(direction: .down, amount: 50))
    }

    @Test
    func `Page-like scrolling`() async throws {
        let service = ScrollService()

        // Simulate page up with larger scroll amount
        try await service.scroll(self.makeRequest(direction: .up, amount: 10))

        // Simulate page down with larger scroll amount
        try await service.scroll(self.makeRequest(direction: .down, amount: 10))
    }

    @Test
    func `Smooth scroll`() async throws {
        let service = ScrollService()

        // Test smooth scrolling
        try await service.scroll(
            self.makeRequest(direction: .down, amount: 10, smooth: true, delay: 50))
    }

    @Test
    func `Scroll with element target`() async throws {
        let service = ScrollService()

        // Test scrolling within a specific element
        // In test environment, element may not exist
        do {
            try await service.scroll(
                self.makeRequest(direction: .down, amount: 5, target: "scrollable area"))
        } catch {
            // Expected in test environment - element won't exist
            // Could be NotFoundError or PeekabooError.elementNotFound
        }
    }

    @Test
    func `Zero scroll amount`() async throws {
        let service = ScrollService()

        // Should handle zero amount gracefully
        try await service.scroll(self.makeRequest(direction: .down, amount: 0))
    }

    @Test
    func `Negative scroll amount`() async throws {
        let service = ScrollService()

        // Negative amounts should be treated as absolute values
        try await service.scroll(self.makeRequest(direction: .up, amount: -5))
    }

    @Test
    func `Scroll deltas remain bounded`() {
        let service = ScrollService()
        #expect(service.deltasForTesting(direction: .up) == (0, 5))
        #expect(service.deltasForTesting(direction: .down) == (0, -5))
        #expect(service.deltasForTesting(direction: .left) == (5, 0))
        #expect(service.deltasForTesting(direction: .right) == (-5, 0))
    }
}
