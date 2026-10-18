import Foundation
import Network
import CryptoKit
import Observation
import UIKit

/// Pairs with Vela on a computer over the local network and keeps an
/// encrypted connection to it: remote playback (commands out, live state
/// in) and optional saved-data sync. No servers involved — the desktop
/// advertises `_vixscr._tcp` over Bonjour and listens while it's open.
///
/// iOS suspends us in the background, so instead of keeping a listener
/// alive we drop the connection when backgrounded and reconnect when the
/// app becomes active again. Commands are never queued across a
/// disconnect; only a fresh "play this" intent waits briefly for a connect.
@MainActor
@Observable
final class DeviceLink {
    static let shared = DeviceLink()

    enum Phase: Equatable {
        case idle
        case connecting(String)
        case connected
        case failed(String)
    }

    struct Discovered: Identifiable, Hashable {
        var id: String { deskId ?? name }
        var deskId: String?
        var name: String
        var endpoint: NWEndpoint
    }

    struct Offer: Identifiable {
        var id: String { deskId }
        var deskId: String
        var name: String
        var doc: SyncDoc?
    }

    // MARK: Observable state
    private(set) var paired: [PairedDesktop] = []
    private(set) var discovered: [Discovered] = []
    private(set) var isBrowsing = false
    private(set) var browseError: String?
    private(set) var phase: Phase = .idle
    private(set) var connectedDeskId: String?
    private(set) var remote: RemoteState?
    /// Set when the desktop says it's showing a QR code for us.
    private(set) var qrShownBy: String?
    var toastMessage: String?
    /// Asked once, right after the first pairing.
    var syncPrompt: PairedDesktop?
    /// The desktop wants to replace this iPhone's data.
    var offer: Offer?
    private(set) var playbackTargetId: String?

    // MARK: Internals
    private enum Mode {
        case hello(desk: PairedDesktop, auto: Bool, code: Data?)
        case pairRequest(name: String)
    }

    @ObservationIgnored private var identity: LinkKeychain.Stored
    private let privateKey: Curve25519.KeyAgreement.PrivateKey
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var mode: Mode?
    @ObservationIgnored private var reader = LinkFrameReader()
    @ObservationIgnored private var cipher: LinkCipher?
    @ObservationIgnored private var ephemeral: Curve25519.KeyAgreement.PrivateKey?
    @ObservationIgnored private var helloNonce = Data()
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var sync: SyncEngine?
    @ObservationIgnored private var pendingReplaceUntil: Date?
    @ObservationIgnored private var pendingPlay: (command: [String: Any], until: Date)?
    @ObservationIgnored private var keepAliveTask: Task<Void, Never>?
    @ObservationIgnored private var lastReceived = Date()
    @ObservationIgnored private var suppressReconnect = false
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var hostIndex = 0

    private static let targetKey = "vela_link_playback_target"
    private static let lastDeskKey = "vela_link_last_desk"

    private init() {
        if let stored = LinkKeychain.load(),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: stored.privateKey) {
            identity = stored
            privateKey = key
        } else {
            let key = Curve25519.KeyAgreement.PrivateKey()
            identity = .init(deviceId: UUID().uuidString, privateKey: key.rawRepresentation, desktops: [])
            privateKey = key
            LinkKeychain.save(identity)
        }
        paired = identity.desktops
        let target = UserDefaults.standard.string(forKey: Self.targetKey)
        playbackTargetId = paired.contains { $0.deskId == target } ? target : nil
    }

    /// Hooks saved-data sync up to the app's store. Call once at launch.
    func attach(store: AppStore) {
        guard sync == nil else { return }
        let engine = SyncEngine(store: store)
        engine.onLocalChange = { [weak self] in self?.pushLocalChanges() }
        sync = engine
    }

    // MARK: - Derived

    var connectedDesktop: PairedDesktop? { paired.first { $0.deskId == connectedDeskId } }
    var playbackTarget: PairedDesktop? { paired.first { $0.deskId == playbackTargetId } }
    /// True when playback should go to a computer instead of this iPhone.
    var routesPlayback: Bool { playbackTarget != nil }
    var isConnected: Bool { phase == .connected && cipher != nil }

    func isConnected(to deskId: String) -> Bool { isConnected && connectedDeskId == deskId }

    func statusText(for desk: PairedDesktop) -> String {
        if isConnected(to: desk.deskId) { return "Connected" }
        if case .connecting(let id) = phase, id == desk.deskId { return "Connecting…" }
        if let seen = desk.lastSeen { return "Last seen " + seen.formatted(.relative(presentation: .named)) }
        return "Not connected"
    }

    // MARK: - Persistence

    private func savePairs() {
        identity.desktops = paired
        LinkKeychain.save(identity)
    }

    private func updatePair(_ deskId: String, _ change: (inout PairedDesktop) -> Void) {
        guard let i = paired.firstIndex(where: { $0.deskId == deskId }) else { return }
        change(&paired[i])
        savePairs()
    }

    func setPlaybackTarget(_ deskId: String?) {
        playbackTargetId = deskId
        UserDefaults.standard.set(deskId, forKey: Self.targetKey)
        if let deskId, !isConnected(to: deskId) { connect(deskId, auto: false) }
    }

    // MARK: - Discovery

    func startBrowsing() {
        guard browser == nil else { return }
        browseError = nil
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_vixscr._tcp", domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.updateDiscovered(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .failed(let error), .waiting(let error):
                    self.browseError = Self.describe(browseError: error)
                case .ready:
                    self.browseError = nil
                default: break
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
        isBrowsing = true
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
    }

    private static func describe(browseError error: NWError) -> String {
        if case .dns(let code) = error, code == -65570 /* kDNSServiceErr_PolicyDenied */ {
            return "Vela needs Local Network access. Turn it on in Settings › Privacy & Security › Local Network."
        }
        return "Couldn't search the network: \(error.localizedDescription)"
    }

    private func updateDiscovered(_ results: Set<NWBrowser.Result>) {
        discovered = results.compactMap { result in
            guard case let .service(name, _, _, _) = result.endpoint else { return nil }
            var deskId: String?
            var display = name
            if case let .bonjour(txt) = result.metadata {
                deskId = txt.dictionary["id"]
                if let n = txt.dictionary["n"], !n.isEmpty { display = n }
            }
            return Discovered(deskId: deskId, name: display, endpoint: result.endpoint)
        }
        .sorted { $0.name < $1.name }
    }

    // MARK: - Connecting

    /// Connects to a paired computer, preferring its Bonjour endpoint and
    /// falling back to the addresses remembered from the QR code.
    func connect(_ deskId: String, auto: Bool) {
        guard let desk = paired.first(where: { $0.deskId == deskId }) else { return }
        if isConnected(to: deskId) { return }
        if case .connecting(let id) = phase, id == deskId { return }
        if auto && !desk.autoReconnect { return }
        suppressReconnect = false
        startBrowsing()
        phase = .connecting(deskId)
        Task { @MainActor [weak self] in
            // Give Bonjour a moment to resolve before using stored addresses.
            for _ in 0..<15 {
                if self?.discovered.contains(where: { $0.deskId == deskId }) == true { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let self, case .connecting(let id) = self.phase, id == deskId else { return }
            self.hostIndex = 0
            self.open(desk: desk, auto: auto, code: nil)
        }
    }

    private func endpoint(for desk: PairedDesktop) -> NWEndpoint? {
        if let found = discovered.first(where: { $0.deskId == desk.deskId }) { return found.endpoint }
        guard hostIndex < desk.hosts.count, let port = NWEndpoint.Port(rawValue: UInt16(clamping: desk.port)) else { return nil }
        return .hostPort(host: NWEndpoint.Host(desk.hosts[hostIndex]), port: port)
    }

    private func open(desk: PairedDesktop, auto: Bool, code: Data?) {
        guard let endpoint = endpoint(for: desk) else {
            fail("Couldn't find \(desk.name) on this network. Make sure Vela is open on it and both devices are on the same Wi-Fi.")
            return
        }
        start(endpoint: endpoint, mode: .hello(desk: desk, auto: auto, code: code))
    }

    /// Scanned QR code: pair with the computer it describes.
    func pair(with invite: PairingInvite) {
        let desk = PairedDesktop(deskId: invite.deskId, name: invite.name, publicKey: invite.publicKey,
                                 hosts: invite.hosts, port: invite.port, syncEnabled: false, autoReconnect: true,
                                 pairedAt: Date(), lastSeen: nil, lastSync: nil)
        qrShownBy = nil
        suppressReconnect = false
        hostIndex = 0
        phase = .connecting(invite.deskId)
        open(desk: desk, auto: false, code: invite.code)
    }

    /// Asks an unpaired computer found over Bonjour to show its QR code.
    func requestPairing(_ found: Discovered) {
        qrShownBy = nil
        suppressReconnect = true
        start(endpoint: found.endpoint, mode: .pairRequest(name: found.name))
    }

    private func start(endpoint: NWEndpoint, mode: Mode) {
        teardown()
        generation += 1
        let gen = generation
        self.mode = mode
        reader = LinkFrameReader()
        cipher = nil
        let options = NWProtocolTCP.Options()
        options.connectionTimeout = 6
        options.enableKeepalive = true
        let conn = NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: options))
        conn.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.connectionState(state, generation: gen) }
        }
        connection = conn
        conn.start(queue: .main)
        receive(on: conn, generation: gen)
    }

    private func connectionState(_ state: NWConnection.State, generation gen: Int) {
        guard gen == generation else { return }
        switch state {
        case .ready:
            sendHandshake()
        case .waiting(let error), .failed(let error):
            closed(reason: error.localizedDescription)
        case .cancelled:
            break
        default:
            break
        }
    }

    private func receive(on conn: NWConnection, generation gen: Int) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation else { return }
                if let data, !data.isEmpty { self.received(data) }
                if isComplete || error != nil {
                    self.closed(reason: error?.localizedDescription)
                } else if gen == self.generation, let conn = self.connection {
                    self.receive(on: conn, generation: gen)
                }
            }
        }
    }

    private func sendHandshake() {
        guard let mode else { return }
        switch mode {
        case .pairRequest:
            sendPlain(["t": "pair-request", "name": UIDevice.current.name])
        case .hello(let desk, let auto, let code):
            let eph = Curve25519.KeyAgreement.PrivateKey()
            ephemeral = eph
            helloNonce = LinkCrypto.randomBytes(16)
            let pub = privateKey.publicKey.rawRepresentation
            var hello: [String: Any] = [
                "t": "hello", "v": 1, "deviceId": identity.deviceId, "name": UIDevice.current.name,
                "pub": pub.base64EncodedString(), "eph": eph.publicKey.rawRepresentation.base64EncodedString(),
                "nonce": helloNonce.base64EncodedString(), "auto": auto, "deskId": desk.deskId
            ]
            if let code {
                hello["proof"] = LinkCrypto.pairingProof(code: code, phonePub: pub, phoneEph: eph.publicKey.rawRepresentation, phoneNonce: helloNonce).base64EncodedString()
            }
            sendPlain(hello)
        }
    }

    private func received(_ data: Data) {
        lastReceived = Date()
        let frames: [Data]
        do { frames = try reader.push(data) } catch { closed(reason: "Bad data from the computer"); return }
        for frame in frames {
            do {
                if cipher != nil {
                    guard let plain = try cipher?.open(frame),
                          let msg = try JSONSerialization.jsonObject(with: plain) as? [String: Any] else { continue }
                    handle(msg)
                } else {
                    guard let msg = try JSONSerialization.jsonObject(with: frame) as? [String: Any] else { continue }
                    handleHandshake(msg)
                }
            } catch {
                closed(reason: "The connection couldn't be verified")
                return
            }
        }
    }

    private func handleHandshake(_ msg: [String: Any]) {
        switch (msg["t"] as? String, mode) {
        case ("pair-shown", .pairRequest(let name)?):
            qrShownBy = name
            teardown()
            phase = .idle
        case ("hello-ok", .hello(let desk, _, _)?):
            guard msg["deskId"] as? String == desk.deskId,
                  let ephB64 = msg["eph"] as? String, let deskEph = Data(base64Encoded: ephB64),
                  let nonceB64 = msg["nonce"] as? String, let deskNonce = Data(base64Encoded: nonceB64), deskNonce.count == 16,
                  let eph = ephemeral,
                  let deskStatic = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: desk.publicKey),
                  let deskEphKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: deskEph),
                  let staticShared = try? privateKey.sharedSecretFromKeyAgreement(with: deskStatic),
                  let ephShared = try? eph.sharedSecretFromKeyAgreement(with: deskEphKey) else {
                closed(reason: "That computer didn't identify itself correctly")
                return
            }
            let keys = LinkCrypto.sessionKeys(staticShared: staticShared, ephemeralShared: ephShared, phoneNonce: helloNonce, deskNonce: deskNonce)
            cipher = LinkCipher(send: keys.send, receive: keys.receive)
            ephemeral = nil
            // The next frame (welcome) only decrypts if the computer holds
            // the private key matching the pinned public key.
        case ("error", .hello(let desk, _, let code)?):
            let reason = msg["code"] as? String ?? "error"
            suppressReconnect = true
            teardown()
            switch reason {
            case "unpaired":
                if code == nil && paired.contains(where: { $0.deskId == desk.deskId }) {
                    removePair(desk.deskId)
                    fail("\(desk.name) no longer recognises this iPhone. Scan its code to pair again.")
                } else {
                    fail("Show the pairing code on \(desk.name) first (Connect iPhone), then scan it.")
                }
            case "bad-proof": fail("That code didn't match. Show a new code on \(desk.name) and scan it again.")
            case "code-expired": fail("That code has expired. Show a new code on \(desk.name).")
            case "auto-disabled": phase = .idle
            case "wrong-desktop": fail("A different computer answered. Try again.")
            default: fail("\(desk.name) refused the connection (\(reason)).")
            }
        default:
            closed(reason: "Unexpected reply from the computer")
        }
    }

    // MARK: - Messages

    private func handle(_ msg: [String: Any]) {
        guard let type = msg["t"] as? String else { return }
        switch type {
        case "welcome": welcomed(msg)
        case "state":
            if let object = msg["s"], let data = try? JSONSerialization.data(withJSONObject: object),
               let state = try? JSONDecoder().decode(RemoteState.self, from: data) {
                // TCP keeps order, so the newest frame is the current state.
                remote = state
            }
        case "ack":
            if msg["ok"] as? Bool == false, let error = msg["error"] as? String, error != "duplicate" {
                showToast(error == "stale" ? "That was for something that's no longer playing" : error)
            }
        case "pong": break
        case "sync-config":
            if let enabled = msg["enabled"] as? Bool, let id = connectedDeskId {
                updatePair(id) { $0.syncEnabled = enabled }
            }
        case "sync-doc": receivedDoc(msg)
        case "sync-request":
            if msg["mode"] as? String == "replace" { sendDoc(mode: "replace", reply: false) }
        case "fresh-copy-offer":
            if let id = connectedDeskId {
                offer = Offer(deskId: id, name: connectedDesktop?.name ?? "Computer", doc: SyncDoc.validated(msg["doc"]))
            }
        case "fresh-copy-result":
            if msg["ok"] as? Bool == true, let id = connectedDeskId {
                updatePair(id) { $0.syncEnabled = true; $0.lastSync = Date() }
                showToast("\(connectedDesktop?.name ?? "Computer") now matches this iPhone")
            } else {
                showToast("Copy was cancelled on the computer")
            }
        case "revoke":
            if let id = connectedDeskId {
                let name = connectedDesktop?.name ?? "The computer"
                suppressReconnect = true
                removePair(id)
                teardown()
                phase = .idle
                showToast("\(name) removed this iPhone")
            }
        case "bye":
            suppressReconnect = true
            teardown()
            phase = .idle
        default: break
        }
    }

    private func welcomed(_ msg: [String: Any]) {
        guard case .hello(var desk, _, _)? = mode else { return }
        let first = msg["firstPairing"] as? Bool == true
        desk.syncEnabled = msg["syncEnabled"] as? Bool ?? desk.syncEnabled
        if let name = msg["deskName"] as? String, !name.isEmpty { desk.name = name }
        desk.lastSeen = Date()
        if let i = paired.firstIndex(where: { $0.deskId == desk.deskId }) {
            desk.lastSync = paired[i].lastSync
            desk.autoReconnect = paired[i].autoReconnect
            paired[i] = desk
        } else {
            paired.append(desk)
        }
        savePairs()
        connectedDeskId = desk.deskId
        UserDefaults.standard.set(desk.deskId, forKey: Self.lastDeskKey)
        phase = .connected
        remote = nil
        startKeepAlive()
        send(["t": "state-request"])
        if first {
            showToast("Paired with \(desk.name)")
            // Let the connect sheet finish dismissing before asking.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 900_000_000)
                self?.syncPrompt = desk
            }
        } else if desk.syncEnabled {
            sendDoc(mode: "merge", reply: true)
        }
        if let pending = pendingPlay, pending.until > Date() { send(pending.command) }
        pendingPlay = nil
    }

    private func receivedDoc(_ msg: [String: Any]) {
        guard let id = connectedDeskId, let sync else { return }
        guard let doc = SyncDoc.validated(msg["doc"]) else {
            showToast("Ignored invalid data from \(connectedDesktop?.name ?? "the computer")")
            return
        }
        if msg["mode"] as? String == "replace" {
            guard let until = pendingReplaceUntil, until > Date() else { return } // we never asked
            pendingReplaceUntil = nil
            sync.replaceFromRemote(doc)
            updatePair(id) { $0.syncEnabled = true; $0.lastSync = Date() }
            send(["t": "sync-config", "enabled": true])
            sendDoc(mode: "merge", reply: false)
            showToast("Copied from \(connectedDesktop?.name ?? "your computer")")
            return
        }
        guard connectedDesktop?.syncEnabled == true else { return }
        sync.mergeRemote(doc)
        updatePair(id) { $0.lastSync = Date() }
        if msg["reply"] as? Bool == true { sendDoc(mode: "merge", reply: false) }
    }

    private func sendDoc(mode: String, reply: Bool) {
        guard let doc = sync?.current.jsonObject else { return }
        send(["t": "sync-doc", "mode": mode, "reply": reply, "doc": doc])
    }

    private func pushLocalChanges() {
        guard isConnected, connectedDesktop?.syncEnabled == true else { return }
        sendDoc(mode: "merge", reply: false)
    }

    // MARK: - Sending

    private func sendPlain(_ msg: [String: Any]) {
        guard let conn = connection, let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        conn.send(content: LinkFrameReader.encode(data), completion: .contentProcessed { _ in })
    }

    @discardableResult
    private func send(_ msg: [String: Any]) -> Bool {
        guard let conn = connection, cipher != nil,
              let data = try? JSONSerialization.data(withJSONObject: msg),
              let sealed = try? cipher?.seal(data) else { return false }
        conn.send(content: LinkFrameReader.encode(sealed), completion: .contentProcessed { _ in })
        return true
    }

    // MARK: - Remote playback commands

    /// Transport and selection commands apply to whatever is playing on the
    /// computer right now; the desktop drops them if that has changed.
    @discardableResult
    func command(_ action: String, _ args: [String: Any] = [:]) -> Bool {
        guard isConnected else {
            showToast("Not connected to \(playbackTarget?.name ?? "your computer")")
            return false
        }
        var msg = args
        msg["t"] = "cmd"
        msg["id"] = UUID().uuidString
        msg["action"] = action
        msg["session"] = remote?.session ?? ""
        return send(msg)
    }

    private func itemObject(_ item: MediaItem) -> Any? {
        guard let data = try? JSONEncoder().encode(SyncEngine.item(item)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// Starts a title on the computer. If it isn't connected yet, the
    /// request waits up to 10 seconds for the connection, then is dropped.
    func playOnDesktop(_ action: String, item: MediaItem, extra: [String: Any]) {
        guard let target = playbackTarget, let itemObject = itemObject(item) else { return }
        var msg = extra
        msg["t"] = "cmd"
        msg["id"] = UUID().uuidString
        msg["action"] = action
        msg["item"] = itemObject
        if isConnected(to: target.deskId) {
            send(msg)
        } else {
            pendingPlay = (msg, Date().addingTimeInterval(10))
            connect(target.deskId, auto: false)
        }
    }

    // MARK: - Settings actions

    func setSync(_ deskId: String, enabled: Bool) {
        updatePair(deskId) { $0.syncEnabled = enabled }
        guard isConnected(to: deskId) else { return }
        send(["t": "sync-config", "enabled": enabled])
        if enabled { sendDoc(mode: "merge", reply: true) }
    }

    func setAutoReconnect(_ deskId: String, enabled: Bool) {
        updatePair(deskId) { $0.autoReconnect = enabled }
        if isConnected(to: deskId) { send(["t": "set-auto", "enabled": enabled]) }
    }

    func syncNow(_ deskId: String) {
        guard isConnected(to: deskId) else { connect(deskId, auto: false); return }
        sendDoc(mode: "merge", reply: true)
        showToast("Syncing…")
    }

    /// This iPhone → computer. The computer asks its user to confirm.
    func copyToDesktop(_ deskId: String) {
        guard isConnected(to: deskId), let doc = sync?.current.jsonObject else { return }
        send(["t": "fresh-copy-offer", "doc": doc])
        showToast("Confirm on \(connectedDesktop?.name ?? "your computer")")
    }

    /// Computer → this iPhone. Only call after the user confirmed here.
    func copyFromDesktop(_ deskId: String) {
        guard isConnected(to: deskId) else { return }
        pendingReplaceUntil = Date().addingTimeInterval(60)
        send(["t": "sync-request", "mode": "replace"])
    }

    func resolveOffer(accept: Bool) {
        guard let offer else { return }
        self.offer = nil
        guard isConnected(to: offer.deskId) else { return }
        if accept, let doc = offer.doc {
            sync?.replaceFromRemote(doc)
            updatePair(offer.deskId) { $0.syncEnabled = true; $0.lastSync = Date() }
            send(["t": "sync-config", "enabled": true])
            showToast("This iPhone now matches \(offer.name)")
        }
        send(["t": "fresh-copy-result", "ok": accept && offer.doc != nil])
    }

    enum SyncChoice { case none, fromPhone, fromDesktop }

    func answerSyncPrompt(_ choice: SyncChoice) {
        guard let desk = syncPrompt else { return }
        syncPrompt = nil
        switch choice {
        case .none: setSync(desk.deskId, enabled: false)
        case .fromPhone: copyToDesktop(desk.deskId)
        case .fromDesktop: copyFromDesktop(desk.deskId)
        }
    }

    func disconnect() {
        suppressReconnect = true
        send(["t": "bye"])
        teardown()
        phase = .idle
    }

    /// Forgets the pairing; the computer will need to show a new code.
    /// Data already copied to this iPhone stays.
    func forget(_ deskId: String) {
        if isConnected(to: deskId) {
            suppressReconnect = true
            send(["t": "revoke"])
            // Let the revoke go out before closing.
            let gen = generation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self, self.generation == gen else { return }
                self.teardown()
            }
            phase = .idle
        }
        removePair(deskId)
    }

    private func removePair(_ deskId: String) {
        paired.removeAll { $0.deskId == deskId }
        savePairs()
        if playbackTargetId == deskId { setPlaybackTarget(nil) }
        if connectedDeskId == deskId { connectedDeskId = nil; remote = nil }
    }

    // MARK: - Lifecycle

    func appBecameActive() {
        let id = playbackTargetId ?? UserDefaults.standard.string(forKey: Self.lastDeskKey)
        guard let id, paired.contains(where: { $0.deskId == id }), !isConnected(to: id) else { return }
        connect(id, auto: true)
    }

    func appEnteredBackground() {
        // iOS suspends us shortly; close cleanly and reconnect on return.
        suppressReconnect = true
        teardown()
        phase = .idle
        stopBrowsing()
    }

    private func startKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, !Task.isCancelled, self.isConnected else { return }
                if Date().timeIntervalSince(self.lastReceived) > 45 {
                    self.closed(reason: "The computer stopped responding")
                    return
                }
                self.send(["t": "ping"])
            }
        }
    }

    private func teardown() {
        generation += 1
        keepAliveTask?.cancel()
        connection?.cancel()
        connection = nil
        cipher = nil
        ephemeral = nil
    }

    private func closed(reason: String?) {
        let wasConnected = isConnected
        let deskId = connectedDeskId
        let attempt = mode
        teardown()
        if wasConnected, let deskId {
            updatePair(deskId) { $0.lastSeen = Date() }
            phase = .idle
            // Desktop playback carries on; try to come back once.
            if !suppressReconnect, UIApplication.shared.applicationState == .active {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self?.connect(deskId, auto: true)
                }
            }
            return
        }
        // Not connected yet: try the next remembered address, then give up.
        if case .hello(let desk, let auto, let code)? = attempt, !suppressReconnect,
           !discovered.contains(where: { $0.deskId == desk.deskId }), hostIndex + 1 < desk.hosts.count {
            hostIndex += 1
            open(desk: desk, auto: auto, code: code)
            return
        }
        if case .connecting = phase {
            fail(reason.map { "Couldn't connect: \($0)" } ?? "Couldn't connect")
        }
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        pendingPlay = nil
    }

    func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            self?.toastMessage = nil
        }
    }
}
