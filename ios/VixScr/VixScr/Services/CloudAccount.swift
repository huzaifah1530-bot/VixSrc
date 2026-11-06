import Foundation
import Observation
import Security
import UIKit

@MainActor @Observable
final class CloudAccount {
    static let shared = CloudAccount()
    private static let endpoint = URL(string: "https://vela-account.huzaifah1530.workers.dev/v1/")!
    private static let keychainService = "com.vixscr.app.cloud-account"

    struct Device: Identifiable {
        let id: String
        let name: String
        let createdAt: Date
        let isCurrent: Bool
    }

    private struct Session: Codable { var username: String; var token: String; var accountKey: String }
    private var session: Session?
    @ObservationIgnored private weak var syncEngine: SyncEngine?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    var username: String? { session?.username }

    private init() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Self.keychainService,
                                    kSecAttrAccount as String: "session",
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data {
            session = try? JSONDecoder().decode(Session.self, from: data)
        }
    }

    private func save(_ value: Session?) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Self.keychainService,
                                    kSecAttrAccount as String: "session"]
        SecItemDelete(query as CFDictionary)
        if let value {
            let data = try JSONEncoder().encode(value)
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
                throw CloudError.message("Could not save this device's sign-in securely.")
            }
        }
        session = value
    }

    enum CloudError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil,
                         authenticated: Bool = true, allowMissing: Bool = false) async throws -> (Int, [String: Any]) {
        let url = Self.endpoint.appending(path: path)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if authenticated {
            guard let session else { throw CloudError.message("Sign in first.") }
            req.setValue(session.username, forHTTPHeaderField: "X-Vela-Username")
            req.setValue(session.accountKey, forHTTPHeaderField: "X-Vela-Account-Key")
            req.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw CloudError.message("No response from Vela Cloud.") }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if !(200..<300).contains(http.statusCode) && !(allowMissing && http.statusCode == 404) {
            let code = (object["error"] as? [String: Any])?["code"] as? String ?? "unavailable"
            let text: String
            switch code {
            case "invalid_credentials": text = "Incorrect username or PIN."
            case "username_taken": text = "That username is already taken."
            case "temporarily_locked", "rate_limited": text = "Too many attempts. Try again later."
            case "invalid_pin": text = "Choose a 4- or 6-digit PIN that isn't a simple sequence."
            case "conflict": text = "Cloud data changed on another device. Download it before saving again."
            default: text = "Vela Cloud is unavailable (\(code))."
            }
            throw CloudError.message(text)
        }
        return (http.statusCode, object)
    }

    private func authenticate(_ path: String, username: String, pin: String,
                              recoveryCode: String? = nil) async throws -> String? {
        var payload: [String: Any] = ["username": username, "pin": pin, "deviceName": UIDevice.current.name]
        if let recoveryCode { payload["recoveryCode"] = recoveryCode }
        let (_, result) = try await request(path, method: "POST", body: payload, authenticated: false)
        guard let token = result["token"] as? String, let accountKey = result["accountKey"] as? String else { throw CloudError.message("Invalid cloud response.") }
        try save(Session(username: username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), token: token, accountKey: accountKey))
        scheduleSync(after: 1)
        return result["recoveryCode"] as? String
    }

    func create(username: String, pin: String) async throws -> String {
        guard let code = try await authenticate("register", username: username, pin: pin) else {
            throw CloudError.message("No recovery code was returned.")
        }
        return code
    }
    func signIn(username: String, pin: String) async throws { _ = try await authenticate("login", username: username, pin: pin) }
    func recover(username: String, code: String, newPin: String) async throws -> String {
        guard let replacement = try await authenticate("recover", username: username, pin: newPin, recoveryCode: code) else {
            throw CloudError.message("No new recovery code was returned.")
        }
        return replacement
    }
    func signOut() async {
        _ = try? await request("session", method: "DELETE")
        try? save(nil)
    }
    func refreshSession() async {
        guard var current = session,
              let (_, result) = try? await request("session"),
              let name = result["username"] as? String else { return }
        if name != current.username {
            current.username = name
            try? save(current)
        }
    }
    func rename(to newName: String) async throws {
        let (_, result) = try await request("username", method: "POST", body: ["next": newName])
        guard let name = result["username" ] as? String, var current = session else { throw CloudError.message("Invalid cloud response.") }
        current.username = name
        try save(current)
    }
    func changePin(current: String, new: String) async throws {
        _ = try await request("pin", method: "POST", body: ["currentPin": current, "newPin": new])
    }
    func devices() async throws -> [Device] {
        let (_, result) = try await request("devices")
        return (result["devices"] as? [[String: Any]] ?? []).compactMap { row in
            guard let id = row["device_id"] as? String, let name = row["device_name"] as? String,
                  let ms = row["created_at"] as? Double else { return nil }
            return Device(id: id, name: name, createdAt: Date(timeIntervalSince1970: ms / 1000), isCurrent: row["current"] as? Bool ?? false)
        }
    }
    func revoke(device: Device) async throws {
        let (_, result) = try await request("devices/\(device.id)", method: "DELETE")
        if result["current"] as? Bool == true { try save(nil) }
    }
    func delete(pin: String) async throws {
        _ = try await request("account", method: "DELETE", body: ["pin": pin])
        try save(nil)
    }
    func download(into store: AppStore) async throws {
        let (_, result) = try await request("backup/ios")
        guard let payload = result["payload"] as? [String: Any] else { throw CloudError.message("Cloud backup is empty.") }
        try store.importBackup(JSONSerialization.data(withJSONObject: payload))
    }
    func upload(from store: AppStore) async throws {
        let data = try store.exportBackup()
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudError.message("Could not read local backup.")
        }
        var revision = 0
        if let (_, result) = try? await request("backup/ios") { revision = result["revision"] as? Int ?? 0 }
        _ = try await request("backup/ios", method: "PUT", body: ["baseRevision": revision, "payload": payload])
    }

    func attach(sync engine: SyncEngine) {
        syncEngine = engine
        scheduleSync(after: 1)
    }

    func scheduleSync(after seconds: Double = 10) {
        guard session != nil else { return }
        syncTask?.cancel()
        syncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.syncShared()
        }
    }

    private func syncShared() async {
        guard session != nil, let engine = syncEngine else { return }
        for _ in 0..<3 {
            guard let (status, response) = try? await request("backup/shared", allowMissing: true) else { return }
            let revision = status == 200 ? (response["revision"] as? Int ?? 0) : 0
            if status == 200 {
                guard let remote = SyncDoc.validated(response["payload"]) else { return }
                engine.mergeRemote(remote)
            }
            guard let payload = engine.current.jsonObject as? [String: Any] else { return }
            do {
                _ = try await request("backup/shared", method: "PUT", body: ["baseRevision": revision, "payload": payload])
                return
            } catch CloudError.message(let message) where message.contains("changed on another device") {
                continue
            } catch { return }
        }
    }
}
