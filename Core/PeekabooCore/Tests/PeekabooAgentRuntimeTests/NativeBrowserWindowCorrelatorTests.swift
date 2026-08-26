import Foundation
import PeekabooAutomationKit
import Testing
@testable import PeekabooAgentRuntime

struct NativeBrowserWindowCorrelatorTests {
    @Test
    func `unique geometry and exact target membership correlate`() throws {
        let identity = Self.identity(bounds: CGRect(x: 120, y: 80, width: 1280, height: 720))
        let result = try NativeBrowserWindowCorrelator.correlate(
            expectedNativeWindow: identity,
            currentNativeWindow: identity,
            nativeTitle: nil,
            requestedTargetID: "target-a",
            candidates: [Self.candidate(
                windowID: 91,
                bounds: CGRect(x: 124, y: 75, width: 1272, height: 728),
                targetIDs: ["target-a", "target-b"])])

        #expect(result.nativeWindowIdentity == identity)
        #expect(result.browserWindowID.rawValue == 91)
        #expect(result.browserBounds == CGRect(x: 124, y: 75, width: 1272, height: 728))
        #expect(NativeBrowserWindowCorrelator.geometryTolerance == 8)
    }

    @Test
    func `fixed tolerance accepts its boundary and rejects any component beyond it`() throws {
        let bounds = CGRect(x: 100, y: 200, width: 900, height: 700)
        let identity = Self.identity(bounds: bounds)
        let atBoundary = Self.candidate(
            windowID: 91,
            bounds: CGRect(x: 108, y: 192, width: 908, height: 692),
            targetIDs: ["target-a"])

        let result = try NativeBrowserWindowCorrelator.correlate(
            expectedNativeWindow: identity,
            currentNativeWindow: identity,
            nativeTitle: nil,
            requestedTargetID: "target-a",
            candidates: [atBoundary])
        #expect(result.browserWindowID.rawValue == 91)

        let outsideBoundary = Self.candidate(
            windowID: 92,
            bounds: CGRect(x: 108.01, y: 200, width: 900, height: 700),
            targetIDs: ["target-a"])
        #expect(throws: NativeBrowserWindowCorrelationError.noGeometryMatch) {
            try NativeBrowserWindowCorrelator.correlate(
                expectedNativeWindow: identity,
                currentNativeWindow: identity,
                nativeTitle: nil,
                requestedTargetID: "target-a",
                candidates: [outsideBoundary])
        }
    }

    @Test
    func `negative multi-display coordinates are compared without normalization`() throws {
        let bounds = CGRect(x: -1920, y: -240, width: 1440, height: 900)
        let identity = Self.identity(bounds: bounds)
        let result = try NativeBrowserWindowCorrelator.correlate(
            expectedNativeWindow: identity,
            currentNativeWindow: identity,
            nativeTitle: nil,
            requestedTargetID: "target-negative",
            candidates: [
                Self.candidate(
                    windowID: 10,
                    bounds: CGRect(x: 1920, y: 240, width: 1440, height: 900),
                    targetIDs: []),
                Self.candidate(
                    windowID: 11,
                    bounds: CGRect(x: -1916, y: -246, width: 1436, height: 906),
                    targetIDs: ["target-negative"]),
            ])

        #expect(result.browserWindowID.rawValue == 11)
    }

    @Test
    func `exact title breaks only a geometry tie`() throws {
        let bounds = CGRect(x: 20, y: 30, width: 1100, height: 800)
        let identity = Self.identity(bounds: bounds)
        let result = try NativeBrowserWindowCorrelator.correlate(
            expectedNativeWindow: identity,
            currentNativeWindow: identity,
            nativeTitle: "Peekaboo - Background",
            requestedTargetID: "target-b",
            candidates: [
                Self.candidate(
                    windowID: 21,
                    bounds: bounds,
                    titles: ["Other", "Background Tab"],
                    targetIDs: ["target-a"]),
                Self.candidate(
                    windowID: 22,
                    bounds: bounds,
                    titles: ["Peekaboo - Background", "Inactive Tab"],
                    targetIDs: ["target-b"]),
            ])

        #expect(result.browserWindowID.rawValue == 22)
    }

    @Test
    func `title comparison is exact and duplicate title matches remain ambiguous`() {
        let bounds = CGRect(x: 20, y: 30, width: 1100, height: 800)
        let identity = Self.identity(bounds: bounds)
        let candidates = [
            Self.candidate(
                windowID: 21,
                bounds: bounds,
                titles: ["Peekaboo"],
                targetIDs: ["target-a"]),
            Self.candidate(
                windowID: 22,
                bounds: bounds,
                titles: ["peekaboo"],
                targetIDs: ["target-b"]),
        ]

        #expect(throws: NativeBrowserWindowCorrelationError.ambiguousGeometry) {
            try NativeBrowserWindowCorrelator.correlate(
                expectedNativeWindow: identity,
                currentNativeWindow: identity,
                nativeTitle: " PEEKABOO ",
                requestedTargetID: "target-a",
                candidates: candidates)
        }

        let duplicateTitles = candidates.map {
            Self.candidate(
                windowID: $0.windowID.rawValue,
                bounds: $0.bounds,
                titles: ["Peekaboo"],
                targetIDs: $0.targetIDs)
        }
        #expect(throws: NativeBrowserWindowCorrelationError.ambiguousGeometry) {
            try NativeBrowserWindowCorrelator.correlate(
                expectedNativeWindow: identity,
                currentNativeWindow: identity,
                nativeTitle: "Peekaboo",
                requestedTargetID: "target-a",
                candidates: duplicateTitles)
        }
    }

    @Test
    func `title alone never authorizes a geometry mismatch`() {
        let identity = Self.identity(bounds: CGRect(x: 20, y: 30, width: 1100, height: 800))
        let titleOnly = Self.candidate(
            windowID: 21,
            bounds: CGRect(x: 500, y: 500, width: 700, height: 600),
            titles: ["Exact Title"],
            targetIDs: ["target-a"])

        #expect(throws: NativeBrowserWindowCorrelationError.noGeometryMatch) {
            try NativeBrowserWindowCorrelator.correlate(
                expectedNativeWindow: identity,
                currentNativeWindow: identity,
                nativeTitle: "Exact Title",
                requestedTargetID: "target-a",
                candidates: [titleOnly])
        }
    }

    @Test
    func `target membership is validation after geometry selection`() {
        let bounds = CGRect(x: 20, y: 30, width: 1100, height: 800)
        let identity = Self.identity(bounds: bounds)
        let candidates = [
            Self.candidate(windowID: 21, bounds: bounds, targetIDs: ["other-target"]),
            Self.candidate(
                windowID: 22,
                bounds: CGRect(x: 500, y: 500, width: 700, height: 600),
                titles: ["Exact Title"],
                targetIDs: ["requested-target"]),
        ]

        #expect(throws: NativeBrowserWindowCorrelationError.wrongTargetMembership) {
            try NativeBrowserWindowCorrelator.correlate(
                expectedNativeWindow: identity,
                currentNativeWindow: identity,
                nativeTitle: "Exact Title",
                requestedTargetID: "requested-target",
                candidates: candidates)
        }
    }

    @Test
    func `target must belong uniquely to the selected CDP window`() {
        let bounds = CGRect(x: 20, y: 30, width: 1100, height: 800)
        let identity = Self.identity(bounds: bounds)
        let candidates = [
            Self.candidate(windowID: 21, bounds: bounds, targetIDs: ["target-a"]),
            Self.candidate(
                windowID: 22,
                bounds: CGRect(x: 500, y: 500, width: 700, height: 600),
                targetIDs: ["target-a"]),
        ]

        #expect(throws: NativeBrowserWindowCorrelationError.wrongTargetMembership) {
            try NativeBrowserWindowCorrelator.correlate(
                expectedNativeWindow: identity,
                currentNativeWindow: identity,
                nativeTitle: nil,
                requestedTargetID: "target-a",
                candidates: candidates)
        }
        #expect(throws: NativeBrowserWindowCorrelationError.wrongTargetMembership) {
            try NativeBrowserWindowCorrelator.correlate(
                expectedNativeWindow: identity,
                currentNativeWindow: identity,
                nativeTitle: nil,
                requestedTargetID: "",
                candidates: [candidates[0]])
        }
    }

    @Test
    func `changed native receipt fails stale before looking at CDP`() {
        let bounds = CGRect(x: 20, y: 30, width: 1100, height: 800)
        let expected = Self.identity(bounds: bounds)
        let moved = Self.identity(bounds: CGRect(x: 21, y: 30, width: 1100, height: 800))
        let replacement = WindowMutationIdentity(
            windowID: expected.windowID,
            ownerProcessIdentifier: expected.ownerProcessIdentifier,
            ownerProcessStartIdentity: expected.ownerProcessStartIdentity + 1,
            capturedBounds: bounds)
        let candidate = Self.candidate(windowID: 21, bounds: bounds, targetIDs: ["target-a"])

        for current in [nil, moved, replacement] as [WindowMutationIdentity?] {
            #expect(throws: NativeBrowserWindowCorrelationError.staleNativeWindow) {
                try NativeBrowserWindowCorrelator.correlate(
                    expectedNativeWindow: expected,
                    currentNativeWindow: current,
                    nativeTitle: nil,
                    requestedTargetID: "target-a",
                    candidates: [candidate])
            }
        }
    }

    @Test
    func `missing native bounds and malformed CDP bounds fail closed`() {
        let missingBounds = Self.identity(bounds: nil)
        #expect(throws: NativeBrowserWindowCorrelationError.staleNativeWindow) {
            try NativeBrowserWindowCorrelator.correlate(
                expectedNativeWindow: missingBounds,
                currentNativeWindow: missingBounds,
                nativeTitle: "Exact Title",
                requestedTargetID: "target-a",
                candidates: [Self.candidate(
                    windowID: 21,
                    bounds: CGRect(x: 20, y: 30, width: 1100, height: 800),
                    titles: ["Exact Title"],
                    targetIDs: ["target-a"])])
        }

        let bounds = CGRect(x: 20, y: 30, width: 1100, height: 800)
        let identity = Self.identity(bounds: bounds)
        #expect(throws: NativeBrowserWindowCorrelationError.noGeometryMatch) {
            try NativeBrowserWindowCorrelator.correlate(
                expectedNativeWindow: identity,
                currentNativeWindow: identity,
                nativeTitle: "Exact Title",
                requestedTargetID: "target-a",
                candidates: [Self.candidate(
                    windowID: 21,
                    bounds: CGRect(x: 20, y: 30, width: CGFloat.nan, height: 800),
                    titles: ["Exact Title"],
                    targetIDs: ["target-a"])])
        }
    }

    private static func identity(bounds: CGRect?) -> WindowMutationIdentity {
        WindowMutationIdentity(
            windowID: 7,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 1042,
            capturedBounds: bounds)
    }

    private static func candidate(
        windowID: Int,
        bounds: CGRect,
        titles: Set<String> = [],
        targetIDs: Set<String>) -> CDPBrowserWindowCandidate
    {
        CDPBrowserWindowCandidate(
            windowID: BrowserMCPDevToolsWindowID(rawValue: windowID),
            bounds: bounds,
            titles: titles,
            targetIDs: targetIDs)
    }
}
