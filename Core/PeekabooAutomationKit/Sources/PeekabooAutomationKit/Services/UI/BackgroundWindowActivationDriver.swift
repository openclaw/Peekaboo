import ApplicationServices
import CoreGraphics
import Darwin
import PeekabooFoundation

/// Sends a target-only window activation record, never a front-process or window-order operation.
@MainActor
enum BackgroundWindowActivationDriver {
    private typealias ResolvePSN = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32
    private typealias ResolvePID = @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<pid_t>) -> Int32
    private typealias PostRecord = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Int32

    private static let skyLight = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let applicationServices = dlopen(
        "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)

    static func prepare(_ target: UIAutomationTarget.ExactWindow) throws -> DesktopActionOutcome {
        guard CGPreflightPostEventAccess() else { throw PeekabooError.permissionDeniedEventSynthesizing }
        guard let skyLight, let applicationServices,
              let resolvePSNSymbol = dlsym(applicationServices, "GetProcessForPID"),
              let resolvePIDSymbol = dlsym(applicationServices, "GetProcessPID"),
              let postSymbol = dlsym(skyLight, "SLPSPostEventRecordTo"),
              let windowID = CGWindowID(exactly: target.identity.windowID)
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .operationUnsupported,
                message: "Target-only background window activation is unavailable on this runtime.")
        }
        let resolvePSN = unsafeBitCast(resolvePSNSymbol, to: ResolvePSN.self)
        let resolvePID = unsafeBitCast(resolvePIDSymbol, to: ResolvePID.self)
        let post = unsafeBitCast(postSymbol, to: PostRecord.self)
        let pid = target.identity.ownerProcessIdentifier
        var psn: [UInt32] = [0, 0]
        let resolved = psn.withUnsafeMutableBytes { resolvePSN(pid, $0.baseAddress!) }
        var reversePID: pid_t = 0
        let reversed = psn.withUnsafeBytes { resolvePID($0.baseAddress!, &reversePID) }
        guard resolved == 0, reversed == 0, reversePID == pid,
              SystemIdentityResolver.validateWindowMutationIdentity(target.identity),
              let window = SystemIdentityResolver.windowIdentity(windowID),
              window.ownerProcessIdentifier == pid, window.bounds == target.bounds,
              window.layer == Int(CGWindowLevelForKey(.normalWindow)), window.isOnScreen, window.alpha > 0,
              SystemIdentityResolver.processStartIdentity(pid) == target.identity.ownerProcessStartIdentity
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "The background window activation target changed before delivery.")
        }
        try Task.checkCancellation()
        let record = self.eventRecord(windowID: windowID)
        let result = psn.withUnsafeBytes { recipient in
            record.withUnsafeBytes { event in post(recipient.baseAddress!, event.baseAddress!) }
        }
        let delivery = DesktopActionOutcome.Delivery(mechanism: .nativeFramework, mode: .background)
        guard result == 0 else {
            throw DesktopActionFailure.indeterminate(
                delivery: delivery, evidence: .completionUnknown, unitCount: .one,
                message: "Background window activation returned an uncertain delivery result; observe before retrying.")
        }
        return .dispatchedUnverified(delivery: delivery, evidence: .deliveryAccepted, unitCount: .one)
    }

    static func eventRecord(windowID: CGWindowID) -> [UInt8] {
        var record = [UInt8](repeating: 0, count: 0xF8)
        record[0x04] = 0xF8
        record[0x08] = 0x0D
        record[0x8A] = 0x01
        for byte in 0..<4 {
            record[0x3C + byte] = UInt8(truncatingIfNeeded: windowID >> (byte * 8))
        }
        return record
    }
}
