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
    @State private var deletePin = ""
    @State private var devices: [CloudAccount.Device] = []
    @State private var busy = false
    @State private var message: String?
    @State private var confirmDownload = false
    @State private var confirmDelete = false

    var body: some View {
        Form {
            if let username = account.username {
                Section {
                    LabeledContent("Username", value: username)
                    Text("Signed in on this device")
                        .foregroundStyle(.secondary)
                } header: { Label("Vela Account", systemImage: "person.crop.circle") }

                Section {
                    Button("Back Up This iPhone Now") { run { try await account.upload(from: store) } }
                    Button("Download Data from Cloud") { confirmDownload = true }
                } header: {
                    Text("Cloud Data")
                } footer: {
                    Text("Your watch history and saved settings stay on this iPhone when you sign out. Cloud data is kept for other signed-in devices.")
                }

                Section("Change Username") {
                    TextField("New username", text: $nextName)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Change Username") {
                        run { try await account.rename(to: nextName); nextName = "" }
                    }.disabled(nextName.isEmpty)
                }

                Section("Change PIN") {
                    SecureField("Current PIN", text: $currentPin).keyboardType(.numberPad)
                    SecureField("New 4- or 6-digit PIN", text: $nextPin).keyboardType(.numberPad)
                    Button("Change PIN") {
                        run { try await account.changePin(current: currentPin, new: nextPin); currentPin = ""; nextPin = "" }
                    }.disabled(currentPin.isEmpty || nextPin.isEmpty)
                }

                Section("Signed-In Devices") {
                    if devices.isEmpty { Text("No sessions loaded").foregroundStyle(.secondary) }
                    ForEach(devices) { device in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.name + (device.isCurrent ? " (this iPhone)" : ""))
                                Text(device.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Sign Out", role: .destructive) {
                                run { try await account.revoke(device: device); devices = try await account.devices() }
                            }
                        }
                    }
                    Button("Refresh Devices") { run { devices = try await account.devices() } }
                }

                Section {
                    Button("Sign Out of This iPhone") { Task { await account.signOut() } }
                    SecureField("PIN to delete account", text: $deletePin).keyboardType(.numberPad)
                    Button("Delete Account", role: .destructive) { confirmDelete = true }
                        .disabled(deletePin.isEmpty)
                }
            } else {
                Section {
                    Picker("Action", selection: $creating) {
                        Text("Sign In").tag(false)
                        Text("Create Account").tag(true)
                    }.pickerStyle(.segmented)
                    TextField("Username", text: $name)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(creating ? "Choose a 4- or 6-digit PIN" : "PIN", text: $pin)
                        .keyboardType(.numberPad)
                    if creating {
                        SecureField("Confirm PIN", text: $confirmPin).keyboardType(.numberPad)
                        Text("Creating an account is a separate step. A username entered under Sign In will never create one.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button(creating ? "Confirm New Account" : "Sign In") {
                        if creating && pin != confirmPin { message = "The PINs do not match."; return }
                        run {
                            if creating { recoveryCode = try await account.create(username: name, pin: pin) }
                            else { try await account.signIn(username: name, pin: pin) }
                            pin = ""; confirmPin = ""
                        }
                    }
                    .disabled(name.isEmpty || pin.isEmpty || (creating && confirmPin.isEmpty))
                } header: {
                    Label("Vela Account", systemImage: "person.crop.circle")
                } footer: {
                    Text("Your account uses a username and a 4- or 6-digit PIN. Keep the recovery code somewhere safe; there is no email reset.")
                }

                Section {
                    Toggle("I have a recovery code", isOn: $recovering)
                    if recovering {
                        TextField("Recovery code", text: $recoveryInput)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Reset PIN with Recovery Code") {
                            run { recoveryCode = try await account.recover(username: name, code: recoveryInput, newPin: pin) }
                        }.disabled(name.isEmpty || pin.isEmpty || recoveryInput.isEmpty)
                    }
                }
            }
            if let recoveryCode {
                Section("Save Your Recovery Code") {
                    Text(recoveryCode).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Button("Copy Code") { UIPasteboard.general.string = recoveryCode }
                    Button("I've Saved It") { self.recoveryCode = nil }
                }
            }
        }
        .navigationTitle("Account")
        .disabled(busy)
        .alert("Account", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
        .confirmationDialog("Replace data on this iPhone with its cloud backup?", isPresented: $confirmDownload) {
            Button("Download and Replace", role: .destructive) { run { try await account.download(into: store) } }
        }
        .confirmationDialog("Delete this account and its cloud data?", isPresented: $confirmDelete) {
            Button("Delete Account", role: .destructive) {
                run { try await account.delete(pin: deletePin); deletePin = "" }
            }
        }
        .task(id: account.username) {
            if account.username != nil { devices = (try? await account.devices()) ?? [] }
        }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            do { try await operation() }
            catch { message = error.localizedDescription }
            busy = false
        }
    }
}
