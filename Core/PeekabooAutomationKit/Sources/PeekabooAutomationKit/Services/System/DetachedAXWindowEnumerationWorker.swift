import ApplicationServices
import CoreGraphics
import Foundation
import PeekabooFoundation

struct DetachedAXWindowDescriptor: Sendable, Equatable {
    let windowID: Int?
    let title: String
    let bounds: CGRect?
    let isMainWindow: Bool
    let subrole: String?
    let isMinimized: Bool?

    init(
        windowID: Int?,
        title: String,
        bounds: CGRect?,
        isMainWindow: Bool = false,
        subrole: String? = nil,
        isMinimized: Bool? = nil)
    {
        self.windowID = windowID
        self.title = title
        self.bounds = bounds
        self.isMainWindow = isMainWindow
        self.subrole = subrole
        self.isMinimized = isMinimized
    }
}

struct DetachedAXWindowEnumerationRequest: Sendable {
    let processIdentifier: Int32
    let expectedProcessStartIdentity: UInt64
    let timeoutSeconds: TimeInterval
    let maximumWindowCount: Int
}

struct DetachedAXWindowEnumerationResult: Sendable {
    let descriptors: [DetachedAXWindowDescriptor]
    let focusedWindowID: Int?
    let timedOut: Bool
    let incomplete: Bool
    let reportedWindowCount: Int
}

struct DetachedAXWindowEnumerationTiming: Sendable, Equatable {
    private static let maximumCompletionGrace: TimeInterval = 0.25
    private static let minimumCompletionGrace: TimeInterval = 0.01

    let softTimeoutSeconds: TimeInterval
    let hardTimeoutSeconds: TimeInterval

    init(hardTimeoutSeconds: TimeInterval) {
        let hardTimeoutSeconds = max(0.001, hardTimeoutSeconds)
        let proportionalGrace = hardTimeoutSeconds * 0.1
        let completionGrace = min(
            Self.maximumCompletionGrace,
            max(Self.minimumCompletionGrace, proportionalGrace))
        self.softTimeoutSeconds = max(0.001, hardTimeoutSeconds - completionGrace)
        self.hardTimeoutSeconds = hardTimeoutSeconds
    }
}

enum DetachedAXWindowEnumerationCoordinator {
    static func run(
        processIdentifier: Int32,
        processStartIdentity: UInt64,
        timeoutSeconds: TimeInterval,
        maximumWindowCount: Int = 100,
        operation: @escaping @Sendable (DetachedAXWindowEnumerationRequest) throws
            -> DetachedAXWindowEnumerationResult = DetachedAXWindowEnumerationWorker.enumerate) async throws
        -> DetachedAXWindowEnumerationResult
    {
        let timing = DetachedAXWindowEnumerationTiming(hardTimeoutSeconds: timeoutSeconds)
        let request = DetachedAXWindowEnumerationRequest(
            processIdentifier: processIdentifier,
            expectedProcessStartIdentity: processStartIdentity,
            timeoutSeconds: timing.softTimeoutSeconds,
            maximumWindowCount: maximumWindowCount)
        return try await ElementDetectionTimeoutRunner.runDetached(
            targetProcessIdentifier: processIdentifier,
            targetProcessStartIdentity: processStartIdentity,
            seconds: timing.hardTimeoutSeconds)
        {
            try operation(request)
        }
    }
}

/// A bounded, read-only AX worker for window inventory enrichment. Every AX reference is created and
/// consumed on the generation-pinned detached lane; only immutable descriptors cross back to MainActor.
enum DetachedAXWindowEnumerationWorker {
    private static let maximumPerCallTimeout: Float = 0.2
    private static let descriptorAttributes: [String] = [
        kAXTitleAttribute,
        kAXPositionAttribute,
        kAXSizeAttribute,
        kAXMinimizedAttribute,
        kAXMainAttribute,
        kAXSubroleAttribute,
    ]

    static func enumerate(_ request: DetachedAXWindowEnumerationRequest) throws
        -> DetachedAXWindowEnumerationResult
    {
        try self.validateIdentity(request)
        let deadline = ContinuousClock.now.advanced(by: .seconds(request.timeoutSeconds))
        let application = AXUIElementCreateApplication(request.processIdentifier)

        guard self.remainingMessagingTimeout(until: deadline) != nil else {
            return DetachedAXWindowEnumerationResult(
                descriptors: [],
                focusedWindowID: nil,
                timedOut: true,
                incomplete: true,
                reportedWindowCount: 0)
        }
        let windowsRead = self.rawAttributeRead(kAXWindowsAttribute, of: application, deadline: deadline)
        guard windowsRead.error == .success,
              let windows = windowsRead.value as? [AXUIElement]
        else {
            try self.validateIdentity(request)
            let incomplete = windowsRead.error == .success ||
                windowsRead.error == .attributeUnsupported ||
                windowsRead.error == .parameterizedAttributeUnsupported ||
                windowsRead.error == .notImplemented ||
                windowsRead.isIncomplete
            return DetachedAXWindowEnumerationResult(
                descriptors: [],
                focusedWindowID: nil,
                timedOut: ContinuousClock.now >= deadline,
                incomplete: incomplete,
                reportedWindowCount: 0)
        }

        let focusedWindowRead = self.elementAttribute(
            kAXFocusedWindowAttribute,
            of: application,
            deadline: deadline)
        let focusedWindowIDRead: ValueRead<Int> = if let focusedWindow = focusedWindowRead.value {
            self.windowID(of: focusedWindow, deadline: deadline)
        } else {
            ValueRead(value: nil, incomplete: false)
        }
        let focusedWindowID = focusedWindowIDRead.value

        let limit = max(0, request.maximumWindowCount)
        var descriptors: [DetachedAXWindowDescriptor] = []
        descriptors.reserveCapacity(min(windows.count, limit))
        var incomplete = focusedWindowRead.incomplete || focusedWindowIDRead.incomplete
        var timedOut = false

        for window in windows.prefix(limit) {
            guard ContinuousClock.now < deadline else {
                timedOut = true
                break
            }
            guard let read = self.readDescriptor(
                window,
                expectedProcessIdentifier: request.processIdentifier,
                deadline: deadline)
            else {
                incomplete = true
                if ContinuousClock.now >= deadline {
                    timedOut = true
                    break
                }
                continue
            }
            descriptors.append(read.descriptor)
            incomplete = incomplete || read.incomplete
        }

        if windows.count > limit {
            incomplete = true
        }
        try self.validateIdentity(request)
        return DetachedAXWindowEnumerationResult(
            descriptors: descriptors,
            focusedWindowID: focusedWindowID,
            timedOut: timedOut,
            incomplete: incomplete,
            reportedWindowCount: windows.count)
    }

    static func validateIdentity(
        _ request: DetachedAXWindowEnumerationRequest,
        processStartIdentityProvider: (pid_t) -> UInt64? = SystemIdentityResolver.processStartIdentity) throws
    {
        guard processStartIdentityProvider(request.processIdentifier) == request.expectedProcessStartIdentity else {
            throw PeekabooError.snapshotStale(
                "Target PID \(request.processIdentifier) changed process generation during window enumeration")
        }
    }

    private static func readDescriptor(
        _ window: AXUIElement,
        expectedProcessIdentifier: pid_t,
        deadline: ContinuousClock.Instant) -> DescriptorRead?
    {
        var ownerPID: pid_t = 0
        guard AXUIElementGetPid(window, &ownerPID) == .success,
              self.isExpectedOwner(
                  observedProcessIdentifier: ownerPID,
                  expectedProcessIdentifier: expectedProcessIdentifier)
        else {
            return nil
        }
        guard let values = self.descriptorValues(window, deadline: deadline) else { return nil }

        let title = AXDescriptorReader.stringValue(values[0]) ?? ""
        let position = AXDescriptorReader.cgPointValue(values[1])
        let size = AXDescriptorReader.cgSizeValue(values[2])
        let bounds: CGRect? = if let position, let size {
            CGRect(origin: position, size: size)
        } else {
            nil
        }
        let isMinimized = AXDescriptorReader.boolValue(values[3])
        let isMainWindow = AXDescriptorReader.boolValue(values[4]) ?? false
        let subrole = AXDescriptorReader.stringValue(values[5])
        let resolvedID = self.windowID(of: window, deadline: deadline)

        return DescriptorRead(
            descriptor: DetachedAXWindowDescriptor(
                windowID: resolvedID.value,
                title: title,
                bounds: bounds,
                isMainWindow: isMainWindow,
                subrole: subrole,
                isMinimized: isMinimized),
            incomplete: resolvedID.incomplete)
    }

    private static func descriptorValues(
        _ window: AXUIElement,
        deadline: ContinuousClock.Instant) -> [Any?]?
    {
        guard let timeout = self.remainingMessagingTimeout(until: deadline) else { return nil }
        AXUIElementSetMessagingTimeout(window, timeout)
        var rawValues: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            window,
            self.descriptorAttributes as CFArray,
            [],
            &rawValues)
        AXUIElementSetMessagingTimeout(window, 0)
        let values = rawValues as? [Any]
        if error == .success,
           let values,
           values.count == self.descriptorAttributes.count,
           !AXAttributeReadCompletenessPolicy.hasIncompleteErrorValue(in: values)
        {
            return values.map { value in
                AXAttributeReadCompletenessPolicy.embeddedError(in: value) == nil ? value : nil
            }
        }

        let supportsFallback = error == .attributeUnsupported ||
            error == .parameterizedAttributeUnsupported ||
            error == .notImplemented ||
            (error == .success && values?.count != self.descriptorAttributes.count)
        guard supportsFallback else { return nil }

        var fallbackValues: [Any?] = []
        fallbackValues.reserveCapacity(self.descriptorAttributes.count)
        for attribute in self.descriptorAttributes {
            let read = self.rawAttributeRead(attribute, of: window, deadline: deadline)
            guard !read.isIncomplete else { return nil }
            fallbackValues.append(read.value)
        }
        return fallbackValues
    }

    static func isExpectedOwner(
        observedProcessIdentifier: pid_t,
        expectedProcessIdentifier: pid_t) -> Bool
    {
        observedProcessIdentifier == expectedProcessIdentifier
    }

    private static func remainingMessagingTimeout(until deadline: ContinuousClock.Instant) -> Float? {
        let remaining = ContinuousClock.now.duration(to: deadline).timeInterval
        guard remaining > 0 else { return nil }
        return Float(min(TimeInterval(self.maximumPerCallTimeout), max(0.001, remaining)))
    }

    private static func windowID(of element: AXUIElement, deadline: ContinuousClock.Instant) -> ValueRead<Int> {
        guard let timeout = self.remainingMessagingTimeout(until: deadline) else {
            return ValueRead(value: nil, incomplete: true)
        }
        AXUIElementSetMessagingTimeout(element, timeout)
        defer { AXUIElementSetMessagingTimeout(element, 0) }
        var windowID: CGWindowID = 0
        let error = AXWindowIDResolver.copyWindowID(element, into: &windowID)
        let value = error == .success && windowID > 0 ? Int(windowID) : nil
        return ValueRead(
            value: value,
            incomplete: value == nil && AXAttributeReadCompletenessPolicy.isIncomplete(error: error))
    }

    private static func elementAttribute(
        _ name: String,
        of element: AXUIElement,
        deadline: ContinuousClock.Instant) -> ValueRead<AXUIElement>
    {
        let read = self.rawAttributeRead(name, of: element, deadline: deadline)
        guard let value = read.value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return ValueRead(
                value: nil,
                incomplete: read.error == .success || read.isIncomplete)
        }
        return ValueRead(value: unsafeDowncast(value, to: AXUIElement.self), incomplete: false)
    }

    private static func rawAttributeRead(
        _ name: String,
        of element: AXUIElement,
        deadline: ContinuousClock.Instant) -> AttributeRead
    {
        guard let timeout = self.remainingMessagingTimeout(until: deadline) else {
            return AttributeRead(error: .cannotComplete, value: nil)
        }
        AXUIElementSetMessagingTimeout(element, timeout)
        defer { AXUIElementSetMessagingTimeout(element, 0) }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return AttributeRead(error: error, value: value)
    }

    private struct AttributeRead {
        let error: AXError
        let value: CFTypeRef?

        var isIncomplete: Bool {
            AXAttributeReadCompletenessPolicy.isIncomplete(error: self.error)
        }
    }

    private struct DescriptorRead {
        let descriptor: DetachedAXWindowDescriptor
        let incomplete: Bool
    }

    private struct ValueRead<Value> {
        let value: Value?
        let incomplete: Bool
    }
}

extension Duration {
    fileprivate var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
