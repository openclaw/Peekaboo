import Combine
import PeekabooCore
import SwiftUI

struct SessionMainWindow: View {
    @Environment(SessionStore.self) private var sessionStore
    @Environment(PeekabooAgent.self) private var agent

    var initialSessionId: String?
    @State private var selectedSessionId: String?
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            SessionSidebar(
                selectedSessionId: self.$selectedSessionId,
                searchText: self.$searchText)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
        } detail: {
            SessionDetailContainer(
                selectedSessionId: self.selectedSessionId,
                acceptsInput: self.initialSessionId != nil)
                .toolbar(removing: .sidebarToggle)
        }
        .navigationTitle("Peekaboo Sessions")
        .onAppear {
            self.selectedSessionId = SessionWindowSelection.initialSelection(
                openedSessionId: self.initialSessionId,
                activeSessionId: self.sessionStore.currentSession?.id)
        }
        .onChange(of: self.sessionStore.currentSession?.id) { _, newId in
            // The main window follows the active chat. A window opened for one
            // session stays on that session, so a later active chat cannot replace it.
            guard SessionWindowSelection.followsActiveSession(openedSessionId: self.initialSessionId) else {
                return
            }
            self.selectedSessionId = newId
        }
    }
}

enum SessionWindowSelection {
    static func initialSelection(openedSessionId: String?, activeSessionId: String?) -> String? {
        openedSessionId ?? activeSessionId
    }

    static func followsActiveSession(openedSessionId: String?) -> Bool {
        openedSessionId == nil
    }

    static func showsComposer(
        sessionId: String,
        activeSessionId: String?,
        windowKeepsOpenedSession: Bool) -> Bool
    {
        windowKeepsOpenedSession || sessionId == activeSessionId
    }
}

// MARK: - Session Detail Container

struct SessionDetailContainer: View {
    @Environment(SessionStore.self) private var sessionStore
    @Environment(PeekabooAgent.self) private var agent

    let selectedSessionId: String?
    var acceptsInput = false

    var body: some View {
        if let sessionId = selectedSessionId,
           let session = sessionStore.sessions.first(where: { $0.id == sessionId })
        {
            SessionChatView(session: session, acceptsInput: self.acceptsInput)
        } else if let currentSession = sessionStore.currentSession {
            SessionChatView(session: currentSession, acceptsInput: self.acceptsInput)
        } else {
            EmptySessionView()
        }
    }
}

#Preview {
    let settings = PeekabooSettings()
    SessionMainWindow()
        .environment(SessionStore())
        .environment(PeekabooAgent(settings: settings, sessionStore: SessionStore()))
        .environment(Permissions())
}
