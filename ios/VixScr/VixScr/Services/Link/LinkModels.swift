import Foundation
import Security

/// Live playback snapshot sent by the desktop (`RemoteState` in
/// desktop/src/shared/link.ts).
struct RemoteState: Codable, Equatable, Sendable {
    struct Source: Codable, Equatable, Sendable {
        var name: String
        var audio: String?
        var quality: String?
    }
    var rev: Int
    var open: Bool
    var session: String
    var kind: String
    var title: String
    var subtitle: String?
    var poster: String?
    var itemKey: String?
    var season: Int?
    var episode: Int?
    var animeEpisode: String?
    var mode: String
    var playing: Bool
    var position: Double
    var duration: Double
    var controllable: Bool
    var servers: [String]
    var serverIndex: Int
    var sources: [Source]
    var sourceIndex: Int
    var hasNext: Bool
    /// Caption tracks on the computer's player (older desktops omit these).
    var captions: [String]?
    /// -1 = captions off.
    var captionIndex: Int?
    var status: String?
    var error: String?
}

/// A desktop this phone has paired with. Stored in the Keychain.
struct PairedDesktop: Codable, Identifiable, Hashable, Sendable {
    var deskId: String
    var name: String
    /// The desktop's X25519 public key, pinned from the QR code.
    var publicKey: Data
    /// Last known LAN addresses, used when Bonjour hasn't resolved yet.
    var hosts: [String]
    var port: Int
    var syncEnabled: Bool
    var autoReconnect: Bool
    var pairedAt: Date
    var lastSeen: Date?
    var lastSync: Date?
    var id: String { deskId }
}

/// Parsed `vixscr://pair?...` QR code.
struct PairingInvite: Equatable, Sendable {
    var deskId: String
    var name: String
    var publicKey: Data
    var code: Data
    var hosts: [String]
    var port: Int

    init?(url: String) {
        guard let components = URLComponents(string: url), components.scheme?.lowercased() == "vixscr",
              components.host?.lowercased() == "pair" else { return nil }
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard let deskId = query["d"], !deskId.isEmpty,
              let key = query["k"].flatMap(LinkCrypto.base64URLDecode), key.count == 32,
              let code = query["c"].flatMap(LinkCrypto.base64URLDecode), code.count == 16,
              let port = query["p"].flatMap(Int.init), (1...65535).contains(port) else { return nil }
        self.deskId = deskId
        self.name = query["n"].flatMap { $0.isEmpty ? nil : $0 } ?? "Computer"
        self.publicKey = key
        self.code = code
        self.hosts = (query["h"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        self.port = port
    }
}

/// Phone identity + pairings, kept in the Keychain (this device only, after
/// first unlock) so the private key never lands in UserDefaults or backups.
struct LinkKeychain {
    struct Stored: Codable {
        var deviceId: String
        var privateKey: Data
        var desktops: [PairedDesktop]
    }

    private static let service = "com.vela.link"
    private static let account = "identity"

    static func load() -> Stored? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Stored.self, from: data)
    }

    static func save(_ stored: Stored) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(stored) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        if SecItemUpdate(base as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            SecItemAdd(base.merging(update) { $1 } as CFDictionary, nil)
        }
    }
}
