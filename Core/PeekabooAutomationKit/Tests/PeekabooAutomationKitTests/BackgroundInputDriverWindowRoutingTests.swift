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

    @Test
    func `pointer route treats a visible overlay as the receiver`() throws {
        let point = CGPoint(x: 50, y: 50)
        let overlay = Self.candidate(
            windowID: 99,
            processIdentifier: 999,
            bounds: CGRect(x: 20, y: 20, width: 80, height: 80),
            layer: 8)
        let target = Self.candidate(
            windowID: 42,
            processIdentifier: 123,
            bounds: CGRect(x: 0, y: 0, width: 200, height: 200))

        let route = try #require(BackgroundInputDriver.pointerReceivingWindowRoute(
            at: point,
            candidates: [overlay, target]))

        #expect(route == overlay)
    }

    @Test
    func `pointer route preserves an overlapping sibling ahead of the target`() throws {
        let point = CGPoint(x: 50, y: 50)
        let sibling = Self.candidate(
            windowID: 41,
            processIdentifier: 123,
            bounds: CGRect(x: 0, y: 0, width: 120, height: 120))
        let target = Self.candidate(
            windowID: 42,
            processIdentifier: 123,
            bounds: CGRect(x: 0, y: 0, width: 200, height: 200))

        let route = try #require(BackgroundInputDriver.pointerReceivingWindowRoute(
            at: point,
            candidates: [sibling, target]))

        #expect(route == sibling)
    }

    @Test
    func `pointer route admits the exact target behind only transparent rows`() throws {
        let point = CGPoint(x: 50, y: 50)
        let transparent = Self.candidate(
            windowID: 99,
            processIdentifier: 999,
            bounds: CGRect(x: 20, y: 20, width: 80, height: 80),
            layer: 8,
            alpha: 0)
        let target = Self.candidate(
            windowID: 42,
            processIdentifier: 123,
            bounds: CGRect(x: 0, y: 0, width: 200, height: 200))

        let route = try #require(BackgroundInputDriver.pointerReceivingWindowRoute(
            at: point,
            candidates: [transparent, target]))

        #expect(route == target)
    }

    private static func candidate(
        windowID: CGWindowID,
        processIdentifier: pid_t,
        bounds: CGRect,
        layer: Int = 0,
        alpha: CGFloat = 1) -> BackgroundInputDriver.MouseWindowRouteCandidate
    {
        BackgroundInputDriver.MouseWindowRouteCandidate(
            windowID: windowID,
            processIdentifier: processIdentifier,
            layer: layer,
            bounds: bounds,
            alpha: alpha)
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
