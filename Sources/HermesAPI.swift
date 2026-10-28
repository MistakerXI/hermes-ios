import Foundation
import Security
import WebKit

struct APISession: Decodable, Identifiable, Hashable {
    let id: String
    let title: String?
    let preview: String?
    let started_at: Double?
    let last_activity_at: Double?
    let message_count: Int?
    let source: String?
}

struct APIMessage: Decodable, Identifiable {
    let id: String
    let role: String
    let content: String?
    let timestamp: Double?
    let tool_name: String?
}

private struct SessionsResponse: Decodable { let sessions: [APISession] }
private struct MessagesResponse: Decodable { let messages: [APIMessage] }
private struct LoginResponse: Decodable { let ok: Bool? }

enum APIError: LocalizedError {
    case status(Int)
    case unauthorized
    case decoding

    var errorDescription: String? {
        switch self {
        case .status(let code): return "เซิร์ฟเวอร์ตอบ \(code)"
        case .unauthorized: return "ยังไม่ได้ล็อกอิน หรือ session หมดอายุ"
        case .decoding: return "ข้อมูลที่ได้ไม่ตรงรูปแบบ"
        }
    }
}

enum AccessCookieBridge {
    // WebKit initializes its default data store once and hard-kills the process
    // (EXC_BREAKPOINT) when that happens off the main thread — so this whole
    // bridge is main-actor bound, never called from a cooperative thread.
    @MainActor
    static func syncFromWebView() async -> Int {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                var copied = 0
                for cookie in cookies {
                    let domain = cookie.domain
                    guard domain.contains("thewhome.top") || domain.contains("cloudflareaccess.com") else { continue }
                    HTTPCookieStorage.shared.setCookie(cookie)
                    copied += 1
                }
                continuation.resume(returning: copied)
            }
        }
    }
}

enum AppVersion {
    static var text: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

final class HermesAPI {
    static let shared = HermesAPI()

    var baseURL = URL(string: "https://dash.thewhome.top")!
    private let http = URLSession.shared
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private func url(_ path: String, _ query: [String: String] = [:]) -> URL {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        var basePath = comps.path
        if basePath.hasSuffix("/") { basePath.removeLast() }
        comps.path = basePath + "/" + path
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return comps.url!
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await http.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw APIError.status(-1) }
        if status == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(status) else { throw APIError.status(status) }
        return data
    }

    func login(username: String, password: String) async throws {
        var request = URLRequest(url: url("auth/password-login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(["provider": "basic", "username": username, "password": password])
        let data = try await send(request)
        if let out = try? decoder.decode(LoginResponse.self, from: data), out.ok == false {
            throw APIError.status(403)
        }
    }

    func isLoggedIn() async -> Bool {
        var request = URLRequest(url: url("api/auth/me"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (_, response) = try? await http.data(for: request),
              let reply = response as? HTTPURLResponse else { return false }
        // A Cloudflare Access redirect also finishes as 200 — but on the Access
        // host and as HTML, so require our own host plus a JSON content type.
        guard reply.url?.host == baseURL.host else { return false }
        let type = (reply.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        return reply.statusCode == 200 && type.contains("json")
    }

    func sessions(limit: Int = 60) async throws -> [APISession] {
        let request = URLRequest(url: url("api/sessions", ["limit": "\(limit)", "offset": "0", "order": "latest"]))
        let data = try await send(request)
        guard let out = try? decoder.decode(SessionsResponse.self, from: data) else { throw APIError.decoding }
        return out.sessions
    }

    func messages(sessionId: String, limit: Int = 300, offset: Int = 0) async throws -> [APIMessage] {
        let request = URLRequest(url: url("api/sessions/\(sessionId)/messages",
                                          ["limit": "\(limit)", "offset": "\(offset)", "order": "oldest", "inline_images": "false"]))
        let data = try await send(request)
        guard let out = try? decoder.decode(MessagesResponse.self, from: data) else { throw APIError.decoding }
        return out.messages
    }
}

enum Credentials {
    struct Saved {
        var baseURL: String
        var username: String
        var password: String
    }

    private static let service = "top.thewhome.hermes"

    static func load() -> Saved {
        let defaults = UserDefaults.standard
        return Saved(baseURL: defaults.string(forKey: "baseURL") ?? "https://dash.thewhome.top",
                     username: defaults.string(forKey: "username") ?? "thew",
                     password: readPassword() ?? "")
    }

    static func save(baseURL: String, username: String, password: String) {
        let defaults = UserDefaults.standard
        defaults.set(baseURL, forKey: "baseURL")
        defaults.set(username, forKey: "username")
        writePassword(password)
    }

    private static func writePassword(_ password: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func readPassword() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var baseURLText: String
    @Published var username: String
    @Published var password: String
    @Published var loggedIn = false
    @Published var busy = false
    @Published var error: String?

    init() {
        let saved = Credentials.load()
        baseURLText = saved.baseURL
        username = saved.username
        password = saved.password
        HermesAPI.shared.baseURL = URL(string: saved.baseURL) ?? HermesAPI.shared.baseURL
    }

    func bootstrap() async {
        _ = await AccessCookieBridge.syncFromWebView()
        if await HermesAPI.shared.isLoggedIn() { loggedIn = true }
    }

    func login() async {
        busy = true
        error = nil
        HermesAPI.shared.baseURL = URL(string: baseURLText) ?? HermesAPI.shared.baseURL
        do {
            _ = await AccessCookieBridge.syncFromWebView()
            try await HermesAPI.shared.login(username: username, password: password)
            Credentials.save(baseURL: baseURLText, username: username, password: password)
            loggedIn = true
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }
}

extension APISession {
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let preview, !preview.isEmpty { return preview }
        return "(ไม่มีชื่อ)"
    }

    var dateText: String? {
        guard let stamp = last_activity_at ?? started_at else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: Date(timeIntervalSince1970: stamp), relativeTo: Date())
    }
}