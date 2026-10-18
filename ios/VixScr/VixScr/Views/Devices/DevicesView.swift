import SwiftUI

/// Settings › Devices: paired computers, their connection and sync status,
/// and every per-device action.
struct DevicesView: View {
    @State private var link = DeviceLink.shared
    @State private var showConnect = false

    var body: some View {
        Form {
            Section {
                if link.paired.isEmpty {
                    Text("No computers paired yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(link.paired) { desk in
                    NavigationLink {
                        DeviceDetailView(deskId: desk.deskId)
                    } label: {
                        DeviceRow(desk: desk)
                    }
                }
                Button {
                    showConnect = true
                } label: {
                    Label("Connect a Computer", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("Computers")
            } footer: {
                Text("Open Vela on your Windows PC on the same Wi-Fi. Devices talk directly over your local network with end-to-end encryption; nothing goes through a server.")
            }

            Section {
                Picker("Play On", selection: Binding(
                    get: { link.playbackTargetId ?? "" },
                    set: { link.setPlaybackTarget($0.isEmpty ? nil : $0) }
                )) {
                    Label("This iPhone", systemImage: "iphone").tag("")
                    ForEach(link.paired) { desk in
                        Label(desk.name, systemImage: "desktopcomputer").tag(desk.deskId)
                    }
                }
            } footer: {
                Text("When a computer is selected, movies, shows and anime you start here play on it. You keep browsing and controlling from this iPhone.")
            }
        }
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showConnect) { ConnectFlowView() }
    }
}

private struct DeviceRow: View {
    let desk: PairedDesktop
    @State private var link = DeviceLink.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.title3)
                .foregroundStyle(link.isConnected(to: desk.deskId) ? .green : .secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(desk.name).font(.body.weight(.semibold))
                Text(link.statusText(for: desk) + (desk.syncEnabled ? " · Sync on" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct DeviceDetailView: View {
    let deskId: String
    @State private var link = DeviceLink.shared
    @State private var confirmCopyFrom = false
    @State private var confirmForget = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let desk = link.paired.first(where: { $0.deskId == deskId }) {
            Form {
                Section {
                    LabeledContent("Status", value: link.statusText(for: desk))
                    if case .failed(let message) = link.phase, !link.isConnected {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                    if link.isConnected(to: deskId) {
                        Button("Disconnect") { link.disconnect() }
                    } else {
                        Button("Connect") { link.connect(deskId, auto: false) }
                    }
                    Toggle("Reconnect Automatically", isOn: Binding(
                        get: { desk.autoReconnect },
                        set: { link.setAutoReconnect(deskId, enabled: $0) }
                    ))
                    Toggle("Play Here From iPhone", isOn: Binding(
                        get: { link.playbackTargetId == deskId },
                        set: { link.setPlaybackTarget($0 ? deskId : nil) }
                    ))
                } footer: {
                    Text("Vela reconnects when you come back to the app. Playback on the computer carries on while this iPhone is away.")
                }

                Section {
                    Toggle("Keep in Sync", isOn: Binding(
                        get: { desk.syncEnabled },
                        set: { link.setSync(deskId, enabled: $0) }
                    ))
                    if desk.syncEnabled {
                        LabeledContent("Last Synced", value: desk.lastSync.map { $0.formatted(.relative(presentation: .named)) } ?? "Never")
                        Button("Sync Now") { link.syncNow(deskId) }
                            .disabled(!link.isConnected(to: deskId))
                    }
                } header: {
                    Text("Saved Data")
                } footer: {
                    Text("Syncs your TMDB key, servers, favourites, history, watch positions and searches. Appearance and performance settings stay on each device. Turning sync off keeps the pairing.")
                }

                Section {
                    Button("Copy This iPhone to \(desk.name)") { link.copyToDesktop(deskId) }
                    Button("Copy \(desk.name) to This iPhone") { confirmCopyFrom = true }
                } header: {
                    Text("Fresh Copy")
                } footer: {
                    Text(link.isConnected(to: deskId)
                         ? "Replaces the other device's saved data. The device being replaced asks to confirm first."
                         : "Connect to \(desk.name) first.")
                }
                .disabled(!link.isConnected(to: deskId))

                Section {
                    Button("Forget This Computer", role: .destructive) { confirmForget = true }
                } footer: {
                    Text("You'll need to scan a new code to pair again. Data already copied to this iPhone stays.")
                }
            }
            .navigationTitle(desk.name)
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Replace this iPhone's saved data with \(desk.name)'s?", isPresented: $confirmCopyFrom, titleVisibility: .visible) {
                Button("Replace", role: .destructive) { link.copyFromDesktop(deskId) }
            } message: {
                Text("Favourites, history, watch positions, servers and your TMDB key on this iPhone will be replaced.")
            }
            .confirmationDialog("Forget \(desk.name)?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget", role: .destructive) {
                    link.forget(deskId)
                    dismiss()
                }
            }
        } else {
            ContentUnavailableView("Computer removed", systemImage: "desktopcomputer")
        }
    }
}

/// Find a computer on the network (auto-picking it when there's only one),
/// ask it to show its QR code if it isn't paired yet, then scan.
struct ConnectFlowView: View {
    @State private var link = DeviceLink.shared
    @State private var scanning = false
    @State private var chosen: DeviceLink.Discovered?
    @State private var scanError: String?
    @State private var autoPicked = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if scanning {
                    scanner
                } else {
                    picker
                }
            }
            .navigationTitle(scanning ? "Scan Code" : "Connect a Computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if !scanning {
                    ToolbarItem(placement: .primaryAction) {
                        Button { scanning = true } label: { Label("Scan Code", systemImage: "qrcode.viewfinder") }
                    }
                }
            }
        }
        .onAppear { link.startBrowsing() }
        .onChange(of: link.phase) { _, phase in
            if phase == .connected { dismiss() }
        }
        .onChange(of: link.qrShownBy) { _, shownBy in
            if shownBy != nil { scanning = true }
        }
        .task {
            // One computer on the network: pick it automatically.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !autoPicked, link.discovered.count == 1, let only = link.discovered.first {
                autoPicked = true
                choose(only)
            }
        }
        .presentationDragIndicator(.visible)
    }

    private var picker: some View {
        List {
            Section {
                if link.discovered.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Looking for Vela on your network…").foregroundStyle(.secondary)
                    }
                }
                ForEach(link.discovered) { found in
                    Button { choose(found) } label: {
                        HStack {
                            Image(systemName: "desktopcomputer").frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(found.name).foregroundStyle(.primary)
                                Text(isPaired(found) ? "Paired" : "Not paired")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if chosen?.id == found.id, !(link.phase == .idle) {
                                ProgressView()
                            }
                        }
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if let error = link.browseError { Text(error).foregroundStyle(.orange) }
                    if case .failed(let message) = link.phase { Text(message).foregroundStyle(.orange) }
                    Text("Open Vela on your computer. If it doesn't appear, choose Scan Code and use Connect iPhone on the computer.")
                }
            }
        }
    }

    private var scanner: some View {
        VStack(spacing: 16) {
            QRScannerView { value in
                guard let invite = PairingInvite(url: value) else {
                    scanError = "That isn't a Vela pairing code."
                    return
                }
                if let chosen, let id = chosen.deskId, id != invite.deskId {
                    scanError = "That code is for a different computer."
                    return
                }
                scanError = nil
                link.pair(with: invite)
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white.opacity(0.2), lineWidth: 1))
            .aspectRatio(1, contentMode: .fit)
            .padding(.horizontal, 24)

            Group {
                if case .connecting = link.phase {
                    HStack(spacing: 8) { ProgressView(); Text("Pairing…") }
                } else if let scanError {
                    Text(scanError).foregroundStyle(.orange)
                } else if case .failed(let message) = link.phase {
                    Text(message).foregroundStyle(.orange)
                } else {
                    Text(link.qrShownBy.map { "Scan the code showing on \($0)." } ?? "On your computer, click the iPhone button in Vela's toolbar, then scan the code.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            Spacer()
        }
        .padding(.top, 16)
    }

    private func isPaired(_ found: DeviceLink.Discovered) -> Bool {
        link.paired.contains { $0.deskId == found.deskId }
    }

    private func choose(_ found: DeviceLink.Discovered) {
        chosen = found
        if let id = found.deskId, isPaired(found) {
            link.connect(id, auto: false)
        } else {
            link.requestPairing(found)
        }
    }
}

/// App-wide prompts: sync choice after first pairing, confirming a fresh
/// copy, replacement offers from the computer, and link toasts.
struct DeviceLinkPrompts: ViewModifier {
    @State private var link = DeviceLink.shared
    @State private var confirmFromDesktop: PairedDesktop?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Keep this iPhone and \(link.syncPrompt?.name ?? "your computer") in sync?",
                isPresented: Binding(get: { link.syncPrompt != nil }, set: { if !$0 { link.syncPrompt = nil } }),
                titleVisibility: .visible,
                presenting: link.syncPrompt
            ) { desk in
                Button("Sync, Starting From This iPhone") { link.answerSyncPrompt(.fromPhone) }
                Button("Sync, Starting From \(desk.name)") {
                    confirmFromDesktop = desk
                    link.syncPrompt = nil
                }
                Button("Don't Sync") { link.answerSyncPrompt(.none) }
            } message: { _ in
                Text("Sync keeps your TMDB key, servers, favourites, history and watch positions the same on both. Pick which device to copy from first; after that, changes flow both ways. You can still control playback without syncing.")
            }
            .alert(
                "Replace this iPhone's saved data?",
                isPresented: Binding(get: { confirmFromDesktop != nil }, set: { if !$0 { confirmFromDesktop = nil } }),
                presenting: confirmFromDesktop
            ) { desk in
                Button("Replace", role: .destructive) { link.copyFromDesktop(desk.deskId) }
                Button("Cancel", role: .cancel) { link.setSync(desk.deskId, enabled: false) }
            } message: { desk in
                Text("Favourites, history, watch positions, servers and your TMDB key on this iPhone will be replaced with \(desk.name)'s.")
            }
            .alert(
                "Replace this iPhone's saved data?",
                isPresented: Binding(get: { link.offer != nil }, set: { if !$0 { link.resolveOffer(accept: false) } }),
                presenting: link.offer
            ) { offer in
                Button("Replace", role: .destructive) { link.resolveOffer(accept: true) }
                    .disabled(offer.doc == nil)
                Button("Cancel", role: .cancel) { link.resolveOffer(accept: false) }
            } message: { offer in
                Text(offer.doc == nil
                     ? "The data from \(offer.name) was invalid, so nothing can be copied."
                     : "\(offer.name) wants to copy its favourites, history, watch positions, servers and TMDB key to this iPhone.")
            }
            .overlay(alignment: .top) {
                if let toast = link.toastMessage {
                    ToastView(message: toast)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.25), value: link.toastMessage)
    }
}

extension View {
    func deviceLinkPrompts() -> some View { modifier(DeviceLinkPrompts()) }
}

/// Toolbar menu in the players: play here or on a paired computer.
struct PlaybackTargetMenu: View {
    @State private var link = DeviceLink.shared
    @State private var showConnect = false
    var onChange: () -> Void

    var body: some View {
        Menu {
            Picker("Play On", selection: Binding(
                get: { link.playbackTargetId ?? "" },
                set: { value in
                    link.setPlaybackTarget(value.isEmpty ? nil : value)
                    onChange()
                }
            )) {
                Label("This iPhone", systemImage: "iphone").tag("")
                ForEach(link.paired) { desk in
                    Label(desk.name, systemImage: "desktopcomputer").tag(desk.deskId)
                }
            }
            Divider()
            Button { showConnect = true } label: { Label("Connect a Computer…", systemImage: "plus") }
        } label: {
            Image(systemName: link.routesPlayback ? "desktopcomputer" : "iphone")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(link.routesPlayback ? Color.blue : .white)
                .frame(width: 34, height: 34)
                .vixGlass(.regular, cornerRadius: 17)
        }
        .accessibilityLabel(link.routesPlayback ? "Playing on \(link.playbackTarget?.name ?? "computer")" : "Playing on this iPhone")
        .sheet(isPresented: $showConnect) { ConnectFlowView() }
    }
}
