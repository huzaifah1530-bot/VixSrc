import SwiftUI
import UniformTypeIdentifiers

/// Settings tab. Uses a native grouped `Form` — the exact same control
/// Apple's own Settings app, and most well-behaved iOS apps, build their
/// preference screens from — instead of a custom sheet of glass cards.
struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var credentialText = ""
    @State private var showCredential = false
    @State private var newServerName = ""
    @State private var newServerURL = ""
    @State private var editingIndex: Int?
    @State private var serverStatus: (text: String, isError: Bool)?
    @State private var isTestingServer = false
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var showRestartAlert = false
    @State private var newAnimeServerName = ""
    @State private var newAnimeServerURL = ""
    @State private var editingAnimeIndex: Int?
    @State private var animeServerStatus: (text: String, isError: Bool)?
    @State private var isTestingAnimeServer = false
    @State private var exportDocument: VelaBackupDocument?
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var showImportConfirm = false
    @State private var pendingImportURL: URL?
    @AppStorage(CaptionSize.storageKey) private var captionScale = CaptionSize.medium.rawValue

    var body: some View {
        NavigationStack {
            Form {
                credentialSection
                devicesSection
                performanceSection
                cardSizeSection
                playerSection
                serverManagementSection
                animeToggleSection
                animeServerSection
                    .disabled(!store.animeEnabled)
                    .opacity(store.animeEnabled ? 1 : 0.45)
                backupSection
                searchHistorySection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                ToastView(message: toastMessage)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear { credentialText = store.credential }
    }

    private func showToast(_ message: String) {
        toastTask?.cancel()
        withAnimation { toastMessage = message }
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_550_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { toastMessage = nil }
        }
    }

    private var credentialSection: some View {
        Section {
            HStack {
                Group {
                    if showCredential {
                        TextField("TMDB API key or read access token", text: $credentialText)
                    } else {
                        SecureField("TMDB API key or read access token", text: $credentialText)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                Button {
                    showCredential.toggle()
                } label: {
                    Image(systemName: showCredential ? "eye.slash" : "eye")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showCredential ? "Hide credential" : "Show credential")
            }

            Button("Save Key") { save() }
            if !store.credential.isEmpty {
                Button("Clear Key", role: .destructive) {
                    credentialText = ""
                    store.credential = ""
                    showToast("TMDB key cleared")
                }
            }
        } header: {
            Text("TMDB API Key")
        } footer: {
            Text("VixSrc is currently the only streaming API we've tested that doesn't display ads. You can add your own APIs below. The app blocks pop-ups and redirects, but this may not work with untested APIs.")
        }
    }

    @AppStorage("vela_party_paste_banner") private var pasteBannerEnabled = true

    private var partySection: some View {
        Section {
            if PartySession.shared.active {
                Button("Open Watch Party") { PartySession.shared.sheetOpen = true }
            } else {
                PasteButton(payloadType: String.self) { strings in
                    Task { @MainActor in if let s = strings.first { PartySession.shared.join(s) } }
                }
                .labelStyle(.titleAndIcon)
            }
            Toggle("Suggest Pasted Party Links", isOn: $pasteBannerEnabled)
        } header: {
            Text("Watch Together")
        } footer: {
            Text("Copy a watch party invite link, then paste it here to join. Useful when tapping the link doesn't open Vela (for example inside LiveContainer). The toggle controls the \"Got a watch party link?\" banner that appears when a link is on your clipboard.")
        }
    }

    @ViewBuilder private var devicesSection: some View {
        partySection
        Section {
            NavigationLink {
                DevicesView()
            } label: {
                HStack {
                    Label("Devices", systemImage: "desktopcomputer")
                    Spacer()
                    Text(DeviceLink.shared.connectedDesktop?.name ?? (DeviceLink.shared.paired.isEmpty ? "Connect" : "Not connected"))
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Pair with Vela on your computer to play there from this iPhone and keep your library in sync.")
        }
    }

    private var performanceSection: some View {
        Section {
            Toggle("Performance Mode", isOn: Binding(
                get: { store.performanceMode },
                set: { newValue in
                    store.performanceMode = newValue
                    showRestartAlert = true
                }
            ))
            Toggle("Ultra Performance Mode", isOn: Binding(
                get: { store.ultraPerformanceMode },
                set: { newValue in
                    store.ultraPerformanceMode = newValue
                    showRestartAlert = true
                }
            ))
        } header: {
            Text("Performance")
        } footer: {
            Text("Performance Mode disables Liquid Glass blur and animations. Ultra Performance Mode also hides backdrop images. Use either on older hardware or to save battery.")
        }
        .alert("Restart Required", isPresented: $showRestartAlert) {
            Button("Restart Now", role: .destructive) {
                // exit(0) is the accepted iOS pattern for forced app restart.
                // The OS relaunches the app cleanly from scratch.
                exit(0)
            }
            Button("Later", role: .cancel) {}
        } message: {
            Text("Performance mode changes take full effect after restarting Vela.")
        }
    }

    private static func clock(_ t: Double?) -> String {
        guard let t, t.isFinite else { return "–" }
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    private var playerSection: some View {
        Section {
            Picker("Double-Tap Skip", selection: Binding(
                get: { store.seekInterval },
                set: { store.seekInterval = $0 }
            )) {
                ForEach(AppStore.seekIntervalOptions, id: \.self) { seconds in
                    Text("\(seconds)s").tag(seconds)
                }
            }
            .pickerStyle(.segmented)
            Picker("Caption Size", selection: $captionScale) {
                ForEach(CaptionSize.allCases) { size in
                    Text(size.label).tag(size.rawValue)
                }
            }
            Toggle("Automatically Skip Intros", isOn: Binding(
                get: { store.autoSkipIntro },
                set: { store.autoSkipIntro = $0 }
            ))
            if !store.introOverrides.isEmpty {
                ForEach(store.introOverrides.keys.sorted(), id: \.self) { key in
                    if let o = store.introOverrides[key] {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(o.title.isEmpty ? key : o.title)
                                Text("Custom intro \(Self.clock(o.start)) – \(Self.clock(o.end))\(o.isComplete ? "" : " (incomplete)")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                store.introOverrides[key] = nil
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove custom intro for \(o.title)")
                        }
                    }
                }
            }
        } header: {
            Text("Player")
        } footer: {
            Text("Double-tap the left or right of the video to skip back or forward. Hold either edge for 2× speed. Caption Size applies to subtitles Vela draws itself, such as anime subtitles. Skip Intro appears when an intro's timestamps are known (TheIntroDB, AniSkip); in a watch party only the host skips automatically. Set custom intro times in the Intro start / end boxes under a show's player (both 00:00 = off); they apply to every episode.")
        }
    }

    private var cardSizeSection: some View {
        Section("Poster Size") {
            Picker("Card Density", selection: Binding(
                get: { store.cardSize },
                set: { store.cardSize = $0 }
            )) {
                Text("Compact").tag(AppStore.CardSize.compact)
                Text("Large").tag(AppStore.CardSize.large)
            }
            .pickerStyle(.segmented)
        }
    }

    private var searchHistorySection: some View {
        Section("Local Data") {
            Button("Clear Recently Watched", role: .destructive) {
                store.recents = []
                showToast("Recently watched cleared")
            }
            .disabled(store.recents.isEmpty)

            Button("Clear Recent Searches", role: .destructive) {
                store.clearSearchHistory()
                showToast("Recent searches cleared")
            }
            .disabled(store.searchHistory.isEmpty)
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: Bundle.main.appVersionString)
        }
    }

    // MARK: - Server management

    private var serverManagementSection: some View {
        Section {
            ForEach(Array(store.servers.enumerated()), id: \.offset) { index, server in
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name).font(.subheadline.weight(.semibold))
                    Text(server.base).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        store.removeServer(at: index)
                        showToast("\(server.name) removed")
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        editingIndex = index
                        newServerName = server.name
                        newServerURL = server.base
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: $newServerName)
                TextField("https://your-api.com", text: $newServerURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                HStack {
                    if let status = serverStatus {
                        Text(status.text)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(status.isError ? .red : .green)
                    }
                    Spacer()
                    Button {
                        Task { await addOrUpdateServer() }
                    } label: {
                        if isTestingServer {
                            ProgressView()
                        } else {
                            Text(editingIndex == nil ? "Add" : "Update")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isTestingServer)
                }
            }
            .padding(.top, 4)
        } header: {
            Text("Streaming Servers")
        } footer: {
            Text("Add, edit or remove streaming API backends. Each is tested with movie ID 157336 before saving.")
        }
    }

    // MARK: - Anime servers

    private var animeToggleSection: some View {
        Section {
            Toggle("Anime", isOn: Binding(
                get: { store.animeEnabled },
                set: { store.animeEnabled = $0 }
            ))
        } footer: {
            Text("Shows the Anime tab. Turn off to hide it and disable anime servers.")
        }
    }

    private var animeServerSection: some View {
        Section {
            ForEach(Array(store.animeServers.enumerated()), id: \.offset) { index, server in
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name).font(.subheadline.weight(.semibold))
                    Text(server.base).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        store.removeAnimeServer(at: index)
                        showToast("\(server.name) removed")
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        editingAnimeIndex = index
                        newAnimeServerName = server.name
                        newAnimeServerURL = server.base
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: $newAnimeServerName)
                TextField("https://animekaitv.to", text: $newAnimeServerURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                HStack {
                    if let status = animeServerStatus {
                        Text(status.text)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(status.isError ? .red : .green)
                    }
                    Spacer()
                    Button {
                        Task { await addOrUpdateAnimeServer() }
                    } label: {
                        if isTestingAnimeServer {
                            ProgressView()
                        } else {
                            Text(editingAnimeIndex == nil ? "Add" : "Update")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isTestingAnimeServer)
                }
            }
            .padding(.top, 4)

            if store.animeServers.isEmpty {
                Button("Restore Default Anime Servers") {
                    store.animeServers = AnimeServer.defaults
                    showToast("Anime servers restored")
                }
            }
        } header: {
            Text("Anime Servers")
        } footer: {
            Text("AnimeKai-compatible sites that power the Anime tab. The first server supplies the catalogue and search; the others are alternatives in the player. Each is tested with a search before saving.")
        }
    }

    private func addOrUpdateAnimeServer() async {
        let name = newAnimeServerName.trimmingCharacters(in: .whitespaces)
        var url = newAnimeServerURL.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !url.isEmpty else {
            animeServerStatus = ("Enter both a name and a URL", true)
            return
        }
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") { url = "https://" + url }
        if url.hasSuffix("/") { url.removeLast() }

        isTestingAnimeServer = true
        animeServerStatus = ("Testing server with a search...", false)
        let reachable = await testServer(URL(string: url + "/filter?keyword=naruto"))
        isTestingAnimeServer = false

        guard reachable else {
            animeServerStatus = ("That URL does not seem quite right. The server did not respond.", true)
            return
        }
        store.addOrUpdateAnimeServer(AnimeServer(name: name, base: url), replacing: editingAnimeIndex)
        animeServerStatus = (editingAnimeIndex == nil ? "Anime server added" : "Anime server updated", false)
        editingAnimeIndex = nil
        newAnimeServerName = ""
        newAnimeServerURL = ""
        showToast("Anime servers updated")
    }

    // MARK: - Backup

    private var backupSection: some View {
        Section {
            Button {
                do {
                    exportDocument = VelaBackupDocument(data: try store.exportBackup())
                    isExporting = true
                } catch {
                    showToast("Couldn't create backup")
                }
            } label: {
                Label("Export Vela Data", systemImage: "square.and.arrow.up")
            }
            Button {
                isImporting = true
            } label: {
                Label("Import Vela Data", systemImage: "square.and.arrow.down")
            }
        } header: {
            Text("Backup")
        } footer: {
            Text("Exports your TMDB key, favourites, watch history and timings, search history, servers and preferences to a file. The file contains your API key, so keep it private. Importing replaces everything on this device.")
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "Vela Backup \(Date().formatted(.iso8601.year().month().day()))"
        ) { result in
            if case .success = result { showToast("Vela data exported") }
            exportDocument = nil
        }
        // UIKit picker in copy mode: works without security-scoped access,
        // which sandboxed hosts like LiveContainer don't always grant, and
        // accepts any file so a backup renamed or saved as .txt still opens.
        .sheet(isPresented: $isImporting) {
            BackupDocumentPicker { url in
                isImporting = false
                pendingImportURL = url
                showImportConfirm = true
            }
            .ignoresSafeArea()
        }
        .alert("Import Vela Data?", isPresented: $showImportConfirm) {
            Button("Import", role: .destructive) { performImport() }
            Button("Cancel", role: .cancel) { pendingImportURL = nil }
        } message: {
            Text("This replaces your current key, history, favourites and settings with the backup.")
        }
    }

    private func performImport() {
        guard let url = pendingImportURL else { return }
        pendingImportURL = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try store.importBackup(try Data(contentsOf: url))
            credentialText = store.credential
            showToast("Vela data imported")
        } catch {
            showToast("That file isn't a valid Vela backup")
        }
    }

    private func addOrUpdateServer() async {
        let name = newServerName.trimmingCharacters(in: .whitespaces)
        var url = newServerURL.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !url.isEmpty else {
            serverStatus = ("Enter both a name and a URL", true)
            return
        }
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") {
            url = "https://" + url
        }

        isTestingServer = true
        serverStatus = ("Testing server with movie ID 157336...", false)
        let testURL = URL(string: url.hasSuffix("/") ? String(url.dropLast()) + "/movie/157336" : url + "/movie/157336")
        let reachable = await testServer(testURL)
        isTestingServer = false

        guard reachable else {
            serverStatus = ("That URL does not seem quite right. The server did not respond.", true)
            return
        }

        let server = StreamServer(name: name, base: url.hasSuffix("/") ? String(url.dropLast()) : url)
        store.addOrUpdateServer(server, replacing: editingIndex)
        serverStatus = (editingIndex == nil ? "Server added and tested successfully" : "Server updated successfully", false)
        editingIndex = nil
        newServerName = ""
        newServerURL = ""
        showToast("Servers updated")
    }

    private func testServer(_ url: URL?) async -> Bool {
        guard let url else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            // Any HTTPURLResponse used to count as success, so a typo'd host
            // that merely resolves would "pass". Require a non-error status,
            // matching `testServerUrl` in index.html.
            return (200..<400).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private func save() {
        let value = credentialText.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else {
            showToast("Paste a TMDB key first")
            return
        }
        store.credential = value
        showToast("TMDB key saved")
    }
}

/// Document picker that copies the chosen file into the app's tmp folder.
struct BackupDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json, .plainText, .data, .item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}

/// JSON backup file handed to `fileExporter`.
struct VelaBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private extension Bundle {
    var appVersionString: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return version
    }
}
