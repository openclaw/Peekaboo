import ApplicationServices
import Foundation
import Testing
@testable @_spi(Testing) import PeekabooAutomationKit

struct DetachedExactWindowFocusMetadataTests {
    @Test
    func `metadata uses one seven-attribute batch without reading user values`() throws {
        var batches = 0
        var singles = 0
        let result = try #require(DetachedExactWindowFocusReader.readMetadata(
            copyAttributes: { names in
                batches += 1
                #expect(names == Self.names)
                #expect(!names.contains(kAXValueAttribute))
                #expect(!names.contains(kAXFocusedAttribute))
                #expect(!names.contains(kAXSelectedTextRangeAttribute))
                return (.success, names.map { $0 as Any })
            },
            copyAttribute: { _ in singles += 1; return nil }))
        #expect(batches == 1 && singles == 0)
        for name in Self.names {
            #expect(result[name]?.error == .success)
            #expect(result[name]?.value as? String == name)
        }
    }

    @Test(arguments: [
        AXError.noValue,
        .attributeUnsupported,
        .parameterizedAttributeUnsupported,
        .notImplemented,
        .cannotComplete,
        .failure,
        .invalidUIElement,
    ])
    func `batch embedded subrole errors preserve the existing secure-read admission`(error: AXError) throws {
        var nativeError = error
        let value = try #require(AXValueCreate(.axError, &nativeError))
        let result = try #require(DetachedExactWindowFocusReader.readMetadata(
            copyAttributes: { names in (.success, names.map { $0 == kAXSubroleAttribute ? value : $0 as Any }) },
            copyAttribute: { _ in Issue.record("Unexpected single read"); return nil }))
        let read = try #require(result[kAXSubroleAttribute])
        #expect(read.error == error)
        #expect(read.value == nil)
        let subrole = DetachedExactWindowFocusReader.subroleObservation(read)
        #expect(subrole.value == nil)
        #expect(subrole.isReadable == (error == .noValue || error == .attributeUnsupported))
        #expect(result[kAXRoleAttribute]?.value as? String == kAXRoleAttribute)
    }

    @Test
    func `secure and malformed subrole values are not normalized into safe absence`() throws {
        for value: Any in ["AXSecureTextField", NSNumber(value: 1), NSNull()] {
            let result = try #require(DetachedExactWindowFocusReader.readMetadata(
                copyAttributes: { names in (.success, names.map { $0 == kAXSubroleAttribute ? value : $0 as Any }) },
                copyAttribute: { _ in Issue.record("Unexpected single read"); return nil }))
            let subrole = DetachedExactWindowFocusReader.subroleObservation(result[kAXSubroleAttribute])
            if let string = value as? String {
                #expect(subrole.isReadable)
                #expect(subrole.value == string)
                #expect(!DetachedExactWindowFocusReader.allowsValueRead(role: "AXTextField", subrole: subrole.value))
            } else {
                #expect(!subrole.isReadable)
            }
        }
    }

    @Test(arguments: [
        AXError.attributeUnsupported,
        .parameterizedAttributeUnsupported,
        .notImplemented,
        .failure,
        .success,
    ])
    func `unsupported failed or malformed batches use existing single-attribute reads`(error: AXError) throws {
        var singles: [String] = []
        let result = try #require(DetachedExactWindowFocusReader.readMetadata(
            copyAttributes: { _ in (error, []) },
            copyAttribute: { name in
                singles.append(name)
                return .init(error: name == kAXSubroleAttribute ? .notImplemented : .success, value: name)
            }))
        #expect(singles == Self.names)
        #expect(result[kAXSubroleAttribute]?.error == .notImplemented)
        #expect(!DetachedExactWindowFocusReader.subroleObservation(result[kAXSubroleAttribute]).isReadable)
    }

    @Test(arguments: [AXError.cannotComplete, .invalidUIElement, .apiDisabled, .noValue])
    func `hard batch failures do not trigger more native reads`(error: AXError) {
        let result = DetachedExactWindowFocusReader.readMetadata(
            copyAttributes: { _ in (error, nil) },
            copyAttribute: { _ in Issue.record("Unexpected fallback after failed batch"); return nil })
        #expect(result == nil)
    }

    @Test(arguments: ["expired", "timeoutRejected", "late"], [AXError.attributeUnsupported, .failure])
    func `batch deadline refusal never starts fallback`(stage: String, error: AXError) {
        let start = ContinuousClock.now
        let deadline = start.advanced(by: .milliseconds(50))
        var now = stage == "expired" ? deadline : start
        var batches = 0
        let result = DetachedExactWindowFocusReader.readMetadata(
            copyAttributes: { _ in
                DetachedExactWindowFocusReader.readBeforeDeadline(
                    deadline,
                    now: { now },
                    applyTimeout: { _ in stage != "timeoutRejected" },
                    read: {
                        batches += 1
                        now = deadline
                        return (error, [Any]?.none)
                    })
            },
            copyAttribute: { _ in Issue.record("Expired batch started fallback"); return nil })
        #expect(result == nil)
        #expect(batches == (stage == "late" ? 1 : 0))
    }

    @Test
    func `expired single-read fallback stops without reading remaining attributes`() {
        var singles: [String] = []
        let result = DetachedExactWindowFocusReader.readMetadata(
            copyAttributes: { _ in (.notImplemented, nil) },
            copyAttribute: { name in
                singles.append(name)
                return singles.count == 3 ? nil : .init(error: .success, value: name)
            })
        #expect(result == nil)
        #expect(singles == Array(Self.names.prefix(3)))
    }

    @Test(arguments: [AXError.success, .failure])
    func `scalar observation retains both metadata snapshots around its admitted value read`(
        batchError: AXError) throws
    {
        var events: [String] = []
        let native = AXUIElementCreateApplication(4242)
        let values = try Self.nativeMetadata(window: native)
        let result = DetachedAXMutationReader.readSynchronously(
            request: (
                target: AXMutationObservationTarget(processIdentifier: 4242, processStartIdentity: 99),
                attribute: .value, deadline: .now.advanced(by: .seconds(1))),
            processStartIdentity: { 99 },
            readSnapshot: { _ in
                guard let metadata = DetachedExactWindowFocusReader.readMetadata(
                    copyAttributes: { names in
                        events.append("batch")
                        #expect(names == Self.names)
                        return (batchError, values)
                    },
                    copyAttribute: { name in
                        events.append(name)
                        guard let index = Self.names.firstIndex(of: name) else { return nil }
                        let value = values[index]
                        let error = AXAttributeReadCompletenessPolicy.embeddedError(in: value) ?? .success
                        return .init(error: error, value: error == .success ? value : nil)
                    })
                else { return nil }
                return DetachedExactWindowFocusReader.snapshot(
                    element: native,
                    processIdentifier: 4242,
                    metadata: metadata,
                    resolveWindowID: {
                        #expect(CFEqual($0, native))
                        events.append("window")
                        return 42
                    })
            },
            readAttribute: { name, _ in
                #expect(name == kAXValueAttribute)
                events.append("value")
                return NSNumber(value: 62)
            })
        #expect(result?.value == .int(62))
        #expect(result?.identity.processIdentifier == 4242)
        #expect(result?.identity.windowID == 42)
        #expect(result?.identity.frame == CGRect(x: 1, y: 2, width: 100, height: 20))
        #expect(result?.identity.role == "AXSlider")
        #expect(result?.identity.title == "Volume")
        #expect(result?.identity.identifier == "slider")
        let identityReads = ["batch"] + (batchError == .failure ? Self.names : []) + ["window"]
        #expect(events == identityReads + ["value"] + identityReads)
    }

    @Test(arguments: [kAXPositionAttribute, kAXSizeAttribute, kAXWindowAttribute, kAXRoleAttribute], [false, true])
    func `invalid native metadata cannot admit a value observation`(attribute: String, embeddedError: Bool) throws {
        let native = AXUIElementCreateApplication(4242)
        var values = try Self.nativeMetadata(window: native)
        var error = AXError.cannotComplete
        let invalid: Any = if embeddedError {
            try #require(AXValueCreate(.axError, &error))
        } else {
            NSNumber(value: 1)
        }
        try values[#require(Self.names.firstIndex(of: attribute))] = invalid
        let metadata = try #require(DetachedExactWindowFocusReader.readMetadata(
            copyAttributes: { _ in (.success, values) },
            copyAttribute: { _ in Issue.record("Unexpected fallback"); return nil }))
        var windowReads = 0
        let snapshot = DetachedExactWindowFocusReader.snapshot(
            element: native,
            processIdentifier: 4242,
            metadata: metadata,
            resolveWindowID: { _ in windowReads += 1; return 42 })
        #expect(windowReads == (attribute == kAXWindowAttribute ? 0 : 1))
        let result = DetachedAXMutationReader.readSynchronously(
            request: (
                target: AXMutationObservationTarget(processIdentifier: 4242, processStartIdentity: 99),
                attribute: .value, deadline: .now.advanced(by: .seconds(1))),
            processStartIdentity: { 99 },
            readSnapshot: { _ in snapshot },
            readAttribute: { _, _ in Issue.record("Invalid metadata admitted value read"); return nil })
        #expect(result == nil)
    }

    @Test(arguments: [AXError.noValue, .attributeUnsupported, .notImplemented, .cannotComplete])
    func `decoded snapshot preserves actual subrole readability`(error: AXError) throws {
        let native = AXUIElementCreateApplication(4242)
        var values = try Self.nativeMetadata(window: native)
        var error = error
        values[4] = try #require(AXValueCreate(.axError, &error))
        let metadata = try #require(DetachedExactWindowFocusReader.readMetadata(
            copyAttributes: { _ in (.success, values) },
            copyAttribute: { _ in Issue.record("Unexpected fallback"); return nil }))
        let snapshot = DetachedExactWindowFocusReader.snapshot(
            element: native, processIdentifier: 4242, metadata: metadata, resolveWindowID: { _ in 42 })
        #expect(snapshot.subrole == nil)
        #expect(snapshot.subroleIsReadable == (error == .noValue || error == .attributeUnsupported))
        #expect(DetachedExactWindowFocusReader.allowsValueRead(snapshot) == snapshot.subroleIsReadable)
        #expect(snapshot.nativeElement == RetainedFocusElement(element: native))
    }

    private static func nativeMetadata(window: AXUIElement) throws -> [Any] {
        var point = CGPoint(x: 1, y: 2)
        var size = CGSize(width: 100, height: 20)
        var absent = AXError.attributeUnsupported
        return try [
            #require(AXValueCreate(.cgPoint, &point)),
            #require(AXValueCreate(.cgSize, &size)),
            window,
            "AXSlider",
            #require(AXValueCreate(.axError, &absent)),
            "Volume",
            "slider",
        ]
    }

    private static let names = [
        kAXPositionAttribute,
        kAXSizeAttribute,
        kAXWindowAttribute,
        kAXRoleAttribute,
        kAXSubroleAttribute,
        kAXTitleAttribute,
        kAXIdentifierAttribute,
    ]
}
