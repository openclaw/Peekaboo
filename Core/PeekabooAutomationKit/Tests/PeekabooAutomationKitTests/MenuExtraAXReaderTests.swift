import ApplicationServices
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct MenuExtraAXReaderTests {
    @Test(arguments: [AXError.attributeUnsupported, .noValue])
    func `only explicit absence produces an empty optional attribute`(_ error: AXError) throws {
        let value: AXUIElement? = try MenuExtraAXReader.attributeValue(nil, error: error)
        #expect(value == nil)
    }

    @Test(arguments: [
        AXError.failure,
        .cannotComplete,
        .apiDisabled,
        .invalidUIElement,
        .notImplemented,
        .parameterizedAttributeUnsupported,
    ])
    func `unreadable menu attributes are never absence`(_ error: AXError) {
        #expect(throws: PeekabooError.self) {
            let _: AXUIElement? = try MenuExtraAXReader.attributeValue(nil, error: error)
        }
    }

    @Test
    func `success requires typed AX references and complete child arrays`() {
        #expect(throws: PeekabooError.self) {
            let _: AXUIElement? = try MenuExtraAXReader.attributeValue("wrong" as CFString, error: .success)
        }
        #expect(throws: PeekabooError.self) {
            let _: [AXUIElement]? = try MenuExtraAXReader.attributeValue(NSArray(array: [NSNull()]), error: .success)
        }
        #expect(throws: PeekabooError.self) {
            let _: String? = try MenuExtraAXReader.attributeValue(nil, error: .success)
        }
    }

    @Test
    func `typed application inventory retains the actual owner and native frame`() throws {
        let fixture = Fixture()
        let snapshots = try fixture.read()
        let snapshot = try #require(snapshots.first)
        #expect(snapshots.count == 1)
        #expect(snapshot.processIdentity == fixture.owner)
        #expect(snapshot.title == "Fixture")
        #expect(snapshot.frame == CGRect(x: 100, y: 5, width: 20, height: 20))
        #expect(snapshot.actions == ["AXPress"])
        #expect(CFEqual(snapshot.identity.element, fixture.leaf))
    }

    @Test(arguments: ["AXExtrasMenuBar", "AXChildren", "AXTitle"])
    func `failed inventory reads cannot publish an apparently unique item`(_ attribute: String) throws {
        let fixture = Fixture()
        #expect(throws: PeekabooError.self) { try fixture.read(failed: attribute) }
    }

    @Test
    func `foreign owner and generation replacement fail closed`() throws {
        let fixture = Fixture()
        #expect(throws: PeekabooError.self) { try fixture.read(pid: 73) }
        var reads = 0
        #expect(throws: PeekabooError.self) {
            try MenuExtraAXReader.readSynchronously(
                owner: fixture.owner,
                deadline: .now.advanced(by: .seconds(1)),
                copyAttribute: fixture.attribute,
                copyActions: { _ in (["AXPress"] as CFArray, .success) },
                processIdentifier: { _ in fixture.owner.processIdentifier },
                processGeneration: { _ in
                    reads += 1
                    return reads < 3 ? fixture.owner.processStartIdentity : 100
                },
                setMessagingTimeout: { _, _ in .success })
        }
    }

    @Test
    func `expired discovery performs no native read`() throws {
        let fixture = Fixture()
        #expect(throws: PeekabooError.self) {
            try MenuExtraAXReader.readSynchronously(
                owner: fixture.owner,
                deadline: .now.advanced(by: .seconds(-1)),
                copyAttribute: { _, _ in
                    Issue.record("Expired inventory started native work"); return (nil, .failure)
                },
                processGeneration: { _ in fixture.owner.processStartIdentity },
                setMessagingTimeout: { _, _ in
                    Issue.record("Expired inventory changed messaging timeout"); return .failure
                })
        }
    }

    @Test(arguments: [1.0, 0.025])
    func `read timeout respects both per-message cap and remaining budget then restores`(seconds: Double) throws {
        let element = AXUIElementCreateApplication(954_010)
        let startedAt = ContinuousClock.now
        var timeouts: [Float] = []
        let result = try MenuExtraAXReader.withReadTimeout(
            on: element,
            deadline: startedAt.advanced(by: .seconds(seconds)),
            setMessagingTimeout: { _, timeout in timeouts.append(timeout); return .success },
            now: { startedAt },
            read: {
                #expect(timeouts.count == 1)
                #expect(timeouts[0] > 0)
                #expect(Double(timeouts[0]) <= min(0.1, seconds))
                return 7
            })
        #expect(result == 7)
        #expect(timeouts.count == 2)
        #expect(timeouts.last == 0)
    }

    @Test
    func `failed timeout installation performs no read and still clears the private override`() {
        let element = AXUIElementCreateApplication(954_011)
        var timeouts: [Float] = []
        #expect(throws: PeekabooError.self) {
            try MenuExtraAXReader.withReadTimeout(
                on: element,
                deadline: .now.advanced(by: .seconds(1)),
                setMessagingTimeout: { _, timeout in
                    timeouts.append(timeout)
                    return timeout == 0 ? .success : .failure
                },
                read: {
                    Issue.record("Failed timeout installation reached the native read")
                })
        }
        #expect(timeouts.count == 2)
        #expect(timeouts.last == 0)
    }

    @Test
    func `throwing read restores timeout and failed restoration cannot publish a result`() {
        let element = AXUIElementCreateApplication(954_012)
        var timeouts: [Float] = []
        #expect(throws: ReadFailure.self) {
            let _: Int = try MenuExtraAXReader.withReadTimeout(
                on: element,
                deadline: .now.advanced(by: .seconds(1)),
                setMessagingTimeout: { _, timeout in timeouts.append(timeout); return .success },
                read: { throw ReadFailure.injected })
        }
        #expect(timeouts.count == 2)
        #expect(timeouts.last == 0)
        var published = false
        #expect(throws: PeekabooError.self) {
            _ = try MenuExtraAXReader.withReadTimeout(
                on: element,
                deadline: .now.advanced(by: .seconds(1)),
                setMessagingTimeout: { _, timeout in timeout == 0 ? .failure : .success },
                read: { 7 })
            published = true
        }
        #expect(!published)
    }

    @Test(arguments: [false, true])
    func `expired and late native reads never publish past the shared deadline`(late: Bool) {
        let element = AXUIElementCreateApplication(954_013)
        let startedAt = ContinuousClock.now
        let deadline = startedAt.advanced(by: .milliseconds(25))
        var now = late ? startedAt : deadline
        var timeouts: [Float] = []
        var reads = 0
        #expect(throws: PeekabooError.self) {
            try MenuExtraAXReader.withReadTimeout(
                on: element,
                deadline: deadline,
                setMessagingTimeout: { _, timeout in timeouts.append(timeout); return .success },
                now: { now },
                read: {
                    reads += 1
                    now = deadline
                })
        }
        #expect(reads == (late ? 1 : 0))
        #expect(timeouts.count == (late ? 2 : 0))
        if late {
            #expect(timeouts.last == 0)
        }
    }

    @Test
    func `attribute and action reads restore timeout before snapshot publication`() throws {
        let fixture = Fixture()
        var overrides: [MenuExtraAXIdentity: Float] = [:]
        var actionReads = 0
        let snapshots = try MenuExtraAXReader.readSynchronously(
            owner: fixture.owner,
            deadline: .now.advanced(by: .seconds(1)),
            copyAttribute: { element, name in
                #expect((overrides[.init(element: element)] ?? 0) > 0)
                return fixture.attribute(element, name)
            },
            copyActions: { element in
                #expect((overrides[.init(element: element)] ?? 0) > 0)
                actionReads += 1
                return (["AXPress"] as CFArray, .success)
            },
            processIdentifier: { _ in fixture.owner.processIdentifier },
            processGeneration: { _ in fixture.owner.processStartIdentity },
            setMessagingTimeout: { element, timeout in
                overrides[.init(element: element)] = timeout
                return .success
            })
        #expect(snapshots.count == 1)
        #expect(actionReads == 1)
        #expect(overrides.count == 3)
        #expect(overrides.values.allSatisfy { $0 == 0 })
        #expect(overrides[snapshots[0].identity] == 0)
    }

    @Test
    func `system-wide root never changes global timeout while returned bar reads remain scoped`() throws {
        let fixture = Fixture()
        let root = AXUIElementCreateSystemWide()
        var timeouts: [Float] = []
        let result = try MenuExtraAXReader.readSynchronously(
            owner: fixture.owner,
            systemWide: true,
            deadline: .now.advanced(by: .seconds(1)),
            copyAttribute: { element, name in
                if name == kAXMenuBarAttribute {
                    #expect(CFEqual(element, root))
                    #expect(timeouts.isEmpty)
                    return (fixture.bar, .success)
                }
                #expect(name == kAXChildrenAttribute)
                #expect(timeouts.count == 1 && timeouts[0] > 0)
                return (NSArray(), .success)
            },
            processGeneration: { _ in fixture.owner.processStartIdentity },
            setMessagingTimeout: { element, timeout in
                #expect(!CFEqual(element, root))
                timeouts.append(timeout)
                return .success
            })
        #expect(result.isEmpty)
        #expect(timeouts.count == 2 && timeouts.last == 0)
    }

    private enum ReadFailure: Error { case injected }

    private struct Fixture {
        let owner = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 99)
        let bar = AXUIElementCreateApplication(954_001)
        let leaf = AXUIElementCreateApplication(954_002)

        func read(failed: String? = nil, pid: pid_t = 42) throws -> [MenuExtraAXSnapshot] {
            try MenuExtraAXReader.readSynchronously(
                owner: self.owner,
                deadline: .now.advanced(by: .seconds(1)),
                copyAttribute: { element, name in
                    name == failed ? (nil, .cannotComplete) : self.attribute(element, name)
                },
                copyActions: { _ in (["AXPress"] as CFArray, .success) },
                processIdentifier: { _ in pid },
                processGeneration: { _ in self.owner.processStartIdentity },
                setMessagingTimeout: { _, _ in .success })
        }

        func attribute(_ element: AXUIElement, _ name: String) -> (CFTypeRef?, AXError) {
            switch name {
            case "AXExtrasMenuBar": return (self.bar, .success)
            case "AXChildren": return (NSArray(array: [self.leaf]), .success)
            case "AXRole": return ("AXMenuBarItem" as CFString, .success)
            case "AXTitle": return ("Fixture" as CFString, .success)
            case "AXIdentifier": return ("fixture.status" as CFString, .success)
            case "AXPosition":
                var point = CGPoint(x: 100, y: 5)
                return (AXValueCreate(.cgPoint, &point), .success)
            case "AXSize":
                var size = CGSize(width: 20, height: 20)
                return (AXValueCreate(.cgSize, &size), .success)
            default: return (nil, .noValue)
            }
        }
    }
}
