import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

@Suite(.serialized)
struct PeekabooBridgeScreenObservationBindingTests: DesktopObservationBindingFixtureProviding {
    @Test(arguments: [false, true])
    @MainActor
    func `screen raster and generation bound AX owner remain distinct signed evidence`(
        includesFocusedElement: Bool) async throws
    {
        let request = Self.request
        let result = Self.result(context: Self.context(focusedElement: includesFocusedElement ? Self.focus() : nil))
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(request: request, result: result) == nil)
        #expect(result.target.app == nil)
        #expect(result.target.window == nil)
        #expect(result.capture.metadata.applicationInfo == nil)
        #expect(result.elements?.metadata.windowContext?.applicationProcessId == 42)

        let provider = ObservationProvider(result: result)
        let server = Self.server(provider: provider)
        _ = try await PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
            try await server.handleAuthorized(.desktopObservation(request), peer: nil, permissions: Self.permissions)
        }
        #expect(provider.observationCount == 1)

        let bundle = try await Self.makeBundle(
            request: .desktopObservation(request), response: .desktopObservation(result), target: .global)
        try bundle.validateIntegrity()
    }

    @Test
    @MainActor
    func `screen AX owner rejects missing generation and contradictory window receipts`() async throws {
        let wrongOwner = WindowMutationIdentity(
            windowID: 73,
            ownerProcessIdentifier: 99,
            ownerProcessStartIdentity: 1001,
            capturedBounds: Self.windowBounds)
        let wrongGeneration = WindowMutationIdentity(
            windowID: 73,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 1002,
            capturedBounds: Self.windowBounds)
        let wrongBounds = WindowMutationIdentity(
            windowID: 73,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 1001,
            capturedBounds: CGRect(x: 10, y: 10, width: 400, height: 300))
        let contexts = [
            Self.context(generation: nil),
            Self.context(generation: 0),
            Self.context(processIdentifier: 0),
            Self.context(receipt: wrongOwner),
            Self.context(receipt: wrongGeneration),
            Self.context(receipt: wrongBounds),
            Self.context(focusedElement: Self.focus(processIdentifier: 99)),
            Self.context(focusedElement: Self.focus(windowID: 74)),
            Self.context(focusedElement: Self.focus(role: "")),
            Self.context(focusedElement: Self.focus(frame: CGRect(x: 1000, y: 1000, width: 10, height: 10))),
        ]
        for context in contexts {
            let result = Self.result(context: context)
            #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
                request: Self.request, result: result) != nil)
            let bundle = try await Self.makeBundle(
                request: .desktopObservation(Self.request), response: .desktopObservation(result), target: .global)
            #expect(throws: PeekabooBridgeOperationReceiptError.self) {
                try bundle.validateIntegrity()
            }
        }
    }

    @Test
    func `screen semantics accept a consistent exact window receipt without changing raster scope`() {
        let receipt = WindowMutationIdentity(
            windowID: 73,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 1001,
            capturedBounds: Self.windowBounds)
        let result = Self.result(context: Self.context(receipt: receipt))
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(request: Self.request, result: result) == nil)
        #expect(result.capture.metadata.windowInfo == nil)
    }

    private static var request: DesktopObservationRequest {
        DesktopObservationRequest(target: .screen(index: 0), detection: .init(traversalBudget: AXTraversalBudget()))
    }

    private static let windowBounds = CGRect(x: 20, y: 30, width: 400, height: 300)

    private static func context(
        processIdentifier: Int32 = 42,
        generation: UInt64? = 1001,
        receipt: WindowMutationIdentity? = nil,
        focusedElement: FocusedElementIdentity? = nil) -> WindowContext
    {
        WindowContext(
            applicationName: "Fixture",
            applicationBundleId: "example.fixture",
            applicationProcessId: processIdentifier,
            applicationProcessStartIdentity: generation,
            windowTitle: "Fixture window",
            windowID: 73,
            windowBounds: self.windowBounds,
            windowMutationIdentity: receipt,
            focusedElement: focusedElement,
            shouldFocusWebContent: false,
            includeMenuBarElements: false,
            traversalBudget: AXTraversalBudget())
    }

    private static func focus(
        processIdentifier: Int32 = 42,
        windowID: Int = 73,
        role: String = "AXButton",
        frame: CGRect = CGRect(x: 30, y: 40, width: 10, height: 10)) -> FocusedElementIdentity
    {
        FocusedElementIdentity(processIdentifier: processIdentifier, windowID: windowID, role: role, frame: frame)
    }

    private static func result(context: WindowContext) -> DesktopObservationResult {
        replacingElements(
            screenResult(index: 0),
            with: ElementDetectionResult(
                snapshotId: "screen-semantic-fixture",
                screenshotPath: "",
                elements: .init(buttons: [.init(id: "B1", type: .button, bounds: self.windowBounds)]),
                metadata: .init(
                    detectionTime: 0, elementCount: 1, method: "fixture", windowContext: context, isDialog: false)))
    }
}
