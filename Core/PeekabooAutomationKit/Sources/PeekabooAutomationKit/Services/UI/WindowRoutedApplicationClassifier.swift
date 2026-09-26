import AppKit
import Foundation

enum WindowRoutedApplicationKind: Equatable {
    case appKit
    case catalyst
    case chromium
    case electron
}

/// A narrow runtime gate for process-targeted pointer delivery.
///
/// Wheel events are enabled only for visible native applications whose executable imports WebKit.
/// Electron, Chromium, and Catalyst keep their existing click transport classification but are not
/// admitted to background wheel delivery because receiver consumption cannot be proven there.
@MainActor
struct WindowRoutedApplicationClassifier {
    struct Metadata {
        let bundleIdentifier: String?
        let principalClass: String?
        let hasElectronAsarIntegrity: Bool
        let isCatalyst: Bool
        var isHidden = false
        var isTerminated = false
        var executableURL: URL?
    }

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

    private let metadata: Metadata
    private let executablePrefixReader: @MainActor (URL) -> Data?

    init(
        metadata: Metadata,
        executablePrefixReader: @escaping @MainActor (URL) -> Data? = Self.executablePrefix)
    {
        self.metadata = metadata
        self.executablePrefixReader = executablePrefixReader
    }

    var kind: WindowRoutedApplicationKind {
        let normalizedBundleIdentifier = self.metadata.bundleIdentifier?.lowercased() ?? ""
        if Self.chromiumBundlePrefixes.contains(where: normalizedBundleIdentifier.hasPrefix) {
            return .chromium
        }
        if self.metadata.principalClass?.lowercased().contains("atomapplication") == true ||
            self.metadata.hasElectronAsarIntegrity
        {
            return .electron
        }
        if self.metadata.isCatalyst {
            return .catalyst
        }
        return .appKit
    }

    var pointerTransport: WindowRoutedPointerTransport {
        switch self.kind {
        case .catalyst, .chromium, .electron:
            .skyLight
        case .appKit:
            .publicCGEvent
        }
    }

    var supportsBackgroundWheelScroll: Bool {
        guard !self.metadata.isHidden,
              !self.metadata.isTerminated,
              self.kind == .appKit,
              let executableURL = self.metadata.executableURL,
              let prefix = self.executablePrefixReader(executableURL)
        else {
            return false
        }
        return prefix.range(of: Self.webKitImportMarker) != nil
    }

    static func pointerTransport(processIdentifier: pid_t) -> WindowRoutedPointerTransport {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier) else {
            return .publicCGEvent
        }
        return Self(application: application).pointerTransport
    }

    static func supportsBackgroundWheelScroll(processIdentifier: pid_t) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier),
              self.applicationIsVisible(application)
        else {
            return false
        }
        return Self(application: application).supportsBackgroundWheelScroll
    }

    static func applicationIsVisible(processIdentifier: pid_t) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier) else { return false }
        return self.applicationIsVisible(application)
    }

    private init(application: NSRunningApplication) {
        let bundle = application.bundleURL.flatMap(Bundle.init(url:))
        let info = bundle?.infoDictionary ?? [:]
        self.init(metadata: Metadata(
            bundleIdentifier: application.bundleIdentifier,
            principalClass: info["NSPrincipalClass"] as? String,
            hasElectronAsarIntegrity: info["ElectronAsarIntegrity"] != nil,
            isCatalyst: info["UIApplicationSceneManifest"] != nil || info["UIDeviceFamily"] != nil,
            isHidden: application.isHidden,
            isTerminated: application.isTerminated,
            executableURL: bundle?.executableURL))
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
