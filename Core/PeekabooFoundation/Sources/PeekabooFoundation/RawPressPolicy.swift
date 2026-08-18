import Foundation

/// Public raw keyboard chords cannot prove semantic intent or effect on a shared desktop.
public enum RawPressPolicy {
    public static let foregroundConsentRequiredMessage =
        "Raw key presses require explicit foreground consent unless a fresh exact receipt pins background delivery."

    public static let foregroundConsentRequiredHint =
        "Use a fresh exact non-dialog snapshot for background Agent/MCP delivery, an exact window/snapshot receipt " +
        "where the direct CLI permits it, or re-run with --foreground in the CLI / foreground=true in a " +
        "foreground-capable MCP session. Prefer a semantic action when one exists."

    public static let errorCode = StandardErrorCode.interactionFailed

    public static var foregroundConsentRefusal: DesktopActionOutcome {
        .refused(reason: .foregroundConsentRequired)
    }
}
