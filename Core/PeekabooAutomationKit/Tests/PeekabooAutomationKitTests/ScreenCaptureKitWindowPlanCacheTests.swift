import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@_spi(Testing) @testable import PeekabooAutomationKit

@MainActor
struct ScreenCaptureKitWindowPlanCacheTests {
    private final class Plan: @unchecked Sendable {}

    @Test
    func `fresh entries reuse the same plan and expire at the TTL`() {
        let cache = ScreenCaptureKitWindowPlanCache<Plan>(timeToLive: .seconds(2), capacity: 4)
        let key = ScreenCaptureKitWindowPlanCache<Plan>.Key(windowID: 42, usesNativeScale: false)
        let plan = Plan()
        let start = ContinuousClock.now

        cache.insert(plan, for: key, now: start)

        #expect(cache.value(for: key, now: start.advanced(by: .milliseconds(1999))) === plan)
        #expect(cache.value(for: key, now: start.advanced(by: .seconds(2))) == nil)
        #expect(cache.isEmpty)
    }

    @Test
    func `scale variants are independent and capacity evicts the oldest live plan`() {
        let cache = ScreenCaptureKitWindowPlanCache<Plan>(timeToLive: .seconds(10), capacity: 2)
        let logical = ScreenCaptureKitWindowPlanCache<Plan>.Key(windowID: 42, usesNativeScale: false)
        let native = ScreenCaptureKitWindowPlanCache<Plan>.Key(windowID: 42, usesNativeScale: true)
        let other = ScreenCaptureKitWindowPlanCache<Plan>.Key(windowID: 43, usesNativeScale: false)
        let start = ContinuousClock.now
        let logicalPlan = Plan()
        let nativePlan = Plan()
        let otherPlan = Plan()

        cache.insert(logicalPlan, for: logical, now: start)
        cache.insert(nativePlan, for: native, now: start.advanced(by: .milliseconds(1)))
        cache.insert(otherPlan, for: other, now: start.advanced(by: .milliseconds(2)))

        #expect(cache.value(for: logical, now: start.advanced(by: .milliseconds(3))) == nil)
        #expect(cache.value(for: native, now: start.advanced(by: .milliseconds(3))) === nativePlan)
        #expect(cache.value(for: other, now: start.advanced(by: .milliseconds(3))) === otherPlan)
    }

    @Test
    func `expired entries are purged before a live plan is evicted`() {
        let cache = ScreenCaptureKitWindowPlanCache<Plan>(timeToLive: .seconds(2), capacity: 2)
        let expired = ScreenCaptureKitWindowPlanCache<Plan>.Key(windowID: 1, usesNativeScale: false)
        let live = ScreenCaptureKitWindowPlanCache<Plan>.Key(windowID: 2, usesNativeScale: false)
        let inserted = ScreenCaptureKitWindowPlanCache<Plan>.Key(windowID: 3, usesNativeScale: false)
        let start = ContinuousClock.now
        let livePlan = Plan()

        cache.insert(Plan(), for: expired, now: start)
        cache.insert(livePlan, for: live, now: start.advanced(by: .milliseconds(1500)))
        cache.insert(Plan(), for: inserted, now: start.advanced(by: .seconds(2)))

        #expect(cache.value(for: expired, now: start.advanced(by: .seconds(2))) == nil)
        #expect(cache.value(for: live, now: start.advanced(by: .seconds(2))) === livePlan)
        #expect(cache.value(for: inserted, now: start.advanced(by: .seconds(2))) != nil)
    }

    @Test
    func `stale-plan eviction cannot remove a replacement`() {
        let cache = ScreenCaptureKitWindowPlanCache<Plan>(timeToLive: .seconds(2), capacity: 2)
        let key = ScreenCaptureKitWindowPlanCache<Plan>.Key(windowID: 42, usesNativeScale: false)
        let stale = Plan()
        let replacement = Plan()

        cache.insert(stale, for: key)
        cache.insert(replacement, for: key)

        #expect(!cache.removeValue(for: key, ifSameAs: stale))
        #expect(cache.value(for: key) === replacement)
        #expect(cache.removeValue(for: key, ifSameAs: replacement))
    }

    @Test
    func `independent host caches never share plans`() {
        let first = ScreenCaptureKitWindowPlanCache<Plan>()
        let second = ScreenCaptureKitWindowPlanCache<Plan>()
        let key = ScreenCaptureKitWindowPlanCache<Plan>.Key(windowID: 42, usesNativeScale: false)
        let firstPlan = Plan()
        let secondPlan = Plan()

        first.insert(firstPlan, for: key)
        #expect(first.value(for: key) === firstPlan)
        #expect(second.value(for: key) == nil)

        second.insert(secondPlan, for: key)
        #expect(first.value(for: key) === firstPlan)
        #expect(second.value(for: key) === secondPlan)
    }

    @Test
    func `distinct operators own distinct caches and generation sequences`() {
        let logger = MockLoggingService().logger(category: "test")
        let first = ScreenCaptureKitOperator(
            logger: logger,
            feedbackClient: NoopAutomationFeedbackClient(),
            frameSource: OperatorNoOpFrameSource())
        let second = ScreenCaptureKitOperator(
            logger: logger,
            feedbackClient: NoopAutomationFeedbackClient(),
            frameSource: OperatorNoOpFrameSource())

        #expect(first.exactWindowPlanCache !== second.exactWindowPlanCache)
        #expect(first.nextExactWindowPlanGeneration == 1)
        #expect(second.nextExactWindowPlanGeneration == 1)

        first.nextExactWindowPlanGeneration &+= 1
        #expect(first.nextExactWindowPlanGeneration == 2)
        #expect(second.nextExactWindowPlanGeneration == 1)

        second.nextExactWindowPlanGeneration &+= 1
        #expect(first.nextExactWindowPlanGeneration == 2)
        #expect(second.nextExactWindowPlanGeneration == 2)
    }

    @Test
    func `capture diagnostics preserve rebuilt cache and generation receipts`() throws {
        let plan = ScreenCaptureScaleResolver.Plan(
            preference: .logical1x,
            nativeScale: 2,
            outputScale: 1,
            source: .screenBackingScaleFactor)
        let diagnostics = ScreenCaptureScaleResolver.diagnostics(
            plan: plan,
            finalPixelSize: CGSize(width: 800, height: 600),
            windowPlanCacheStatus: .rebuilt,
            windowPlanCacheGeneration: 17)

        let encoded = try JSONEncoder().encode(diagnostics)
        let decoded = try JSONDecoder().decode(CaptureDiagnostics.self, from: encoded)

        #expect(decoded.windowPlanCacheStatus == .rebuilt)
        #expect(decoded.windowPlanCacheGeneration == 17)
    }

    @Test
    func `observation span publishes cache receipts without changing its duration`() {
        let tracer = DesktopObservationTraceRecorder()
        let start = ContinuousClock.now
        tracer.record("capture.window", start: start, metadata: ["existing": "value"])
        let original = tracer.timings().spans[0]

        tracer.annotateLastSpan(
            named: "capture.window",
            metadata: [
                "window_plan_cache": "hit",
                "window_plan_cache_generation": "17",
            ])

        let span = tracer.timings().spans[0]
        #expect(span.durationMS == original.durationMS)
        #expect(span.metadata["existing"] == "value")
        #expect(span.metadata["window_plan_cache"] == "hit")
        #expect(span.metadata["window_plan_cache_generation"] == "17")
    }

    @Test
    func `idle entries release their retained plan after the TTL`() async throws {
        let cache = ScreenCaptureKitWindowPlanCache<Plan>(timeToLive: .milliseconds(20), capacity: 1)
        let key = ScreenCaptureKitWindowPlanCache<Plan>.Key(windowID: 42, usesNativeScale: false)
        cache.insert(Plan(), for: key)

        try await Task.sleep(for: .milliseconds(50))
        for _ in 0..<100 where !cache.isEmpty {
            await Task.yield()
        }

        #expect(cache.isEmpty)
    }

    @Test
    func `receipt and topology validation distinguishes drift from unavailable evidence`() {
        let bounds = CGRect(x: 10, y: 20, width: 800, height: 600)
        let receipt = Self.receipt(bounds: bounds)
        let topology = Self.topology(pixelWidth: 1920)

        #expect(Self.validation(receipt, topology, receipt, topology) == .matched)
        #expect(Self.validation(
            receipt,
            topology,
            Self.receipt(bounds: CGRect(x: 11, y: 20, width: 800, height: 600)),
            topology) == .changed)
        #expect(Self.validation(receipt, topology, Self.receipt(bounds: bounds, windowID: 43), topology) == .changed)
        #expect(Self.validation(
            receipt,
            topology,
            Self.receipt(bounds: bounds, ownerProcessIdentifier: 124),
            topology) == .changed)
        #expect(Self.validation(
            receipt,
            topology,
            Self.receipt(bounds: bounds, ownerProcessStartIdentity: 457),
            topology) == .changed)
        #expect(Self.validation(receipt, topology, Self.receipt(bounds: bounds, layer: 1), topology) == .changed)
        #expect(Self.validation(receipt, topology, Self.receipt(bounds: bounds, isOnScreen: false), topology) ==
            .changed)
        #expect(Self.validation(receipt, topology, Self.receipt(bounds: bounds, alpha: 0.5), topology) == .changed)
        #expect(Self.validation(receipt, topology, Self.receipt(bounds: bounds, sharingState: 0), topology) ==
            .changed)
        #expect(Self.validation(receipt, topology, receipt, Self.topology(pixelWidth: 2560)) == .changed)
        #expect(Self.validation(receipt, topology, nil, topology) == .unavailable)
        #expect(Self.validation(receipt, topology, receipt, nil) == .unavailable)

        let expectedScale = ScreenCaptureScaleResolver.plan(
            preference: .native,
            screenBackingScaleFactor: 2,
            fallbackPixelWidth: 3840,
            frameWidth: 1920)
        let changedScale = ScreenCaptureScaleResolver.plan(
            preference: .native,
            screenBackingScaleFactor: 1,
            fallbackPixelWidth: 1920,
            frameWidth: 1920)
        #expect(Self.validation(
            receipt,
            topology,
            receipt,
            topology,
            expectedScale,
            changedScale) == .changed)
        #expect(Self.validation(receipt, topology, receipt, topology, expectedScale, nil) == .unavailable)
    }

    @Test
    func `display topology separates point matching from pixel rotation and mirror fingerprints`() {
        let retina = Self.topology(pixelWidth: 3840, pixelHeight: 2160)

        #expect(retina.containsScreenCaptureKitDisplay(
            displayID: 1,
            bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            width: 1920,
            height: 1080))
        #expect(!retina.containsScreenCaptureKitDisplay(
            displayID: 1,
            bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            width: 2560,
            height: 1080))
        #expect(retina != Self.topology(pixelWidth: 1920, pixelHeight: 1080))
        #expect(retina != Self.topology(pixelWidth: 3840, pixelHeight: 2160, rotation: 90))
        #expect(retina != Self.topology(
            pixelWidth: 3840,
            pixelHeight: 2160,
            mirrorOwnerDisplayID: 2))

        let mixedScale = ScreenCaptureDisplayTopology(displays: [
            .init(
                displayID: 1,
                bounds: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                pixelWidth: 3840,
                pixelHeight: 2160,
                rotation: 0),
            .init(
                displayID: 2,
                bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                pixelWidth: 2560,
                pixelHeight: 1440,
                rotation: 0,
                isMain: true),
        ])
        #expect(mixedScale.containsScreenCaptureKitDisplay(
            displayID: 1,
            bounds: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            width: 1920,
            height: 1080))
        #expect(mixedScale != ScreenCaptureDisplayTopology(displays: Array(mixedScale.displays.reversed())))
    }

    @Test
    func `physical pixel fallback preserves one and two times display scale`() {
        let oneX = ScreenCaptureScaleResolver.plan(
            preference: .native,
            screenBackingScaleFactor: nil,
            fallbackPixelWidth: 1920,
            frameWidth: 1920)
        let twoX = ScreenCaptureScaleResolver.plan(
            preference: .native,
            screenBackingScaleFactor: nil,
            fallbackPixelWidth: 3840,
            frameWidth: 1920)
        let logical = ScreenCaptureScaleResolver.plan(
            preference: .logical1x,
            screenBackingScaleFactor: nil,
            fallbackPixelWidth: 3840,
            frameWidth: 1920)

        #expect(oneX.nativeScale == 1)
        #expect(twoX.nativeScale == 2)
        #expect(twoX.source == .displayPixelRatio)
        #expect(logical.nativeScale == 2)
        #expect(logical.outputScale == 1)
    }

    @Test
    func `receipt construction brackets window and process generation`() {
        let identity = Self.systemWindowIdentity()
        var identities = [identity, identity]
        var generations: [UInt64] = [456, 456]

        let receipt = ScreenCaptureWindowPlanReceipt.current(
            windowID: 42,
            windowIdentityProvider: { _ in identities.removeFirst() },
            processStartIdentityProvider: { _ in generations.removeFirst() })

        #expect(receipt == Self.receipt(bounds: identity.bounds, sharingState: 2))
        #expect(identities.isEmpty)
        #expect(generations.isEmpty)
    }

    @Test
    func `receipt construction rejects generation owner and window races but allows title refresh`() {
        let identity = Self.systemWindowIdentity()
        let variants = [
            Self.systemWindowIdentity(bounds: CGRect(x: 11, y: 20, width: 800, height: 600)),
            Self.systemWindowIdentity(ownerProcessIdentifier: 124),
        ]
        for variant in variants {
            var identities = [identity, variant]
            var generations: [UInt64] = [456, 456]
            #expect(ScreenCaptureWindowPlanReceipt.current(
                windowID: 42,
                windowIdentityProvider: { _ in identities.removeFirst() },
                processStartIdentityProvider: { _ in generations.removeFirst() }) == nil)
        }

        var renamedIdentities = [identity, Self.systemWindowIdentity(title: "Renamed")]
        var stableGenerations: [UInt64] = [456, 456]
        #expect(ScreenCaptureWindowPlanReceipt.current(
            windowID: 42,
            windowIdentityProvider: { _ in renamedIdentities.removeFirst() },
            processStartIdentityProvider: { _ in stableGenerations.removeFirst() }) != nil)

        var stableIdentities = [identity, identity]
        var changedGenerations: [UInt64] = [456, 457]
        #expect(ScreenCaptureWindowPlanReceipt.current(
            windowID: 42,
            windowIdentityProvider: { _ in stableIdentities.removeFirst() },
            processStartIdentityProvider: { _ in changedGenerations.removeFirst() }) == nil)
    }

    @Test
    func `valid cached plan captures without construction`() async throws {
        let cached = Plan()
        var buildCalls = 0
        var evictions = 0

        let result = try await ScreenCaptureWindowPlanExecutor.execute(
            cachedPlan: { cached },
            buildPlan: {
                buildCalls += 1
                return Plan()
            },
            capture: { _, _ in "pixels" },
            validation: { _ in .matched },
            evict: { _ in evictions += 1 })

        #expect(result.plan === cached)
        #expect(result.output == "pixels")
        #expect(result.cacheStatus == .hit)
        #expect(buildCalls == 0)
        #expect(evictions == 0)
    }

    @Test
    func `cold post-capture drift suppresses stale output and rebuilds once`() async throws {
        let first = Plan()
        let second = Plan()
        var plans = [first, second]
        var validationCalls: [ObjectIdentifier: Int] = [:]
        var captured: [ObjectIdentifier] = []
        var evicted: [ObjectIdentifier] = []

        let result = try await ScreenCaptureWindowPlanExecutor.execute(
            cachedPlan: { nil },
            buildPlan: { plans.removeFirst() },
            capture: { plan, _ in
                captured.append(ObjectIdentifier(plan))
                return plan === first ? "stale" : "fresh"
            },
            validation: { plan in
                let identifier = ObjectIdentifier(plan)
                validationCalls[identifier, default: 0] += 1
                return plan === first && validationCalls[identifier] == 2 ? .changed : .matched
            },
            evict: { evicted.append(ObjectIdentifier($0)) })

        #expect(result.output == "fresh")
        #expect(result.plan === second)
        #expect(result.cacheStatus == .miss)
        #expect(plans.isEmpty)
        #expect(captured == [ObjectIdentifier(first), ObjectIdentifier(second)])
        #expect(evicted == [ObjectIdentifier(first)])
    }

    @Test
    func `invalid cached plan consumes the only recovery budget`() async {
        let stale = Plan()
        let rebuilt = Plan()
        var buildCalls = 0
        var rebuiltValidations = 0
        var evicted: [ObjectIdentifier] = []

        await #expect(throws: PeekabooError.self) {
            _ = try await ScreenCaptureWindowPlanExecutor.execute(
                cachedPlan: { stale },
                buildPlan: {
                    buildCalls += 1
                    return rebuilt
                },
                capture: { _, _ in "replacement pixels" },
                validation: { plan in
                    guard plan === rebuilt else { return .changed }
                    rebuiltValidations += 1
                    return rebuiltValidations == 1 ? .matched : .changed
                },
                evict: { evicted.append(ObjectIdentifier($0)) })
        }
        #expect(buildCalls == 1)
        #expect(evicted == [ObjectIdentifier(stale), ObjectIdentifier(rebuilt)])
    }

    @Test
    func `unavailable validation bypasses cache without capture or rebuild`() async {
        let cached = Plan()
        var buildCalls = 0
        var captureCalls = 0
        var evictions = 0

        await #expect(throws: ScreenCaptureWindowPlanCacheUnavailableError.self) {
            _ = try await ScreenCaptureWindowPlanExecutor.execute(
                cachedPlan: { cached },
                buildPlan: {
                    buildCalls += 1
                    return Plan()
                },
                capture: { _, _ in
                    captureCalls += 1
                    return "pixels"
                },
                validation: { _ in .unavailable },
                evict: { _ in evictions += 1 })
        }
        #expect(buildCalls == 0)
        #expect(captureCalls == 0)
        #expect(evictions == 1)
    }

    @Test
    func `post-capture unavailable evidence discards pixels and routes fresh`() async {
        let cached = Plan()
        var validationCalls = 0
        var evictions = 0

        await #expect(throws: ScreenCaptureWindowPlanCacheUnavailableError.self) {
            _ = try await ScreenCaptureWindowPlanExecutor.execute(
                cachedPlan: { cached },
                buildPlan: { Plan() },
                capture: { _, _ in "unproven pixels" },
                validation: { _ in
                    validationCalls += 1
                    return validationCalls == 1 ? .matched : .unavailable
                },
                evict: { _ in evictions += 1 })
        }
        #expect(validationCalls == 2)
        #expect(evictions == 1)
    }

    @Test
    func `retry-safe stale capture rebuilds once and returns only fresh output`() async throws {
        let cached = Plan()
        let rebuilt = Plan()
        var captureCalls = 0
        var buildCalls = 0

        let result = try await ScreenCaptureWindowPlanExecutor.execute(
            cachedPlan: { cached },
            buildPlan: {
                buildCalls += 1
                return rebuilt
            },
            capture: { _, _ in
                captureCalls += 1
                if captureCalls == 1 {
                    throw RetrySafeStaleWindowPlanError(terminalError: .captureFailed("stale geometry"))
                }
                return "fresh pixels"
            },
            validation: { _ in .matched },
            evict: { _ in })

        #expect(result.plan === rebuilt)
        #expect(result.output == "fresh pixels")
        #expect(result.cacheStatus == .rebuilt)
        #expect(buildCalls == 1)
        #expect(captureCalls == 2)
    }

    @Test
    func `second retry-safe stale failure returns its terminal error`() async {
        let terminal = PeekabooError.captureFailed("stale twice")
        var buildCalls = 0
        var captureCalls = 0

        let thrown = await #expect(throws: PeekabooError.self) {
            _ = try await ScreenCaptureWindowPlanExecutor.execute(
                cachedPlan: { Plan() },
                buildPlan: {
                    buildCalls += 1
                    return Plan()
                },
                capture: { _, _ -> String in
                    captureCalls += 1
                    throw RetrySafeStaleWindowPlanError(terminalError: terminal)
                },
                validation: { _ in .matched },
                evict: { _ in })
        }
        #expect(thrown?.localizedDescription == terminal.localizedDescription)
        #expect(buildCalls == 1)
        #expect(captureCalls == 2)
    }

    @Test
    func `cold construction timeout is preserved without retry`() async {
        var buildCalls = 0
        let thrown = await #expect(throws: PeekabooError.self) {
            _ = try await ScreenCaptureWindowPlanExecutor.execute(
                cachedPlan: { nil },
                buildPlan: { () throws -> Plan in
                    buildCalls += 1
                    throw PeekabooError.timeout("plan construction")
                },
                capture: { _, _ in "pixels" },
                validation: { _ in .matched },
                evict: { _ in })
        }
        #expect(thrown?.code == .timeout)
        #expect(buildCalls == 1)
    }

    @Test
    func `cancellation after capture discards output without rebuild`() async {
        let task = Task { @MainActor in
            try await ScreenCaptureWindowPlanExecutor.execute(
                cachedPlan: { Plan() },
                buildPlan: { Issue.record("Cancellation must not rebuild"); return Plan() },
                capture: { _, _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return "discarded pixels"
                },
                validation: { _ in .matched },
                evict: { _ in })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test(arguments: [
        PeekabooError.timeout("fixture timeout"),
        PeekabooError.permissionDeniedScreenRecording,
        PeekabooError.captureFailed("ScreenCaptureKit is quarantined"),
    ])
    func `typed capture failures are preserved without rebuild`(expected: PeekabooError) async {
        var buildCalls = 0
        let thrown = await #expect(throws: PeekabooError.self) {
            _ = try await ScreenCaptureWindowPlanExecutor.execute(
                cachedPlan: { Plan() },
                buildPlan: {
                    buildCalls += 1
                    return Plan()
                },
                capture: { _, _ -> String in throw expected },
                validation: { _ in .matched },
                evict: { _ in })
        }
        #expect(thrown?.code == expected.code)
        #expect(thrown?.localizedDescription == expected.localizedDescription)
        #expect(buildCalls == 0)
    }

    @Test
    func `raw ScreenCaptureKit TCC denial is preserved without internal retry`() async {
        let expected = NSError(
            domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
            code: -3801,
            userInfo: [NSLocalizedDescriptionKey: "The user declined TCCs"])
        var captureCalls = 0

        do {
            _ = try await ScreenCaptureWindowPlanExecutor.execute(
                cachedPlan: { Plan() },
                buildPlan: { Plan() },
                capture: { _, _ -> String in
                    captureCalls += 1
                    throw expected
                },
                validation: { _ in .matched },
                evict: { _ in })
            Issue.record("TCC denial should throw")
        } catch let error as NSError {
            #expect(error.domain == expected.domain)
            #expect(error.code == expected.code)
        }
        #expect(captureCalls == 1)
    }

    private static func receipt(
        bounds: CGRect,
        windowID: CGWindowID = 42,
        ownerProcessIdentifier: pid_t = 123,
        ownerProcessStartIdentity: UInt64 = 456,
        layer: Int = 0,
        alpha: CGFloat = 1,
        isOnScreen: Bool = true,
        sharingState: Int? = 1) -> ScreenCaptureWindowPlanReceipt
    {
        ScreenCaptureWindowPlanReceipt(
            windowID: windowID,
            ownerProcessIdentifier: ownerProcessIdentifier,
            ownerProcessStartIdentity: ownerProcessStartIdentity,
            bounds: bounds,
            layer: layer,
            alpha: alpha,
            isOnScreen: isOnScreen,
            sharingState: sharingState)
    }

    private static func topology(
        pixelWidth: Int,
        pixelHeight: Int = 1080,
        rotation: Double = 0,
        mirrorOwnerDisplayID: CGDirectDisplayID? = nil) -> ScreenCaptureDisplayTopology
    {
        ScreenCaptureDisplayTopology(displays: [
            .init(
                displayID: 1,
                bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                rotation: rotation,
                mirrorOwnerDisplayID: mirrorOwnerDisplayID),
        ])
    }

    private static func systemWindowIdentity(
        bounds: CGRect = CGRect(x: 10, y: 20, width: 800, height: 600),
        ownerProcessIdentifier: pid_t = 123,
        title: String = "Fixture") -> SystemWindowIdentity
    {
        SystemWindowIdentity(
            windowID: 42,
            ownerProcessIdentifier: ownerProcessIdentifier,
            title: title,
            bounds: bounds,
            layer: 0,
            alpha: 1,
            isOnScreen: true,
            sharingState: .readWrite,
            applicationName: "Fixture")
    }

    private static func validation(
        _ expectedReceipt: ScreenCaptureWindowPlanReceipt,
        _ expectedTopology: ScreenCaptureDisplayTopology,
        _ currentReceipt: ScreenCaptureWindowPlanReceipt?,
        _ currentTopology: ScreenCaptureDisplayTopology?,
        _ expectedScalePlan: ScreenCaptureScaleResolver.Plan? = nil,
        _ currentScalePlan: ScreenCaptureScaleResolver.Plan? = nil) -> ScreenCaptureWindowPlanValidation.Result
    {
        ScreenCaptureWindowPlanValidation.result(
            expectedReceipt: expectedReceipt,
            expectedTopology: expectedTopology,
            currentReceipt: currentReceipt,
            currentTopology: currentTopology,
            expectedScalePlan: expectedScalePlan,
            currentScalePlan: currentScalePlan)
    }
}

private struct OperatorNoOpFrameSource: CaptureFrameSource {
    func nextFrame() async throws -> (cgImage: CGImage?, metadata: CaptureMetadata)? {
        nil
    }
}
