import Foundation
import CryptoKit

/// Crypto for the desktop link. Byte-compatible with the desktop's
/// `src/main/link/crypto.ts`:
///   • X25519 static (pinned from the QR code) + ephemeral key agreement
///   • HKDF-SHA256(ikm: static ‖ ephemeral, salt: phoneNonce ‖ deskNonce,
///     info: "vixscr-link-v1") → 64 bytes: phone→desktop key, desktop→phone key
///   • ChaCha20-Poly1305 with a 12-byte nonce of 4 zero bytes + a
///     big-endian 64-bit counter per direction; wire form is ciphertext ‖ tag.
enum LinkCrypto {
    static let info = Data("vixscr-link-v1".utf8)

    static func raw(_ secret: SharedSecret) -> Data {
        secret.withUnsafeBytes { Data($0) }
    }

    /// Returns (send, receive) keys from the phone's point of view.
    static func sessionKeys(staticShared: SharedSecret, ephemeralShared: SharedSecret,
                            phoneNonce: Data, deskNonce: Data) -> (send: SymmetricKey, receive: SymmetricKey) {
        let ikm = SymmetricKey(data: raw(staticShared) + raw(ephemeralShared))
        let out = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: phoneNonce + deskNonce, info: info, outputByteCount: 64)
        let bytes = out.withUnsafeBytes { Data($0) }
        return (SymmetricKey(data: Data(bytes.prefix(32))), SymmetricKey(data: Data(bytes.suffix(32))))
    }

    /// Proof that we scanned the desktop's pairing code.
    static func pairingProof(code: Data, phonePub: Data, phoneEph: Data, phoneNonce: Data) -> Data {
        let message = Data("vixscr-pair".utf8) + phonePub + phoneEph + phoneNonce
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: code)))
    }

    static func randomBytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    static func base64URLDecode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }
}

struct LinkCipher {
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    init(send: SymmetricKey, receive: SymmetricKey) {
        sendKey = send
        receiveKey = receive
    }

    private static func nonce(_ n: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: n.bigEndian) { bytes.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }

    mutating func seal(_ plain: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plain, using: sendKey, nonce: Self.nonce(sendCounter))
        sendCounter += 1
        return box.ciphertext + box.tag
    }

    mutating func open(_ sealed: Data) throws -> Data {
        guard sealed.count >= 16 else { throw CryptoKitError.incorrectParameterSize }
        let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(receiveCounter),
                                           ciphertext: Data(sealed.prefix(sealed.count - 16)),
                                           tag: Data(sealed.suffix(16)))
        receiveCounter += 1
        return try ChaChaPoly.open(box, using: receiveKey)
    }
}

/// Length-prefixed frames (4-byte big-endian length, then payload).
struct LinkFrameReader {
    private var buffer = Data()
    static let maxFrame = 16 * 1024 * 1024

    static func encode(_ payload: Data) -> Data {
        var out = Data()
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    mutating func push(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length <= Self.maxFrame else { throw URLError(.dataLengthExceedsMaximum) }
            guard buffer.count >= 4 + length else { break }
            let start = buffer.startIndex + 4
            frames.append(Data(buffer[start ..< start + length]))
            buffer = Data(buffer[(start + length)...])
        }
        return frames
    }
}
