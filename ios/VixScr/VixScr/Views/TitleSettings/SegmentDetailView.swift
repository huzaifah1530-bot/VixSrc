import SwiftUI

/// One recorded segment: its name, how it's found, and whether it skips
/// by itself.
struct SegmentDetailView: View {
    let context: TitleContext
    let segmentID: UUID
    let onRecordAgain: () -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var confidence = 0.5
    @State private var confirmDelete = false
    @FocusState private var nameFocused: Bool

    private var settings: TitleSettings? { store.titleSettings[context.key] }
    private var segment: RecordedSegment? { settings?.skipping.segment(segmentID) }

    var body: some View {
        Form {
            if let segment {
                nameSection(segment)
                behaviourSection(segment)
                detectionSection(segment)
                recordingSection(segment)
                Section {
                    Button("Delete Segment", role: .destructive) { confirmDelete = true }
                }
            } else {
                ContentUnavailableView("Segment Deleted", systemImage: "trash")
            }
        }
        .navigationTitle(segment?.buttonTitle ?? "Segment")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            name = segment?.name ?? ""
            confidence = segment?.matchConfidence ?? 0.5
        }
        .onChange(of: nameFocused) { _, focused in if !focused { saveName() } }
        .onDisappear { saveName() }
        .confirmationDialog("Delete \(segment?.buttonTitle ?? "Segment")?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { delete() }
        } message: {
            Text("Its recording is removed from this iPhone.")
        }
    }

    // MARK: Sections

    private func nameSection(_ segment: RecordedSegment) -> some View {
        Section {
            HStack(spacing: 6) {
                Text("Skip").foregroundStyle(.secondary)
                TextField("Name", text: $name)
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .onSubmit(saveName)
                    .textInputAutocapitalization(.words)
            }
        } header: {
            Text("Button")
        } footer: {
            Text("The player shows “\(previewTitle)” while this part plays.")
        }
    }

    private var previewTitle: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Skip" : "Skip \(trimmed)"
    }

    private func behaviourSection(_ segment: RecordedSegment) -> some View {
        Section {
            Toggle("Enabled", isOn: binding(\.isEnabled))
            Toggle("Skip Automatically", isOn: binding(\.autoSkip))
                .disabled(!segment.isEnabled)
            Toggle("Override Online Skips", isOn: binding(\.overridesOnline))
                .disabled(!segment.isEnabled || settings?.skipping.segmentsAsFallback != true)
            MatchConfidenceControl(value: $confidence) {
                update { $0.matchConfidence = confidence }
            }
            .disabled(!segment.isEnabled)
        } footer: {
            Text("Automatic skipping jumps past this part once per episode, the first time it plays. In a watch party only the host skips. Override Online Skips works when Use My Segments as Fallback is on: this segment is used even where an online skip covers the same part.")
        }
    }

    private func detectionSection(_ segment: RecordedSegment) -> some View {
        Section {
            ForEach(DetectionMethod.allCases, id: \.self) { method in
                let available = isAvailable(method, segment)
                Button {
                    update { $0.detection = method }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(method.title).foregroundStyle(available ? .primary : .secondary)
                            Text(unavailableReason(method, segment) ?? method.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if segment.detection == method {
                            Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .disabled(!available)
            }
        } header: {
            Text("Find It By")
        }
    }

    private func recordingSection(_ segment: RecordedSegment) -> some View {
        Section {
            LabeledContent("Recorded From", value: segment.sourceLabel)
            LabeledContent("Starts At", value: clockString(segment.sourceStart))
            LabeledContent("Length", value: durationString(segment.duration))
            LabeledContent("Found In", value: segment.matches.count == 1 ? "1 episode" : "\(segment.matches.count) episodes")
            if !SegmentLibrary.exists(segment.id) {
                Text("This iPhone doesn't have the recording (it came from a backup). Record it again to find it in new episodes.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Button("Record Again") {
                onRecordAgain()
            }
            if !segment.matches.isEmpty {
                Button("Forget Where It Was Found") {
                    update { $0.matches = [:] }
                }
            }
        } header: {
            Text("Recording")
        } footer: {
            Text("Vela remembers where it found this part in each episode, so later visits know straight away.")
        }
    }

    // MARK: Helpers

    private func isAvailable(_ method: DetectionMethod, _ segment: RecordedSegment) -> Bool {
        unavailableReason(method, segment) == nil
    }

    private func unavailableReason(_ method: DetectionMethod, _ segment: RecordedSegment) -> String? {
        if method.usesAudio && !segment.hasAudio { return "No sound was recorded. Record again to add it." }
        if method.usesVisual && !segment.hasVisual { return "The picture was too plain to recognise." }
        return nil
    }

    private func binding(_ keyPath: WritableKeyPath<RecordedSegment, Bool>) -> Binding<Bool> {
        Binding(
            get: { segment?[keyPath: keyPath] ?? false },
            set: { value in update { $0[keyPath: keyPath] = value } }
        )
    }

    private func update(_ change: (inout RecordedSegment) -> Void) {
        guard var settings, settings.skipping.segment(segmentID) != nil else { return }
        settings.skipping.update(segmentID, change)
        store.saveTitleSettings(settings, key: context.key)
        context.apply()
    }

    private func saveName() {
        guard let segment, segment.name != name else { return }
        update { $0.name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func delete() {
        guard var settings else { return }
        settings.skipping.remove(segmentID)
        SegmentLibrary.delete(segmentID)
        store.saveTitleSettings(settings, key: context.key)
        context.apply()
        dismiss()
    }
}
