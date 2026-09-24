import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct ApplicationRunningStateTests {
    @Test(arguments: ["Notes", "com.example.notes", "PID:701", "/Applications/Notes.app", "NotesExecutable", "Not"])
    func `A unique application is running through the production service`(identifier: String) async throws {
        let service = Self.service(candidates: [Self.notes])

        #expect(try await service.isApplicationRunning(identifier: identifier))
    }

    @Test(arguments: ["Missing", "com.example.missing", "PID:999", "PID:invalid", ""])
    func `A missing application is not running`(identifier: String) async throws {
        #expect(try await !Self.service(candidates: [Self.notes]).isApplicationRunning(identifier: identifier))
        #expect(try await !Self.service(candidates: []).isApplicationRunning(identifier: identifier))
    }

    @Test(arguments: ["Notes", "com.example.notes", "Not"])
    func `An ambiguous application is not reported as stopped`(identifier: String) async throws {
        let otherNotes = ApplicationIdentifierMatcher.Candidate(
            processIdentifier: 702,
            bundleIdentifier: "com.example.notes",
            name: "Notes",
            bundlePath: "/Applications/Notes.app",
            executablePath: "/Applications/Notes.app/Contents/MacOS/NotesExecutable")
        let unrelated = ApplicationIdentifierMatcher.Candidate(
            processIdentifier: 703,
            bundleIdentifier: "com.example.unrelated",
            name: "Unrelated")
        let service = Self.service(candidates: [Self.notes, otherNotes, unrelated])

        do {
            _ = try await service.isApplicationRunning(identifier: identifier)
            Issue.record("An ambiguous application must not be reported as stopped")
        } catch let error as PeekabooError {
            guard case let .ambiguousAppIdentifier(actualIdentifier, suggestions) = error else { throw error }
            #expect(actualIdentifier == identifier)
            #expect(suggestions == ["Notes (PID:701)", "Notes (PID:702)"])
        }
        #expect(try await service.isApplicationRunning(identifier: "PID:701"))
        #expect(try await service.isApplicationRunning(identifier: "PID:702"))
    }

    @Test
    func `Non Peekaboo resolution errors propagate from the production service`() async {
        let count = ApplicationIdentifierMatcher.maximumProofCandidateCount + 1
        let oversizedInventory = Self.service(candidates: Array(repeating: Self.notes, count: count))
        await #expect(throws: ApplicationIdentifierMatcher.ResolutionError.candidateSetTooLarge(count)) {
            _ = try await oversizedInventory.isApplicationRunning(identifier: "Missing")
        }

        let oversizedField = Self.service(candidates: [.init(
            processIdentifier: 701,
            bundleIdentifier: "com.example.notes",
            name: String(repeating: "N", count: 4097))])
        await #expect(throws: ApplicationIdentifierMatcher.ResolutionError.candidateFieldTooLarge) {
            _ = try await oversizedField.isApplicationRunning(identifier: "PID:701")
        }
    }

    @Test
    func `Each running check reads a fresh selector inventory`() async throws {
        var reads = 0
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in throw PeekabooError.notImplemented("Unexpected launch") },
            applicationSelectorCandidatesProvider: {
                reads += 1
                return reads == 1 ? [Self.notes] : []
            })

        #expect(try await service.isApplicationRunning(identifier: "Notes"))
        #expect(try await !service.isApplicationRunning(identifier: "Notes"))
        #expect(reads == 2)
    }

    private static var notes: ApplicationIdentifierMatcher.Candidate {
        .init(
            processIdentifier: 701,
            bundleIdentifier: "com.example.notes",
            name: "Notes",
            bundlePath: "/Applications/Notes.app",
            executablePath: "/Applications/Notes.app/Contents/MacOS/NotesExecutable")
    }

    private static func service(candidates: [ApplicationIdentifierMatcher.Candidate]) -> ApplicationService {
        ApplicationService(
            applicationOpenHandler: { _, _, _ in throw PeekabooError.notImplemented("Unexpected launch") },
            applicationSelectorCandidatesProvider: { candidates })
    }
}
