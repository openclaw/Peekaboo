import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

struct BrowserMCPPreparedExecution {
    let sessionBinding: BrowserMCPExecutionSessionBinding
    let connectionOutcome: DesktopActionOutcome?
}

enum BrowserMCPCallFailure: Error {
    case preDispatch(any Error)
    case mayHaveDispatched(any Error)
}

struct BrowserMCPProjectedProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        self.message
    }
}

struct BrowserMCPEnvironmentOptions: Sendable {
    let browserURL: String?
    let isolated: Bool
    let headless: Bool

    var supportsNativeBrowserConnectionBinding: Bool {
        self.browserURL == nil && !self.isolated
    }

    init(environment: [String: String]) {
        let browserURL = environment["PEEKABOO_BROWSER_MCP_BROWSER_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.browserURL = browserURL?.isEmpty == false ? browserURL : nil
        self.isolated = Self.flag("PEEKABOO_BROWSER_MCP_ISOLATED", in: environment)
        self.headless = Self.flag("PEEKABOO_BROWSER_MCP_HEADLESS", in: environment)
    }

    private static func flag(_ name: String, in environment: [String: String]) -> Bool {
        guard let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return ["1", "true", "yes", "on"].contains(value)
    }
}

enum BrowserMCPConnectionTargetKind: Sendable, Equatable {
    case external
    case isolated
    case nativeChannel
}

public struct BrowserMCPConnectionHandoffAuthorization: Sendable, Equatable {
    let sourceBinding: BrowserMCPExecutionSessionBinding

    public var connectionReceipt: BrowserMCPConnectionReceipt {
        self.sourceBinding.connectionReceipt
    }
}

struct BrowserMCPAuthorizedHandoffTarget: Sendable, Equatable {
    let receipt: BrowserMCPConnectionReceipt
    let channelEndpoint: BrowserMCPDevToolsEndpoint?
    let codeSignatureIdentity: ChromeProcessCodeSignatureValidator.Identity?
    let targetKind: BrowserMCPConnectionTargetKind
}

enum BrowserMCPHandoffSourceDrainError: Error {
    case sourceStillLive(any Error)
    case recoveryRequired(any Error)
}

struct BrowserMCPHandoffDestinationError: Error {
    let cause: any Error
    let cleanupConfirmed: Bool
}
