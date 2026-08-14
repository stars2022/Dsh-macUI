import CryptoKit
import Foundation
import UIKit

@MainActor
final class PairingCoordinator: ObservableObject {
    @Published var status = ""
    @Published var busy = false

    func pair(profile: ServerProfile, code: String) async throws -> RelayCredential {
        busy = true
        defer { busy = false }
        let identity = try VaultCrypto.identity(account: "pairing.identity.\(profile.id.uuidString)")
        let publicKey = identity.publicKey.x963Representation.base64URLEncodedString()
        let relay = RelayClient(baseURL: profile.baseURL)
        status = "正在提交配对请求…"
        let claim = try await relay.claim(code: code.uppercased(), deviceName: UIDevice.current.name, publicKey: publicKey)
        status = "请在 Mac 上批准这台设备"

        for _ in 0..<90 {
            let value = try await relay.claimStatus(id: claim.claimId, secret: claim.claimSecret)
            if value.status == "approved" {
                guard let deviceID = value.deviceId, let token = value.accessToken,
                      let wrapped = value.wrappedVaultKey, let approver = value.approverPublicKey else {
                    throw TransportError.invalidResponse
                }
                let wrapping = try VaultCrypto.wrappingKey(privateKey: identity, peerPublicKey: approver,
                                                           salt: Data(claim.vaultId.utf8))
                let keyData = wrapping.withUnsafeBytes { Data($0) }
                let aad = Data("dsh-pairing-v1:\(claim.vaultId):\(claim.claimId)".utf8)
                let vaultKey = try VaultCrypto.open(wrapped, keyData: keyData, aad: aad)
                let credential = RelayCredential(vaultId: claim.vaultId, deviceId: deviceID,
                                                 accessToken: token, vaultKey: vaultKey)
                try KeychainStore.setCredential(credential, profileID: profile.id)
                status = "配对完成"
                return credential
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw TransportError.remote("配对审批超时，请重新生成配对码")
    }
}
