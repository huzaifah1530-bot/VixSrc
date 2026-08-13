import SwiftUI

/// Mirrors `#settingsModal` — TMDB credential field, performance mode
/// toggles, streaming server management, poster card size, and recent
/// search history clearing.
struct SettingsSheet: View {
    @Bindable var viewModel: CatalogViewModel
    @State private var credentialText = ""
    @State private var showCredential = false
    @State private var newServerName = ""
    @State private var newServerURL = ""
    @State private var editingIndex: Int?
    @State private var serverStatus: (text: String, isError: Bool)?
    @State private var isTestingServer = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    credentialSection
                    performanceSection
                    serverManagementSection
                    cardSizeSection
                    searchHistorySection
                }
                .padding(20)
            }
            .background(VixTheme.background.ignoresSafeArea())
            .navigationTitle("Screen House Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { viewModel.isSettingsPresented = false }
                        .foregroundStyle(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(.white)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { credentialText = viewModel.store.credential }
    }

    private var credentialSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("API KEY / READ TOKEN")
                .font(.system(size: 11, weight: .black))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.45))

            HStack {
                Group {
                    if showCredential {
                        TextField("Paste TMDB credential here", text: $credentialText)
                    } else {
                        SecureField("Paste TMDB credential here", text: $credentialText)
                    }
                }
                .foregroundStyle(.white)
                Button { showCredential.toggle() } label: {
                    Image(systemName: showCredential ? "eye.slash" : "eye")
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(14)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.2), lineWidth: 1))

            HStack(spacing: 8) {
                Button {
                    credentialText = ""
                    viewModel.store.credential = ""
                    viewModel.showToast("TMDB key cleared")
                    Task { await viewModel.loadHome() }
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .font(.system(size: 12, weight: .black))
                .padding(.horizontal, 14).padding(.vertical, 10)
                .foregroundStyle(.white)
                .vixGlass(.regular, cornerRadius: 14)
            }

            Text("VixSrc is currently the only streaming API we've tested that doesn't display ads. You can add your own APIs below. The app blocks pop-ups and redirects, but this may not work with untested APIs.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.58))
                .padding(14)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var performanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsRow(title: "PERFORMANCE", subtitle: "Performance mode", description: "Disables blur, glass effects, transitions and animations. Use on low-end hardware.") {
                Toggle("", isOn: Binding(
                    get: { viewModel.store.performanceMode },
                    set: { viewModel.store.performanceMode = $0 }
                ))
                .labelsHidden()
                .tint(.white)
            }
            settingsRow(title: "PERFORMANCE", subtitle: "Ultra performance mode", description: "Maximum performance. Hides backdrop images and removes shadows/gradients. For low-end hardware or battery saving.") {
                Toggle("", isOn: Binding(
                    get: { viewModel.store.ultraPerformanceMode },
                    set: { viewModel.store.ultraPerformanceMode = $0 }
                ))
                .labelsHidden()
                .tint(.white)
            }
        }
    }

    private var cardSizeSection: some View {
        settingsRow(title: "POSTER SIZE", subtitle: "Card density", description: "Compact fits more posters on mobile. Large keeps the cinematic feel.") {
            HStack(spacing: 4) {
                sizeButton("Compact", isActive: viewModel.store.cardSize == .compact) { viewModel.store.cardSize = .compact }
                sizeButton("Large", isActive: viewModel.store.cardSize == .large) { viewModel.store.cardSize = .large }
            }
            .padding(4)
            .background(Color.white.opacity(0.08), in: Capsule())
        }
    }

    private func sizeButton(_ title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(title.uppercased(), action: action)
            .font(.system(size: 11, weight: .black))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(isActive ? .black : .white.opacity(0.7))
            .background(isActive ? Color.white : Color.clear, in: Capsule())
    }

    private var searchHistorySection: some View {
        settingsRow(title: "LOCAL DATA", subtitle: "Recent searches", description: "Clear the search chips that appear under the live search panel.") {
            Button {
                viewModel.store.clearSearchHistory()
                viewModel.showToast("Recent searches cleared")
            } label: {
                Label("Clear", systemImage: "eraser")
            }
            .font(.system(size: 12, weight: .black))
            .padding(.horizontal, 14).padding(.vertical, 10)
            .foregroundStyle(.white)
            .vixGlass(.regular, cornerRadius: 14)
        }
    }

    private func settingsRow<Accessory: View>(title: String, subtitle: String, description: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 10, weight: .black))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.45))
                Text(subtitle)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(.white)
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.52))
            }
            Spacer()
            accessory()
        }
        .padding(16)
        .vixGlass(.regular, cornerRadius: 22)
    }

    // MARK: - Server management

    private var serverManagementSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("STREAMING SERVERS")
                    .font(.system(size: 10, weight: .black))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.45))
                Text("Manage backends")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(.white)
                Text("Add, edit or remove streaming API backends. Each is tested with movie ID 157336 before saving.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.52))
            }

            HStack(spacing: 8) {
                TextField("Name", text: $newServerName)
                    .padding(10)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(.white)
                TextField("https://your-api.com", text: $newServerURL)
                    .padding(10)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(.white)
                Button {
                    Task { await addOrUpdateServer() }
                } label: {
                    if isTestingServer {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: editingIndex == nil ? "plus" : "checkmark")
                    }
                }
                .padding(10)
                .foregroundStyle(.white)
                .vixGlass(.regular, cornerRadius: 12)
                .disabled(isTestingServer)
            }

            if let status = serverStatus {
                Text(status.text)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(status.isError ? .red.opacity(0.85) : .green.opacity(0.85))
            }

            VStack(spacing: 8) {
                ForEach(Array(viewModel.store.servers.enumerated()), id: \.offset) { index, server in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                            Text(server.base).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        }
                        Spacer()
                        Button {
                            editingIndex = index
                            newServerName = server.name
                            newServerURL = server.base
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .foregroundStyle(.white)
                        Button {
                            viewModel.store.removeServer(at: index)
                            viewModel.showToast("\(server.name) removed")
                        } label: {
                            Image(systemName: "trash")
                        }
                        .foregroundStyle(.red.opacity(0.85))
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .padding(16)
        .vixGlass(.regular, cornerRadius: 22)
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
        viewModel.store.addOrUpdateServer(server, replacing: editingIndex)
        serverStatus = (editingIndex == nil ? "Server added and tested successfully" : "Server updated successfully", false)
        editingIndex = nil
        newServerName = ""
        newServerURL = ""
        viewModel.showToast("Servers updated")
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
            viewModel.showToast("Paste a TMDB key first")
            return
        }
        viewModel.store.credential = value
        viewModel.showToast("TMDB key saved")
        viewModel.isSettingsPresented = false
        Task { await viewModel.loadHome() }
    }
}
