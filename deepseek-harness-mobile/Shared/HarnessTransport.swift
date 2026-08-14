import Foundation

protocol HarnessTransport {
    func call(_ method: String, payload: [String: Any]) async throws -> [String: Any]
    func respond(rpcID: String, result: [String: Any]) async throws
}

struct DirectHarnessTransport: HarnessTransport {
    let baseURL: URL

    func call(_ method: String, payload: [String: Any]) async throws -> [String: Any] {
        let rpcID = UUID().uuidString.lowercased()
        let body: [String: Any] = ["type": "client-request", "rpcId": rpcID, "method": method, "payload": payload]
        var request = URLRequest(url: baseURL.appendingPathComponent("api/\(method)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw TransportError.http((response as? HTTPURLResponse)?.statusCode ?? 0) }
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["rpcId"] as? String == rpcID,
              let result = envelope["result"] as? [String: Any] else { throw TransportError.invalidResponse }
        if result["ok"] as? Bool == true {
            if let value = result["value"] as? [String: Any] { return value }
            if let value = result["value"] as? [[String: Any]] { return ["_array": value] }
            return [:]
        }
        let detail = result["error"] as? [String: Any]
        throw TransportError.remote(detail?["message"] as? String ?? detail?["code"] as? String ?? "Host request failed")
    }

    func respond(rpcID: String, result: [String: Any]) async throws {
        let body: [String: Any] = ["type": "client-response", "rpcId": rpcID, "result": result]
        var request = URLRequest(url: baseURL.appendingPathComponent("api/respond"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw TransportError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let receipt = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TransportError.invalidResponse
        }
        guard receipt["accepted"] as? Bool == true else {
            throw TransportError.remote(receipt["reason"] as? String ?? "Host 已不再等待这个审核结果")
        }
    }
}

final class RemoteRelayTransport: HarnessTransport {
    let relay: RelayClient
    let credential: RelayCredential
    private var cursor = 0

    init(baseURL: URL, credential: RelayCredential) {
        relay = RelayClient(baseURL: baseURL, accessToken: credential.accessToken)
        self.credential = credential
    }

    func call(_ method: String, payload: [String: Any]) async throws -> [String: Any] {
        try await exchange(["method": method, "payload": payload])
    }

    func respond(rpcID: String, result: [String: Any]) async throws {
        // The paired Mac relay agent forwards this carrier to POST /api/respond.
        // Keeping it inside the same encrypted host.rpc.request channel means
        // the relay never learns the approval decision or its correlation id.
        _ = try await exchange(["response": [
            "type": "client-response", "rpcId": rpcID, "result": result,
        ]])
    }

    private func exchange(_ request: [String: Any]) async throws -> [String: Any] {
        let devices = try await relay.devices()
        guard let host = devices.first(where: { $0.role == "host" }) else { throw TransportError.remote("没有在线的 Host 设备") }
        let requestID = UUID().uuidString.lowercased()
        var value = request
        value["requestId"] = requestID
        let plaintext = try JSONSerialization.data(withJSONObject: value)
        let aad = Data("dsh-relay-v1:\(credential.vaultId):host.rpc.request".utf8)
        let envelope = try VaultCrypto.seal(plaintext, keyData: credential.vaultKey, aad: aad)
        try await relay.send(kind: "host.rpc.request", recipientDeviceID: host.id, envelope: envelope)

        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            let result = try await relay.frames(after: cursor, wait: 20)
            cursor = max(cursor, result.cursor)
            for frame in result.items where frame.kind == "host.rpc.response" {
                let responseAAD = Data("dsh-relay-v1:\(credential.vaultId):host.rpc.response".utf8)
                let decoded = try VaultCrypto.open(frame.envelope, keyData: credential.vaultKey, aad: responseAAD)
                guard let object = try JSONSerialization.jsonObject(with: decoded) as? [String: Any],
                      object["requestId"] as? String == requestID else { continue }
                if let error = object["error"] as? String { throw TransportError.remote(error) }
                return object["value"] as? [String: Any] ?? [:]
            }
        }
        throw TransportError.remote("等待 Mac Host 响应超时")
    }
}

enum TransportError: LocalizedError {
    case http(Int), invalidResponse, remote(String), notPaired
    var errorDescription: String? {
        switch self {
        case let .http(status): return "HTTP \(status)"
        case .invalidResponse: return "服务器返回了无效数据"
        case let .remote(message): return message
        case .notPaired: return "这个加密服务端尚未完成设备配对"
        }
    }
}

/// Local Host mux stream. It owns its retry loop so transient Wi-Fi changes do
/// not turn into modal errors or require the user to tap Refresh.
@MainActor
final class MobileEventStream {
    private var socket: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var generation = 0
    private var enabled = false
    private var baseURL: URL?
    var onFrame: (([String: Any]) -> Void)?
    var onConnectionState: ((Bool) -> Void)?

    func connect(baseURL: URL) {
        self.baseURL = baseURL
        enabled = true
        generation &+= 1
        start(generation: generation)
    }

    func disconnect() {
        enabled = false
        generation &+= 1
        receiveLoop?.cancel()
        receiveLoop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func start(generation expectedGeneration: Int) {
        guard enabled, expectedGeneration == generation, let baseURL else { return }
        receiveLoop?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        var components = URLComponents(url: baseURL.appendingPathComponent("api/events.mux"), resolvingAgainstBaseURL: false)
        let secure = components?.scheme == "https"
        components?.scheme = secure ? "wss" : "ws"
        guard let url = components?.url else { return }
        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()
        receiveLoop = Task { [weak self, weak task] in
            guard let self, let task else { return }
            var announcedConnected = false
            do {
                while !Task.isCancelled, self.enabled, expectedGeneration == self.generation {
                    let message = try await task.receive()
                    if !announcedConnected {
                        announcedConnected = true
                        self.onConnectionState?(true)
                    }
                    let data: Data?
                    switch message {
                    case let .string(text): data = text.data(using: .utf8)
                    case let .data(value): data = value
                    @unknown default: data = nil
                    }
                    if let data,
                       let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       var payload = envelope["payload"] as? [String: Any] {
                        if let rpcID = envelope["rpcId"] as? String { payload["_rpcId"] = rpcID }
                        self.onFrame?(payload)
                    }
                }
            } catch {
                guard self.enabled, expectedGeneration == self.generation, !Task.isCancelled else { return }
                self.onConnectionState?(false)
                try? await Task.sleep(for: .seconds(2))
                guard self.enabled, expectedGeneration == self.generation, !Task.isCancelled else { return }
                self.start(generation: expectedGeneration)
            }
        }
    }
}
