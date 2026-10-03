import Foundation
import Testing
@testable import PeekabooAutomationKit

struct WindowRoutedApplicationClassifierTests {
    private static let executableURL = URL(fileURLWithPath: "/test/PeekabooFixture")
    private static let webKitPrefix = Data("/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit".utf8)
    private static let safariPrefix = Data(
        "/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari".utf8)

    @Test(arguments: Family.allCases)
    @MainActor
    private func `pointer transport never probes the executable`(_ family: Family) {
        var readCount = 0
        let classifier = WindowRoutedApplicationClassifier(metadata: family.metadata) { _ in
            readCount += 1
            return Self.webKitPrefix
        }

        #expect(classifier.kind == family.expectedKind)
        #expect(classifier.pointerTransport == family.expectedTransport)
        #expect(readCount == 0)
    }

    @Test(arguments: [
        "COM.GOOGLE.CHROME.canary",
        "org.chromium.Chromium",
        "com.microsoft.edgemac.Beta",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser",
    ])
    @MainActor
    func `Chromium bundle prefixes keep their existing transport`(_ bundleIdentifier: String) {
        let classifier = WindowRoutedApplicationClassifier(metadata: .init(
            bundleIdentifier: bundleIdentifier,
            principalClass: "AtomApplication",
            hasElectronAsarIntegrity: true,
            isCatalyst: true,
            executableURL: Self.executableURL))
        { _ in
            Issue.record("Chromium classification must not inspect the executable")
            return Self.webKitPrefix
        }

        #expect(classifier.kind == .chromium)
        #expect(classifier.pointerTransport == .skyLight)
        #expect(!classifier.supportsBackgroundWheelScroll)
    }

    @Test(arguments: Family.allCases.filter { $0 != .native })
    @MainActor
    private func `excluded wheel families never probe WebKit imports`(_ family: Family) {
        var readCount = 0
        let classifier = WindowRoutedApplicationClassifier(metadata: family.metadata) { _ in
            readCount += 1
            return Self.webKitPrefix
        }

        #expect(!classifier.supportsBackgroundWheelScroll)
        #expect(readCount == 0)
    }

    @Test
    @MainActor
    func `visible native wheel capability reads one executable prefix`() {
        var readURLs: [URL] = []
        let classifier = WindowRoutedApplicationClassifier(metadata: Family.native.metadata) { url in
            readURLs.append(url)
            return Self.webKitPrefix
        }

        #expect(classifier.supportsBackgroundWheelScroll)
        #expect(classifier.pointerTransport == .publicCGEvent)
        #expect(readURLs == [Self.executableURL])
    }

    @Test(arguments: [0, 1, 2, 4, 8, 16, 32])
    @MainActor
    func `known Safari framework preserves every wheel eligibility guard`(flags: Int) {
        let metadata = WindowRoutedApplicationClassifier.Metadata(
            bundleIdentifier: "com.apple.Safari",
            principalClass: flags & 4 == 0 ? "BrowserApplication" : "AtomApplication",
            hasElectronAsarIntegrity: flags & 8 != 0,
            isCatalyst: flags & 16 != 0,
            isHidden: flags & 1 != 0,
            isTerminated: flags & 2 != 0,
            executableURL: flags & 32 == 0 ? Self.executableURL : nil)
        var readURLs: [URL] = []
        let classifier = WindowRoutedApplicationClassifier(metadata: metadata) { url in
            readURLs.append(url)
            return Self.safariPrefix
        }

        #expect(classifier.supportsBackgroundWheelScroll == (flags == 0))
        #expect(readURLs == (flags == 0 ? [Self.executableURL] : []))
        if flags == 0 {
            #expect(classifier.kind == .appKit)
            #expect(classifier.pointerTransport == .publicCGEvent)
            #expect(readURLs == [Self.executableURL])
        }
    }

    @Test(arguments: [
        nil, "com.example.Native", "com.apple.safari", "com.apple.Safari.extra",
        "com.apple.SafariTechnologyPreview",
    ] as [String?])
    @MainActor
    func `Safari framework marker requires the exact Safari bundle identifier`(_ bundleIdentifier: String?) {
        let classifier = WindowRoutedApplicationClassifier(metadata: .init(
            bundleIdentifier: bundleIdentifier,
            principalClass: "BrowserApplication",
            hasElectronAsarIntegrity: false,
            isCatalyst: false,
            executableURL: Self.executableURL)) { _ in Self.safariPrefix }

        #expect(!classifier.supportsBackgroundWheelScroll)
    }

    @Test(arguments: [
        nil, "", "Safari.framework", "/Safari.framework/",
        "/System/Library/PrivateFrameworks/Safari.framework/Versions/B/Safari",
    ] as [String?])
    @MainActor
    func `Safari wheel capability requires its full readable framework marker`(_ prefix: String?) {
        var readCount = 0
        let classifier = WindowRoutedApplicationClassifier(metadata: .init(
            bundleIdentifier: "com.apple.Safari",
            principalClass: "BrowserApplication",
            hasElectronAsarIntegrity: false,
            isCatalyst: false,
            executableURL: Self.executableURL))
        { _ in
            readCount += 1
            return prefix.map { Data($0.utf8) }
        }

        #expect(!classifier.supportsBackgroundWheelScroll)
        #expect(readCount == 1)
    }

    @Test
    @MainActor
    func `missing family metadata retains native transport and wheel checks`() {
        var readCount = 0
        let classifier = WindowRoutedApplicationClassifier(metadata: .init(
            bundleIdentifier: nil,
            principalClass: nil,
            hasElectronAsarIntegrity: false,
            isCatalyst: false,
            executableURL: Self.executableURL))
        { _ in
            readCount += 1
            return Self.webKitPrefix
        }

        #expect(classifier.kind == .appKit)
        #expect(classifier.pointerTransport == .publicCGEvent)
        #expect(readCount == 0)
        #expect(classifier.supportsBackgroundWheelScroll)
        #expect(readCount == 1)
    }

    @Test(arguments: [(true, false), (false, true), (true, true)])
    @MainActor
    func `hidden or terminated applications do not probe the executable`(isHidden: Bool, isTerminated: Bool) {
        var metadata = Family.native.metadata
        metadata.isHidden = isHidden
        metadata.isTerminated = isTerminated
        var readCount = 0
        let classifier = WindowRoutedApplicationClassifier(metadata: metadata) { _ in
            readCount += 1
            return Self.webKitPrefix
        }

        #expect(!classifier.supportsBackgroundWheelScroll)
        #expect(readCount == 0)
    }

    @Test
    @MainActor
    func `missing executable URL denies wheel capability without a probe`() {
        var metadata = Family.native.metadata
        metadata.executableURL = nil
        var readCount = 0
        let classifier = WindowRoutedApplicationClassifier(metadata: metadata) { _ in
            readCount += 1
            return Self.webKitPrefix
        }

        #expect(!classifier.supportsBackgroundWheelScroll)
        #expect(classifier.pointerTransport == .publicCGEvent)
        #expect(readCount == 0)
    }

    @Test(arguments: ["", "AppKit.framework", "WebKit.framework", "/webkit.framework/"])
    @MainActor
    func `wheel capability requires the exact WebKit import marker`(_ prefix: String) {
        var readCount = 0
        let classifier = WindowRoutedApplicationClassifier(metadata: Family.native.metadata) { _ in
            readCount += 1
            return Data(prefix.utf8)
        }

        #expect(!classifier.supportsBackgroundWheelScroll)
        #expect(readCount == 1)
    }

    @Test
    @MainActor
    func `unreadable executable denies wheel capability`() {
        var readCount = 0
        let classifier = WindowRoutedApplicationClassifier(metadata: Family.native.metadata) { _ in
            readCount += 1
            return nil
        }

        #expect(!classifier.supportsBackgroundWheelScroll)
        #expect(readCount == 1)
    }

    @Test
    @MainActor
    func `wheel capability does not cache executable evidence`() {
        var prefix: Data? = Self.webKitPrefix
        var readCount = 0
        let classifier = WindowRoutedApplicationClassifier(metadata: Family.native.metadata) { _ in
            readCount += 1
            return prefix
        }

        #expect(classifier.supportsBackgroundWheelScroll)
        prefix = nil
        #expect(!classifier.supportsBackgroundWheelScroll)
        #expect(readCount == 2)
    }

    private enum Family: CaseIterable {
        case native
        case chromium
        case electronPrincipalClass
        case electronIntegrity
        case catalyst
        case allMarkers
        case electronAndCatalyst

        @MainActor
        var metadata: WindowRoutedApplicationClassifier.Metadata {
            .init(
                bundleIdentifier: self == .chromium || self == .allMarkers
                    ? "com.google.Chrome.canary" : "com.example.Native",
                principalClass: self == .electronPrincipalClass ? "CustomATOMAPPLICATIONSubclass" : "NSApplication",
                hasElectronAsarIntegrity: self == .electronIntegrity || self == .allMarkers ||
                    self == .electronAndCatalyst,
                isCatalyst: self == .catalyst || self == .allMarkers || self == .electronAndCatalyst,
                executableURL: WindowRoutedApplicationClassifierTests.executableURL)
        }

        var expectedKind: WindowRoutedApplicationKind {
            switch self {
            case .native: .appKit
            case .chromium, .allMarkers: .chromium
            case .electronPrincipalClass, .electronIntegrity, .electronAndCatalyst: .electron
            case .catalyst: .catalyst
            }
        }

        var expectedTransport: WindowRoutedPointerTransport {
            self == .native ? .publicCGEvent : .skyLight
        }
    }
}
