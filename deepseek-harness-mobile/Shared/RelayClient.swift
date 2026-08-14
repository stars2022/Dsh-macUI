import Foundation

struct RelayDevice: Decodable, Identifiable { let id: String; let deviceName: String; let role: String; let publicKey: String }
struct RelayFrame: Decodable { let cursor: Int; let kind: String; let senderDeviceId: String; let envelope: EncryptedEnvelope }
struct RelayFramePage: Decodable { let cursor: Int; let items: [RelayFrame] }

final class RelayClient {
    let baseURL: URL
    var accessToken: String?

    init(baseURL: URL, accessToken: String? = nil) { self.baseURL = baseURL; self.accessToken = accessToken }

    func devices() async throws -> [RelayDevice] {
        let data = try await request("GET", "v1/devices")
        return try JSONDecoder().decode(DevicePage.self, from: data).items
    }

    func send(kind: String, recipientDeviceID: String?, envelope: EncryptedEnvelope) async throws {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as! [String: Any]
        object["kind"] = kind
        if let recipientDeviceID { object["recipientDeviceId"] = recipientDeviceID }
        _ = try await request("POST", "v1/relay/frames", object: object)
    }

    func frames(after: Int, wait: Int) async throws -> RelayFramePage {
        let data = try await request("GET", "v1/relay/frames?after=\(after)&wait=\(wait)")
        return try JSONDecoder().decode(RelayFramePage.self, from: data)
    }

    func claim(code: String, deviceName: String, publicKey: String) async throws -> PairingClaim {
        let data = try await request("POST", "v1/pairings/claim", object: ["code": code, "deviceName": deviceName, "role": "mobile", "publicKey": publicKey])
        return try JSONDecoder().decode(PairingClaim.self, from: data)
    }

    func claimStatus(id: String, secret: String) async throws -> PairingClaimStatus {
        let prior = accessToken; accessToken = secret
        defer { accessToken = prior }
        let data = try await request("GET", "v1/pairing-claims/\(id)")
        return try JSONDecoder().decode(PairingClaimStatus.self, from: data)
    }

    private func request(_ method: String, _ path: String, object: [String: Any]? = nil) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { throw TransportError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 35
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        if let object {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: object)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = body["error"] as? [String: Any], let message = error["message"] as? String { throw TransportError.remote(message) }
            throw TransportError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }
}

private struct DevicePage: Decodable { let items: [RelayDevice] }
struct PairingClaim: Decodable { let claimId: String; let claimSecret: String; let vaultId: String; let pairingId: String }
struct PairingClaimStatus: Decodable {
    let status: String
    let vaultId: String?
    let deviceId: String?
    let accessToken: String?
    let wrappedVaultKey: EncryptedEnvelope?
    let approverPublicKey: String?
}
