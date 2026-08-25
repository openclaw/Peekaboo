import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

struct CaptureLiveBehaviorTests {
    private enum SelectorSurface: CaseIterable {
        case live
        case action
    }

    @Test
    func `resolveMode defaults to window when targeting app pid title or index`() throws {
        var cmd = CaptureLiveCommand()
        cmd.app = "Safari"
        #expect(try cmd.resolveMode() == .window)

        cmd.app = nil
        cmd.pid = 123
        #expect(try cmd.resolveMode() == .window)

        cmd.pid = nil
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
    func `resolveMode uses area when region is provided`() throws {
        var cmd = CaptureLiveCommand()
        cmd.region = "10,20,300,200"
        #expect(try cmd.resolveMode() == .area)
        #expect(try cmd.parseRegion() == CGRect(x: 10, y: 20, width: 300, height: 200))
    }

    @Test
    func `resolveMode accepts region alias for area`() throws {
        var cmd = CaptureLiveCommand()
        cmd.mode = "region"
        cmd.region = "10,20,300,200"
        #expect(try cmd.resolveMode() == .area)
    }

    @Test
    func `resolveMode rejects invalid mode`() {
        var cmd = CaptureLiveCommand()
        cmd.mode = "banana"
        #expect(throws: ValidationError.self) {
            _ = try cmd.resolveMode()
        }
    }

    @Test
    func `parseRegion rejects malformed or empty dimensions`() {
        var invalid = CaptureLiveCommand()
        invalid.region = "1,2,3"
        #expect(throws: PeekabooError.self) {
            _ = try invalid.parseRegion()
        }

        var zero = CaptureLiveCommand()
        zero.region = "1,2,0,4"
        #expect(throws: PeekabooError.self) {
            _ = try zero.parseRegion()
        }
    }

    @Test
    @MainActor
    func `capture live and action reject simultaneous title and index selectors`() throws {
        for surface in SelectorSurface.allCases {
            #expect(throws: ValidationError.self) {
                _ = try Self.selector(for: surface, title: "Draft", index: 0)
            }
        }
    }

    @Test
    @MainActor
    func `capture live and action reject duplicate exact title matches`() throws {
        let windows = [
            Self.window(id: 101, title: "Draft", index: 0),
            Self.window(id: 102, title: "Draft", index: 1),
        ]
        let expectedMessage =
            "Capture selector test window title 'Draft' is ambiguous " +
            "(id=101 index=0 'Draft'; id=102 index=1 'Draft'). " +
            "Select one --window-id or --window-index explicitly."

        for surface in SelectorSurface.allCases {
            let selector = try Self.selector(for: surface, title: "Draft")
            for inventory in [windows, Array(windows.reversed())] {
                do {
                    _ = try ExactWindowSelectorResolver.select(
                        from: inventory,
                        selector: selector,
                        operation: "Capture selector test")
                    Issue.record("Expected duplicate exact title selection to fail")
                } catch let error as ExactWindowSelectorResolutionError {
                    #expect(error.message == expectedMessage)
                }
            }
        }
    }

    @Test
    @MainActor
    func `capture live and action reject duplicate partial title matches`() throws {
        let windows = [
            Self.window(id: 101, title: "Draft One", index: 0),
            Self.window(id: 102, title: "Draft Two", index: 1),
        ]
        let expectedMessage =
            "Capture selector test window title 'Draft' is ambiguous " +
            "(id=101 index=0 'Draft One'; id=102 index=1 'Draft Two'). " +
            "Select one --window-id or --window-index explicitly."

        for surface in SelectorSurface.allCases {
            let selector = try Self.selector(for: surface, title: "Draft")
            for inventory in [windows, Array(windows.reversed())] {
                do {
                    _ = try ExactWindowSelectorResolver.select(
                        from: inventory,
                        selector: selector,
                        operation: "Capture selector test")
                    Issue.record("Expected duplicate partial title selection to fail")
                } catch let error as ExactWindowSelectorResolutionError {
                    #expect(error.message == expectedMessage)
                }
            }
        }
    }

    @Test
    @MainActor
    func `capture selectors deterministically report unrelated conflicting duplicates`() throws {
        let selected = Self.window(id: 101, title: "Draft", index: 0)
        let firstConflict = Self.window(id: 202, title: "Other A", index: 1)
        let secondConflict = Self.window(id: 202, title: "Other B", index: 2)
        let inventories = [
            [selected, firstConflict, secondConflict],
            [secondConflict, firstConflict, selected],
        ]
        let expectedMessage =
            "Capture selector test found conflicting inventory rows for window ID 202 " +
            "(id=202 index=1 'Other A'; id=202 index=2 'Other B'). " +
            "Refresh the window inventory before retrying."

        for surface in SelectorSurface.allCases {
            let selector = try Self.selector(for: surface, title: "Draft")
            for inventory in inventories {
                do {
                    _ = try ExactWindowSelectorResolver.select(
                        from: inventory,
                        selector: selector,
                        operation: "Capture selector test")
                    Issue.record("Expected conflicting inventory selection to fail")
                } catch let error as ExactWindowSelectorResolutionError {
                    #expect(error.message == expectedMessage)
                }
            }
        }
    }

    @Test
    @MainActor
    func `capture selectors canonicalize repeated stable inventory rows`() throws {
        let window = Self.window(id: 101, title: "Draft", index: 0)

        for surface in SelectorSurface.allCases {
            let selector = try Self.selector(for: surface, title: "Draft")
            let selected = try ExactWindowSelectorResolver.select(
                from: [window, window],
                selector: selector,
                operation: "Capture selector test")
            #expect(selected == window)
        }
    }

    @Test
    @MainActor
    func `capture live and action resolve one unique partial title match`() throws {
        let windows = [
            Self.window(id: 101, title: "Draft One", index: 0),
            Self.window(id: 102, title: "Release Notes", index: 1),
        ]

        for surface in SelectorSurface.allCases {
            let selector = try Self.selector(for: surface, title: "Notes")
            let selected = try ExactWindowSelectorResolver.select(
                from: windows,
                selector: selector,
                operation: "Capture selector test"
            )
            #expect(selected.windowID == 102)
        }
    }

    @Test
    func `capture commands reject invalid diff strategy`() {
        var live = CaptureLiveCommand()
        live.diffStrategy = "slow"
        #expect(throws: ValidationError.self) {
            _ = try live.buildOptions()
        }

        var video = CaptureVideoCommand()
        video.diffStrategy = "slow"
        #expect(throws: ValidationError.self) {
            _ = try video.buildOptions()
        }
    }

    @Test
    func `live cadence rejects nonfinite out of range and inverted rates`() {
        for idle in [Double.nan, 0, 0.099, 5.001] {
            var command = CaptureLiveCommand()
            command.idleFps = idle
            #expect(throws: CaptureCadenceValidationError.self) {
                _ = try command.buildOptions()
            }
        }

        for active in [Double.infinity, 0, 0.499, 15.001] {
            var command = CaptureLiveCommand()
            command.activeFps = active
            #expect(throws: CaptureCadenceValidationError.self) {
                _ = try command.buildOptions()
            }
        }

        var inverted = CaptureLiveCommand()
        inverted.idleFps = 5
        inverted.activeFps = 4
        #expect(throws: CaptureCadenceValidationError.self) {
            _ = try inverted.buildOptions()
        }
    }

    @Test
    func `cadence validation maps to a pre-dispatch validation error`() {
        let error = CaptureCadenceValidationError.activeBelowIdle(active: 4, idle: 5)
        #expect(CaptureLiveCommand().mapErrorToCode(error) == .VALIDATION_ERROR)
    }

    @Test
    func `Commander preserves negative cadence for shared validation`() throws {
        let command = try CaptureLiveCommand.parse(["--idle-fps", "-1"])
        #expect(command.idleFps == -1)
        #expect(throws: CaptureCadenceValidationError.self) {
            _ = try command.buildOptions()
        }
    }

    @Test
    func `Commander cadence metadata declares the complete validation contract`() {
        let live = CaptureLiveCommand.commanderSignature()
        let action = CaptureActionCommand.commanderSignature()

        for signature in [live, action] {
            let idleHelp = signature.options.first { $0.label == "idleFps" }?.help
            let activeHelp = signature.options.first { $0.label == "activeFps" }?.help
            #expect(idleHelp == "Idle FPS (default 2; finite range 0.1...5)")
            #expect(activeHelp == "Active FPS (default 8; finite range 0.5...15; must be >= idle FPS)")
        }
    }

    @Test
    func `human output preserves nonzero tiny frame deltas`() {
        #expect(CaptureLiveCommand.formatChangePercent(0) == "0.00")
        #expect(CaptureLiveCommand.formatChangePercent(0.004) == "0.004")
        #expect(CaptureLiveCommand.formatChangePercent(0.012) == "0.01")
    }

    @MainActor
    private static func selector(
        for surface: SelectorSurface,
        title: String?,
        index: Int? = nil
    ) throws -> InteractionTargetSelector {
        switch surface {
        case .live:
            var command = CaptureLiveCommand()
            command.app = "Fixture"
            command.windowTitle = title
            command.windowIndex = index
            return try command.validatedCaptureWindowSelector()
        case .action:
            var command = CaptureActionCommand()
            command.app = "Fixture"
            command.windowTitle = title
            command.windowIndex = index
            return try command.validatedCaptureWindowSelector()
        }
    }

    private static func window(id: Int, title: String, index: Int) -> ServiceWindowInfo {
        let position = CGFloat(index * 20)
        let bounds = CGRect(x: position, y: position, width: 640, height: 480)
        return ServiceWindowInfo(
            windowID: id,
            title: title,
            bounds: bounds,
            index: index,
            mutationIdentity: WindowMutationIdentity(
                windowID: id,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 7,
                capturedBounds: bounds
            )
        )
    }
}
