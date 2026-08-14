import Foundation

protocol HarnessTransport {
    func call(_ method: String, payload: [String: Any]) async throws -> [String: Any]
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
        let devices = try await relay.devices()
        guard let host = devices.first(where: { $0.role == "host" }) else { throw TransportError.remote("没有在线的 Host 设备") }
        let requestID = UUID().uuidString.lowercased()
        let value: [String: Any] = ["requestId": requestID, "method": method, "payload": payload]
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
