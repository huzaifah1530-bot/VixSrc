import Foundation
import CryptoKit

/// Relay connection for Watch Together. Same wire format as the desktop's
/// `partyClient.ts`: frames are JSON; payloads are AES-256-GCM sealed with
/// the key from the invite link and sent as base64url(nonce ‖ ciphertext ‖ tag),
/// which is exactly CryptoKit's `SealedBox.combined`.
@MainActor
final class PartyConnection: NSObject, PartyTransport {
    enum Status: String { case connecting, connected, reconnecting, closed }

    static let relay = "https://vela-party.huzaifah1530.workers.dev"

    struct Invite: Equatable {
        var room: String
        var key: String
        var link: String { "\(PartyConnection.relay)/p/\(room)#\(key)" }

        static func new() -> Invite { Invite(room: b64u(rand(9)), key: b64u(rand(32))) }

        /// https://…/p/<room>#<key> or vela://party/<room>#<key>
        init?(text: String) {
            let pattern = #"(?:/p/|party/)([A-Za-z0-9_-]{8,32})#([A-Za-z0-9_-]{43})"#
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r = Range(m.range(at: 1), in: text), let k = Range(m.range(at: 2), in: text) else { return nil }
            room = String(text[r]); key = String(text[k])
        }
        init(room: String, key: String) { self.room = room; self.key = key }
    }

    static func rand(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: 0...255) }) }
    static func b64u(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func unb64u(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    let invite: Invite
    let peer: String
    private let secret: String
    private let key: SymmetricKey
    private(set) var status: Status = .connecting { didSet { onStatus?(status) } }
    var onStatus: ((Status) -> Void)?
    weak var core: PartyCore?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession!
    private var offset: Double = 0
    private var bestRtt = Double.infinity
    private var retry = 0
    private var closedByUser = false
    private var lastHeard = Date()
    private var timers: [Task<Void, Never>] = []
    private var generation = 0

    init?(invite: Invite, peer: String, secret: String) {
        guard let raw = Self.unb64u(invite.key), raw.count == 32 else { return nil }
        self.invite = invite
        self.peer = peer
        self.secret = secret
        self.key = SymmetricKey(data: raw)
        super.init()
        session = URLSession(configuration: .default)
    }

    var isOpen: Bool { task?.state == .running && status == .connected }
    func now() -> Double { Date().timeIntervalSince1970 * 1000 + offset }

    func open() {
        connect()
        timers.append(Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !self.closedByUser else { return }
                // Watchdog: pings are answered every 15s; 40s of silence means
                // the network died without telling us.
                if self.status == .connected && Date().timeIntervalSince(self.lastHeard) > 40 { self.reconnectNow() }
            }
        })
        timers.append(Task { @MainActor [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, !self.closedByUser else { return }
                tick += 1
                self.task?.send(.string("ping")) { _ in }
                if tick % 2 == 0 { self.clockSync() }
            }
        })
    }

    func close() {
        closedByUser = true
        timers.forEach { $0.cancel() }
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        status = .closed
    }

    func reconnectNow() {
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        core?.disconnected()
        guard !closedByUser else { return }
        status = .reconnecting
        let delay = min(15, 0.5 * pow(2, Double(retry))) * Double.random(in: 0.75...1.25)
        retry += 1
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !self.closedByUser, self.task == nil else { return }
            self.connect()
        }
    }

    /// App came back to the foreground or the network changed.
    func refreshNow() { guard !closedByUser else { return }; retry = 0; if !isOpen { reconnectNow() } }

    private func connect() {
        var c = URLComponents(string: Self.relay.replacingOccurrences(of: "https://", with: "wss://") + "/room/\(invite.room)")!
        c.queryItems = [URLQueryItem(name: "peer", value: peer), URLQueryItem(name: "s", value: secret)]
        guard let url = c.url else { return }
        generation += 1
        let gen = generation
        let t = session.webSocketTask(with: url)
        task = t
        lastHeard = Date()
        t.resume()
        receive(t, gen)
        clockSync()
    }

    private func receive(_ t: URLSessionWebSocketTask, _ gen: Int) {
        t.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, gen == self.generation else { return }
                switch result {
                case .success(let message):
                    self.lastHeard = Date()
                    if case .string(let text) = message { self.frame(text) }
                    self.receive(t, gen)
                case .failure:
                    if self.task === t, !self.closedByUser { self.reconnectNow() }
                }
            }
        }
    }

    private func clockSync() {
        let msg = #"{"t":"time","c":\#(Int(Date().timeIntervalSince1970 * 1000))}"#
        task?.send(.string(msg)) { _ in }
    }

    private func frame(_ text: String) {
        if text == "pong" { return }
        guard let data = text.data(using: .utf8), let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        switch m["sys"] as? String {
        case "time":
            guard let echo = m["echo"] as? Double, let now = m["now"] as? Double else { return }
            let local = Date().timeIntervalSince1970 * 1000
            let rtt = local - echo
            if rtt <= bestRtt * 1.5 { bestRtt = min(bestRtt, rtt); offset = now - (echo + rtt / 2) }
        case "welcome":
            if let now = m["now"] as? Double { offset = now - Date().timeIntervalSince1970 * 1000 }
            retry = 0
            var keep: Any?
            if let k = m["keep"] as? String, let kd = k.data(using: .utf8),
               let kobj = try? JSONSerialization.jsonObject(with: kd) as? [String: Any],
               let d = kobj["d"] as? String, let obj = decrypt(d), obj["k"] as? String == "state" { keep = obj["s"] }
            let peers = (m["peers"] as? [[String: Any]] ?? []).compactMap { p -> (String, Double)? in
                guard let id = p["peer"] as? String else { return nil }
                return (id, p["joined"] as? Double ?? 0)
            }
            status = .connected
            core?.welcome(peers: peers, keep: keep, myJoined: m["now"] as? Double ?? 0)
        case "join":
            if let id = m["peer"] as? String { core?.join(id, joined: m["joined"] as? Double ?? 0) }
        case "leave":
            if let id = m["peer"] as? String { core?.leave(id) }
        default:
            if let from = m["from"] as? String, let d = m["d"] as? String, let obj = decrypt(d) { core?.receive(from: from, obj) }
        }
    }

    private func decrypt(_ d: String) -> [String: Any]? {
        guard let raw = Self.unb64u(d), let box = try? AES.GCM.SealedBox(combined: raw),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return try? JSONSerialization.jsonObject(with: plain) as? [String: Any]
    }

    func send(_ object: [String: Any], keep: Bool, to: String?) {
        guard task != nil, JSONSerialization.isValidJSONObject(object),
              let plain = try? JSONSerialization.data(withJSONObject: object),
              let sealed = try? AES.GCM.seal(plain, using: key).combined else { return }
        var frame: [String: Any] = ["d": Self.b64u(sealed)]
        if keep { frame["keep"] = true }
        if let to { frame["to"] = to }
        guard let data = try? JSONSerialization.data(withJSONObject: frame), let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }
}
