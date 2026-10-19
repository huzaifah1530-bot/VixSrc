import SwiftUI

/// Toolbar button in both player sheets. Opens the party sheet (or starts a
/// party). When playback is routed to a computer, the computer is the one
/// in the party and this iPhone just controls it.
struct PartyButton<Host: PartyPlayerHost>: View {
    let host: Host
    @State private var party = PartySession.shared
    @State private var link = DeviceLink.shared
    @State private var confirming = false
    @State private var proceed = false
    @Environment(\.glassFidelity) private var fidelity

    var body: some View {
        Button {
            if link.routesPlayback {
                party.sheetOpen = true
            } else if party.active {
                party.sheetOpen = true
            } else {
                confirming = true
            }
        } label: {
            Image(systemName: party.active || link.remote?.party != nil ? "person.2.fill" : "person.2")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(party.active ? Color.blue : .white)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(party.active ? "Watch party, \(party.peers.count + 1) watching" : "Watch Together")
        .sheet(isPresented: $party.sheetOpen) { PartySheet() }
        .sheet(isPresented: $confirming, onDismiss: {
            // Start once the confirmation has fully gone, so the invite sheet can appear.
            if proceed { proceed = false; party.start(from: host) }
        }) {
            StartPartySheet { proceed = true }
        }
    }
}

/// Explains Watch Together before anything is created.
struct StartPartySheet: View {
    let onContinue: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.blue)
                    .accessibilityHidden(true)
                Text("Watch Together")
                    .font(.title2.bold())
                Text("Watch this with friends in sync. Playback, pausing and seeking stay in step for everyone, and the room waits if someone is buffering.\n\nContinuing creates a room and gives you an invite link. Anyone with the link can join, and everything in the room is end-to-end encrypted.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer(minLength: 0)
                Button {
                    onContinue()
                    dismiss()
                } label: {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(24)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
    }
}

struct PartySheet: View {
    @State private var party = PartySession.shared
    @State private var link = DeviceLink.shared
    @State private var joinText = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if link.routesPlayback {
                    computerSection
                } else if party.active {
                    inviteSection
                    peopleSection
                    if party.canConfigure { hostSection }
                    nudgeSection
                    Section { Button("Leave Party", role: .destructive) { party.leave(); dismiss() } }
                } else {
                    joinSection
                }
            }
            .navigationTitle("Watch Together")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    private var statusText: String {
        switch party.status {
        case .connected: return "\(party.peers.count + 1) watching"
        case .reconnecting: return "Reconnecting…"
        case .connecting: return "Connecting…"
        case .closed: return "Not connected"
        }
    }

    private var inviteSection: some View {
        Section {
            ShareLink(item: URL(string: party.link)!, message: Text("Watch with me on Vela")) {
                Label("Share Invite Link", systemImage: "square.and.arrow.up")
            }
            Button {
                UIPasteboard.general.string = party.link
                party.show("Invite link copied")
            } label: { Label("Copy Link", systemImage: "doc.on.doc") }
        } header: {
            Text(statusText)
        } footer: {
            Text("Anyone with the link can join. Everything in the room is end-to-end encrypted with a key that only lives in the link.")
        }
    }

    private var peopleSection: some View {
        Section("People") {
            personRow(id: party.me, name: "You", buffering: false, error: nil)
            ForEach(party.peers) { p in personRow(id: p.id, name: p.name, buffering: p.buffering, error: p.error, gap: p.gap) }
        }
    }

    // From the host's 30-second check: only worth mentioning when noticeable.
    private func gapText(_ gap: Double?) -> String {
        guard let gap, abs(gap) >= 0.5 else { return "" }
        return String(format: " · %.1fs %@", abs(gap), gap > 0 ? "ahead" : "behind")
    }

    private func personRow(id: String, name: String, buffering: Bool, error: String?, gap: Double? = nil) -> some View {
        HStack {
            Circle().fill(error != nil ? .red : buffering ? .yellow : .green).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
                    if id == party.hostId { badge("HOST") } else if id == party.leader { badge("ACTING HOST") }
                }
                Text(error ?? (buffering ? "Buffering…" : (party.peerCanControl(id) ? "Can control" : "Watching") + gapText(gap)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if party.canConfigure && party.mode == "select" && id != party.me {
                Button(party.allowed.contains(id) ? "Can Control" : "Allow") { party.toggleAllowed(id) }
                    .buttonStyle(.bordered)
                    .tint(party.allowed.contains(id) ? .blue : .gray)
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Color.white.opacity(0.1), in: Capsule())
    }

    private var hostSection: some View {
        Section {
            Picker("Who Can Control", selection: Binding(get: { party.mode }, set: { party.setMode($0) })) {
                Text("Everyone").tag("everyone")
                Text("Only Me").tag("host")
                Text("People I Pick").tag("select")
            }
            Toggle("Wait for Anyone Buffering", isOn: Binding(get: { party.waitForAll }, set: { party.setWaitForAll($0) }))
        } header: {
            Text("Host")
        } footer: {
            Text("Waiting pauses the room for up to 15 seconds while someone buffers; after that the room carries on and they catch up. If you leave, the person who's been here longest takes over until you're back.")
        }
    }

    private var nudgeSection: some View {
        Section {
            HStack {
                Button("−0.5s") { party.nudge(-0.5) }.buttonStyle(.bordered)
                Spacer()
                Text(String(format: "%+.1fs", party.offset)).monospacedDigit().font(.headline)
                Spacer()
                Button("+0.5s") { party.nudge(0.5) }.buttonStyle(.bordered)
            }
        } header: {
            Text("Your Sync")
        } footer: {
            Text("Only shifts your own player — useful if your dub runs slightly ahead or behind. Captions, Sub/Dub and quality are always your own choice.")
        }
    }

    private var joinSection: some View {
        Section {
            TextField("Paste an invite link", text: $joinText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Join Party") { if party.join(joinText) { dismiss() } }
                .disabled(joinText.isEmpty)
        } footer: {
            Text("Or start one from the player's Watch Together button.")
        }
    }

    // Phone is a remote for the computer: the computer is in the party.
    @ViewBuilder private var computerSection: some View {
        let pc = link.playbackTarget?.name ?? "your computer"
        if let p = link.remote?.party {
            Section {
                if let url = URL(string: p.link) {
                    ShareLink(item: url, message: Text("Watch with me on Vela")) { Label("Share Invite Link", systemImage: "square.and.arrow.up") }
                }
                Button("Leave Party on \(pc)", role: .destructive) { link.command("party-leave") }
            } header: {
                Text("\(p.count) watching · on \(pc)")
            } footer: {
                Text("\(pc) is in the party; this iPhone controls it.")
            }
        } else {
            Section {
                Button { link.command("party-start") } label: { Label("Start Party on \(pc)", systemImage: "person.2") }
            } footer: {
                Text("Playback is on \(pc), so it joins the party and this iPhone stays the remote.")
            }
            Section("Join") {
                TextField("Paste an invite link", text: $joinText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Join on \(pc)") { link.command("party-join", ["link": joinText]) }.disabled(joinText.isEmpty)
            }
        }
    }
}

/// Floating party pill while browsing (the player has its own button).
struct PartyDock: View {
    @State private var party = PartySession.shared
    var body: some View {
        if party.active {
            Button { party.sheetOpen = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "person.2.fill")
                    Text(party.status == .reconnecting ? "Reconnecting…" : "\(party.peers.count + 1) in party")
                        .font(.subheadline.weight(.semibold))
                    Text(party.canConfigure ? "· pick something" : "· waiting for host")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 10)
                // Non-interactive glass: the interactive (.strong) kind swallowed
                // the taps, so the dock could not be opened.
                .vixGlass(.regular, cornerRadius: 22)
                .contentShape(RoundedRectangle(cornerRadius: 22))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 84)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .sheet(isPresented: $party.sheetOpen) { PartySheet() }
            .accessibilityLabel("Watch party, \(party.peers.count + 1) people")
        }
    }
}

@MainActor @Observable final class PartyPasteFlag {
    static let shared = PartyPasteFlag()
    var found = false
}

/// Shown when something that looks like a link is on the clipboard — for
/// LiveContainer, where tapping an invite link can't open Vela directly.
struct PartyPasteBanner: View {
    @State private var party = PartySession.shared
    @State private var show = false
    @State private var lastChange = UserDefaults.standard.integer(forKey: "vela_party_paste_seen")
    /// Settings › Watch Together can switch the banner off.
    @AppStorage("vela_party_paste_banner") private var bannerEnabled = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if show && bannerEnabled && !party.active {
                HStack(spacing: 10) {
                    Image(systemName: "person.2.fill")
                    Text("Got a watch party link?").font(.subheadline.weight(.semibold))
                    PasteButton(payloadType: String.self) { strings in
                        Task { @MainActor in
                            dismiss()
                            if let text = strings.first { party.join(text) }
                        }
                    }
                    .labelStyle(.titleOnly)
                    .buttonBorderShape(.capsule)
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .frame(width: 32, height: 32) // a real tap target
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
                .foregroundStyle(.white)
                .padding(.leading, 14).padding(.trailing, 4).padding(.vertical, 4)
                // Non-interactive glass: the interactive kind swallowed the
                // taps meant for the buttons, so the banner couldn't be closed.
                .vixGlass(.regular, cornerRadius: 22)
                // Swipe it away too.
                .gesture(DragGesture(minimumDistance: 10).onEnded { if $0.translation.height < -10 { dismiss() } })
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.25), value: show)
        .onChange(of: scenePhase, initial: true) { _, phase in if phase == .active { check() } }
        .onChange(of: PartyPasteFlag.shared.found) { _, found in
            // Ignore a late detection result for a clipboard already dismissed.
            guard found, UIPasteboard.general.changeCount != lastChange else { show = false; return }
            show = true
            // Never sticks around: hides itself after 12 seconds.
            hideTask?.cancel()
            hideTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                guard !Task.isCancelled else { return }
                dismiss()
            }
        }
    }

    @State private var hideTask: Task<Void, Never>?

    private func check() {
        let pb = UIPasteboard.general
        guard bannerEnabled, pb.changeCount != lastChange, !party.active else { return }
        // Pattern detection doesn't read the clipboard, so no paste prompt.
        // The completion runs on a background queue. It must not be
        // main-actor isolated (that crashed the app at launch with a link
        // on the clipboard), so it only hands a Bool back to the main actor.
        let update: @Sendable (Bool) -> Void = { found in
            Task { @MainActor in PartyPasteFlag.shared.found = found }
        }
        pb.detectPatterns(for: [\.probableWebURL], completionHandler: Self.patternHandler(update))
    }

    /// Built outside any actor so the closure isn't main-actor isolated.
    nonisolated static func patternHandler(_ update: @escaping @Sendable (Bool) -> Void)
        -> @Sendable (Result<Set<PartialKeyPath<UIPasteboard.DetectedValues>>, Error>) -> Void {
        { result in update((try? result.get())?.contains(\UIPasteboard.DetectedValues.probableWebURL) == true) }
    }

    private func dismiss() {
        hideTask?.cancel()
        show = false
        PartyPasteFlag.shared.found = false
        lastChange = UIPasteboard.general.changeCount
        UserDefaults.standard.set(lastChange, forKey: "vela_party_paste_seen")
    }
}

/// "The host moved on — follow?" Shown to viewers once; following sticks.
struct PartyPrompts: ViewModifier {
    @State private var party = PartySession.shared
    /// The app-wide instance steps aside while a player screen is up: that
    /// screen has its own, and an alert can only appear from the front-most
    /// presentation (two at once made it fail to show).
    var root = false
    func body(content: Content) -> some View {
        content.alert(
            party.prompt?.title != nil ? "The host started something new" : "The host went back to browsing",
            // Both buttons answer; dismissing must never count as "leave".
            isPresented: Binding(get: { party.prompt != nil && !(root && party.playerAttached) }, set: { _ in }),
            presenting: party.prompt
        ) { _ in
            Button("Follow Host") { party.answerFollow(true) }
            Button("Leave Party", role: .destructive) { party.answerFollow(false) }
        } message: { p in
            Text((p.title.map { "They're now watching \($0). " } ?? "They're picking what to watch next. ") + "Follow them for the rest of the party, or leave.")
        }
    }
}

extension View {
    func partyPrompts(root: Bool = false) -> some View { modifier(PartyPrompts(root: root)) }
}

/// "Waiting for …" / reconnecting banner shown over the player.
struct PartyBanner: View {
    @State private var party = PartySession.shared
    var body: some View {
        Group {
            if party.active && party.status == .reconnecting {
                pill("Reconnecting to the party…")
            } else if !party.waitingOn.isEmpty {
                pill("Waiting for \(party.waitingOn.prefix(3).joined(separator: ", "))\(party.waitingOn.count > 3 ? " +\(party.waitingOn.count - 3)" : "")…")
            } else if let toast = party.toast {
                pill(toast)
            }
        }
        .animation(.easeOut(duration: 0.2), value: party.toast)
        .animation(.easeOut(duration: 0.2), value: party.waitingOn)
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .vixGlass(.strong, cornerRadius: 18)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}
