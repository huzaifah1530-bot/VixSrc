import SwiftUI

/// Settings › Playback › Split by Speaker: which speaker model splits auto
/// captions, or none, and at which precision.
struct SpeakerModelSettingsView: View {
    @AppStorage(SpeakerModelChoice.key) private var choiceRaw = SpeakerModelChoice.current.rawValue
    @AppStorage(SpeakerModelChoice.precisionKey) private var precision = "full"

    private var choice: SpeakerModelChoice { SpeakerModelChoice(rawValue: choiceRaw) ?? .balanced }

    var body: some View {
        Form {
            Section {
                ForEach(SpeakerModelChoice.allCases) { option in
                    Button {
                        choiceRaw = option.rawValue
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title).foregroundStyle(.primary)
                                Text(option.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if option == choice {
                                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityAddTraits(option == choice ? .isSelected : [])
                }
            } footer: {
                Text("Starts a new auto-caption line when someone else talks, with an em dash for each speaker in a quick exchange. The model hears that voices differ, not who they are. Takes effect the next time auto captions start.")
            }

            if choice != .off {
                Section {
                    Picker("Precision", selection: $precision) {
                        Text("Full").tag("full")
                        Text("Compressed").tag("compressed")
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(precisionFooter)
                }
            }
        }
        .navigationTitle("Split by Speaker")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var precisionFooter: String {
        if choice == .highContext && precision == "full" && !SpeakerModelChoice.deviceFitsFullHighContext {
            return "Full-precision High Context needs about 2.4 GB of memory, more than this device has, so Vela uses the compressed version."
        }
        return "Compressed is smaller to download and uses less memory, and is very slightly less accurate. Each model downloads once; delete ones you don't use in Settings › Models."
    }
}

/// Settings › Models: downloaded models and how much space they take.
struct ModelsSettingsView: View {
    @State private var entries: [ModelStore.Entry] = []
    @State private var pendingDelete: ModelStore.Entry?

    var body: some View {
        Form {
            Section {
                if entries.isEmpty {
                    Text("No models downloaded.").foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                            Text(entry.inUse ? "\(entry.detail) · In use" : entry.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { pendingDelete = entry } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) { pendingDelete = entry } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("Downloaded")
            } footer: {
                Text("Swipe to delete. A deleted model downloads again the next time it's needed. Apple's speech recognition languages are managed by iOS and don't appear here.")
            }
            if !entries.isEmpty {
                Section {
                    LabeledContent("Total", value: ByteCountFormatter.string(fromByteCount: entries.reduce(0) { $0 + $1.bytes }, countStyle: .file))
                }
            }
        }
        .navigationTitle("Models")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { entries = ModelStore.entries() }
        .confirmationDialog("Delete \(pendingDelete?.title ?? "model")?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let entry = pendingDelete { ModelStore.delete(entry) }
                pendingDelete = nil
                entries = ModelStore.entries()
            }
        } message: {
            Text(pendingDelete?.inUse == true
                 ? "It's the model Split by Speaker uses, so it downloads again the next time auto captions start."
                 : "Frees \(ByteCountFormatter.string(fromByteCount: pendingDelete?.bytes ?? 0, countStyle: .file)).")
        }
    }
}
