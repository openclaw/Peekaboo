import AppKit
import Darwin

/// Corroborates a denied full generation read; credentials alone never determine targetability.
struct ApplicationMutationEligibility: Equatable, Sendable {
    let credentials: SystemIdentityResolver.ProcessCredentials
    let runtimeHostUserID: uid_t
    let activationPolicy: ServiceApplicationActivationPolicy

    func isForeignProhibited(processIdentifier: pid_t) -> Bool {
        self.credentials.processIdentifier == processIdentifier &&
            self.credentials.effectiveUserID != self.runtimeHostUserID &&
            self.activationPolicy == .prohibited
    }

    static func read(_ processIdentifier: pid_t) -> Self? {
        guard let credentials = SystemIdentityResolver.processCredentials(processIdentifier),
              let application = NSRunningApplication(processIdentifier: processIdentifier),
              application.processIdentifier == processIdentifier,
              !application.isTerminated
        else { return nil }
        let policy = ApplicationService.serviceActivationPolicy(from: application.activationPolicy)
        return Self(credentials: credentials, runtimeHostUserID: geteuid(), activationPolicy: policy)
    }
}
