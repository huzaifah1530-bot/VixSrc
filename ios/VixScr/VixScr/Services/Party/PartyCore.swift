import Foundation

/// Watch Together sync core — a line-for-line Swift twin of the desktop's
/// `desktop/src/shared/party.ts` (which has the scenario notes and the
/// multi-viewer simulation tests). Keep the two in step.
enum PartyRules {
    static let version = 1
    static let waitLimit: TimeInterval = 15
    static let waitMaxPeers = 8
    /// Off by more than this and a player jumps; under it, speed eases the gap out.
    static let hardSync = 5.0
    /// Players that can't change speed (web players) only have jumps, so they use less.
    static let hardSyncCoarse = 2.0
    /// Every `probeEvery` the leader asks everyone where they are at one agreed moment.
    static let probeEvery: TimeInterval = 30
    static let probeLead: TimeInterval = 10
    static let probeCollect: TimeInterval = 4
    /// The leader's own player differing from the timeline by more than this moves the timeline to it.
    static let reanchor = 0.3
    static let softSync = 0.25
    static let peerTimeout: TimeInterval = 75
    static let aliveEvery: TimeInterval = 30
    static let stallWindow: TimeInterval = 1.5
    static let stallGrace: TimeInterval = 2.5
    static let hardSeekCooldown: TimeInterval = 4
    static let reholdCooldown: TimeInterval = 3
}

struct PartyMedia: Codable, Equatable {
    var kind: String          // "tmdb" | "anime"
    var key: String
    var item: [String: JSONValue]
    var season: Int?
    var episode: JSONValue?   // Int for tmdb, String for anime
    var episodeTitle: String?
    var slug: String?
    var title: String?
    var server: String

    enum CodingKeys: String, CodingKey { case kind, key, item, season, episode, episodeTitle, slug, title, server }

    // Swift would leave nil fields out; the desktop expects an explicit null
    // for season / episode, so write them that way.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(key, forKey: .key)
        try c.encode(item, forKey: .item)
        try c.encode(season, forKey: .season)
        try c.encode(episode, forKey: .episode)
        try c.encodeIfPresent(episodeTitle, forKey: .episodeTitle)
        try c.encodeIfPresent(slug, forKey: .slug)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encode(server, forKey: .server)
    }

    var tmdbEpisode: Int? { if case .number(let n)? = episode { return Int(n) } else { return nil } }
    var animeEpisode: String? { if case .string(let s)? = episode { return s } else { return nil } }
}

struct PartyTimeline: Codable, Equatable {
    var n: Int
    var by: String
    var media: PartyMedia?
    var playing: Bool
    var pos: Double
    var at: Double
    var hold: Bool

    enum CodingKeys: String, CodingKey { case n, by, media, playing, pos, at, hold }

    // "No media" must be sent as null, not left out (the desktop rejects a missing field).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(n, forKey: .n)
        try c.encode(by, forKey: .by)
        try c.encode(media, forKey: .media)
        try c.encode(playing, forKey: .playing)
        try c.encode(pos, forKey: .pos)
        try c.encode(at, forKey: .at)
        try c.encode(hold, forKey: .hold)
    }
}

struct PartyConfig: Codable, Equatable {
    var n: Int
    var host: String
    var mode: String          // "everyone" | "host" | "select"
    var allowed: [String]
    var waitForAll: Bool
}

struct PartyRoomState: Codable, Equatable {
    var v: Int
    var tl: PartyTimeline
    var cfg: PartyConfig
}

struct PartyPeer: Identifiable, Equatable {
    var id: String
    var name: String
    var platform: String
    var joined: Double
    var buffering = false
    var bufSince = Date.distantPast
    var error: String?
    var lastSeen = Date()
    /// Seconds ahead (+) or behind (-) the leader at the last check.
    var gap: Double?
}

struct PartyCorrection { var play: Bool; var rate: Float; var seek: Double?; var drift: Double }

@MainActor
protocol PartyTransport: AnyObject {
    func send(_ object: [String: Any], keep: Bool, to: String?)
    func now() -> Double
    var isOpen: Bool { get }
}

@MainActor
final class PartyCore {
    let me: String
    let name: String
    let platform: String
    weak var transport: PartyTransport?

    private(set) var state: PartyRoomState?
    private(set) var peers: [String: PartyPeer] = [:]
    private(set) var connected = false
    private(set) var joinedAt = Double.greatestFiniteMagnitude
    private var excluded = Set<String>()
    private var myBuffering = false
    private var hardSyncs: [Date] = []
    private var advancing = false
    private var lastSentTimeline = Date.distantPast
    private var lastAlive = Date.distantPast

    /// Room media changed. `initial` = first state after (re)joining; `mine` = we changed it.
    var onMedia: ((PartyMedia?, _ initial: Bool, _ mine: Bool) -> Void)?
    var onChange: (() -> Void)?
    var onToast: ((String) -> Void)?
    var onStruggling: (() -> Void)?
    var nextMedia: ((PartyMedia) async -> PartyMedia?)?

    init(me: String, name: String, platform: String) {
        self.me = me; self.name = name; self.platform = platform
    }

    // MARK: Roles

    private func present(_ id: String) -> Bool {
        id == me || peers[id].map { Date().timeIntervalSince($0.lastSeen) < PartyRules.peerTimeout } == true
    }

    var leader: String {
        if let host = state?.cfg.host, present(host) { return host }
        let all = peers.values.filter { present($0.id) }.map { ($0.id, $0.joined) } + [(me, joinedAt)]
        return all.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }.first!.0
    }
    var isLeader: Bool { leader == me }
    var isHost: Bool { state?.cfg.host == me }

    func canControl(_ id: String? = nil) -> Bool {
        let id = id ?? me
        guard let cfg = state?.cfg else { return true }
        return canControl(id, under: cfg)
    }

    private func canControl(_ id: String, under cfg: PartyConfig) -> Bool {
        if id == leader { return true }
        return cfg.mode == "everyone" || (cfg.mode == "select" && cfg.allowed.contains(id))
    }

    func canConfigure(_ id: String? = nil) -> Bool { (id ?? me) == leader }

    // MARK: Transport events

    func create(media: PartyMedia?, pos: Double, playing: Bool) {
        let now = transport?.now() ?? 0
        state = PartyRoomState(
            v: PartyRules.version,
            tl: PartyTimeline(n: 1, by: me, media: media, playing: playing, pos: pos, at: now, hold: false),
            cfg: PartyConfig(n: 1, host: me, mode: "everyone", allowed: [], waitForAll: true)
        )
        publish()
    }

    func welcome(peers list: [(String, Double)], keep: Any?, myJoined: Double) {
        connected = true
        joinedAt = myJoined
        peers = Dictionary(uniqueKeysWithValues: list.map { ($0.0, PartyPeer(id: $0.0, name: "…", platform: "", joined: $0.1)) })
        transport?.send(["k": "hello", "name": name, "platform": platform, "buffering": myBuffering], keep: false, to: nil)
        if let incoming = parse(keep) { adopt(incoming, force: true) }
        else if state != nil && isLeader { publish() }
        onChange?()
    }

    func disconnected() { connected = false; onChange?() }

    func join(_ peer: String, joined: Double) {
        peers[peer] = PartyPeer(id: peer, name: "…", platform: "", joined: joined)
        transport?.send(["k": "hello", "name": name, "platform": platform, "buffering": myBuffering], keep: false, to: peer)
        onChange?()
    }

    func leave(_ peer: String) {
        let was = peers.removeValue(forKey: peer)
        excluded.remove(peer)
        if let was {
            if state?.cfg.host == peer {
                let who = isLeader ? "you are" : "\(peers[leader]?.name ?? "someone") is"
                onToast?("\(was.name) (host) left — \(who) in charge until they're back")
            } else {
                onToast?("\(was.name) left")
            }
        }
        onChange?()
    }

    func receive(from: String, _ m: [String: Any]) {
        guard let k = m["k"] as? String else { return }
        peers[from]?.lastSeen = Date()
        switch k {
        case "alive": return
        case "hello":
            guard peers[from] != nil else { return }
            peers[from]!.name = (m["name"] as? String).map { String($0.prefix(60)) } ?? "Guest"
            peers[from]!.platform = (m["platform"] as? String).map { String($0.prefix(20)) } ?? ""
            peers[from]!.buffering = m["buffering"] as? Bool == true
            peers[from]!.bufSince = peers[from]!.buffering ? Date() : .distantPast
            onChange?()
        case "state":
            guard var s = parse(m["s"]) else { return }
            let mediaChange = state != nil && state!.tl.media?.key != s.tl.media?.key
            let tlOk = s.tl.by == from && canControl(from, under: state?.cfg ?? s.cfg) && (!mediaChange || from == leader)
            let cfgOk = state == nil || s.cfg == state!.cfg || canConfigure(from)
            if !cfgOk { s.cfg = state!.cfg }
            if !tlOk, let current = state { s.tl = current.tl }
            adopt(s, force: false)
        case "buf":
            guard peers[from] != nil else { return }
            let on = m["on"] as? Bool == true
            if on != peers[from]!.buffering {
                peers[from]!.buffering = on
                peers[from]!.bufSince = on ? Date() : .distantPast
                if !on { excluded.remove(from) }
            }
            peers[from]!.error = (m["error"] as? String).map { String($0.prefix(200)) }
            onChange?()
        case "probe":
            guard from == leader, from != me, let id = m["id"] as? Int, let at = m["at"] as? Double else { return }
            let tn = transport?.now() ?? 0
            guard at >= tn - 1000, at <= tn + 30_000 else { return }
            probe = Probe(id: id, at: at, from: from, n: -1)
        case "probe-reply":
            guard let p = probe, p.from == me, m["id"] as? Int == p.id, let pos = m["pos"] as? Double,
                  pos.isFinite, pos >= 0, pos < 1e6, peers[from] != nil else { return }
            probe?.replies[from] = pos
        case "probe-result":
            guard from == leader, let gaps = m["gaps"] as? [String: Any] else { return }
            for (id, raw) in gaps.prefix(200) {
                guard let g = raw as? Double, g.isFinite else { continue }
                if id == me { myGap = g } else { peers[id]?.gap = g }
            }
            peers[from]?.gap = 0
            onChange?()
        case "req-sync":
            if let state, isLeader, let obj = Self.object(state) { transport?.send(["k": "state", "s": obj], keep: false, to: from) }
        default: break
        }
    }

    private func parse(_ raw: Any?) -> PartyRoomState? {
        guard let raw, JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let s = try? JSONDecoder().decode(PartyRoomState.self, from: data),
              s.v == PartyRules.version, s.tl.pos.isFinite, s.tl.pos >= 0, s.tl.pos < 1e6,
              ["everyone", "host", "select"].contains(s.cfg.mode), s.cfg.allowed.count <= 500 else { return nil }
        return s
    }

    static func object<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func newer(_ a: PartyTimeline, _ b: PartyTimeline) -> Bool {
        a.n != b.n ? a.n > b.n : a.by > b.by
    }

    private func adopt(_ s: PartyRoomState, force: Bool) {
        let prev = state
        var tl = prev?.tl ?? s.tl, cfg = prev?.cfg ?? s.cfg
        if prev == nil || force || Self.newer(s.tl, prev!.tl) { tl = s.tl }
        if prev == nil || force || s.cfg.n > prev!.cfg.n { cfg = s.cfg }
        let mediaChanged = prev?.tl.media?.key != tl.media?.key
        state = PartyRoomState(v: PartyRules.version, tl: tl, cfg: cfg)
        if mediaChanged { resetProgress(Date()); stalled = false }
        if mediaChanged || force { onMedia?(tl.media, force || prev == nil, tl.by == me) }
        onChange?()
    }

    private func publish() {
        guard let state, let obj = Self.object(state) else { return }
        lastSentTimeline = Date()
        transport?.send(["k": "state", "s": obj], keep: true, to: nil)
        onChange?()
    }

    // MARK: User actions

    private func bump(keepHold: Bool = false, _ change: (inout PartyTimeline) -> Void) -> Bool {
        guard var current = state, connected, transport?.isOpen == true else { onToast?("Reconnecting to the party…"); return false }
        guard canControl() else { onToast?("The host is controlling playback"); return false }
        let now = transport?.now() ?? 0
        var tl = current.tl
        tl.pos = Self.position(tl, now: now)
        tl.at = now
        // A seek during a "waiting for…" hold keeps the hold so the room
        // still resumes by itself; play / pause / new media ends it.
        if !keepHold { tl.hold = false }
        change(&tl)
        tl.n = current.tl.n + 1
        tl.by = me
        current.tl = tl
        state = current
        publish()
        return true
    }

    @discardableResult func play() -> Bool { bump { $0.playing = true } }
    @discardableResult func pause() -> Bool { bump { $0.playing = false } }
    @discardableResult func seek(_ pos: Double) -> Bool { bump(keepHold: true) { $0.pos = max(0, pos) } }
    @discardableResult func skip(_ by: Double) -> Bool { seek(target().pos + by) }

    /// Only the host (or acting host) picks what the room watches. `nil` = browsing.
    @discardableResult func setMedia(_ media: PartyMedia?, startAt: Double = 0) -> Bool {
        guard isLeader else { onToast?("Only the host can change what's playing"); return false }
        let ok = bump { $0.media = media; $0.pos = max(0, startAt); $0.playing = media != nil }
        if ok { onMedia?(media, false, true) }
        return ok
    }

    @discardableResult func configure(_ change: (inout PartyConfig) -> Void) -> Bool {
        guard var current = state, canConfigure() else { return false }
        var cfg = current.cfg
        change(&cfg)
        cfg.n = current.cfg.n + 1
        cfg.host = current.cfg.host
        current.cfg = cfg
        state = current
        publish()
        return true
    }

    // MARK: Player

    static func position(_ tl: PartyTimeline, now: Double) -> Double {
        tl.playing ? tl.pos + max(0, now - tl.at) / 1000 : tl.pos
    }

    func target() -> (media: PartyMedia?, playing: Bool, pos: Double) {
        guard let tl = state?.tl else { return (nil, false, 0) }
        return (tl.media, tl.playing, Self.position(tl, now: transport?.now() ?? 0))
    }

    static func correction(localPos: Double, localPlaying: Bool, target: (playing: Bool, pos: Double), canNudge: Bool = true) -> PartyCorrection {
        let drift = localPos - target.pos
        if !target.playing {
            return PartyCorrection(play: false, rate: 1, seek: abs(drift) > 0.5 ? target.pos : nil, drift: drift)
        }
        if abs(drift) > (canNudge ? PartyRules.hardSync : PartyRules.hardSyncCoarse) { return PartyCorrection(play: true, rate: 1, seek: target.pos + 0.25, drift: drift) }
        if !canNudge { return PartyCorrection(play: true, rate: 1, seek: nil, drift: drift) }
        // Smooth catch-up: the bigger the gap, the stronger the nudge (5 / 10 / 15 %).
        let a = abs(drift)
        let step: Float = a < PartyRules.softSync ? 0 : a < 1 ? 0.05 : a < 2.5 ? 0.1 : 0.15
        let rate: Float = drift > 0 ? 1 - step : 1 + step
        return PartyCorrection(play: true, rate: rate, seek: nil, drift: drift)
    }

    // Stall detection from real progress (see party.ts): the player's own
    // "waiting" flag flickers on seeks and speed changes, which made a host
    // hold the room for themselves over and over (the freezing loop).
    private var samples: [(t: Date, pos: Double)] = []
    private var wantSince: Date?
    private var stalled = false
    private var loading = false
    private var loadingError: String?
    private var lastHardSeek = Date.distantPast
    private var lastHardSeekN = -1
    private var lastResume = Date.distantPast
    var buffering: Bool { myBuffering }

    func sync(localPos: Double, localPlaying: Bool, ended: Bool = false, quiet: Bool = false, canNudge: Bool = true) -> PartyCorrection {
        let now = Date()
        let t = target()
        answerProbe(localPos, localPlaying)
        let holdingForMe = state?.tl.hold == true && stalled
        let want = (t.playing || holdingForMe) && !ended
        // At the end while the room still plays: the host moves it on
        // (retried every tick, so a missed "ended" event can't strand the room).
        if ended && t.playing && isLeader { self.ended() }

        samples = samples.filter { now.timeIntervalSince($0.t) < 2.5 } + [(now, localPos)]
        var notMoving = false
        if !want || quiet {
            stalled = false
            wantSince = nil
        } else {
            if wantSince == nil { wantSince = now }
            // Position jumped back (new episode, reload): restart measuring.
            if samples.count >= 2, localPos < samples[samples.count - 2].pos - 1 { resetProgress(now) }
            if let old = samples.first(where: { now.timeIntervalSince($0.t) >= PartyRules.stallWindow }) {
                let moved = localPos - old.pos
                notMoving = moved < 0.3
                if notMoving && now.timeIntervalSince(wantSince!) > PartyRules.stallGrace { stalled = true }
                else if moved > 0.8 { stalled = false }
            }
        }
        publishBuffering()

        // The room is waiting for us: keep trying to play where it stopped.
        if holdingForMe {
            let seek: Double? = abs(localPos - t.pos) > 3 ? t.pos : nil
            if seek != nil { resetProgress(now) }
            return PartyCorrection(play: true, rate: 1, seek: seek, drift: localPos - t.pos)
        }

        // Alone in the room: this player is the timeline. Re-anchor instead
        // of chasing (clock-sync adjustments made a solo host hunt and stutter).
        if isLeader && peers.isEmpty && t.playing && localPlaying && connected, var current = state {
            if abs(localPos - t.pos) > 1 {
                current.tl.pos = localPos
                current.tl.at = transport?.now() ?? 0
                current.tl.n += 1
                current.tl.by = me
                state = current
                publish()
            }
            return PartyCorrection(play: true, rate: 1, seek: nil, drift: 0)
        }

        var c = Self.correction(localPos: localPos, localPlaying: localPlaying, target: (t.playing, t.pos), canNudge: canNudge)
        if c.seek != nil && t.playing {
            if c.drift < 0 && (notMoving || stalled) {
                // Behind because we're stuck: jumping ahead lands on more unbuffered video.
                c.seek = nil; c.rate = 1
            } else if now.timeIntervalSince(lastHardSeek) < PartyRules.hardSeekCooldown && lastHardSeekN == state?.tl.n && abs(c.drift) < 15 {
                // The last jump is still loading: steer with speed instead.
                c.seek = nil; c.rate = c.drift > 0 ? 0.9 : 1.1
            } else {
                lastHardSeek = now
                lastHardSeekN = state?.tl.n ?? 0
                hardSyncs = hardSyncs.filter { now.timeIntervalSince($0) < 30 } + [now]
                if hardSyncs.count >= 3 { hardSyncs = []; onStruggling?() }
            }
        }
        if c.seek != nil { resetProgress(now) }
        return c
    }

    private func resetProgress(_ now: Date) { samples = []; wantSince = now }

    /// No player yet / loading the room's media (counts as buffering).
    func setLoading(_ on: Bool, error: String? = nil) {
        loading = on
        loadingError = error
        publishBuffering()
    }

    private func publishBuffering() {
        let on = loading || stalled
        guard on != myBuffering else { return }
        myBuffering = on
        if connected {
            var msg: [String: Any] = ["k": "buf", "on": on]
            if let loadingError { msg["error"] = loadingError }
            transport?.send(msg, keep: false, to: nil)
        }
    }

    func ended() {
        guard let media = state?.tl.media, isLeader, !advancing else { return }
        advancing = true
        Task { @MainActor in
            defer { advancing = false }
            let next = await nextMedia?(media)
            guard state?.tl.media?.key == media.key else { return }
            if let next { setMedia(next) } else { pause() }
        }
    }

    // MARK: Leader duties (call ~1/s)

    func tick() {
        if connected && Date().timeIntervalSince(lastAlive) > PartyRules.aliveEvery {
            lastAlive = Date()
            transport?.send(["k": "alive"], keep: false, to: nil)
        }
        guard var current = state, connected, isLeader else { return }
        let now = Date()
        let stalled = peers.values.filter { $0.buffering && !excluded.contains($0.id) && present($0.id) }.sorted { $0.bufSince < $1.bufSince }
        for p in stalled where now.timeIntervalSince(p.bufSince) > PartyRules.waitLimit {
            excluded.insert(p.id)
            onToast?("Carrying on without \(p.name) — they'll catch up")
        }
        let waitingOn = stalled.filter { !excluded.contains($0.id) }.prefix(PartyRules.waitMaxPeers)
        let tl = current.tl
        let cooling = now.timeIntervalSince(lastResume) < PartyRules.reholdCooldown
        // Alone, there's nobody to hold the room for: the timeline just follows us.
        if current.cfg.waitForAll && tl.playing && !cooling && (!waitingOn.isEmpty || (myBuffering && !peers.isEmpty)) && tl.media != nil {
            bumpAsLeader(&current) { $0.playing = false; $0.hold = true }
        } else if tl.hold && !tl.playing && waitingOn.isEmpty && !myBuffering {
            lastResume = now
            bumpAsLeader(&current) { $0.playing = true; $0.hold = false }
        } else if now.timeIntervalSince(lastSentTimeline) > 30 {
            publish()
        }
        leaderProbe()
    }

    // MARK: Periodic "where is everyone?" check
    // Every `probeEvery` the leader names a moment about `probeLead` ahead on
    // the shared clock. Everyone reports its position *at that moment*, so
    // slower replies don't skew the comparison. The leader is the reference:
    // it tells the room each gap, and if its own player has drifted from the
    // timeline, the timeline moves to the leader. Everyone then closes any gap
    // themselves: smoothly under `hardSync`, with a jump above it.

    private struct Probe {
        var id: Int
        var at: Double
        var from: String
        var answered = false
        var own: Double?
        var replies: [String: Double] = [:]
        var n: Int
    }
    private var probe: Probe?
    private var probeSeq = 0
    private var lastProbe = Date.distantPast
    /// Our gap to the leader at the last check (seconds, + = ahead).
    private(set) var myGap: Double?

    private func leaderProbe() {
        guard let st = state else { return }
        let tn = transport?.now() ?? 0
        if let p = probe, p.from == me {
            // Someone changed playback during the check: the answers are stale.
            if st.tl.n != p.n || !st.tl.playing || st.tl.hold { probe = nil; return }
            if tn >= p.at + PartyRules.probeCollect * 1000 { finishProbe(p) }
            return
        }
        guard Date().timeIntervalSince(lastProbe) >= PartyRules.probeEvery, st.tl.playing, !st.tl.hold,
              st.tl.media != nil, !peers.isEmpty else { return }
        lastProbe = Date()
        probeSeq += 1
        let p = Probe(id: probeSeq, at: tn + PartyRules.probeLead * 1000, from: me, n: st.tl.n)
        probe = p
        transport?.send(["k": "probe", "id": p.id, "at": p.at], keep: false, to: nil)
    }

    /// Called from sync(): once the agreed moment has passed, report where we were at it.
    private func answerProbe(_ localPos: Double, _ playing: Bool) {
        guard var p = probe, !p.answered else { return }
        let tn = transport?.now() ?? 0
        if tn < p.at { return }
        if tn > p.at + 8000 { if p.from != me { probe = nil }; return }
        p.answered = true
        let pos = playing ? localPos - (tn - p.at) / 1000 : localPos
        if p.from == me { p.own = pos } else { transport?.send(["k": "probe-reply", "id": p.id, "pos": pos], keep: false, to: p.from) }
        probe = p
    }

    private func finishProbe(_ p: Probe) {
        probe = nil
        guard let own = p.own, var current = state else { return }
        var gaps: [String: Double] = [:]
        for (id, pos) in p.replies where peers[id] != nil {
            let g = ((pos - own) * 100).rounded() / 100
            gaps[id] = g
            peers[id]?.gap = g
        }
        myGap = 0
        transport?.send(["k": "probe-result", "id": p.id, "gaps": gaps], keep: false, to: nil)
        let tn = transport?.now() ?? 0
        let expected = Self.position(current.tl, now: p.at)
        if abs(own - expected) > PartyRules.reanchor && !myBuffering && !loading {
            bumpAsLeader(&current) { $0.pos = own + max(0, tn - p.at) / 1000 }
        }
        onChange?()
    }

    private func bumpAsLeader(_ current: inout PartyRoomState, _ change: (inout PartyTimeline) -> Void) {
        let now = transport?.now() ?? 0
        var tl = current.tl
        tl.pos = Self.position(tl, now: now)
        tl.at = now
        change(&tl)
        tl.n += 1
        tl.by = me
        current.tl = tl
        state = current
        publish()
    }

    func waitingOn() -> [PartyPeer] {
        guard state?.tl.hold == true else { return [] }
        return peers.values.filter { $0.buffering && !excluded.contains($0.id) }
    }
}
