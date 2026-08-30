import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

struct CaptureLiveBehaviorTests {
    @Test
    func `resolveMode defaults to window when targeting app pid title or index`() throws {
        var cmd = CaptureLiveCommand()
        cmd.app = "Safari"
        #expect(try cmd.resolveMode() == .window)
        cmd.app = nil
        cmd.windowTitle = "Log"
        #expect(try cmd.resolveMode() == .window)
        cmd.windowTitle = nil
        cmd.windowIndex = 0
        #expect(try cmd.resolveMode() == .window)
    }

    @Test
    func `resolveMode defaults to frontmost when no targeting`() throws {
        let cmd = CaptureLiveCommand()
        #expect(try cmd.resolveMode() == .frontmost)
    }

    @Test
    @MainActor
    func `capture live scope rejects duplicate exact and partial titles`() async throws {
        for (titles, query) in [(["Draft", "Draft"], "Draft"), (["Draft One", "Draft Two"], "Draft")] {
            var command = CaptureLiveCommand()
            command.app = "Fixture"
            command.windowTitle = query
            command.runtime = self.makeRuntime(titles: titles)

            await #expect(throws: Commander.ValidationError.self) {
                _ = try await command.resolveScope()
            }
        }
    }

    @Test
    @MainActor
    func `capture action scope rejects duplicate exact and partial titles`() async throws {
        for (titles, query) in [(["Draft", "Draft"], "Draft"), (["Draft One", "Draft Two"], "Draft")] {
            var command = CaptureActionCommand()
            command.app = "Fixture"
            command.windowTitle = query
            command.runtime = self.makeRuntime(titles: titles)

            await #expect(throws: Commander.ValidationError.self) {
                _ = try await command.resolveScope()
            }
        }
    }

    @Test
    @MainActor
    func `capture live and action scopes freeze one unique partial title to exact ID`() async throws {
        let runtime = self.makeRuntime(titles: ["Draft One", "Release Notes"])
        var live = CaptureLiveCommand()
        live.app = "Fixture"
        live.windowTitle = "Notes"
        live.runtime = runtime

        var action = CaptureActionCommand()
        action.app = "Fixture"
        action.windowTitle = "Notes"
        action.runtime = runtime

        let liveScope = try await live.resolveScope()
        let actionScope = try await action.resolveScope()
        #expect(liveScope.windowId == 102)
        #expect(actionScope.windowId == 102)
        #expect(liveScope.windowMutationIdentity?.windowID == 102)
        #expect(actionScope.windowMutationIdentity?.windowID == 102)
    }

    @Test
    @MainActor
    func `capture live automatic app scope freezes the selected exact window`() async throws {
        var command = CaptureLiveCommand()
        command.app = "Fixture"
        command.runtime = self.makeRuntime(titles: ["Main", "Secondary"])

        let scope = try await command.resolveScope()

        #expect(scope.windowId == 101)
        #expect(scope.windowMutationIdentity?.windowID == 101)
        #expect(scope.windowMutationIdentity?.capturedBounds == CGRect(x: 0, y: 0, width: 640, height: 480))
    }

    @Test
    @MainActor
    func `capture foreground focus retains the exact window frozen by scope resolution`() async throws {
        var focusedWindowIDs: [CGWindowID] = []
        var focusedIdentities: [WindowMutationIdentity] = []
        let runtime = self.makeRuntime(titles: ["Draft One", "Release Notes"])
        let provider: FocusResultProvider = { windowID, _, identity in
            focusedWindowIDs.append(windowID)
            focusedIdentities.append(identity)
            return .confirmedChange(
                delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                unitCount: .one
            )
        }

        var live = CaptureLiveCommand()
        live.app = "Fixture"
        live.windowIndex = 1
        live.captureFocus = .foreground
        live.runtime = runtime
        let liveScope = try await live.resolveScope()
        let liveOutcome = try await live.focusIfNeeded(
            appIdentifier: #require(liveScope.applicationIdentifier),
            windowID: liveScope.windowId,
            windowMutationIdentity: liveScope.windowMutationIdentity,
            focusResultProvider: provider
        )

        var action = CaptureActionCommand()
        action.app = "Fixture"
        action.windowIndex = 1
        action.captureFocus = .foreground
        action.runtime = runtime
        let actionScope = try await action.resolveScope()
        let actionOutcome = try await action.focusIfNeeded(
            appIdentifier: #require(actionScope.applicationIdentifier),
            windowID: actionScope.windowId,
            windowMutationIdentity: actionScope.windowMutationIdentity,
            focusResultProvider: provider
        )

        let expectedOutcome = DesktopActionOutcome.confirmedChange(
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            unitCount: .one
        )
        #expect(liveOutcome == expectedOutcome)
        #expect(actionOutcome == expectedOutcome)
        #expect(focusedWindowIDs == [102, 102])
        #expect(try focusedIdentities == [
            #require(liveScope.windowMutationIdentity),
            #require(actionScope.windowMutationIdentity),
        ])
    }

    @Test
    @MainActor
    func `capture focus never reauthorizes a replaced reusable window ID`() async throws {
        let runtime = self.makeRuntime(titles: ["Draft One"])
        var command = CaptureLiveCommand()
        command.app = "Fixture"
        command.captureFocus = .foreground
        command.runtime = runtime
        let scope = try await command.resolveScope()
        let originalIdentity = try #require(scope.windowMutationIdentity)
        let windows = try #require(runtime.services.windows as? StubWindowService)
        let replacementIdentity = WindowMutationIdentity(
            windowID: originalIdentity.windowID,
            ownerProcessIdentifier: originalIdentity.ownerProcessIdentifier,
            ownerProcessStartIdentity: originalIdentity.ownerProcessStartIdentity + 1,
            capturedBounds: originalIdentity.capturedBounds
        )
        windows.windowsByApp["Fixture"] = try [ServiceWindowInfo(
            windowID: originalIdentity.windowID,
            title: "Replacement",
            bounds: #require(originalIdentity.capturedBounds),
            mutationIdentity: replacementIdentity
        )]
        var receivedIdentity: WindowMutationIdentity?

        let outcome = try await command.focusIfNeeded(
            appIdentifier: #require(scope.applicationIdentifier),
            windowID: scope.windowId,
            windowMutationIdentity: scope.windowMutationIdentity,
            focusResultProvider: { _, _, identity in
                receivedIdentity = identity
                return .confirmedChange(
                    delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                    unitCount: .one
                )
            }
        )

        #expect(outcome == .confirmedChange(
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            unitCount: .one
        ))
        #expect(receivedIdentity == originalIdentity)
        #expect(receivedIdentity != replacementIdentity)
    }

    @Test
    @MainActor
    func `capture foreground focus rejects a returned non-success outcome`() async throws {
        let runtime = self.makeRuntime(titles: ["Draft One", "Release Notes"])
        var command = CaptureLiveCommand()
        command.app = "Fixture"
        command.windowIndex = 1
        command.captureFocus = .foreground
        command.runtime = runtime
        let scope = try await command.resolveScope()

        await #expect(throws: (any Error).self) {
            try await command.focusIfNeeded(
                appIdentifier: #require(scope.applicationIdentifier),
                windowID: scope.windowId,
                windowMutationIdentity: scope.windowMutationIdentity,
                focusResultProvider: { _, _, _ in
                    .refused(reason: .targetUnavailable)
                }
            )
        }
        #expect(command.captureMutationDispatched)
    }

    @MainActor
    private func makeRuntime(titles: [String]) -> CommandRuntime {
        let appName = "Fixture"
        let windows = titles.enumerated().map { offset, title in
            let position = CGFloat(offset * 20)
            return ServiceWindowInfo(
                windowID: 101 + offset,
                title: title,
                bounds: CGRect(x: position, y: position, width: 640, height: 480),
                isMainWindow: offset == 0,
                index: offset,
                mutationIdentity: WindowMutationIdentity(
                    windowID: 101 + offset,
                    ownerProcessIdentifier: 42,
                    ownerProcessStartIdentity: 7,
                    capturedBounds: CGRect(x: position, y: position, width: 640, height: 480)
                )
            )
        }
        let application = ServiceApplicationInfo(
            processIdentifier: 42,
            processStartIdentity: 7,
            bundleIdentifier: "dev.fixture",
            name: appName
        )
        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(
                applications: [application],
                windowsByApp: [appName: windows]
            ),
            windows: StubWindowService(windowsByApp: [appName: windows])
        )
        return CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: false, logLevel: nil),
            services: services
        )
    }
}
