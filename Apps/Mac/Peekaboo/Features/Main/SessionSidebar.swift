import PeekabooCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Session Sidebar

struct SessionSidebar: View {
    @Environment(SessionStore.self) private var sessionStore
    @Environment(PeekabooAgent.self) private var agent

    @Binding var selectedSessionId: String?
    @Binding var searchText: String

    private var filteredSessions: [ConversationSession] {
        if self.searchText.isEmpty {
            self.sessionStore.sessions
        } else {
            self.sessionStore.sessions.filter { session in
                session.title.localizedCaseInsensitiveContains(self.searchText) ||
                    session.summary.localizedCaseInsensitiveContains(self.searchText) ||
                    session.messages.contains { message in
                        message.content.localizedCaseInsensitiveContains(self.searchText)
                    }
            }
        }
    }

    var body: some View {
        List(self.filteredSessions, selection: self.$selectedSessionId) { session in
            SessionRow(
                session: session,
                isActive: self.agent.currentSession?.id == session.id)
                .tag(session.id)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        self.deleteSession(session)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button("Duplicate") {
                        self.duplicateSession(session)
                    }
                    Button("Export…") {
                        self.exportSession(session)
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        self.deleteSession(session)
                    }
                }
        }
        .listStyle(.sidebar)
        .searchable(text: self.$searchText, prompt: "Search Sessions")
        .overlay {
            if self.filteredSessions.isEmpty {
                if self.searchText.isEmpty {
                    ContentUnavailableView {
                        Label {
                            Text("No Sessions")
                        } icon: {
                            GhostImageView(state: .idle, size: CGSize(width: 56, height: 56))
                        }
                    } description: {
                        Text("Conversations with Peekaboo will appear here.")
                    }
                } else {
                    ContentUnavailableView.search(text: self.searchText)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button(action: self.createNewSession) {
                    Label("New Session", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("New Session (⌘N)")
            }
        }
        .onDeleteCommand {
            // Delete the currently selected session
            if let selectedId = selectedSessionId,
               let session = sessionStore.sessions.first(where: { $0.id == selectedId }),
               session.id != agent.currentSession?.id
            {
                self.deleteSession(session)
            }
        }
    }

    private func createNewSession() {
        let newSession = self.sessionStore.createSession(title: "New Session")
        self.selectedSessionId = newSession.id
    }

    private func deleteSession(_ session: ConversationSession) {
        // Don't delete active session
        guard session.id != self.agent.currentSession?.id else { return }

        self.sessionStore.sessions.removeAll { $0.id == session.id }
        Task { @MainActor in
            self.sessionStore.saveSessions()
        }

        if self.selectedSessionId == session.id {
            self.selectedSessionId = nil
        }
    }

    private func duplicateSession(_ session: ConversationSession) {
        var newSession = ConversationSession(title: "\(session.title) (Copy)")
        newSession.messages = session.messages
        newSession.summary = session.summary

        self.sessionStore.sessions.insert(newSession, at: 0)
        Task { @MainActor in
            self.sessionStore.saveSessions()
        }

        self.selectedSessionId = newSession.id
    }

    private func exportSession(_ session: ConversationSession) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = "\(session.title).json"

        savePanel.begin { response in
            guard response == .OK else { return }

            // Capture URL on main thread before Task
            Task { @MainActor in
                guard let url = savePanel.url else { return }

                do {
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    encoder.outputFormatting = .prettyPrinted
                    let data = try encoder.encode(session)
                    try data.write(to: url)
                } catch {
                    print("Failed to export session: \(error)")
                }
            }
        }
    }
}

// MARK: - Session Row

struct SessionRow: View {
    let session: ConversationSession
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if self.isActive {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.green)
                        .symbolEffect(.pulse, options: .repeating)
                }

                Text(self.session.title)
                    .fontWeight(self.isActive ? .semibold : .regular)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(
                    self.session.startTime,
                    format: .relative(presentation: .named, unitsStyle: .abbreviated))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if !self.session.summary.isEmpty {
                Text(self.session.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 6) {
                if !self.session.messages.isEmpty {
                    Text("^[\(self.session.messages.count) message](inflect: true)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if !self.session.modelName.isEmpty {
                    Text(formatModelName(self.session.modelName))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }
}
