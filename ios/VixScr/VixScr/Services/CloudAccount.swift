import Foundation
import Observation
import Security
import UIKit
import CryptoKit

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

    /// Outcome of the most recent shared sync, shown live on the Account page.
    enum SyncState: Equatable, Sendable {
        case idle, syncing, synced(Date), offline, failed(String)
    }

    private struct Session: Codable { var username: String; var token: String; var accountKey: String }
    private var session: Session?
    private(set) var syncState: SyncState = .idle
    @ObservationIgnored private weak var syncEngine: SyncEngine?
    @ObservationIgnored private weak var backupStore: AppStore?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    /// The sync currently talking to the server. Kept apart from `syncTask`
    /// (the debounce) so rescheduling never cancels requests mid-flight.
    @ObservationIgnored private var runningSync: Task<SyncState, Never>?
    var username: String? { session?.username }
    private var revisionKey: String? { session.map { "vela_cloud_ios_revision_\($0.accountKey)" } }
    private var backupHashKey: String? { session.map { "vela_cloud_ios_hash_\($0.accountKey)" } }

    private func backupHash(_ payload: [String: Any]) -> String? {
        var stable = payload
        stable.removeValue(forKey: "exportedAt")
        guard let data = try? JSONSerialization.data(withJSONObject: stable, options: [.sortedKeys]) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

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
        if value == nil { syncState = .idle }
    }

    enum CloudError: LocalizedError {
        case message(String), unauthorized
        var errorDescription: String? {
            switch self {
            case .message(let text): return text
            case .unauthorized: return "This device was signed out. Sign in again."
            }
        }
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
        if authenticated && http.statusCode == 401 {
            try? save(nil)
            throw CloudError.unauthorized
        }
        if !(200..<300).contains(http.statusCode) && !(allowMissing && http.statusCode == 404) {
            let code = (object["error"] as? [String: Any])?["code"] as? String ?? "unavailable"
            let text: String
            switch code {
            case "invalid_credentials": text = "Incorrect username or PIN."
            case "username_taken": text = "That username is already taken."
            case "temporarily_locked", "rate_limited": text = "Too many attempts. Try again later."
            case "invalid_pin": text = "Choose a 4- or 6-digit PIN that isn't a simple sequence."
            case "conflict": text = "Cloud data changed on another device. Download it before saving again."
            case "not_found": text = "No cloud backup is saved for this platform yet."
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
        if let key = revisionKey { UserDefaults.standard.set(0, forKey: key) }
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
    /// Picks up a username changed on another device. `visible` reports the
    /// result through the status pill; background refreshes stay silent.
    func refreshSession(visible: Bool = false) async {
        guard var current = session else { return }
        let pill = visible ? StatusPillCenter.shared.begin("Checking your Vela account…") : nil
        do {
            let (_, result) = try await request("session")
            guard let name = result["username"] as? String else { throw CloudError.message("Invalid cloud response.") }
            if name != current.username {
                current.username = name
                try? save(current)
            }
            if let pill { StatusPillCenter.shared.finish(pill, success: true, text: "Signed in as \(name)") }
        } catch {
            if let pill { StatusPillCenter.shared.finish(pill, success: false, text: Self.failureText(Self.syncFailure(error))) }
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
        if let key = revisionKey { UserDefaults.standard.set(result["revision"] as? Int ?? 0, forKey: key) }
        if let key = backupHashKey, let hash = backupHash(payload) { UserDefaults.standard.set(hash, forKey: key) }
    }
    func upload(from store: AppStore) async throws {
        let data = try store.exportBackup()
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudError.message("Could not read local backup.")
        }
        var revision = 0
        if let (_, result) = try? await request("backup/ios") { revision = result["revision"] as? Int ?? 0 }
        _ = try await request("backup/ios", method: "PUT", body: ["baseRevision": revision, "payload": payload])
        if let key = revisionKey { UserDefaults.standard.set(revision + 1, forKey: key) }
        if let key = backupHashKey, let hash = backupHash(payload) { UserDefaults.standard.set(hash, forKey: key) }
    }

    func attach(sync engine: SyncEngine, store: AppStore) {
        syncEngine = engine
        backupStore = store
        scheduleSync(after: 1)
    }

    func scheduleSync(after seconds: Double = 10) {
        guard session != nil else { return }
        syncTask?.cancel()
        syncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.runSync()
        }
    }

    /// Syncs right away instead of waiting for the debounce. `visible` shows
    /// progress and the outcome in the status pill; pass false for anything
    /// the user didn't explicitly ask for.
    func syncNow(visible: Bool) {
        guard session != nil else { return }
        // This run covers whatever the pending debounce would have sent.
        syncTask?.cancel()
        let pill = visible ? StatusPillCenter.shared.begin("Syncing with Vela Cloud…") : nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.runSync()
            guard let pill else { return }
            if case .synced = result {
                StatusPillCenter.shared.finish(pill, success: true, text: "Up to date")
            } else {
                StatusPillCenter.shared.finish(pill, success: false, text: CloudAccount.failureText(result))
            }
        }
    }

    func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.scheduleSync(after: 0)
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Runs one shared sync, waiting for any sync already in flight first so
    /// the debounce, polling and Sync Now never race each other.
    @discardableResult
    private func runSync() async -> SyncState {
        while let running = runningSync { _ = await running.value }
        // Unstructured on purpose: cancelling the caller (a debounce being
        // rescheduled) must not cancel the network requests underneath.
        let task = Task { @MainActor [weak self] () -> SyncState in
            guard let self else { return .idle }
            let result = await self.syncShared()
            self.runningSync = nil
            return result
        }
        runningSync = task
        return await task.value
    }

    private func syncShared() async -> SyncState {
        guard session != nil else {
            syncState = .idle
            return .idle
        }
        guard let engine = syncEngine else {
            // Only possible before launch has attached the sync engine.
            return .failed("Sync is still starting. Try again in a moment.")
        }
        syncState = .syncing
        let result = await pushShared(engine)
        // A 401 signs the device out mid-sync; don't leave a stale failure behind.
        syncState = session == nil ? .idle : result
        return result
    }

    private func pushShared(_ engine: SyncEngine) async -> SyncState {
        for _ in 0..<3 {
            let fetched: (Int, [String: Any])
            do {
                fetched = try await request("backup/shared", allowMissing: true)
            } catch {
                return Self.syncFailure(error)
            }
            let (status, response) = fetched
            let revision = status == 200 ? (response["revision"] as? Int ?? 0) : 0
            if status == 200 {
                guard let remote = SyncDoc.validated(response["payload"]) else {
                    return .failed("Cloud data couldn't be read.")
                }
                engine.mergeRemote(remote)
            }
            guard let payload = engine.current.jsonObject as? [String: Any] else {
                return .failed("Couldn't read this iPhone's library.")
            }
            do {
                _ = try await request("backup/shared", method: "PUT", body: ["baseRevision": revision, "payload": payload])
                await autoUploadBackup()
                return .synced(Date())
            } catch CloudError.message(let message) where message.contains("changed on another device") {
                continue
            } catch {
                return Self.syncFailure(error)
            }
        }
        return .failed("Cloud data kept changing. Try again.")
    }

    /// Connectivity errors read as "offline" rather than a scary failure;
    /// everything else keeps the server's own message.
    private static func syncFailure(_ error: Error) -> SyncState {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
                return .offline
            default:
                return .failed(urlError.localizedDescription)
            }
        }
        return .failed(error.localizedDescription)
    }

    private static func failureText(_ state: SyncState) -> String {
        switch state {
        case .offline: return "You're offline"
        case .failed(let reason): return reason
        case .idle: return "Sign in to sync"
        case .syncing, .synced: return "Up to date"
        }
    }

    private func autoUploadBackup() async {
        guard let store = backupStore, let revisionKey, let backupHashKey,
              let revision = UserDefaults.standard.object(forKey: revisionKey) as? Int,
              let data = try? store.exportBackup(),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hash = backupHash(payload),
              hash != UserDefaults.standard.string(forKey: backupHashKey) else { return }
        do {
            _ = try await request("backup/ios", method: "PUT", body: ["baseRevision": revision, "payload": payload])
            UserDefaults.standard.set(revision + 1, forKey: revisionKey)
            UserDefaults.standard.set(hash, forKey: backupHashKey)
        } catch CloudError.message(let message) where message.contains("changed on another device") {
            UserDefaults.standard.removeObject(forKey: revisionKey)
        } catch { /* Offline: keep the revision and retry on the next sync. */ }
    }
}
