import UIKit
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
            Section("Cloudflare Service Token (ถ้าใช้)") {
                TextField("Client ID", text: $model.accessClientID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Client Secret", text: $model.accessClientSecret)
            }
            if let error = model.error {
                Section {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
            Section {
                Button("ซิงค์สิทธิ์จากแท็บ Terminal (Cloudflare)") {
                    Task {
                        let synced = await AccessCookieBridge.syncFromWebView()
                        model.error = synced > 0 ? "ซิงค์คุกกี้แล้ว \(synced) รายการ — กดเข้าสู่ระบบอีกครั้ง" : "ยังไม่พบคุกกี้ Cloudflare — ไปล็อกอินที่แท็บ Terminal ก่อน"
                    }
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
            } footer: {
                Text("native chat · build \(AppVersion.text)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
        .navigationTitle("Sessions · \(AppVersion.text)")
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
            self.error = "\(error.localizedDescription) — ถ้าเป็นเรื่องสิทธิ์ ให้ล็อกอิน Cloudflare ที่แท็บ Terminal แล้วกลับมากด refresh"
        }
        loading = false
    }
}

struct ChatDetailView: View {
    let session: APISession

    @State private var messages: [APIMessage] = []
    @State private var error: String?
    @State private var loading = false
    @State private var draft = ""
    @State private var pendingUserText: String?
    @State private var query = ""
    @StateObject private var gateway = GatewaySocket()

    private var filtered: [APIMessage] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return messages }
        return messages.filter { ($0.content ?? "").lowercased().contains(needle) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let error {
                            Text(error).font(.footnote).foregroundStyle(.red)
                        }
                        ForEach(filtered) { message in
                            MessageRow(message: message).id(message.id)
                        }
                        if let pendingUserText {
                            UserBubble(text: pendingUserText).id("pending-user")
                        }
                        if !gateway.liveText.isEmpty {
                            LiveBubble(text: gateway.liveText).id("live-assistant")
                        } else if gateway.busy {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("กำลังตอบ…").font(.caption).foregroundStyle(.secondary)
                            }
                            .id("live-busy")
                        }
                        ForEach(Array(gateway.approvals.enumerated()), id: \.offset) { _, approval in
                            ApprovalCard(approval: approval) { choice in
                                gateway.respondApproval(approval, choice: choice)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .refreshable { await reload(proxy: nil) }
                .task {
                    await reload(proxy: proxy)
                    await openGateway()
                }
                .onChange(of: gateway.liveText) { _ in
                    if !gateway.liveText.isEmpty {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("live-assistant", anchor: .bottom)
                        }
                    }
                }
            }
            composer
        }
        .searchable(text: $query, prompt: "ค้นหาในประวัติ")
        .navigationTitle(session.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("พิมพ์ข้อความ…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color(white: 0.14))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 28))
            }
            .disabled(gateway.runtimeSessionId == nil || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(white: 0.07))
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let runtime = gateway.runtimeSessionId else { return }
        draft = ""
        pendingUserText = text
        gateway.markBusy()
        gateway.rpc("prompt.submit", ["session_id": runtime, "text": text])
    }

    private func reload(proxy: ScrollViewProxy?) async {
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

    private func openGateway() async {
        do {
            let ticket = try await HermesAPI.shared.wsTicket()
            gateway.reconnectHandler = { Task { await openGateway() } }
            gateway.connect(base: HermesAPI.shared.baseURL,
                            ticket: ticket,
                            clientId: HermesAPI.shared.accessClientID,
                            clientSecret: HermesAPI.shared.accessClientSecret)
            try? await Task.sleep(nanoseconds: 400_000_000)
            gateway.rpc("session.resume",
                        ["session_id": session.id, "lazy": true, "omit_messages": true]) { reply in
                let payload = reply["result"] as? [String: Any] ?? [:]
                if let sid = payload["session_id"] as? String {
                    gateway.runtimeSessionId = sid
                    gateway.refreshApprovals()
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ApprovalCard: View {
    let approval: [String: Any]
    let onChoice: (String) -> Void

    private var title: String {
        (approval["title"] as? String)
            ?? (approval["command"] as? String)
            ?? (approval["prompt"] as? String)
            ?? "มีคำขออนุญาต"
    }

    private var detail: String {
        (approval["description"] as? String) ?? (approval["reason"] as? String) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("ต้องอนุมัติ").font(.caption2).fontWeight(.bold)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.yellow.opacity(0.25))
                    .foregroundStyle(.yellow)
                    .clipShape(Capsule())
                Spacer(minLength: 0)
            }
            Text(title).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            if !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button("อนุญาต (ครั้งนี้)") { onChoice("once") }
                    .buttonStyle(.borderedProminent)
                Button("ปฏิเสธ") { onChoice("deny") }
                    .buttonStyle(.bordered)
                Spacer(minLength: 0)
            }
            .font(.caption)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct UserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            Text(text)
                .font(.callout)
                .padding(11)
                .background(Color.cyan.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct LiveBubble: View {
    let text: String

    var body: some View {
        HStack {
            Text(text)
                .font(.callout)
                .padding(11)
                .background(Color.green.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Spacer(minLength: 40)
        }
    }
}

struct MessagePiece: Identifiable {
    let id = UUID()
    let isCode: Bool
    let text: String
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
                if isCollapsedTool {
                    Text("\(fullText.count) ตัวอักษร").font(.caption2).foregroundStyle(.tertiary)
                }
            }

            if isCollapsedTool {
                Text("ผลลัพธ์จากเครื่องมือ — แตะเพื่อเปิดดู")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if pieces.isEmpty {
                Text("(ไม่มีข้อความ)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(pieces) { piece in
                    if piece.isCode {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(piece.text)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HStack {
                                Spacer(minLength: 0)
                                Button {
                                    UIPasteboard.general.string = piece.text
                                } label: {
                                    Label("คัดลอก", systemImage: "doc.on.doc")
                                        .font(.caption2)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(8)
                        .background(Color(white: 0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Text(markdown(piece.text))
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(11)
        .background(Color(white: 0.11))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture { expanded.toggle() }
    }

    private var isCollapsedTool: Bool { message.role == "tool" && !expanded }
    private var fullText: String { message.content ?? "" }

    private var pieces: [MessagePiece] {
        let limit = expanded ? 12000 : 2400
        var text = fullText
        if text.count > limit {
            text = String(text.prefix(limit)) + "\n\n… แตะเพื่อแสดงทั้งหมด"
        }
        var result: [MessagePiece] = []
        var buffer = ""
        var inCode = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if !buffer.isEmpty {
                    result.append(MessagePiece(isCode: inCode, text: buffer))
                    buffer = ""
                }
                inCode.toggle()
                continue
            }
            buffer += buffer.isEmpty ? line : "\n" + line
        }
        if !buffer.isEmpty { result.append(MessagePiece(isCode: inCode, text: buffer)) }
        return result
    }

    private func markdown(_ text: String) -> AttributedString {
        if let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attributed
        }
        return AttributedString(text)
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