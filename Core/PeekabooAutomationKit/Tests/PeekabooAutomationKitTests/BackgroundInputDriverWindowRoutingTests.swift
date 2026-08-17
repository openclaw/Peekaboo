import CoreGraphics
import Testing
@testable import PeekabooAutomationKit

struct BackgroundInputDriverWindowRoutingTests {
    @Test
    func `Exact window lookup falls back to the full catalog for another Space`() throws {
        var queries: [(CGWindowListOption, CGWindowID)] = []
        let candidates = BackgroundInputDriver
            .mouseWindowRouteCandidates(exactWindowID: 42) { options, relativeToWindow in
                queries.append((options, relativeToWindow))
                if options.contains(.optionIncludingWindow) {
                    return []
                }
                return [Self.windowDictionary(
                    windowID: 42,
                    processIdentifier: 123,
                    bounds: CGRect(x: 0, y: 0, width: 200, height: 200))]
            }

        let resolved = try BackgroundInputDriver.resolveTargetWindowID(
            at: CGPoint(x: 50, y: 50),
            targetProcessIdentifier: 123,
            exactWindowID: 42,
            candidates: candidates)

        #expect(queries.count == 2)
        #expect(queries[0].0 == [.optionIncludingWindow])
        #expect(queries[0].1 == 42)
        #expect(queries[1].0 == [.optionAll, .excludeDesktopElements])
        #expect(queries[1].1 == kCGNullWindowID)
        #expect(resolved == 42)
    }

    @Test
    func `Exact window lookup stays stale when both catalogs omit it`() {
        var queries: [(CGWindowListOption, CGWindowID)] = []
        let candidates = BackgroundInputDriver.mouseWindowRouteCandidates(exactWindowID: 42) {
            options,
            relativeToWindow in
            queries.append((options, relativeToWindow))
            return []
        }

        #expect(throws: (any Error).self) {
            try BackgroundInputDriver.resolveTargetWindowID(
                at: CGPoint(x: 50, y: 50),
                targetProcessIdentifier: 123,
                exactWindowID: 42,
                candidates: candidates)
        }
        #expect(queries.count == 2)
        #expect(queries[0].0 == [.optionIncludingWindow])
        #expect(queries[1].0 == [.optionAll, .excludeDesktopElements])
    }

    @Test
    func `Targetless lookup remains on screen only`() throws {
        var queries: [(CGWindowListOption, CGWindowID)] = []
        let candidates = BackgroundInputDriver.mouseWindowRouteCandidates(exactWindowID: nil) {
            options,
            relativeToWindow in
            queries.append((options, relativeToWindow))
            return [Self.windowDictionary(
                windowID: 42,
                processIdentifier: 123,
                bounds: CGRect(x: 0, y: 0, width: 200, height: 200))]
        }

        let resolved = try BackgroundInputDriver.resolveTargetWindowID(
            at: CGPoint(x: 50, y: 50),
            targetProcessIdentifier: 123,
            exactWindowID: nil,
            candidates: candidates)

        #expect(queries.count == 1)
        #expect(queries[0].0 == [.optionOnScreenOnly, .excludeDesktopElements])
        #expect(queries[0].1 == kCGNullWindowID)
        #expect(resolved == 42)
    }

    @Test
    func `Exact window wins over an overlapping sibling window`() throws {
        let candidates = [
            Self.candidate(windowID: 99, processIdentifier: 123, bounds: CGRect(x: 0, y: 0, width: 200, height: 200)),
            Self.candidate(windowID: 42, processIdentifier: 123, bounds: CGRect(x: 0, y: 0, width: 200, height: 200)),
        ]

        let resolved = try BackgroundInputDriver.resolveTargetWindowID(
            at: CGPoint(x: 50, y: 50),
            targetProcessIdentifier: 123,
            exactWindowID: 42,
            candidates: candidates)

        #expect(resolved == 42)
    }

    @Test
    func `Exact window rejects PID reuse`() {
        let candidates = [
            Self.candidate(windowID: 42, processIdentifier: 999, bounds: CGRect(x: 0, y: 0, width: 200, height: 200)),
        ]

        #expect(throws: (any Error).self) {
            try BackgroundInputDriver.resolveTargetWindowID(
                at: CGPoint(x: 50, y: 50),
                targetProcessIdentifier: 123,
                exactWindowID: 42,
                candidates: candidates)
        }
    }

    @Test
    func `Exact window rejects a point outside current bounds`() {
        let candidates = [
            Self.candidate(windowID: 42, processIdentifier: 123, bounds: CGRect(x: 0, y: 0, width: 20, height: 20)),
        ]

        #expect(throws: (any Error).self) {
            try BackgroundInputDriver.resolveTargetWindowID(
                at: CGPoint(x: 50, y: 50),
                targetProcessIdentifier: 123,
                exactWindowID: 42,
                candidates: candidates)
        }
    }

    private static func candidate(
        windowID: CGWindowID,
        processIdentifier: pid_t,
        bounds: CGRect) -> BackgroundInputDriver.MouseWindowRouteCandidate
    {
        BackgroundInputDriver.MouseWindowRouteCandidate(
            windowID: windowID,
            processIdentifier: processIdentifier,
            layer: 0,
            bounds: bounds)
    }

    private static func windowDictionary(
        windowID: CGWindowID,
        processIdentifier: pid_t,
        bounds: CGRect) -> [String: Any]
    {
        [
            kCGWindowNumber as String: Int(windowID),
            kCGWindowOwnerPID as String: Int(processIdentifier),
            kCGWindowLayer as String: 0,
            kCGWindowBounds as String: bounds.dictionaryRepresentation,
        ]
    }
}
