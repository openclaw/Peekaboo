import Foundation
import PeekabooFoundation

extension ScreenCaptureKitOwnershipDiagnostic {
    public static func capturing(
        _ error: any Error,
        stage: Stage,
        operation: String? = nil) -> Self
    {
        if let diagnostic = error as? Self {
            return diagnostic
        }
        guard let lease = error as? ScreenCaptureKitOwnerLease.LeaseError else {
            return Self(
                kind: error is CancellationError ? .cancelled : .unknown,
                stage: stage,
                message: error.localizedDescription,
                operation: operation)
        }
        var kind: Kind
        var path: String?
        var systemCode: Int32?
        var timeout: TimeInterval?
        var blockers: [ProcessEvidence] = []
        var failedOperation = operation
        switch lease {
        case let .fileSystem(leaseOperation, leasePath, _):
            kind = .fileSystem
            failedOperation = leaseOperation
            path = leasePath
        case let .systemCall(leaseOperation, leasePath, code):
            kind = .systemCall
            failedOperation = leaseOperation
            path = leasePath
            systemCode = code
        case let .unsafeDirectory(leasePath):
            kind = .unsafeDirectory
            path = leasePath
        case let .unsafeLockFile(leasePath):
            kind = .unsafeLockFile
            path = leasePath
        case .invalidOwnerIdentity:
            kind = .invalidOwnerIdentity
        case let .invalidOwnerReceipt(leasePath, _):
            kind = .invalidOwnerReceipt
            path = leasePath
        case let .ownedByAnotherProcess(leasePath, receipt):
            kind = .ownedByAnotherProcess
            path = leasePath
            blockers = [.init(
                processIdentifier: receipt.processIdentifier,
                processStartIdentity: receipt.processStartIdentity,
                buildIdentity: receipt.buildIdentity,
                codeSignatureHash: receipt.codeSignatureHash)]
        case let .uncoordinatedProcesses(processes):
            kind = .uncoordinatedProcesses
            blockers = processes.map {
                .init(
                    processIdentifier: $0.processIdentifier,
                    processStartIdentity: $0.processStartIdentity,
                    executablePath: $0.executablePath)
            }
        case let .uncoordinatedHosts(hosts):
            kind = .uncoordinatedHosts
            blockers = hosts.map {
                .init(
                    processIdentifier: $0.processIdentifier,
                    processStartIdentity: $0.processStartIdentity,
                    socketPath: $0.socketPath,
                    buildIdentity: $0.buildIdentity)
            }
        case let .preparationTimedOut(seconds):
            kind = .timedOut
            timeout = seconds
        }
        return Self(
            kind: kind,
            stage: stage,
            message: lease.localizedDescription,
            operation: failedOperation,
            path: path,
            systemCode: systemCode,
            timeoutSeconds: timeout,
            blockers: blockers)
    }
}

extension ScreenCaptureKitReadiness {
    public static func failed(_ error: any Error, stage: ScreenCaptureKitOwnershipDiagnostic.Stage) -> Self {
        let failure = ScreenCaptureKitOwnershipDiagnostic.capturing(error, stage: stage)
        let blocked = [.ownedByAnotherProcess, .uncoordinatedProcesses, .uncoordinatedHosts].contains(failure.kind)
        return Self(state: blocked ? .blocked : .unavailable, failure: failure)
    }
}
