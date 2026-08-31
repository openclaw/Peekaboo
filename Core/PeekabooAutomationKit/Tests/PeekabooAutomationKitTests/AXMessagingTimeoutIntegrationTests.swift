import ApplicationServices
import AXorcist
import Darwin
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct AXMessagingTimeoutIntegrationTests {
    @Test
    func `setup refusal skips the read and releases ownership`() {
        let invalidApplication = Element(AXUIElementCreateApplication(-1))
        var readCount = 0

        for timeout in [Float(0.25), 0.5] {
            #expect(throws: AXMessagingTimeoutError.systemFailure(code: AXError.invalidUIElement.rawValue)) {
                try invalidApplication.withMessagingTimeout(timeout) { _ in
                    readCount += 1
                }
            }
        }

        #expect(readCount == 0)
    }

    @Test(arguments: [Float.zero, -0.1, -.infinity, .infinity, .nan])
    func `invalid deadlines skip the read and release ownership`(timeout: Float) throws {
        let application = Element(AXUIElementCreateApplication(getpid()))
        var readCount = 0

        #expect(throws: AXMessagingTimeoutError.invalidTimeout) {
            try application.withMessagingTimeout(timeout) { _ in
                readCount += 1
            }
        }

        #expect(readCount == 0)
        let value = try application.withMessagingTimeout(0.25) { _ in 42 }
        #expect(value == 42)
    }

    @Test
    func `optional caller returns nil without dispatching a refused read`() {
        let invalidApplication = Element(AXUIElementCreateApplication(-1))
        var readCount = 0

        let value = try? invalidApplication.withMessagingTimeout(0.25) { _ in
            readCount += 1
            return 42
        }

        #expect(value == nil)
        #expect(readCount == 0)
    }

    @Test
    func `scope releases ownership after an operation throws or synchronously cancels`() throws {
        let application = Element(AXUIElementCreateApplication(getpid()))

        #expect(throws: MessagingTimeoutProbeError.self) {
            try application.withMessagingTimeout(0.25) { _ in
                throw MessagingTimeoutProbeError.failed
            }
        }
        #expect(throws: CancellationError.self) {
            try application.withMessagingTimeout(0.25) { _ in
                throw CancellationError()
            }
        }

        let value = try application.withMessagingTimeout(0.25) { _ in 42 }
        #expect(value == 42)
    }

    @Test(arguments: [Float(0.25), 0, .nan])
    func `wrappers of the same native reference refuse nesting before deadline validation`(timeout: Float) throws {
        let nativeApplication = AXUIElementCreateApplication(getpid())
        let first = Element(nativeApplication)
        let second = Element(nativeApplication)
        var readCount = 0

        try first.withMessagingTimeout(0.5) { boundedApplication in
            #expect(ObjectIdentifier(boundedApplication.underlyingElement) == ObjectIdentifier(nativeApplication))
            #expect(throws: AXMessagingTimeoutError.nestedScope) {
                try second.withMessagingTimeout(timeout) { _ in
                    readCount += 1
                }
            }
        }

        #expect(readCount == 0)
        let value = try second.withMessagingTimeout(0.25) { _ in 42 }
        #expect(value == 42)
    }

    @Test
    func `equal ordinary elements with distinct native references keep independent scopes`() throws {
        let first = Element(AXUIElementCreateApplication(getpid()))
        let second = Element(AXUIElementCreateApplication(getpid()))
        #expect(first == second)
        #expect(ObjectIdentifier(first.underlyingElement) != ObjectIdentifier(second.underlyingElement))

        let value = try first.withMessagingTimeout(0.25) { _ in
            try second.withMessagingTimeout(0.25) { _ in 42 }
        }
        #expect(value == 42)
    }

    @Test
    func `distinct system-wide references share one scope`() throws {
        let first = Element(AXUIElementCreateSystemWide())
        let second = Element(AXUIElementCreateSystemWide())
        #expect(first == second)
        #expect(ObjectIdentifier(first.underlyingElement) != ObjectIdentifier(second.underlyingElement))

        _ = try first.withMessagingTimeout(0.25) { _ in
            #expect(throws: AXMessagingTimeoutError.nestedScope) {
                try second.withMessagingTimeout(0.25) { _ in
                    Issue.record("The nested system-wide operation must not run")
                }
            }
        }

        let value = try second.withMessagingTimeout(0.25) { _ in 42 }
        #expect(value == 42)
    }

    @Test
    func `AXorcist convenience wrappers refuse nested reads without releasing the outer owner`() throws {
        let nativeApplication = AXUIElementCreateApplication(getpid())
        let application = Element(nativeApplication)
        let secondWrapper = Element(nativeApplication)

        try application.withMessagingTimeout(0.25) { _ in
            #expect(secondWrapper.windowsWithTimeout(timeout: 0.5) == nil)
            #expect(secondWrapper.menuBarWithTimeout(timeout: 0.5) == nil)
            #expect(throws: AXMessagingTimeoutError.nestedScope) {
                try secondWrapper.withMessagingTimeout(0.5) { _ in
                    Issue.record("Convenience-wrapper refusal must preserve the outer owner")
                }
            }
        }

        let value = try secondWrapper.withMessagingTimeout(0.25) { _ in 42 }
        #expect(value == 42)
    }

    @Test(arguments: [nil, "Save"], [nil, "Synthetic App"])
    func `dialog candidates propagate native timeout setup failure`(title: String?, appName: String?) {
        let invalidApplication = Element(AXUIElementCreateApplication(-1))

        #expect(throws: AXMessagingTimeoutError.systemFailure(code: AXError.invalidUIElement.rawValue)) {
            try DialogService().dialogWindowCandidates(in: invalidApplication, title: title, appName: appName)
        }
    }

    @Test(arguments: [nil, "Save"], [nil, "Synthetic App"])
    func `dialog candidates propagate nesting refusal without releasing the outer owner`(
        title: String?,
        appName: String?) throws
    {
        let nativeApplication = AXUIElementCreateApplication(getpid())
        let application = Element(nativeApplication)
        let secondWrapper = Element(nativeApplication)
        let service = DialogService()

        try application.withMessagingTimeout(0.25) { _ in
            #expect(throws: AXMessagingTimeoutError.nestedScope) {
                try service.dialogWindowCandidates(in: secondWrapper, title: title, appName: appName)
            }
            #expect(throws: AXMessagingTimeoutError.nestedScope) {
                try secondWrapper.withMessagingTimeout(0.5) { _ in
                    Issue.record("Dialog candidate refusal must preserve the outer owner")
                }
            }
        }

        let value = try secondWrapper.withMessagingTimeout(0.25) { _ in 42 }
        #expect(value == 42)
    }

    @Test
    func `window identity stays unresolved when native timeout setup fails`() {
        let invalidApplication = Element(AXUIElementCreateApplication(-1))

        #expect(WindowIdentityService().getWindowID(from: invalidApplication) == nil)
    }

    @Test(arguments: [Float.zero, -0.1, -.infinity, .infinity, .nan])
    func `window identity stays unresolved for invalid deadlines`(timeout: Float) {
        let application = Element(AXUIElementCreateApplication(getpid()))

        #expect(WindowIdentityService().getWindowID(from: application, messagingTimeout: timeout) == nil)
    }

    @Test
    func `window identity refuses an AXorcist owned reference without releasing it`() throws {
        let application = Element(AXUIElementCreateApplication(getpid()))
        let secondWrapper = Element(application.underlyingElement)
        let service = WindowIdentityService()

        try application.withMessagingTimeout(0.25) { _ in
            #expect(service.getWindowID(from: secondWrapper) == nil)
            #expect(throws: AXMessagingTimeoutError.nestedScope) {
                try secondWrapper.withMessagingTimeout(0.5) { _ in
                    Issue.record("Identity refusal must preserve the outer owner")
                }
            }
        }

        let value = try secondWrapper.withMessagingTimeout(0.25) { _ in 42 }
        #expect(value == 42)
    }
}

private enum MessagingTimeoutProbeError: Error {
    case failed
}
