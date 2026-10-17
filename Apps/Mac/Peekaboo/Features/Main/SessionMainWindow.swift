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
            SessionDetailContainer(selectedSessionId: self.selectedSessionId)
                .toolbar(removing: .sidebarToggle)
        }
        .navigationTitle("Peekaboo Sessions")
        .onAppear {
            self.selectedSessionId = self.initialSessionId ?? self.sessionStore.currentSession?.id
        }
        .onChange(of: self.sessionStore.currentSession?.id) { _, newId in
            self.selectedSessionId = newId
        }
    }
}

// MARK: - Session Detail Container

struct SessionDetailContainer: View {
    @Environment(SessionStore.self) private var sessionStore
    @Environment(PeekabooAgent.self) private var agent

    let selectedSessionId: String?

    var body: some View {
        if let sessionId = selectedSessionId,
           let session = sessionStore.sessions.first(where: { $0.id == sessionId })
        {
            SessionChatView(session: session)
        } else if let currentSession = sessionStore.currentSession {
            SessionChatView(session: currentSession)
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
