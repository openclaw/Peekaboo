import Foundation
import Testing
@testable import PeekabooAutomationKit

struct WindowRoutedApplicationClassifierTests {
    @Test
    @MainActor
    func `native WebKit import is admitted`() {
        let prefix = Data("/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit".utf8)

        #expect(WindowRoutedApplicationClassifier.kind(
            bundleIdentifier: "com.example.TauriLike",
            principalClass: "NSApplication",
            hasElectronAsarIntegrity: false,
            isCatalyst: false,
            executablePrefix: prefix) == .webKit)
    }

    @Test(arguments: [
        ("com.example.Electron", "AtomApplication", false, false),
        ("com.example.Electron", "NSApplication", true, false),
    ])
    @MainActor
    func `Electron markers override a WebKit-like binary prefix`(
        bundleIdentifier: String,
        principalClass: String,
        hasElectronAsarIntegrity: Bool,
        isCatalyst: Bool)
    {
        let prefix = Data("/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit".utf8)

        #expect(WindowRoutedApplicationClassifier.kind(
            bundleIdentifier: bundleIdentifier,
            principalClass: principalClass,
            hasElectronAsarIntegrity: hasElectronAsarIntegrity,
            isCatalyst: isCatalyst,
            executablePrefix: prefix) == .electron)
    }

    @Test
    @MainActor
    func `Chromium and Catalyst remain outside the WebKit wheel capability`() {
        let prefix = Data("/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit".utf8)

        #expect(WindowRoutedApplicationClassifier.kind(
            bundleIdentifier: "com.google.Chrome.canary",
            principalClass: nil,
            hasElectronAsarIntegrity: false,
            isCatalyst: false,
            executablePrefix: prefix) == .chromium)
        #expect(WindowRoutedApplicationClassifier.kind(
            bundleIdentifier: "com.example.Catalyst",
            principalClass: nil,
            hasElectronAsarIntegrity: false,
            isCatalyst: true,
            executablePrefix: prefix) == .catalyst)
    }

    @Test
    @MainActor
    func `ordinary AppKit executable is not admitted`() {
        #expect(WindowRoutedApplicationClassifier.kind(
            bundleIdentifier: "com.example.Native",
            principalClass: "NSApplication",
            hasElectronAsarIntegrity: false,
            isCatalyst: false,
            executablePrefix: Data("AppKit.framework".utf8)) == .appKit)
    }

    @Test
    @MainActor
    func `hidden or terminated WebKit applications are not admitted`() {
        #expect(WindowRoutedApplicationClassifier.supportsBackgroundWheelScroll(
            isHidden: false,
            isTerminated: false,
            kind: .webKit))
        #expect(!WindowRoutedApplicationClassifier.supportsBackgroundWheelScroll(
            isHidden: true,
            isTerminated: false,
            kind: .webKit))
        #expect(!WindowRoutedApplicationClassifier.supportsBackgroundWheelScroll(
            isHidden: false,
            isTerminated: true,
            kind: .webKit))
        #expect(!WindowRoutedApplicationClassifier.supportsBackgroundWheelScroll(
            isHidden: false,
            isTerminated: false,
            kind: .electron))
    }
}
