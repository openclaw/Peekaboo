import Commander

/// Manipulate application windows with various actions
@MainActor
struct WindowCommand: ParsableCommand {
    static let commandDescription = CommandDescription(
        commandName: "window",
        abstract: "Manipulate application windows",
        discussion: """
        SYNOPSIS:
          peekaboo window SUBCOMMAND [OPTIONS]

        DESCRIPTION:
          Provides window manipulation capabilities including closing, minimizing,
          restoring, maximizing, moving, resizing, and focusing windows.

        EXAMPLES:
          # Close a window
          peekaboo window close --app Safari
          peekaboo window close --app Safari --window-title "GitHub"
          peekaboo window close --window-id 12345

          # Minimize/restore/maximize windows
          peekaboo window minimize --app Finder
          peekaboo window restore --app Finder --window-id 12345
          peekaboo window maximize --app Terminal

          # Move and resize windows
          peekaboo window move --app TextEdit --x 100 --y 100
          peekaboo window resize --app Safari --width 1200 --height 800
          peekaboo window set-bounds --app Chrome --x 50 --y 50 --width 1024 --height 768

          # Focus a window
          peekaboo window focus --app "Visual Studio Code"
          peekaboo window focus --app Safari --window-title "Apple"
          peekaboo window focus --window-id 12345

          # List windows (convenience shortcut)
          peekaboo window list --app Safari

        SUBCOMMANDS:
          close         Close a window
          minimize      Minimize a window to the Dock
          restore       Restore a minimized window without activation or focus
          maximize      Fill the target screen's visible bounds without entering full screen
          move          Move a window to a new position
          resize        Resize a window
          set-bounds    Set window position and size in one operation
          focus         Bring a window to the foreground
          list          List windows for an application

        OUTPUT FORMAT:
          Default output is human-readable text.
          Use --json for machine-readable JSON format.
        """,
        subcommands: [
            CloseSubcommand.self,
            MinimizeSubcommand.self,
            RestoreSubcommand.self,
            MaximizeSubcommand.self,
            MoveSubcommand.self,
            ResizeSubcommand.self,
            SetBoundsSubcommand.self,
            FocusSubcommand.self,
            WindowListSubcommand.self,
        ],
        showHelpOnEmptyInvocation: true
    )
}
