import Testing
@testable import PeekabooBridge

struct DesktopObservationWindowTitleAgreementTests {
    @Test
    func `identical titles agree`() {
        #expect(PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            "Report", "Report", applicationName: "TextEdit"))
    }

    @Test
    func `accessibility title with application suffix matches bare window-server title`() {
        // Chrome reports "Document - Google Chrome" through Accessibility while CoreGraphics
        // reports the bare "Document"; both identify the same window.
        #expect(PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            "SM100 - DeepSeek - Google Chrome",
            "SM100 - DeepSeek",
            applicationName: "Google Chrome"))
    }

    @Test
    func `window-server title with application suffix matches bare accessibility title`() {
        #expect(PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            "SM100 - DeepSeek",
            "SM100 - DeepSeek - Google Chrome",
            applicationName: "Google Chrome"))
    }

    @Test
    func `surrounding whitespace is ignored`() {
        #expect(PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            "  Report  ", "Report", applicationName: "TextEdit"))
    }

    @Test
    func `different documents are rejected`() {
        #expect(!PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            "Document A - Google Chrome", "Document B", applicationName: "Google Chrome"))
    }

    @Test
    func `suffix naming a different application is rejected`() {
        #expect(!PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            "Doc - Safari", "Doc", applicationName: "Google Chrome"))
    }

    @Test
    func `suffix without the separator space is rejected`() {
        // "Doc - Chrome" is not the documented " - <applicationName>" form for "Google Chrome",
        // and it is not the localized profile decoration " - Chrome - {profile}" either.
        #expect(!PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            "Doc - Chrome", "Doc", applicationName: "Google Chrome"))
    }

    @Test
    func `prefix collision is rejected`() {
        #expect(!PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            "DocX - Google Chrome", "Doc", applicationName: "Google Chrome"))
    }

    @Test
    func `empty candidate is rejected`() {
        #expect(!PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            "", "Doc", applicationName: "Google Chrome"))
    }

    @Test
    func `suffix difference without a known application name is rejected`() {
        #expect(!PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            "Doc - Google Chrome", "Doc", applicationName: nil))
        #expect(!PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            "Doc - Google Chrome", "Doc", applicationName: "   "))
    }

    // MARK: - Localized Chrome profile decoration

    /// Korean stable Chrome (multiple profiles) exposes
    /// "{page} - Chrome - {profile}" through Accessibility while CoreGraphics keeps "{page}".
    /// The macOS application name remains "Google Chrome".
    @Test
    func `localized chrome profile title matches the bare document title`() {
        #expect(PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            "Peekaboo title test - Chrome - Work",
            "Peekaboo title test",
            applicationName: "Google Chrome"))
        #expect(PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            "  Peekaboo title test - Chrome - Work  ",
            "Peekaboo title test",
            applicationName: "Google Chrome"))
    }

    @Test
    func `localized chrome profile title matches regardless of argument order`() {
        #expect(PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            "Peekaboo title test",
            "Peekaboo title test - Chrome - Work",
            applicationName: "Google Chrome"))
    }

    @Test
    func `localized chrome profile title keeps a different document rejected`() {
        #expect(!PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            "Document A - Chrome - Work",
            "Document B",
            applicationName: "Google Chrome"))
    }

    @Test
    func `localized chrome profile decoration does not match a partial document`() {
        #expect(!PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            "Peekaboo title test - Chrome - Work",
            "Peekaboo",
            applicationName: "Google Chrome"))
        #expect(!PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            "DocX - Chrome - Work",
            "Doc",
            applicationName: "Google Chrome"))
    }

    @Test
    func `localized chrome profile decoration is tied to google chrome`() {
        #expect(!PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            "Peekaboo title test - Chrome - Work",
            "Peekaboo title test",
            applicationName: "Safari"))
        #expect(!PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            "Peekaboo title test - Chrome - Work",
            "Peekaboo title test",
            applicationName: "Google Chrome Canary"))
        #expect(!PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            "Peekaboo title test - Chrome - Work",
            "Peekaboo title test",
            applicationName: nil))
        #expect(!PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            "Peekaboo title test - Chrome - Work",
            "Peekaboo title test",
            applicationName: "   "))
    }

    @Test
    func `empty chrome profile decoration is rejected`() {
        #expect(!PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            "Doc - Chrome -",
            "Doc",
            applicationName: "Google Chrome"))
        #expect(!PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            "Doc - Chrome -   ",
            "Doc",
            applicationName: "Google Chrome"))
    }

    @Test
    func `a different title that merely contains the chrome profile marker is rejected`() {
        #expect(!PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            "Doc - Chrome - Work - extra",
            "Doc - Chrome - Work",
            applicationName: "Google Chrome"))
        #expect(!PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            "Peekaboo title test \u{2013} Chrome \u{2013} Work",
            "Peekaboo title test",
            applicationName: "Google Chrome"))
    }

    /// The profile marker is removed before middle-elision, so a long AX title
    /// "{page} - Chrome - {profile}" still agrees with a WindowServer-elided "{page}".
    @Test
    func `localized chrome profile decoration matches an elided document title`() {
        let decorated = "Guide for authors - Linguistics and Education | Elsevier - Chrome - Work"
        let elided = "Guide for authors - Linguistics \u{2026} | Elsevier"
        #expect(PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            decorated,
            elided,
            applicationName: "Google Chrome"))
        #expect(PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            elided,
            decorated,
            applicationName: "Google Chrome"))
        #expect(!PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            decorated,
            "Guide for authors - Linguistics \u{2026} | Somewhere else",
            applicationName: "Google Chrome"))
    }

    /// " - Google Chrome" inside the page is document text. Stripping it before the profile
    /// grammar would turn the CoreGraphics title into "Download" and reject the real pair.
    @Test
    func `localized chrome profile decoration preserves a document ending in the application name`() {
        let decorated = "Download - Google Chrome - Chrome - Work"
        let document = "Download - Google Chrome"
        #expect(PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            decorated,
            document,
            applicationName: "Google Chrome"))
        #expect(PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            document,
            decorated,
            applicationName: "Google Chrome"))
        #expect(!PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            decorated,
            "Download",
            applicationName: "Google Chrome"))
        #expect(!PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            decorated,
            "Upload - Google Chrome",
            applicationName: "Google Chrome"))
    }

    /// A profile whose name is the application name must stay part of the decoration.
    @Test
    func `localized chrome profile decoration keeps an opaque profile named google chrome`() {
        #expect(PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            "Doc - Chrome - Google Chrome",
            "Doc",
            applicationName: "Google Chrome"))
        #expect(PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            "Doc",
            "Doc - Chrome - Google Chrome",
            applicationName: "Google Chrome"))
        #expect(PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            "Doc - Chrome - Google Chrome",
            "Doc - Google Chrome",
            applicationName: "Google Chrome"))
    }

    // MARK: - WindowServer middle elision

    /// Captured from a live Chrome window: CoreGraphics elides the middle of the long title
    /// with a single U+2026 while Accessibility retains the full text and its app suffix.
    private static let elidedTitle =
        "Guide for authors - Linguistics \u{2026} | ScienceDirect.com by Elsevier"
    private static let fullAccessibilityTitle =
        "Guide for authors - Linguistics and Education - ISSN 0898-5898 | " +
        "ScienceDirect.com by Elsevier - Google Chrome"

    @Test
    func `window-server elided title matches the full accessibility title`() {
        #expect(PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            Self.fullAccessibilityTitle,
            Self.elidedTitle,
            applicationName: "Google Chrome"))
    }

    @Test
    func `elided title matches the full title regardless of argument order`() {
        #expect(PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            Self.elidedTitle,
            Self.fullAccessibilityTitle,
            applicationName: "Google Chrome"))
    }

    /// Regression: when both layers carry a U+2026, a miss in the first orientation must not
    /// prevent the reverse orientation from matching.
    @Test
    func `elided title matches when both sides contain an ellipsis`() {
        #expect(PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            "Weekly digest \u{2026} issue 42 and more | Example.com - Google Chrome",
            "Weekly digest \u{2026} issue 42 and \u{2026} | Example.com",
            applicationName: "Google Chrome"))
    }

    @Test
    func `elided titles whose fragments are reordered are rejected`() {
        #expect(!PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            "Weekly digest \u{2026} issue 42 and more | Example.com - Google Chrome",
            "issue 42 and \u{2026} Weekly digest | Example.com",
            applicationName: "Google Chrome"))
    }

    @Test
    func `elided title with unrelated visible fragments is rejected`() {
        #expect(!PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            "Unrelated heading \u{2026} Nope", Self.fullAccessibilityTitle, applicationName: "Google Chrome"))
    }

    @Test
    func `elided title whose tail does not match is rejected`() {
        #expect(!PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            "Guide for authors \u{2026} Different site", Self.fullAccessibilityTitle, applicationName: "Google Chrome"))
    }

    @Test
    func `elided title without a known application name is rejected`() {
        // Without the application name the Accessibility suffix cannot be stripped, so the
        // elided tail cannot be proven to belong to the same title.
        #expect(!PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            Self.elidedTitle, Self.fullAccessibilityTitle, applicationName: nil))
    }

    @Test
    func `edge or doubled ellipses are not middle elision`() {
        for elided in [
            "Report \u{2026} Site \u{2026}",
            "\u{2026} Report \u{2026} Site",
            "Report \u{2026}\u{2026} Site",
        ] {
            #expect(!PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
                elided,
                "Report confidential Site",
                applicationName: nil))
        }
        #expect(PeekabooBridgeDesktopObservationBinding.windowTitlesAgree(
            "Report \u{2026} Site",
            "Report confidential Site",
            applicationName: nil))
    }
}
