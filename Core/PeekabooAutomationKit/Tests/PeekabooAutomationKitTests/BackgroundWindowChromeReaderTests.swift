import ApplicationServices
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct BackgroundWindowChromeReaderTests {
    @Test
    func `complete native reads admit the exact blank window hit and aliased fullscreen control`() throws {
        let fixture = Fixture()
        let admitted = try BackgroundWindowChromeReader.read(target: fixture.target(), access: fixture.access())
        #expect(admitted.window == RetainedFocusElement(element: fixture.nodes[0]))
        #expect(admitted.point.x > 392)
        #expect(admitted.point.y == 16)
        _ = try BackgroundWindowChromeReader.read(
            target: fixture.target(), retained: admitted, access: fixture.access())
    }

    @Test(arguments: ["", "Untitled", " "])
    func `absent title geometry requires exactly empty readable title`(title: String) throws {
        let fixture = Fixture()
        var access = fixture.access()
        let read = access.attribute
        access.attribute = { element, name in
            if name == kAXTitleUIElementAttribute {
                return (.noValue, nil)
            }
            if name == kAXTitleAttribute {
                return (.success, title as CFString)
            }
            return read(element, name)
        }
        if title.isEmpty {
            _ = try BackgroundWindowChromeReader.read(target: fixture.target(), access: access)
        } else {
            #expect(throws: DesktopActionFailure.self) {
                try BackgroundWindowChromeReader.read(target: fixture.target(), access: access)
            }
        }
    }

    @Test(arguments: [AXError.noValue, .failure, .success])
    func `missing title geometry cannot use unreadable or wrong type title`(error: AXError) throws {
        let fixture = Fixture()
        var access = fixture.access()
        let read = access.attribute
        access.attribute = { element, name in
            if name == kAXTitleUIElementAttribute {
                return (.noValue, nil)
            }
            if name == kAXTitleAttribute {
                return (error, kCFBooleanFalse)
            }
            return read(element, name)
        }
        #expect(throws: DesktopActionFailure.self) {
            try BackgroundWindowChromeReader.read(target: fixture.target(), access: access)
        }
    }

    @Test(arguments: [0, 1, 2, 3, 4, 5, 6, 7])
    func `incomplete changing excessive or unavailable hierarchy refuses`(failure: Int) throws {
        let fixture = Fixture()
        var access = fixture.access()
        switch failure {
        case 0: access.names = { _ in nil }
        case 1: access.childCount = { _ in nil }
        case 2: access.children = { _, _ in nil }
        case 3: access.children = { _, _ in [] }
        case 4: access.childCount = { _ in 257 }
        case 5: access.setTimeout = { _, _ in .failure }
        case 6:
            let read = access.childCount
            var reads = 0
            access.childCount = { element in reads += 1; return reads == 2 ? 6 : read(element) }
        default:
            let read = access.attribute
            access.attribute = { element, name in
                if name == kAXRoleAttribute, CFEqual(element, fixture.nodes[5]) {
                    return (.success, kAXSheetRole as CFString)
                }
                return read(element, name)
            }
        }
        #expect(throws: DesktopActionFailure.self) {
            try BackgroundWindowChromeReader.read(target: fixture.target(), access: access)
        }
    }

    @Test(arguments: [0, 1, 2, 3, 4])
    func `foreign owners nonroot hits replaced windows and geometry drift refuse`(failure: Int) throws {
        let fixture = Fixture()
        var access = fixture.access()
        switch failure {
        case 0: access.processID = { _ in 99 }
        case 1: access.windowID = { _ in 99 }
        case 2: access.hit = { _, _ in fixture.nodes[4] }
        case 3: access.windowIsCurrent = { _ in false }
        default:
            let read = access.attribute
            access.attribute = { element, name in
                if name == kAXPositionAttribute, CFEqual(element, fixture.nodes[0]) {
                    var moved = CGPoint(x: 1, y: 0)
                    return (.success, AXValueCreate(.cgPoint, &moved))
                }
                return read(element, name)
            }
        }
        #expect(throws: DesktopActionFailure.self) {
            try BackgroundWindowChromeReader.read(target: fixture.target(), access: access)
        }
        let old = BackgroundWindowChromeAdmission(
            window: RetainedFocusElement(element: fixture.nodes[1]), point: CGPoint(x: 484, y: 16))
        #expect(throws: DesktopActionFailure.self) {
            try BackgroundWindowChromeReader.read(target: fixture.target(), retained: old, access: fixture.access())
        }
    }

    @Test
    func `deadline crossed during final window validation refuses a late result`() throws {
        let fixture = Fixture()
        var access = fixture.access()
        var now = ContinuousClock.now
        var validations = 0
        access.windowIsCurrent = { _ in
            validations += 1
            if validations == 2 {
                now = now.advanced(by: .milliseconds(201))
            }
            return true
        }
        #expect(throws: DesktopActionFailure.self) {
            try BackgroundWindowChromeReader.read(target: fixture.target(), access: access, now: { now })
        }
        #expect(validations == 2)
    }

    @Test
    func `cancellation during final window validation refuses`() async throws {
        let refused = try await Task {
            let fixture = Fixture()
            var access = fixture.access()
            var validations = 0
            access.windowIsCurrent = { _ in
                validations += 1
                if validations == 2 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                return true
            }
            do {
                _ = try BackgroundWindowChromeReader.read(target: fixture.target(), access: access)
                return false
            } catch is CancellationError {
                return validations == 2
            }
        }.value
        #expect(refused)
    }

    @Test(arguments: [true, false])
    func `explicit noValue is optional absence`(advertised: Bool) {
        #expect(BackgroundWindowChromeReader.optionalAttributeIsAbsent(advertised: advertised, error: .noValue))
    }

    @Test
    func `unsupported is absence only for an unadvertised optional attribute`() {
        #expect(BackgroundWindowChromeReader.optionalAttributeIsAbsent(advertised: false, error: .attributeUnsupported))
        #expect(!BackgroundWindowChromeReader.optionalAttributeIsAbsent(advertised: true, error: .attributeUnsupported))
    }

    @Test(arguments: [AXError.success, .failure, .cannotComplete, .invalidUIElement, .apiDisabled, .notImplemented])
    func `hard errors and actual values are never absence`(error: AXError) {
        #expect(!BackgroundWindowChromeReader.optionalAttributeIsAbsent(advertised: false, error: error))
        #expect(!BackgroundWindowChromeReader.optionalAttributeIsAbsent(advertised: true, error: error))
    }

    private struct Fixture {
        let nodes = (0..<6).map { AXUIElementCreateApplication(pid_t(9000 + $0)) }
        let frames = [
            CGRect(x: 0, y: 0, width: 580, height: 400),
            CGRect(x: 8, y: 8, width: 16, height: 16),
            CGRect(x: 31, y: 8, width: 16, height: 16),
            CGRect(x: 54, y: 8, width: 16, height: 16),
            CGRect(x: 82, y: 8, width: 306, height: 16),
            CGRect(x: 0, y: 32, width: 580, height: 368),
        ]

        func target() throws -> UIAutomationTarget.ExactWindow {
            try .init(
                identity: WindowMutationIdentity(
                    windowID: 100,
                    ownerProcessIdentifier: 8100,
                    ownerProcessStartIdentity: 77),
                bounds: self.frames[0])
        }

        func access() -> BackgroundWindowChromeReader.Access {
            .init(
                attribute: { element, name in
                    if name == kAXWindowsAttribute {
                        return (.success, [self.nodes[0]] as CFArray)
                    }
                    guard let index = self.nodes.firstIndex(where: { CFEqual($0, element) }) else {
                        return (.invalidUIElement, nil)
                    }
                    switch name {
                    case kAXCloseButtonAttribute: return (.success, self.nodes[1])
                    case kAXMinimizeButtonAttribute: return (.success, self.nodes[2])
                    case kAXZoomButtonAttribute, "AXFullScreenButton": return (.success, self.nodes[3])
                    case kAXTitleUIElementAttribute: return (.success, self.nodes[4])
                    case "AXProxy", "AXToolbarButton": return (.noValue, nil)
                    case "AXSheets": return (.attributeUnsupported, nil)
                    case kAXRoleAttribute:
                        let role = index == 0 ? kAXWindowRole : (index < 4 ? kAXButtonRole : kAXStaticTextRole)
                        return (.success, role as CFString)
                    case kAXSubroleAttribute: return (.success, kAXStandardWindowSubrole as CFString)
                    case kAXTitleAttribute: return (.success, "Synthetic title" as CFString)
                    case kAXMinimizedAttribute, "AXFullScreen", kAXModalAttribute: return (.success, kCFBooleanFalse)
                    case kAXPositionAttribute:
                        var point = self.frames[index].origin
                        return (.success, AXValueCreate(.cgPoint, &point))
                    case kAXSizeAttribute:
                        var size = self.frames[index].size
                        return (.success, AXValueCreate(.cgSize, &size))
                    default: return (.attributeUnsupported, nil)
                    }
                },
                names: { _ in [kAXTitleUIElementAttribute, "AXProxy", "AXFullScreenButton", "AXToolbarButton"] },
                childCount: { CFEqual($0, self.nodes[0]) ? 5 : 0 },
                children: { _, _ in Array(self.nodes.dropFirst()) },
                windowID: { _ in 100 }, processID: { _ in 8100 },
                hit: { _, _ in self.nodes[0] }, setTimeout: { _, _ in .success },
                windowIsCurrent: { _ in true })
        }
    }
}
