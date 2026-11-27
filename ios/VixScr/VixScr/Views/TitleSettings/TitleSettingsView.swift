import SwiftUI

/// Show / Movie / Anime Settings: defaults for one title. Every option has
/// its own switch; while it's off, the app's normal behaviour applies. The
/// first visit runs the setup walkthrough (`TitleSetupFlow`).
struct TitleSettingsView: View {
    let context: TitleContext
    @Environment(AppStore.self) private var store
    @State private var settings: TitleSettings
    @State private var showSetup = false
    @State private var recorder: RecorderRequest?
    @State private var confirmReset = false

    init(context: TitleContext) {
        self.context = context
        _settings = State(initialValue: TitleSettings(title: context.title, kind: context.kind))
    }

    private var kind: TitleKind { context.kind }

    var body: some View {
        Form {
            headerSection
            captionsSection
            timingSection
            audioSection
            skippingSection
            nextEpisodeSection
            manageSection
        }
        .navigationTitle(kind.settingsTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            settings = store.settings(forTitle: context.key, title: context.title, kind: kind)
            if !settings.setupCompleted { showSetup = true }
        }
        // Matches found while this page is open (the video keeps playing).
        .onChange(of: store.titleSettings[context.key]) { _, saved in
            if let saved { settings.skipping.segments = saved.skipping.segments }
        }
        .fullScreenCover(isPresented: $showSetup) {
            TitleSetupFlow(context: context, initial: settings) { result, wantsRecording in
                settings = result
                settings.setupCompleted = true
                commit()
                showSetup = false
                if wantsRecording {
                    // Let the walkthrough slide away first.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 450_000_000)
                        recorder = RecorderRequest(replacing: nil)
                    }
                }
            }
        }
        .fullScreenCover(item: $recorder) { request in
            SegmentRecorderView(context: context, replacing: request.replacing) { segment in
                save(recorded: segment, replacing: request.replacing)
            }
        }
        .confirmationDialog("Reset \(kind.settingsTitle)?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                store.resetTitleSettings(key: context.key)
                settings = TitleSettings(title: context.title, kind: kind)
                context.apply()
            }
        } message: {
            Text("Turns every option off and deletes this title's recorded segments.")
        }
    }

    // MARK: Sections

    private var headerSection: some View {
        Section {
            HStack(spacing: 14) {
                AsyncImage(url: context.item.posterURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: kind.symbol).font(.title2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 54, height: 80)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.title).font(.headline).lineLimit(2)
                    Text("Applies to \(kind.scopePhrase). Options that are off use your app-wide settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var captionsSection: some View {
        Section {
            Toggle("Default Captions", isOn: binding(\.caption.enabled))
            if settings.caption.enabled {
                NavigationLink {
                    Form {
                        ChoiceList(sections: TitleChoices.captions(for: context),
                                   selection: binding(\.caption.choice),
                                   title: { $0.title })
                    }
                    .navigationTitle("Default Captions")
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    LabeledContent("Captions", value: settings.caption.choice.title)
                }
                if case .language = settings.caption.choice {
                    CaptionConfidenceControl(value: binding(\.caption.minimumConfidence))
                    if context.playerManager.player != nil {
                        LabeledContent("This Episode", value: captionMatchSummary)
                    }
                }
            }
        } header: {
            Text("Captions")
        } footer: {
            Text(settings.caption.enabled
                 ? "Turned on for every episode, even if you change captions while watching."
                 : "Off: captions follow your last choice in the player.")
        }
    }

    private var timingSection: some View {
        Section {
            Toggle("Adjust Caption Timing", isOn: binding(\.captionTiming.enabled))
            if settings.captionTiming.enabled {
                CaptionOffsetControl(offset: binding(\.captionTiming.offset))
            }
        } footer: {
            Text(settings.captionTiming.enabled
                 ? "Shows captions earlier or later than the video says. Changes apply to the playing video straight away."
                 : "For captions that run ahead of or behind the dialogue.")
        }
    }

    private var audioSection: some View {
        Section {
            Toggle(kind == .anime ? "Default Sub or Dub" : "Default Audio", isOn: binding(\.audio.enabled))
            if settings.audio.enabled {
                if kind == .anime {
                    Picker("Version", selection: binding(\.audio.choice)) {
                        Text("Subtitled").tag(AudioChoice.animeTrack("Sub"))
                        Text("Dubbed").tag(AudioChoice.animeTrack("Dub"))
                    }
                    .pickerStyle(.segmented)
                } else {
                    NavigationLink {
                        Form {
                            ChoiceList(sections: TitleChoices.audio(for: context),
                                       selection: binding(\.audio.choice),
                                       title: { $0.title })
                        }
                        .navigationTitle("Default Audio")
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        LabeledContent("Language", value: settings.audio.choice.title)
                    }
                }
            }
        } header: {
            Text(kind == .anime ? "Sub & Dub" : "Audio")
        } footer: {
            Text(kind == .anime
                 ? "Picks the subtitled or dubbed version whenever an episode has it."
                 : "Picks this audio language when the server offers several.")
        }
    }

    @ViewBuilder private var skippingSection: some View {
        Section {
            Toggle("Custom Skipping", isOn: binding(\.skipping.enabled))
            if settings.skipping.enabled {
                sourceRow(.online, title: "Found Online",
                          detail: "Timestamps from SkipDB, TheIntroDB and AniSkip.",
                          symbol: "globe")
                sourceRow(.recorded, title: "My Segments",
                          detail: "Mark a part once; Vela finds it in every episode by picture or sound.",
                          symbol: "waveform.and.magnifyingglass")
            }
            if !settings.skipping.enabled || settings.skipping.source == .online {
                LabeledContent(context.kind.hasEpisodes ? "This Episode" : "Found", value: foundOnlineSummary)
            }
        } header: {
            Text("Skipping")
        } footer: {
            if !settings.skipping.enabled {
                Text("Off: Skip buttons use timestamps found online, like every other title.")
            }
        }

        if settings.skipping.enabled && settings.skipping.source == .recorded {
            Section {
                ForEach(settings.skipping.segments) { segment in
                    NavigationLink {
                        SegmentDetailView(context: context, segmentID: segment.id) {
                            recorder = RecorderRequest(replacing: segment.id)
                        }
                    } label: {
                        SegmentRow(segment: segment, manager: context.playerManager)
                    }
                }
                Button {
                    recorder = RecorderRequest(replacing: nil)
                } label: {
                    Label(settings.skipping.segments.isEmpty ? "Record a Segment" : "Record Another Segment",
                          systemImage: "plus.circle.fill")
                }
            } header: {
                Text("My Segments")
            } footer: {
                Text(kind.hasEpisodes
                     ? "Pick an episode, mark where the part starts and ends, and name it. Each segment gets its own Skip button."
                     : "Mark where the part starts and ends, and name it. It gets its own Skip button.")
            }
        }
    }

    /// The track the default caption picked in the playing episode.
    private var captionMatchSummary: String {
        guard let match = context.playerManager.titleCaptionMatch else { return "No track matched" }
        return "\(match.label) · \(Int((match.confidence * 100).rounded()))% match"
    }

    @ViewBuilder private var nextEpisodeSection: some View {
        if kind.hasEpisodes {
            Section {
                Toggle("Custom Next Episode Timing", isOn: binding(\.nextEpisode.enabled))
                if settings.nextEpisode.enabled {
                    NextEpisodeTimingControl(timing: binding(\.nextEpisode))
                }
            } header: {
                Text("Next Episode")
            } footer: {
                Text(settings.nextEpisode.enabled
                     ? "When the Next Episode button appears in the player for this \(kind.noun.lowercased())."
                     : "Off: the Next Episode button appears five minutes before the end.")
            }
        }
    }

    /// What the online sources found for the playing episode.
    private var foundOnlineSummary: String {
        let found = context.playerManager.skipSegments.filter { $0.source != .recorded }
        guard !found.isEmpty else { return context.playerManager.player == nil ? "Not playing" : "Nothing found" }
        return found.map { "\($0.kind.rawValue.capitalized) \(clockString($0.start))–\(clockString($0.end))" }
            .joined(separator: ", ")
    }

    private func sourceRow(_ source: SkipSource, title: String, detail: String, symbol: String) -> some View {
        Button {
            settings.skipping.source = source
            commit()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.body.weight(.semibold))
                    .frame(width: 26)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if settings.skipping.source == source {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(settings.skipping.source == source ? .isSelected : [])
    }

    private var manageSection: some View {
        Section {
            Button("Run Setup Again") { showSetup = true }
            Button("Reset \(kind.settingsTitle)", role: .destructive) { confirmReset = true }
                .disabled(!settings.isCustomised && settings.skipping.segments.isEmpty)
        }
    }

    // MARK: Saving

    /// A binding into the settings that saves and applies every change.
    private func binding<Value>(_ keyPath: WritableKeyPath<TitleSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                settings[keyPath: keyPath] = value
                commit()
            }
        )
    }

    private func commit() {
        // Keep matches recorded meanwhile; the page holds an older copy.
        if let saved = store.titleSettings[context.key] {
            for index in settings.skipping.segments.indices {
                if let current = saved.skipping.segments.first(where: { $0.id == settings.skipping.segments[index].id }) {
                    settings.skipping.segments[index].matches = current.matches
                }
            }
        }
        store.saveTitleSettings(settings, key: context.key)
        context.apply()
    }

    private func save(recorded segment: RecordedSegment, replacing id: UUID?) {
        settings = store.settings(forTitle: context.key, title: context.title, kind: kind)
        if let id, let index = settings.skipping.segments.firstIndex(where: { $0.id == id }) {
            var updated = segment
            updated.id = id
            settings.skipping.segments[index] = updated
        } else {
            settings.skipping.segments.append(segment)
        }
        settings.skipping.enabled = true
        settings.skipping.source = .recorded
        settings.setupCompleted = true
        store.saveTitleSettings(settings, key: context.key)
        context.apply()
    }
}

/// Which segment the recorder replaces (nil: a new one).
struct RecorderRequest: Identifiable {
    let id = UUID()
    let replacing: UUID?
}

/// One recorded segment in the list.
private struct SegmentRow: View {
    let segment: RecordedSegment
    @Bindable var manager: VideoPlayerManager

    private var status: (text: String, color: Color)? {
        if !segment.isEnabled { return ("Off", .secondary) }
        if let start = manager.foundSegmentStarts[segment.id] { return ("Found at \(clockString(start))", .green) }
        if manager.searchingSegmentIDs.contains(segment.id) { return ("Looking…", .orange) }
        if segment.effectiveDetection == nil || !SegmentLibrary.exists(segment.id) {
            return ("Record again on this iPhone", .red)
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(segment.buttonTitle)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(segment.isEnabled ? .primary : .secondary)
                if segment.autoSkip {
                    Image(systemName: "forward.end.alt.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Skips automatically")
                }
            }
            Text("\(durationString(segment.duration)) · from \(segment.sourceLabel) · \(segment.detection.title)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let status {
                Text(status.text).font(.caption.weight(.semibold)).foregroundStyle(status.color)
            }
        }
        .padding(.vertical, 2)
    }
}
