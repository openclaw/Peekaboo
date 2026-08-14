import AppKit
import Foundation

enum WindowRoutedApplicationKind: Equatable {
    case appKit
    case catalyst
    case chromium
    case electron
    case webKit
}

/// A narrow runtime gate for process-targeted pointer delivery.
///
/// Wheel events are enabled only for visible native applications whose executable imports WebKit.
/// Electron, Chromium, and Catalyst keep their existing click transport classification but are not
/// admitted to background wheel delivery because receiver consumption cannot be proven there.
@MainActor
enum WindowRoutedApplicationClassifier {
    private static let chromiumBundlePrefixes = [
        "com.google.chrome",
        "org.chromium.chromium",
        "com.microsoft.edgemac",
        "com.brave.browser",
        "com.vivaldi.vivaldi",
        "company.thebrowser.browser",
    ]
    private static let executableProbeLimit = 1_048_576
    private static let webKitImportMarker = Data("/WebKit.framework/".utf8)

    static func kind(processIdentifier: pid_t) -> WindowRoutedApplicationKind {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier) else {
            return .appKit
        }
        let info = application.bundleURL.flatMap(Bundle.init(url:))?.infoDictionary ?? [:]
        let executablePrefix = application.bundleURL
            .flatMap(Bundle.init(url:))?
            .executableURL
            .flatMap(self.executablePrefix)
        return self.kind(
            bundleIdentifier: application.bundleIdentifier,
            principalClass: info["NSPrincipalClass"] as? String,
            hasElectronAsarIntegrity: info["ElectronAsarIntegrity"] != nil,
            isCatalyst: info["UIApplicationSceneManifest"] != nil || info["UIDeviceFamily"] != nil,
            executablePrefix: executablePrefix)
    }

    static func supportsBackgroundWheelScroll(processIdentifier: pid_t) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier),
              self.applicationIsVisible(application)
        else {
            return false
        }
        return self.supportsBackgroundWheelScroll(
            isHidden: false,
            isTerminated: false,
            kind: self.kind(processIdentifier: processIdentifier))
    }

    static func applicationIsVisible(processIdentifier: pid_t) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier) else { return false }
        return self.applicationIsVisible(application)
    }

    static func supportsBackgroundWheelScroll(
        isHidden: Bool,
        isTerminated: Bool,
        kind: WindowRoutedApplicationKind) -> Bool
    {
        !isHidden && !isTerminated && kind == .webKit
    }

    static func kind(
        bundleIdentifier: String?,
        principalClass: String?,
        hasElectronAsarIntegrity: Bool,
        isCatalyst: Bool,
        executablePrefix: Data?) -> WindowRoutedApplicationKind
    {
        let normalizedBundleIdentifier = bundleIdentifier?.lowercased() ?? ""
        if self.chromiumBundlePrefixes.contains(where: normalizedBundleIdentifier.hasPrefix) {
            return .chromium
        }
        if principalClass?.lowercased().contains("atomapplication") == true || hasElectronAsarIntegrity {
            return .electron
        }
        if isCatalyst {
            return .catalyst
        }
        if executablePrefix?.range(of: self.webKitImportMarker) != nil {
            return .webKit
        }
        return .appKit
    }

    private static func executablePrefix(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: self.executableProbeLimit)
    }

    private static func applicationIsVisible(_ application: NSRunningApplication) -> Bool {
        !application.isHidden && !application.isTerminated
    }
}
