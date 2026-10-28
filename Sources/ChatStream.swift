import Foundation

@MainActor
final class GatewaySocket: ObservableObject {
    @Published var runtimeSessionId: String?
    @Published private(set) var liveText = ""
    @Published private(set) var busy = false
    @Published private(set) var lastError: String?

    private var socket: URLSessionWebSocketTask?
    private var pending: [Int: ([String: Any]) -> Void] = [:]
    private var nextId = 1
    private let urlSession = URLSession(configuration: .default)

    func markBusy() {
        busy = true
        liveText = ""
    }

    func connect(base: URL, ticket: String, clientId: String, clientSecret: String) {
        if socket != nil { return }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.scheme = base.scheme == "https" ? "wss" : "ws"
        var prefix = components.path
        if prefix.hasSuffix("/") { prefix.removeLast() }
        components.path = prefix + "/api/ws"
        components.queryItems = [URLQueryItem(name: "ticket", value: ticket)]
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        if !clientId.isEmpty, !clientSecret.isEmpty {
            request.setValue(clientId, forHTTPHeaderField: "CF-Access-Client-Id")
            request.setValue(clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
        let task = urlSession.webSocketTask(with: request)
        socket = task
        task.resume()
        listen()
    }

    private func listen() {
        socket?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.lastError = error.localizedDescription
                case .success(let message):
                    self.handle(message)
                    self.listen()
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let raw) = message,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let id = object["id"] as? Int, let callback = pending.removeValue(forKey: id) {
            callback(object)
            return
        }
        guard let params = object["params"] as? [String: Any],
              let type = params["type"] as? String else { return }
        let payload = params["payload"] as? [String: Any] ?? [:]
        switch type {
        case "message.start":
            busy = true
            liveText = ""
        case "message.delta":
            if let chunk = payload["text"] as? String { liveText += chunk }
        case "message.complete":
            if let whole = payload["text"] as? String, !whole.isEmpty { liveText = whole }
            busy = false
        default:
            break
        }
    }

    func rpc(_ method: String, _ params: [String: Any], _ done: (([String: Any]) -> Void)? = nil) {
        guard let socket else { return }
        let id = nextId
        nextId += 1
        if let done { pending[id] = done }
        let envelope: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.lastError = error.localizedDescription }
        }
    }
}
