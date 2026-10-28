import SwiftUI

struct ChatRootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.loggedIn {
                SessionListView()
            } else {
                LoginView()
            }
        }
    }
}

struct LoginView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("เซิร์ฟเวอร์") {
                TextField("https://dash.thewhome.top", text: $model.baseURLText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }
            Section("ล็อกอิน dashboard") {
                TextField("username", text: $model.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("password", text: $model.password)
            }
            if let error = model.error {
                Section {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
            Section {
                Button {
                    Task { await model.login() }
                } label: {
                    HStack {
                        Spacer()
                        if model.busy { ProgressView() } else { Text("เข้าสู่ระบบ") }
                        Spacer()
                    }
                }
                .disabled(model.busy || model.password.isEmpty)
            }
        }
        .navigationTitle("Hermes")
    }
}

struct SessionListView: View {
    @State private var sessions: [APISession] = []
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        List {
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            ForEach(sessions) { session in
                NavigationLink(value: session) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.displayTitle)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .lineLimit(2)
                        if let preview = session.preview, !preview.isEmpty, preview != session.title {
                            Text(preview)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        HStack(spacing: 10) {
                            if let count = session.message_count { Text("\(count) msgs") }
                            if let when = session.dateText { Text(when) }
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Sessions")
        .navigationDestination(for: APISession.self) { session in
            ChatDetailView(session: session)
        }
        .refreshable { await load() }
        .task { if sessions.isEmpty { await load() } }
        .overlay {
            if loading && sessions.isEmpty {
                ProgressView().controlSize(.large)
            }
        }
    }

    private func load() async {
        loading = true
        error = nil
        do {
            sessions = try await HermesAPI.shared.sessions()
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

struct ChatDetailView: View {
    let session: APISession

    @State private var messages: [APIMessage] = []
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    ForEach(messages) { message in
                        MessageRow(message: message).id(message.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .refreshable { await load(proxy: nil) }
            .task { await load(proxy: proxy) }
            .overlay {
                if loading && messages.isEmpty {
                    ProgressView().controlSize(.large)
                }
            }
        }
        .navigationTitle(session.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func load(proxy: ScrollViewProxy?) async {
        loading = true
        error = nil
        do {
            let loaded = try await HermesAPI.shared.messages(sessionId: session.id)
            messages = loaded
            if let proxy, let last = loaded.last {
                try? await Task.sleep(nanoseconds: 120_000_000)
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

struct MessageRow: View {
    let message: APIMessage
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(message.role.uppercased())
                    .font(.caption2)
                    .fontWeight(.bold)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(roleColor.opacity(0.22))
                    .foregroundStyle(roleColor)
                    .clipShape(Capsule())
                if let tool = message.tool_name {
                    Text(tool).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Text(rendered)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(11)
        .background(Color(white: 0.11))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture { expanded.toggle() }
    }

    private var fullText: String { message.content ?? "" }

    private var visibleText: String {
        if expanded || fullText.count <= 2400 { return fullText }
        return String(fullText.prefix(2400)) + "\n\n… แตะเพื่อแสดงทั้งหมด"
    }

    private var rendered: AttributedString {
        if let attributed = try? AttributedString(
            markdown: visibleText,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attributed
        }
        return AttributedString(visibleText)
    }

    private var roleColor: Color {
        switch message.role {
        case "user": return .cyan
        case "assistant": return .green
        case "tool": return .orange
        case "system": return .gray
        default: return .blue
        }
    }
}