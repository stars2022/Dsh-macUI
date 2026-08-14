import CryptoKit
import Foundation

struct EncryptedEnvelope: Codable {
    var algorithm = "AES.GCM.256"
    let nonce: String
    let ciphertext: String
    let tag: String
    let aad: String?
}

enum VaultCrypto {
    static func makeVaultKey() -> Data {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    }

    static func seal(_ plaintext: Data, keyData: Data, aad: Data) throws -> EncryptedEnvelope {
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: keyData), authenticating: aad)
        let nonce = sealed.nonce.withUnsafeBytes { Data($0) }
        return EncryptedEnvelope(nonce: nonce.base64URLEncodedString(),
                                 ciphertext: sealed.ciphertext.base64URLEncodedString(),
                                 tag: sealed.tag.base64URLEncodedString(),
                                 aad: aad.base64URLEncodedString())
    }

    static func open(_ envelope: EncryptedEnvelope, keyData: Data, aad: Data) throws -> Data {
        guard let nonce = Data(base64URL: envelope.nonce),
              let ciphertext = Data(base64URL: envelope.ciphertext),
              let tag = Data(base64URL: envelope.tag) else { throw CryptoError.invalidEnvelope }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(box, using: SymmetricKey(data: keyData), authenticating: aad)
    }

    static func identity(account: String) throws -> P256.KeyAgreement.PrivateKey {
        if let raw = try KeychainStore.get(account: account) { return try P256.KeyAgreement.PrivateKey(rawRepresentation: raw) }
        let key = P256.KeyAgreement.PrivateKey()
        try KeychainStore.set(key.rawRepresentation, account: account)
        return key
    }

    static func wrappingKey(privateKey: P256.KeyAgreement.PrivateKey, peerPublicKey: String, salt: Data) throws -> SymmetricKey {
        guard let raw = Data(base64URL: peerPublicKey) else { throw CryptoError.invalidPublicKey }
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: raw)
        return try privateKey.sharedSecretFromKeyAgreement(with: peer)
            .hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                     sharedInfo: Data("dsh-pairing-v1".utf8), outputByteCount: 32)
    }
}

enum CryptoError: Error { case invalidEnvelope, invalidPublicKey }

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL value: String) {
        var text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        self.init(base64Encoded: text)
    }
}
