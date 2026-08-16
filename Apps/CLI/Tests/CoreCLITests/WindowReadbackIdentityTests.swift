import CoreGraphics
import PeekabooFoundation
import Testing
@testable import PeekabooCLI
@testable import PeekabooCore

struct WindowReadbackIdentityTests {
    private let originalBounds = CGRect(x: 10, y: 20, width: 640, height: 480)

    @Test
    func `geometry readback rejects same ID replacement generation`() throws {
        let expected = self.expectedIdentity
        let replacementBounds = CGRect(x: 30, y: 40, width: 640, height: 480)
        let replacement = ServiceWindowInfo(
            windowID: expected.windowID,
            title: "Replacement",
            bounds: replacementBounds,
            mutationIdentity: .init(
                windowID: expected.windowID,
                ownerProcessIdentifier: expected.ownerProcessIdentifier,
                ownerProcessStartIdentity: expected.ownerProcessStartIdentity + 1,
                capturedBounds: replacementBounds
            )
        )

        #expect(throws: PeekabooError.self) {
            _ = try validatedPostMutationWindowReadback(
                replacement,
                expectedIdentity: expected,
                operation: "Window move"
            )
        }
    }

    @Test
    func `maximize readback rejects bounds provenance drift`() throws {
        let expected = self.expectedIdentity
        let reportedBounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let staleReceiptBounds = CGRect(x: 10, y: 20, width: 1200, height: 800)
        let drifted = ServiceWindowInfo(
            windowID: expected.windowID,
            title: "Drifted",
            bounds: reportedBounds,
            mutationIdentity: .init(
                windowID: expected.windowID,
                ownerProcessIdentifier: expected.ownerProcessIdentifier,
                ownerProcessStartIdentity: expected.ownerProcessStartIdentity,
                capturedBounds: staleReceiptBounds
            )
        )

        #expect(throws: PeekabooError.self) {
            _ = try validatedPostMutationWindowReadback(
                drifted,
                expectedIdentity: expected,
                operation: "Window maximize"
            )
        }
    }

    @Test
    func `geometry readback accepts new bounds with matching provenance`() throws {
        let expected = self.expectedIdentity
        let newBounds = CGRect(x: 30, y: 40, width: 800, height: 600)
        let moved = ServiceWindowInfo(
            windowID: expected.windowID,
            title: "Moved",
            bounds: newBounds,
            mutationIdentity: .init(
                windowID: expected.windowID,
                ownerProcessIdentifier: expected.ownerProcessIdentifier,
                ownerProcessStartIdentity: expected.ownerProcessStartIdentity,
                capturedBounds: newBounds
            )
        )

        let validated = try validatedPostMutationWindowReadback(
            moved,
            expectedIdentity: expected,
            operation: "Window move"
        )
        #expect(validated.bounds == newBounds)
    }

    private var expectedIdentity: WindowMutationIdentity {
        WindowMutationIdentity(
            windowID: 77,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 9001,
            capturedBounds: self.originalBounds
        )
    }
}
