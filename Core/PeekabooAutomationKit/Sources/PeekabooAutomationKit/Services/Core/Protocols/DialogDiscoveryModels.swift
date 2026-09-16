import Foundation

/// Only exact Apple bundle and executable identities authorize automatic system-host discovery.
public enum DialogSystemAlertHosts {
    public static let executables: [String: String] = [
        "com.apple.UserNotificationCenter":
            "/System/Library/CoreServices/UserNotificationCenter.app/Contents/MacOS/UserNotificationCenter",
        "com.apple.SecurityAgent":
            "/System/Library/Frameworks/Security.framework/Versions/A/MachServices/" +
            "SecurityAgent.bundle/Contents/MacOS/SecurityAgent",
    ]

    public static func contains(_ application: ServiceApplicationInfo) -> Bool {
        guard let bundle = application.bundleIdentifier,
              let expected = self.executables[bundle]
        else { return false }
        // `bundlePath` is the `.app`/`.bundle` wrapper reported by `NSRunningApplication.bundleURL`,
        // which is three levels up from the executable at `<wrapper>/Contents/MacOS/<exe>`.
        let expectedBundle = URL(fileURLWithPath: expected)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        return application.executablePath == expected && application.bundlePath == expectedBundle
    }
}

public struct DiscoveredDialog: Sendable, Codable {
    public let owner: ServiceApplicationInfo
    public let elements: DialogElements
    public let source: String
    public let displayTitle: String

    public init(owner: ServiceApplicationInfo, elements: DialogElements, source: String) {
        self.owner = owner
        self.elements = elements
        self.source = source
        self.displayTitle = elements.dialogInfo.title.isEmpty ? "Untitled Dialog" : elements.dialogInfo.title
    }
}

public struct DialogDiscoveryInventory: Sendable, Codable {
    public let dialogs: [DiscoveredDialog]
    public let isComplete: Bool
    public let issues: [String]

    public init(dialogs: [DiscoveredDialog], isComplete: Bool, issues: [String] = []) {
        self.dialogs = dialogs
        self.isComplete = isComplete
        self.issues = issues
    }
}

/// Host-attested uniqueness evidence accompanies the same one-shot exact action receipt.
public struct DialogDiscoverySelectionProof: Sendable, Codable, Equatable {
    public let scannedOwners: [ApplicationProcessIdentity]
    public let isComplete: Bool
    public let dialogCount: Int
    public let enabledPressButtonCount: Int
    public let buttonTitle: String

    public init(
        scannedOwners: [ApplicationProcessIdentity],
        isComplete: Bool,
        dialogCount: Int,
        enabledPressButtonCount: Int,
        buttonTitle: String)
    {
        self.scannedOwners = scannedOwners
        self.isComplete = isComplete
        self.dialogCount = dialogCount
        self.enabledPressButtonCount = enabledPressButtonCount
        self.buttonTitle = buttonTitle
    }

    public func validates(target: UIAutomationTarget.ExactWindow, buttonText: String?) -> Bool {
        guard let buttonText else { return false }
        return self.isComplete && self.dialogCount == 1 && self.enabledPressButtonCount == 1 &&
            self.scannedOwners.contains(target.identity.processIdentity) &&
            Self.canonicalButtonName(self.buttonTitle) == Self.canonicalButtonName(buttonText)
    }

    public static func canonicalButtonName(_ name: String) -> String {
        name.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
    }
}
