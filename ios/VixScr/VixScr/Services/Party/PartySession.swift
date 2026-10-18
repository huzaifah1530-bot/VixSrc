import Foundation
import Observation
import UIKit

/// What a player screen exposes to Watch Together. Implemented by
/// `CatalogViewModel` (movies & shows) and `AnimeViewModel`.
@MainActor
protocol PartyPlayerHost: AnyObject {
    var playerManager: VideoPlayerManager { get }
    func currentPartyMedia() -> PartyMedia?
    func loadPartyMedia(_ media: PartyMedia) async
    func nextPartyMedia(after media: PartyMedia) async -> PartyMedia?
    /// Steps quality down within the same audio; returns the new label.
    func stepDownQuality() -> String?
    /// Where this screen will resume the current media (saved progress).
    var partyResumePosition: Double { get }
}

extension Notification.Name {
    /// Joined a party while no player is open: open this media.
    static let velaPartyOpen = Notification.Name("vela.partyOpen")
}

/// Watch Together on iOS: owns the relay connection and keeps this
/// iPhone's player on the room's timeline. Captions, Sub/Dub, quality and
/// the personal sync nudge stay on the device.
@MainActor
@Observable
final class PartySession {
    static let shared = PartySession()

    private(set) var active = false
    private(set) var status: PartyConnection.Status = .closed
    private(set) var link = ""
    private(set) var peers: [PartyPeer] = []
    private(set) var me = ""
    private(set) var hostId = ""
    private(set) var leader = ""
    private(set) var canControl = true
    private(set) var canConfigure = false
    private(set) var mode = "everyone"
    private(set) var allowed: [String] = []
    private(set) var waitForAll = true
    private(set) var waitingOn: [String] = []
    /// Personal sync nudge in seconds (e.g. a dub that runs a little long).
    var offset: Double = 0
    var sheetOpen = false
    var toast: String?

    @ObservationIgnored private var core: PartyCore?
    @ObservationIgnored private var conn: PartyConnection?
    @ObservationIgnored private weak var host: PartyPlayerHost?
    /// App-wide pieces used when joining from a link with no player open.
    @ObservationIgnored weak var animeFallback: AnimeViewModel?
    @ObservationIgnored weak var router: TabRouter?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var loadingKey: String?
    /// Room media key → the local key it loaded as (anime slugs differ by site).
    @ObservationIgnored private var aliases: [String: String] = [:]
    @ObservationIgnored private var quietUntil = Date.distantPast
    @ObservationIgnored private var creating = false
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    private init() {}

    // MARK: - Identity (same id + secret per room, so rejoining keeps your role)

    private func identity(for room: String) -> (peer: String, secret: String) {
        let key = "vela_party_identity_" + room
        if let saved = UserDefaults.standard.dictionary(forKey: key) as? [String: String],
           let p = saved["peer"], let s = saved["secret"] { return (p, s) }
        let id = (PartyConnection.b64u(PartyConnection.rand(15)), PartyConnection.b64u(PartyConnection.rand(24)))
        UserDefaults.standard.set(["peer": id.0, "secret": id.1], forKey: key)
        return id
    }

    // MARK: - Start / join / leave

    func start(from host: PartyPlayerHost) {
        attach(host)
        begin(.new(), creating: true)
    }

    @discardableResult
    func join(_ text: String) -> Bool {
        guard let invite = PartyConnection.Invite(text: text) else { show("That isn't a Vela watch party link"); return false }
        begin(invite, creating: false)
        return true
    }

    private func begin(_ invite: PartyConnection.Invite, creating: Bool) {
        leave(silent: true)
        let id = identity(for: invite.room)
        guard let conn = PartyConnection(invite: invite, peer: id.peer, secret: id.secret) else { return }
        let core = PartyCore(me: id.peer, name: UIDevice.current.name, platform: "ios")
        core.transport = conn
        conn.core = core
        core.onChange = { [weak self] in self?.refresh() }
        core.onToast = { [weak self] in self?.show($0) }
        core.onMedia = { [weak self] media, initial, mine in self?.roomMediaChanged(media, initial: initial, mine: mine) }
        core.onStruggling = { [weak self] in self?.struggling() }
        core.nextMedia = { [weak self] media in await self?.host?.nextPartyMedia(after: media) }
        conn.onStatus = { [weak self] s in
            guard let self else { return }
            self.status = s
            if self.creating, s == .connected, self.core?.state == nil {
                self.creating = false
                let pm = self.host?.playerManager
                self.core?.create(media: self.host?.currentPartyMedia(), pos: pm?.currentTime ?? 0, playing: pm?.isPlaying ?? false)
                self.show("Watch party started — share the link")
            }
            self.refresh()
        }
        self.core = core
        self.conn = conn
        self.creating = creating
        aliases = [:]
        offset = 0
        // Rejoining a party you've been in: you're following the host already.
        let seenKey = "vela_party_seen_" + invite.room
        following = !creating && UserDefaults.standard.bool(forKey: seenKey)
        UserDefaults.standard.set(true, forKey: seenKey)
        prompt = nil
        link = invite.link
        active = true
        sheetOpen = creating
        conn.open()
        installGate()
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.syncOnce()
            }
        }
    }

    func leave(silent: Bool = false) {
        let was = core != nil
        loop?.cancel(); loop = nil
        conn?.close()
        host?.playerManager.partyGate = nil
        host?.playerManager.onEnded = nil
        host?.playerManager.setRate(1)
        core = nil; conn = nil
        active = false; status = .closed; peers = []; waitingOn = []; sheetOpen = false; prompt = nil; following = false
        if was && !silent { show("Left the watch party") }
    }

    /// Back in the foreground: reconnect immediately and catch up.
    func appBecameActive() { conn?.refreshNow() }

    // MARK: - Player attachment

    // MARK: - Following the host

    /// Viewer said "follow" once: keep following for the rest of the session.
    private(set) var following = false
    /// The host moved on; waiting for this viewer to choose.
    struct FollowPrompt: Identifiable { let id = UUID(); var media: PartyMedia?; var title: String? }
    var prompt: FollowPrompt?
    @ObservationIgnored private var closingForRoom = false

    private func roomMediaChanged(_ media: PartyMedia?, initial: Bool, mine: Bool) {
        if mine { return }
        if initial || following {
            if let media { Task { await load(media) } } else { closeForRoom() }
            return
        }
        var title: String?
        if let media {
            if case .string(let t)? = media.item["title"] { title = t }
            if let s = media.season, let e = media.tmdbEpisode { title = (title ?? "") + " · S\(s)E\(e)" }
            if let e = media.animeEpisode { title = (title ?? "") + " · E\(e)" }
        }
        prompt = FollowPrompt(media: media, title: title ?? (media == nil ? nil : "something new"))
    }

    func answerFollow(_ follow: Bool) {
        let p = prompt
        prompt = nil
        guard follow else { leave(); return }
        following = true
        if let media = p?.media { Task { await load(media) } } else { closeForRoom() }
    }

    /// The host went back to browsing: close this viewer's player, stay in the party.
    private func closeForRoom() {
        guard let host else { return }
        closingForRoom = true
        if let vm = host as? CatalogViewModel { vm.closePlayer() } else if let vm = host as? AnimeViewModel { vm.closePlayer() }
        closingForRoom = false
    }

    /// A player screen appeared (or changed what it plays).
    func attach(_ host: PartyPlayerHost) {
        if self.host !== host { self.host?.playerManager.partyGate = nil; self.host?.playerManager.onEnded = nil }
        self.host = host
        installGate()
        // The host opening something new (the player appears after open()).
        if core != nil { localMediaChanged() }
    }

    /// The player closed. Host: the room goes back to browsing (party stays
    /// open). Viewer: leaves — unless we closed it because the host did.
    func detach(_ host: PartyPlayerHost) {
        guard self.host === host, let core else { return }
        host.playerManager.partyGate = nil
        host.playerManager.onEnded = nil
        self.host = nil
        if closingForRoom { return }
        if core.isLeader { core.setMedia(nil) } else { leave(); show("You left the watch party") }
    }

    private func installGate() {
        guard let pm = host?.playerManager, core != nil else { return }
        pm.partyGate = { [weak self] action in
            guard let self, let core = self.core else { return true }
            switch action {
            case .play: return core.play()
            case .pause: return core.pause()
            case .seek(let t): return core.seek(t - self.offset)
            }
        }
        pm.onEnded = { [weak self] in self?.core?.ended() }
    }

    /// The local screen moved to another title / episode (user's choice).
    func localMediaChanged() {
        guard let core, let media = currentKeyedMedia() else { return }
        let room = core.state?.tl.media?.key
        // While loading what the room asked for, local changes are ours.
        guard media.key != room, loadingKey == nil else { return }
        if core.isLeader {
            // The host picked something else: the room follows, starting
            // where the host resumes (not 0:00).
            core.setMedia(media, startAt: host?.partyResumePosition ?? 0)
        } else {
            leave()               // a viewer going their own way leaves
            show("You left the watch party")
        }
    }

    /// A personal reload (Sub/Dub, quality) — don't hold the room for it.
    func personalReload() { quietUntil = Date().addingTimeInterval(8) }

    private func currentKeyedMedia() -> PartyMedia? {
        guard var m = host?.currentPartyMedia() else { return nil }
        if let roomKey = aliases.first(where: { $0.value == m.key })?.key { m.key = roomKey }
        return m
    }

    // MARK: - Room → local

    private func load(_ media: PartyMedia?) async {
        guard let media else { return }
        if currentKeyedMedia()?.key == media.key || loadingKey == media.key { return }
        loadingKey = media.key
        defer { Task { @MainActor in try? await Task.sleep(nanoseconds: 1_500_000_000); if self.loadingKey == media.key { self.loadingKey = nil } } }
        if let host {
            await host.loadPartyMedia(media)
            if let local = host.currentPartyMedia()?.key { aliases[media.key] = local }
        } else if media.kind == "anime", let anime = animeFallback {
            // No player yet (joined from a link). The Anime tab may not have
            // been opened yet, so drive its (app-wide) view model directly.
            router?.selection = .anime
            attach(anime)
            await anime.loadPartyMedia(media)
            if let local = anime.currentPartyMedia()?.key { aliases[media.key] = local }
        } else {
            // Home is always loaded; it opens movies and shows.
            router?.selection = .home
            NotificationCenter.default.post(name: .velaPartyOpen, object: media)
        }
    }

    // MARK: - Sync loop

    private func syncOnce() {
        guard let core, core.state != nil else { return }
        let target = core.target()
        let quiet = Date() < quietUntil
        // The host is browsing: everyone waits.
        guard let media = target.media else { core.setLoading(false); core.tick(); return }
        if currentKeyedMedia()?.key != media.key {
            // Waiting for this viewer to answer "follow the host?"
            if prompt != nil { core.tick(); return }
            if loadingKey != media.key { Task { await load(media) } }
            core.setLoading(true)
            core.tick()
            return
        }
        guard let pm = host?.playerManager, pm.player != nil, pm.duration > 0 || pm.currentTime > 0 else {
            core.setLoading(!quiet)
            core.tick()
            return
        }
        core.setLoading(false)
        let pos = pm.livePosition
        let ended = pm.duration > 0 && pos >= pm.duration - 0.6
        let c = core.sync(localPos: pos - offset, localPlaying: pm.isPlaying, ended: ended, quiet: quiet)
        if ended && c.play { core.tick(); return } // the host is moving the room on
        if let seek = c.seek { pm.rawSeek(to: seek + offset) }
        if c.play && !pm.isPlaying { pm.rawPlay() }
        if !c.play && pm.isPlaying { pm.rawPause() }
        pm.setRate(c.rate)
        core.tick()
    }

    /// Paused here while the room plays (e.g. left the app): re-sync now.
    func resyncSoon() { quietUntil = Date().addingTimeInterval(3) }

    private func struggling() {
        if let label = host?.stepDownQuality() {
            personalReload()
            show("Your connection is struggling to keep up — switched to \(label)")
        } else {
            show("Your connection is struggling to keep up with the party")
        }
    }

    // MARK: - Host settings

    func setMode(_ m: String) { core?.configure { $0.mode = m } }
    func setWaitForAll(_ on: Bool) { core?.configure { $0.waitForAll = on } }
    func toggleAllowed(_ peer: String) {
        core?.configure { cfg in
            if cfg.allowed.contains(peer) { cfg.allowed.removeAll { $0 == peer } } else { cfg.allowed.append(peer) }
        }
    }
    func nudge(_ by: Double) { offset = (offset + by * 10).rounded() / 10 }

    func peerCanControl(_ peer: String) -> Bool {
        peer == leader || mode == "everyone" || (mode == "select" && allowed.contains(peer))
    }

    // MARK: - View state

    private func refresh() {
        guard let core else { return }
        peers = core.peers.values.sorted { $0.joined < $1.joined }
        me = core.me
        hostId = core.state?.cfg.host ?? ""
        leader = core.leader
        canControl = core.canControl()
        canConfigure = core.canConfigure()
        mode = core.state?.cfg.mode ?? "everyone"
        allowed = core.state?.cfg.allowed ?? []
        waitForAll = core.state?.cfg.waitForAll ?? true
        waitingOn = core.waitingOn().map(\.name)
    }

    func show(_ message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
