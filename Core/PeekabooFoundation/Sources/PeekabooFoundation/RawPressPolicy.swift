import Foundation

/// Public raw keyboard chords cannot prove semantic intent or effect on a shared desktop.
public enum RawPressPolicy {
    public static let foregroundConsentRequiredMessage =
        "Raw key presses cannot be certified as safe background intent and require explicit foreground consent."

    public static let foregroundConsentRequiredHint =
        "Re-run with --foreground in the CLI or foreground=true in MCP. " +
        "For background automation, use action, menu, window, app, or dialog with an exact target."

    public static let errorCode = StandardErrorCode.interactionFailed

    public static var foregroundConsentRefusal: DesktopActionOutcome {
        .refused(reason: .foregroundConsentRequired)
    }
}
