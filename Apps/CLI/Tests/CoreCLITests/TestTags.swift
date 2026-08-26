import Foundation
import PeekabooBridge
import Testing

extension PeekabooBridgeHandshakeResponse {
    func withProducerBoundSnapshotFixture() -> PeekabooBridgeHandshakeResponse {
        var supportedOperations = self.supportedOperations
        if !supportedOperations.contains(.ownsSnapshot) {
            supportedOperations.append(.ownsSnapshot)
        }
        var enabledOperations = self.enabledOperations
        if enabledOperations != nil, enabledOperations?.contains(.ownsSnapshot) != true {
            enabledOperations?.append(.ownsSnapshot)
        }
        var hostCapabilities = self.hostCapabilities ?? []
        for capability in [
            PeekabooBridgeHostCapability.attestedOperationReceipts,
            PeekabooBridgeHostCapability.producerBoundSnapshotReferences,
        ] where !hostCapabilities.contains(capability) {
            hostCapabilities.append(capability)
        }
        return PeekabooBridgeHandshakeResponse(
            negotiatedVersion: self.negotiatedVersion,
            hostKind: self.hostKind,
            build: self.build,
            supportedOperations: supportedOperations,
            permissions: self.permissions,
            enabledOperations: enabledOperations,
            permissionTags: self.permissionTags,
            hostIdentity: self.hostIdentity,
            hostCapabilities: hostCapabilities,
            operationAttestation: self.operationAttestation,
            operationSessionAttestation: self.operationSessionAttestation
        )
    }
}

extension Tag {
    // Test categories
    @Tag static var fast: Self
    @Tag static var unit: Self
    @Tag static var integration: Self
    @Tag static var safe: Self
    @Tag static var automation: Self
    @Tag static var regression: Self

    // Feature areas
    @Tag static var permissions: Self
    @Tag static var applicationFinder: Self
    @Tag static var windowManager: Self
    @Tag static var imageCapture: Self
    @Tag static var models: Self
    @Tag static var jsonOutput: Self
    @Tag static var logger: Self
    @Tag static var browserFiltering: Self
    @Tag static var screenshot: Self
    @Tag static var multiWindow: Self
    @Tag static var focus: Self
    @Tag static var imageAnalysis: Self
    @Tag static var formats: Self
    @Tag static var multiDisplay: Self

    // Performance & reliability
    @Tag static var performance: Self
    @Tag static var concurrency: Self
    @Tag static var memory: Self
    @Tag static var flaky: Self

    // Execution environment
    @Tag static var localOnly: Self
    @Tag static var ciOnly: Self
    @Tag static var requiresDisplay: Self
    @Tag static var requiresPermissions: Self
    @Tag static var requiresNetwork: Self
}

@preconcurrency
enum CLITestEnvironment {
    @inline(__always)
    private nonisolated static func flag(_ key: String) -> Bool {
        ProcessInfo.processInfo.environment[key]?.lowercased() == "true"
    }

    @preconcurrency nonisolated(unsafe) static var runAutomationScenarios: Bool {
        flag("RUN_AUTOMATION_TESTS") || flag("RUN_LOCAL_TESTS")
    }
}
