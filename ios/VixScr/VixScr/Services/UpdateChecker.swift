import Foundation
import SwiftUI
import UIKit

/// Checks the public releases repo on every launch. Never installs on its
/// own: "Install" hands the IPA to AltStore / SideStore, and if neither can
/// take it, opens the release page in the browser.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    struct Release: Identifiable, Equatable {
        var id: String { version }
        let version: String
        let notes: String
        let pageURL: URL
        let ipaURL: URL?
    }

    static let repo = "huzaifah1530-bot/Vela"
    static let releasesPage = URL(string: "https://github.com/\(repo)/releases/latest")!

    /// Set when a newer release exists; drives the launch alert.
    var available: Release?
    @ObservationIgnored private var checked = false

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Runs once per process (i.e. every cold launch).
    func checkOnLaunch() async {
        guard !checked else { return }
        checked = true
        guard let release = try? await fetchLatest(),
              Self.compare(release.version, Self.currentVersion) > 0 else { return }
        available = release
    }

    private func fetchLatest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Vela-iOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }

        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct Payload: Decodable { let tag_name: String; let html_url: URL?; let body: String?; let assets: [Asset]? }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let version = payload.tag_name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "^[vV]", with: "", options: .regularExpression)
        let ipa = payload.assets?.first { $0.name.lowercased().hasSuffix(".ipa") }?.browser_download_url
        return Release(version: version,
                       notes: String((payload.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)),
                       pageURL: payload.html_url ?? Self.releasesPage,
                       ipaURL: ipa)
    }

    /// Tries AltStore, then SideStore; falls back to the release page.
    func install(_ release: Release) {
        available = nil
        guard let ipa = release.ipaURL,
              let encoded = ipa.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            UIApplication.shared.open(release.pageURL)
            return
        }
        let candidates = ["altstore://install?url=\(encoded)", "sidestore://install?url=\(encoded)"].compactMap(URL.init(string:))
        open(candidates, fallback: release.pageURL)
    }

    private func open(_ urls: [URL], fallback: URL) {
        guard let first = urls.first else { UIApplication.shared.open(fallback); return }
        UIApplication.shared.open(first) { [weak self] ok in
            guard !ok else { return }
            Task { @MainActor in self?.open(Array(urls.dropFirst()), fallback: fallback) }
        }
    }

    /// Compares dotted versions ("v1.9.0" vs "1.8"). Returns -1, 0 or 1.
    nonisolated static func compare(_ a: String, _ b: String) -> Int {
        func parts(_ v: String) -> [Int] {
            let core = v.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "^[vV]", with: "", options: .regularExpression)
                .split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? ""
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y ? 1 : -1 }
        }
        return 0
    }
}

/// The launch-time "update available" alert.
struct UpdatePrompt: ViewModifier {
    @State private var updater = UpdateChecker.shared

    func body(content: Content) -> some View {
        content
            .task { await updater.checkOnLaunch() }
            .alert(
                "Vela \(updater.available?.version ?? "") Is Available",
                isPresented: Binding(get: { updater.available != nil }, set: { if !$0 { updater.available = nil } }),
                presenting: updater.available
            ) { release in
                Button("Install") { updater.install(release) }
                Button("View Release") { updater.available = nil; UIApplication.shared.open(release.pageURL) }
                Button("Later", role: .cancel) { updater.available = nil }
            } message: { release in
                Text("You're on \(UpdateChecker.currentVersion). Install opens the new version in AltStore or SideStore; if neither is available, the download page opens instead."
                     + (release.notes.isEmpty ? "" : "\n\n\(release.notes)"))
            }
    }
}

extension View {
    func updatePrompt() -> some View { modifier(UpdatePrompt()) }
}
