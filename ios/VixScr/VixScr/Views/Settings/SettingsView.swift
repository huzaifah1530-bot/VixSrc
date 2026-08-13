import SwiftUI

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

    var body: some View {
        NavigationStack {
            Form {
                credentialSection
                performanceSection
                cardSizeSection
                serverManagementSection
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

private extension Bundle {
    var appVersionString: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
