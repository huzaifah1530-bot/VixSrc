import SwiftUI
import UIKit

/// Account controls stay on their own native Settings page. Registration is
/// always a separate, explicit action from signing in.
struct AccountView: View {
    @Environment(AppStore.self) private var store
    @State private var account = CloudAccount.shared
    @State private var creating = false
    @State private var name = ""
    @State private var pin = ""
    @State private var confirmPin = ""
    @State private var recoveryInput = ""
    @State private var recovering = false
    @State private var recoveryCode: String?
    @State private var nextName = ""
    @State private var currentPin = ""
    @State private var nextPin = ""
    @State private var confirmNextPin = ""
    @State private var deletePin = ""
    @State private var devices: [CloudAccount.Device] = []
    @State private var loadingDevices = false
    @State private var busy = false
    @State private var message: String?
    @State private var confirmDownload = false
    @State private var confirmDelete = false
    @State private var confirmSignOut = false
    @State private var editingName = false
    @State private var editingPin = false
    @State private var showDelete = false

    var body: some View {
        Form {
            // Shown first: it's the one thing the user must not miss.
            if let recoveryCode {
                savedCodeSection(recoveryCode)
            }
            if let username = account.username {
                headerSection(username)
                cloudDataSection
                profileSection(username)
                devicesSection
                leaveSection
            } else {
                welcomeSection
                if recovering {
                    recoverySection
                } else {
                    signInSection
                }
            }
        }
        .navigationTitle("Account")
        .disabled(busy)
        .animation(.default, value: account.username)
        .alert("Account", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
        .confirmationDialog("Replace data on this iPhone with its cloud backup?", isPresented: $confirmDownload, titleVisibility: .visible) {
            Button("Download and Replace", role: .destructive) {
                run(pill: "Downloading from Vela Cloud…", done: "Cloud data restored") { try await account.download(into: store) }
            }
        }
        .confirmationDialog("Sign out of Vela on this iPhone?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await account.signOut() } }
        } message: {
            Text("Your watch history and settings stay on this iPhone.")
        }
        .confirmationDialog("Delete this account and its cloud data?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Account", role: .destructive) {
                run(pill: "Deleting account…", done: "Account deleted") {
                    try await account.delete(pin: deletePin)
                    deletePin = ""
                    showDelete = false
                }
            }
        }
        .task(id: account.username) {
            guard account.username != nil else { return }
            loadingDevices = true
            devices = (try? await account.devices()) ?? []
            loadingDevices = false
        }
    }

    // MARK: - Signed in

    private func headerSection(_ username: String) -> some View {
        Section {
            VStack(spacing: 14) {
                HStack(spacing: 14) {
                    Text(String(username.prefix(1)).uppercased())
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(Color.blue.gradient))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(username)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                        SyncStatusLine(state: account.syncState)
                    }
                    Spacer(minLength: 0)
                }
                // Bordered so only the button, not the whole row, is tappable.
                Button {
                    account.syncNow(visible: true)
                } label: {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(account.syncState == .syncing)
            }
            .padding(.vertical, 6)
        }
    }

    private var cloudDataSection: some View {
        Section {
            Button {
                run(pill: "Backing up to Vela Cloud…", done: "Backup saved") { try await account.upload(from: store) }
            } label: {
                Label("Back Up Now", systemImage: "icloud.and.arrow.up")
            }
            Button {
                confirmDownload = true
            } label: {
                Label("Download from Cloud", systemImage: "icloud.and.arrow.down")
            }
        } header: {
            Text("Cloud Data")
        } footer: {
            Text("Your watch history and saved settings stay on this iPhone when you sign out. Cloud data is kept for other signed-in devices.")
        }
    }

    private func profileSection(_ username: String) -> some View {
        Section("Profile") {
            LabeledContent("Username", value: username)

            DisclosureGroup("Change Username…", isExpanded: $editingName.animation()) {
                TextField("New username", text: $nextName)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save Username") {
                    run(pill: "Changing username…", done: "Username changed") {
                        try await account.rename(to: nextName)
                        nextName = ""
                        withAnimation { editingName = false }
                    }
                }
                .disabled(nextName.isEmpty)
            }

            DisclosureGroup("Change PIN…", isExpanded: $editingPin.animation()) {
                SecureField("Current PIN", text: $currentPin).keyboardType(.numberPad)
                SecureField("New 4- or 6-digit PIN", text: $nextPin).keyboardType(.numberPad)
                SecureField("Confirm new PIN", text: $confirmNextPin).keyboardType(.numberPad)
                Button("Save PIN") {
                    guard nextPin == confirmNextPin else { message = "The new PINs do not match."; return }
                    run(pill: "Changing PIN…", done: "PIN changed") {
                        try await account.changePin(current: currentPin, new: nextPin)
                        currentPin = ""; nextPin = ""; confirmNextPin = ""
                        withAnimation { editingPin = false }
                    }
                }
                .disabled(currentPin.isEmpty || nextPin.isEmpty || confirmNextPin.isEmpty)
            }
        }
    }

    private var devicesSection: some View {
        Section("Signed-In Devices") {
            if devices.isEmpty {
                Text(loadingDevices ? "Loading…" : "No sessions loaded").foregroundStyle(.secondary)
            }
            ForEach(devices) { device in
                HStack(spacing: 12) {
                    Image(systemName: Self.symbol(for: device.name))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name).lineLimit(1)
                        Text(Self.subtitle(for: device))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Sign Out", role: .destructive) {
                        run(pill: "Signing out \(device.name)…", done: "Signed out \(device.name)") {
                            try await account.revoke(device: device)
                            // Revoking this iPhone signs it out, so there's nothing left to list.
                            if !device.isCurrent { devices = try await account.devices() }
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button {
                run(pill: "Refreshing devices…", done: "Devices up to date") { devices = try await account.devices() }
            } label: {
                Label("Refresh Devices", systemImage: "arrow.clockwise")
            }
        }
    }

    private var leaveSection: some View {
        Section {
            Button(role: .destructive) {
                confirmSignOut = true
            } label: {
                Label("Sign Out of This iPhone", systemImage: "rectangle.portrait.and.arrow.right")
                    .foregroundStyle(.red)
            }
            DisclosureGroup(isExpanded: $showDelete.animation()) {
                SecureField("PIN to delete account", text: $deletePin).keyboardType(.numberPad)
                Button("Delete Account", role: .destructive) { confirmDelete = true }
                    .disabled(deletePin.isEmpty)
            } label: {
                Label("Delete Account…", systemImage: "trash")
                    .foregroundStyle(.red)
            }
        } footer: {
            Text("Deleting your account removes its cloud data for every device. Data already on this iPhone stays here.")
        }
    }

    // MARK: - Signed out

    private var welcomeSection: some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.blue)
                    .accessibilityHidden(true)
                Text("Vela Account")
                    .font(.title3.weight(.semibold))
                Text("Sync your library between devices and keep a cloud backup.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private var signInSection: some View {
        Section {
            Picker("Action", selection: $creating.animation()) {
                Text("Sign In").tag(false)
                Text("Create Account").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField("Username", text: $name)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField(creating ? "Choose a 4- or 6-digit PIN" : "PIN", text: $pin)
                .keyboardType(.numberPad)
            if creating {
                SecureField("Confirm PIN", text: $confirmPin).keyboardType(.numberPad)
            }
            Button {
                submit()
            } label: {
                HStack {
                    Spacer()
                    if busy {
                        ProgressView()
                    } else {
                        Text(creating ? "Create Account" : "Sign In").fontWeight(.semibold)
                    }
                    Spacer()
                }
            }
            .disabled(name.isEmpty || pin.isEmpty || (creating && confirmPin.isEmpty))
            if !creating {
                Button("Forgot PIN? Use Recovery Code") {
                    withAnimation { recovering = true }
                }
                .font(.subheadline)
            }
        } footer: {
            if creating {
                Text("Creating an account is a separate step. A username entered under Sign In will never create one. Keep the recovery code somewhere safe; there is no email reset.")
            } else {
                Text("Your account uses a username and a 4- or 6-digit PIN. Keep the recovery code somewhere safe; there is no email reset.")
            }
        }
    }

    private var recoverySection: some View {
        Section {
            TextField("Username", text: $name)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Recovery code", text: $recoveryInput)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("Choose a 4- or 6-digit PIN", text: $pin).keyboardType(.numberPad)
            SecureField("Confirm PIN", text: $confirmPin).keyboardType(.numberPad)
            Button("Reset PIN with Recovery Code") {
                guard pin == confirmPin else { message = "The PINs do not match."; return }
                run {
                    recoveryCode = try await account.recover(username: name, code: recoveryInput, newPin: pin)
                    pin = ""; confirmPin = ""; recoveryInput = ""
                    recovering = false
                }
            }
            .disabled(name.isEmpty || pin.isEmpty || confirmPin.isEmpty || recoveryInput.isEmpty)
            Button("Back to Sign In") {
                withAnimation { recovering = false }
            }
        } header: {
            Text("Reset PIN")
        } footer: {
            Text("Enter the recovery code you saved when you created your account. Vela then signs you in and gives you a new recovery code to save.")
        }
    }

    private func savedCodeSection(_ code: String) -> some View {
        Section {
            Text(code).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Button {
                UIPasteboard.general.string = code
            } label: {
                Label("Copy Code", systemImage: "doc.on.doc")
            }
            Button("I've Saved It") { withAnimation { recoveryCode = nil } }
        } header: {
            Text("Save Your Recovery Code")
        } footer: {
            Text("It's the only way to reset your PIN; there is no email reset.")
        }
    }

    // MARK: - Actions

    private func submit() {
        if creating && pin != confirmPin { message = "The PINs do not match."; return }
        run {
            if creating { recoveryCode = try await account.create(username: name, pin: pin) }
            else {
                try await account.signIn(username: name, pin: pin)
                if store.favorites.isEmpty && store.recents.isEmpty && store.watchProgress.isEmpty {
                    try? await account.download(into: store)
                }
            }
            pin = ""; confirmPin = ""
        }
    }

    /// Runs an account call with the form locked. With `pill`, progress and
    /// the outcome (including the error) show in the status pill; otherwise
    /// errors use the alert, which suits the sign-in forms.
    private func run(pill progress: String? = nil, done: String = "Done",
                     _ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        var pill: UUID?
        if let progress { pill = StatusPillCenter.shared.begin(progress) }
        let pillID = pill
        Task { @MainActor in
            do {
                try await operation()
                if let pillID { StatusPillCenter.shared.finish(pillID, success: true, text: done) }
            } catch {
                if let pillID {
                    StatusPillCenter.shared.finish(pillID, success: false, text: error.localizedDescription)
                } else {
                    message = error.localizedDescription
                }
            }
            busy = false
        }
    }

    private static func subtitle(for device: CloudAccount.Device) -> String {
        let signedIn = "Signed in " + device.createdAt.formatted(date: .abbreviated, time: .omitted)
        return device.isCurrent ? "This iPhone · " + signedIn : signedIn
    }

    private static func symbol(for deviceName: String) -> String {
        let lower = deviceName.lowercased()
        if lower.contains("ipad") { return "ipad" }
        if lower.contains("iphone") { return "iphone" }
        if lower.contains("macbook") { return "laptopcomputer" }
        return "desktopcomputer"
    }
}

/// "Synced just now" / "Syncing…" / "Offline" under the account name. The
/// timeline keeps the relative time fresh while the page stays open.
private struct SyncStatusLine: View {
    let state: CloudAccount.SyncState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 5) {
                icon
                Text(text(now: context.date))
                    .lineLimit(2)
            }
            .font(.subheadline)
            .foregroundStyle(isFailure ? Color.orange : Color.secondary)
        }
        .animation(.default, value: state)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .syncing:
            ProgressView().controlSize(.mini)
        case .synced:
            Image(systemName: "checkmark.icloud.fill")
        case .offline:
            Image(systemName: "icloud.slash")
        case .failed:
            Image(systemName: "exclamationmark.icloud.fill")
        case .idle:
            Image(systemName: "icloud")
        }
    }

    private var isFailure: Bool {
        if case .failed = state { return true }
        return false
    }

    private func text(now: Date) -> String {
        switch state {
        case .idle: return "Waiting to sync"
        case .syncing: return "Syncing…"
        case .synced(let date):
            if now.timeIntervalSince(date) < 60 { return "Synced just now" }
            return "Synced \(date.formatted(.relative(presentation: .named)))"
        case .offline: return "Offline"
        case .failed(let reason): return "Sync failed. \(reason)"
        }
    }
}
