import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct DockVisibilityActionResultTests {
    @Test
    func `missing autohide preference is the valid false default`() async throws {
        let runner = DockVisibilityCommandScript([
            .failure(.readAutohide, Self.missingAutohidePreference),
        ])
        let service = self.service(runner: runner)

        let result = try await service.showDockActionResult()

        #expect(result.outcome == .confirmedNoChange())
        #expect(runner.observedCommands == [.readAutohide])
    }

    @Test
    func `genuine autohide read failure still surfaces before dispatch`() async throws {
        let runner = DockVisibilityCommandScript([
            .failure(.readAutohide, "defaults could not access the preference domain"),
        ])
        let service = self.service(runner: runner)

        do {
            _ = try await service.hideDockActionResult()
            Issue.record("Expected a genuine defaults failure")
        } catch let error as PeekabooError {
            #expect(error.localizedDescription.contains("could not access the preference domain"))
        }
        #expect(runner.observedCommands == [.readAutohide])
    }

    @Test(arguments: ["0", " false ", "\nFaLsE\t"])
    func `canonical false outputs are accepted case insensitively`(_ output: String) async throws {
        let runner = DockVisibilityCommandScript([
            .success(.readAutohide, output: output),
        ])
        let service = self.service(runner: runner)

        let result = try await service.showDockActionResult()

        #expect(result.outcome == .confirmedNoChange())
        #expect(runner.observedCommands == [.readAutohide])
    }

    @Test(arguments: ["1", " true ", "\nTrUe\t"])
    func `canonical true outputs are accepted case insensitively`(_ output: String) async throws {
        let runner = DockVisibilityCommandScript([
            .success(.readAutohide, output: output),
        ])
        let service = self.service(runner: runner)

        let result = try await service.hideDockActionResult()

        #expect(result.outcome == .confirmedNoChange())
        #expect(runner.observedCommands == [.readAutohide])
    }

    @Test(arguments: ["", "yes", "2", "true false"])
    func `noncanonical successful read output fails before dispatch`(_ output: String) async throws {
        let runner = DockVisibilityCommandScript([
            .success(.readAutohide, output: output),
        ])
        let service = self.service(runner: runner)

        do {
            _ = try await service.hideDockActionResult()
            Issue.record("Expected a typed Dock visibility parse failure")
        } catch let error as PeekabooError {
            guard case let .operationError(message) = error else {
                Issue.record("Expected operationError, got \(error)")
                return
            }
            #expect(message.contains("Could not parse Dock autohide preference value"))
            #expect(message.contains("expected 0, 1, false, or true"))
        }
        #expect(runner.observedCommands == [.readAutohide])
    }

    @Test
    func `noncanonical verification output becomes dispatched unverified`() async throws {
        let runner = DockVisibilityCommandScript([
            .success(.readAutohide, output: "false\n"),
            .success(.writeAutohide(true)),
            .success(.restartDock),
            .success(.readAutohide, output: "yes\n"),
        ])
        let service = self.service(runner: runner)

        do {
            _ = try await service.hideDockActionResult()
            Issue.record("Expected post-dispatch Dock visibility verification to fail closed")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome == .dispatchedUnverified(
                delivery: .init(mechanism: .nativeFramework, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: DesktopActionOutcome.DispatchUnitCount(2)))
            #expect(failure.message.contains("could not be verified"))
            #expect(failure.causeDescription?.contains("Could not parse Dock autohide preference value") == true)
        }
        #expect(runner.observedCommands == [
            .readAutohide,
            .writeAutohide(true),
            .restartDock,
            .readAutohide,
        ])
    }

    @Test
    func `restart failure reports one completed unit from the two unit mutation`() async throws {
        let restartError = "No matching processes belonging to you were found"
        let runner = DockVisibilityCommandScript([
            .success(.readAutohide, output: "0\n"),
            .success(.writeAutohide(true)),
            .failure(.restartDock, restartError),
        ])
        let service = self.service(runner: runner)

        do {
            _ = try await service.hideDockActionResult()
            Issue.record("Expected Dock restart to fail after the preference write")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome == .partial(
                delivery: .init(mechanism: .nativeFramework, mode: .background),
                unitCount: .one))
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.escalation == .recoverSideEffect)
            #expect(failure.message.contains("preference was written"))
            #expect(failure.causeDescription?.contains(restartError) == true)
        }
        #expect(runner.observedCommands == [
            .readAutohide,
            .writeAutohide(true),
            .restartDock,
        ])
    }

    @Test
    func `missing false default can be changed and records both dispatched units`() async throws {
        let runner = DockVisibilityCommandScript([
            .failure(.readAutohide, Self.missingAutohidePreference),
            .success(.writeAutohide(true)),
            .success(.restartDock),
            .success(.readAutohide, output: "1\n"),
        ])
        let service = self.service(runner: runner)

        let result = try await service.hideDockActionResult()

        #expect(result.outcome == .confirmedChange(
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            unitCount: DesktopActionOutcome.DispatchUnitCount(2)))
    }

    private func service(runner: DockVisibilityCommandScript) -> DockService {
        DockService(
            operationLaneCoordinator: DesktopOperationLaneCoordinator(),
            dockVisibilityCommandRunner: { command in
                try runner.run(command)
            })
    }

    private static let missingAutohidePreference =
        "The domain/default pair of (com.apple.dock, autohide) does not exist\n"
}

@MainActor
private final class DockVisibilityCommandScript {
    enum Step {
        case success(DockVisibilityCommand, output: String = "")
        case failure(DockVisibilityCommand, String)

        var command: DockVisibilityCommand {
            switch self {
            case let .success(command, _), let .failure(command, _): command
            }
        }
    }

    private var steps: [Step]
    private(set) var observedCommands: [DockVisibilityCommand] = []

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func run(_ command: DockVisibilityCommand) throws -> String {
        self.observedCommands.append(command)
        guard !self.steps.isEmpty else {
            throw DockVisibilityTestError("Unexpected command: \(command)")
        }
        let step = self.steps.removeFirst()
        guard step.command == command else {
            throw DockVisibilityTestError("Expected \(step.command), received \(command)")
        }
        switch step {
        case let .success(_, output):
            return output
        case let .failure(_, standardError):
            throw DockVisibilityCommandFailure(
                command: command,
                terminationStatus: 1,
                standardError: standardError)
        }
    }
}

private struct DockVisibilityTestError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
