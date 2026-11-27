import AVFoundation
import SwiftUI

/// Records a skip segment: pick an episode, play to the part, mark where it
/// starts and ends, name it, and save. Vela fingerprints whatever plays here,
/// so a part already watched saves at once; otherwise it plays the part once
/// to record it.
struct SegmentRecorderView: View {
    let context: TitleContext
    /// An existing segment this recording replaces ("Record Again").
    let replacing: UUID?
    let onSave: (RecordedSegment) -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var model = SegmentRecorderModel()
    @State private var name = ""
    @State private var detection: DetectionMethod = .visual
    @State private var autoSkip = false
    @State private var isSaving = false
    @State private var saveError: String?
    @FocusState private var nameFocused: Bool

    private var existing: RecordedSegment? {
        guard let replacing else { return nil }
        return store.titleSettings[context.key]?.skipping.segments.first { $0.id == replacing }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { close() }
                            .disabled(isSaving && !model.isRecording)
                    }
                    if context.kind.hasEpisodes, model.stage != .choosing {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Episodes") {
                                model.teardown()
                                model.stage = .choosing
                            }
                            .disabled(isSaving)
                        }
                    }
                }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isSaving)
        .onAppear(perform: begin)
        .onDisappear { model.teardown() }
        .alert("Couldn't Save Segment", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private var navigationTitle: String {
        switch model.stage {
        case .choosing: return "Choose an Episode"
        default: return model.episode?.label ?? "Record Segment"
        }
    }

    @ViewBuilder private var content: some View {
        switch model.stage {
        case .choosing:
            RecorderEpisodePicker(context: context) { episode in open(episode) }
        case .loading(let message):
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text(message).font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Open", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                if let episode = model.episode {
                    Button("Try Again") { open(episode) }.buttonStyle(.borderedProminent)
                }
                if context.kind.hasEpisodes {
                    Button("Choose Another Episode") { model.stage = .choosing }
                }
            }
        case .marking:
            markingView
        }
    }

    // MARK: Marking

    private var markingView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                RecorderVideo(model: model)
                RecorderTimeline(model: model)
                transportRow
                markButtons
                if model.start != nil || model.end != nil { fineTune }
                nameCard
                detectionCard
                Toggle("Skip Automatically", isOn: $autoSkip)
                    .padding(14)
                    .background(cardBackground)
                captureStatus
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { saveBar }
    }

    private var transportRow: some View {
        HStack(spacing: 28) {
            Button { model.skip(by: -5) } label: {
                Image(systemName: "gobackward.5").font(.title2)
            }
            .accessibilityLabel("Back 5 seconds")
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 46))
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
            Button { model.skip(by: 5) } label: {
                Image(systemName: "goforward.5").font(.title2)
            }
            .accessibilityLabel("Forward 5 seconds")
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .disabled(model.isRecording)
    }

    private var markButtons: some View {
        HStack(spacing: 10) {
            markButton(title: "Set Start", value: model.start, symbol: "arrow.right.to.line") { model.markStart() }
            markButton(title: "Set End", value: model.end, symbol: "arrow.left.to.line") { model.markEnd() }
        }
        .disabled(model.isRecording)
    }

    private func markButton(title: String, value: Double?, symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            VStack(spacing: 4) {
                Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
                Text(value.map(preciseClockString) ?? "Not set")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(value == nil ? .secondary : .primary)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(value == nil ? Color.white.opacity(0.08) : Color.accentColor.opacity(0.28),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityValue(value.map(preciseClockString) ?? "Not set")
    }

    private var fineTune: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.start != nil {
                nudgeRow("Start", value: model.start) { model.nudgeStart(by: $0) }
            }
            if model.end != nil {
                nudgeRow("End", value: model.end) { model.nudgeEnd(by: $0) }
            }
            HStack {
                if let length = model.length, length > 0 {
                    Text("Length \(durationString(length))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.start != nil, model.end != nil {
                    Button { model.preview() } label: {
                        Label("Preview", systemImage: "play.rectangle")
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
        }
        .padding(14)
        .background(cardBackground)
        .disabled(model.isRecording)
    }

    private func nudgeRow(_ title: String, value: Double?, nudge: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(value.map(preciseClockString) ?? "–").font(.subheadline.monospacedDigit())
            }
            .frame(width: 72, alignment: .leading)
            ForEach([-1.0, -0.1, 0.1, 1.0], id: \.self) { amount in
                Button {
                    nudge(amount)
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    Text(amount < 0 ? (amount == -1 ? "−1 s" : "−0.1") : (amount == 1 ? "+1 s" : "+0.1"))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(Color.white.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title) \(amount < 0 ? "earlier" : "later") by \(abs(amount)) seconds")
            }
        }
    }

    private var nameCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Button").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text("Skip").font(.body.weight(.semibold))
                TextField("Name", text: $name)
                    .focused($nameFocused)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            Text("For example Opening, Recap or Credits. Shown on the button while this part plays.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(cardBackground)
    }

    private var detectionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Find It By").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Picker("Find It By", selection: $detection) {
                ForEach(DetectionMethod.allCases, id: \.self) { method in
                    Text(method.title).tag(method)
                }
            }
            .pickerStyle(.segmented)
            Text(detectionNote).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(cardBackground)
    }

    private var detectionNote: String {
        if detection.usesAudio && !model.audioPossible {
            return "Finding by sound needs iOS 27 or later; this segment will be found by picture."
        }
        if detection.usesAudio && context.kind == .anime {
            return detection.detail + " Sound depends on the audio, so record from the Sub or Dub you watch."
        }
        return detection.detail
    }

    @ViewBuilder private var captureStatus: some View {
        if model.markProblem == nil {
            let capture = model.capture()
            VStack(alignment: .leading, spacing: 6) {
                captureLine("Picture", done: capture.picture, wanted: detection.usesVisual || !model.audioPossible)
                if model.audioPossible {
                    captureLine("Sound", done: capture.sound, wanted: detection.usesAudio)
                }
                if !model.isCaptured(for: detection) {
                    Text("Saving plays the marked part once to record it. Keep this screen open.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
        }
    }

    private func captureLine(_ title: String, done: Bool, wanted: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(done ? .green : .secondary)
            Text(done ? "\(title) recorded" : (wanted ? "\(title) not recorded yet" : "\(title) not needed"))
                .font(.subheadline)
                .foregroundStyle(wanted || done ? .primary : .secondary)
        }
    }

    private var saveBar: some View {
        VStack(spacing: 6) {
            if let problem = model.markProblem {
                Text(problem).font(.caption).foregroundStyle(.secondary)
            }
            Button {
                Task { await save() }
            } label: {
                Group {
                    if model.isRecording {
                        Text("Recording… \(Int((model.recordingProgress ?? 0) * 100))%")
                    } else if isSaving {
                        ProgressView().tint(.black)
                    } else {
                        Text(existing == nil ? "Save Segment" : "Save New Recording")
                    }
                }
                .font(.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Color.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.markProblem != nil || isSaving)
            .opacity(model.markProblem != nil ? 0.45 : 1)
            if model.isRecording {
                Button("Stop Recording") { model.cancelRecording() }
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06))
    }

    // MARK: Actions

    private func begin() {
        // The title's own player waits while this one plays (this device only).
        context.playerManager.rawPause()
        if let existing {
            name = existing.name
            detection = existing.detection
            autoSkip = existing.autoSkip
        } else {
            detection = .visual
        }
        guard model.stage == .choosing else { return }
        if !context.kind.hasEpisodes, let movie = context.currentEpisode {
            open(movie)
        }
    }

    private func open(_ episode: EpisodeRef) {
        // Re-recording the same episode starts a little before the old part.
        var position = 0.0
        if let existing, existing.sourceKey == episode.id { position = max(0, existing.sourceStart - 5) }
        model.open(episode, context: context, startingAt: position)
    }

    private func close() {
        if model.isRecording { model.cancelRecording() }
        model.teardown()
        dismiss()
    }

    private func save() async {
        guard model.markProblem == nil, let start = model.start, let end = model.end, let episode = model.episode else { return }
        nameFocused = false
        isSaving = true
        defer { isSaving = false }

        if !model.isCaptured(for: detection) {
            let finished = await model.record()
            guard finished else {
                if model.player != nil {
                    saveError = "Recording stopped before the end of the part. Save again to record it."
                }
                return
            }
        }
        guard let print = model.makePrint() else { return }
        guard print.hasVisual || print.hasAudio else {
            saveError = "Vela couldn't recognise this part: the picture is too plain and no sound was recorded. Try marking a longer part."
            return
        }
        let id = replacing ?? UUID()
        do {
            try SegmentLibrary.save(print, id: id)
        } catch {
            saveError = error.localizedDescription
            return
        }
        var segment = RecordedSegment(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            detection: detection,
            duration: end - start,
            sourceLabel: episode.label,
            sourceKey: episode.id,
            sourceStart: start,
            hasVisual: print.hasVisual,
            hasAudio: print.hasAudio,
            autoSkip: autoSkip
        )
        // It's already known in the episode it was recorded from.
        segment.matches[episode.id] = SegmentMatch(start: start, videoDuration: model.duration, foundAt: Date())
        onSave(segment)
        model.teardown()
        dismiss()
    }
}

// MARK: - Video

private struct RecorderVideo: View {
    @Bindable var model: SegmentRecorderModel

    var body: some View {
        ZStack {
            Color.black
            if let player = model.player {
                VideoPlayerLayer(player: player, isFullscreen: false)
            }
            if model.player?.currentItem?.status != .readyToPlay {
                ProgressView().tint(.white)
            }
            if let progress = model.recordingProgress {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Circle().fill(.red).frame(width: 10, height: 10)
                        Text("Recording").font(.subheadline.weight(.semibold))
                    }
                    ProgressView(value: progress)
                        .tint(.white)
                        .frame(width: 180)
                }
                .padding(14)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Recording, \(Int(progress * 100)) percent")
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if !model.isRecording { model.togglePlay() } }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(model.isPlaying ? "Pause video" : "Play video")
    }
}

// MARK: - Timeline

/// The whole episode, with the marked part highlighted. Drag anywhere to
/// scrub; drag a flag to move that edge.
private struct RecorderTimeline: View {
    @Bindable var model: SegmentRecorderModel
    @State private var scrubbing: Double?
    @State private var dragging: Edge?

    private enum Edge { case start, end }
    private static let space = "recorderTimeline"

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let width = max(1, geo.size.width)
                let duration = max(model.duration, 1)
                let x: (Double) -> CGFloat = { CGFloat(min(1, max(0, $0 / duration))) * width }
                let shown = scrubbing ?? model.currentTime
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2)).frame(height: 6)
                    if let start = model.start, let end = model.end, end > start {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: max(2, x(end) - x(start)), height: 14)
                            .offset(x: x(start))
                    }
                    Capsule().fill(Color.white).frame(width: 3, height: 26).offset(x: x(shown) - 1.5)
                    if let start = model.start { flag(at: x(start), edge: .start, duration: duration, width: width) }
                    if let end = model.end { flag(at: x(end), edge: .end, duration: duration, width: width) }
                }
                .frame(height: 44)
                .contentShape(Rectangle())
                .coordinateSpace(.named(Self.space))
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                        .onChanged { value in
                            guard dragging == nil else { return }
                            scrubbing = Double(min(1, max(0, value.location.x / width))) * duration
                        }
                        .onEnded { value in
                            guard dragging == nil else { return }
                            model.seek(to: Double(min(1, max(0, value.location.x / width))) * duration)
                            scrubbing = nil
                        }
                )
            }
            .frame(height: 44)
            .disabled(model.isRecording)

            HStack {
                Text(preciseClockString(scrubbing ?? model.currentTime))
                Spacer()
                Text(clockString(model.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timeline")
        .accessibilityValue("\(preciseClockString(model.currentTime)) of \(clockString(model.duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.skip(by: 5)
            case .decrement: model.skip(by: -5)
            @unknown default: break
            }
        }
    }

    private func flag(at position: CGFloat, edge: Edge, duration: Double, width: CGFloat) -> some View {
        VStack(spacing: 0) {
            Image(systemName: edge == .start ? "flag.fill" : "flag.checkered")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 22, height: 18)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Rectangle().fill(Color.white).frame(width: 2, height: 18)
        }
        .frame(width: 36, height: 44)
        .contentShape(Rectangle())
        .offset(x: position - 18, y: -8)
        // Wins over the timeline's scrub when the touch starts on a flag.
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                .onChanged { value in
                    dragging = edge
                    let time = Double(min(1, max(0, value.location.x / width))) * duration
                    scrubbing = time
                    if edge == .start { model.start = time } else { model.end = time }
                }
                .onEnded { _ in
                    if let time = scrubbing { model.seek(to: time) }
                    scrubbing = nil
                    dragging = nil
                }
        )
    }
}

// MARK: - Episode picker

private struct RecorderEpisodePicker: View {
    let context: TitleContext
    let onPick: (EpisodeRef) -> Void

    @State private var season: Int?
    @State private var episodes: [EpisodeRef] = []
    @State private var isLoading = false
    @State private var query = ""

    private var filtered: [EpisodeRef] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return episodes }
        return episodes.filter { "\($0.number)" == q || $0.label.lowercased().contains(q) || ($0.title?.lowercased().contains(q) ?? false) }
    }

    var body: some View {
        List {
            Section {
                Text("Pick an episode where the part you want to skip appears. You'll mark its start and end next.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let current = context.currentEpisode {
                    Button { onPick(current) } label: {
                        episodeRow(current, badge: "Watching")
                    }
                }
            }
            if context.kind == .show, context.seasons.count > 1 {
                Section {
                    Picker("Season", selection: Binding(get: { season ?? context.seasons.first ?? 1 }, set: { season = $0 })) {
                        ForEach(context.seasons, id: \.self) { Text("Season \($0)").tag($0) }
                    }
                }
            }
            Section(context.kind == .show ? "Season \(season ?? context.currentSeason ?? 1)" : "Episodes") {
                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if filtered.isEmpty {
                    Text("No episodes").foregroundStyle(.secondary)
                } else {
                    ForEach(filtered) { episode in
                        Button { onPick(episode) } label: {
                            episodeRow(episode, badge: episode.id == context.currentEpisode?.id ? "Watching" : nil)
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Find an episode")
        .task(id: season) { await load() }
        .onAppear {
            if season == nil { season = context.currentSeason ?? context.seasons.first }
        }
    }

    private func episodeRow(_ episode: EpisodeRef, badge: String?) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.label).font(.body.weight(.semibold)).foregroundStyle(.primary)
                if let title = episode.title, !title.isEmpty {
                    Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let badge {
                Text(badge)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.3), in: Capsule())
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func load() async {
        if context.kind == .show && season == nil { return }
        isLoading = true
        episodes = await context.loadEpisodes(context.kind == .show ? season : nil)
        isLoading = false
    }
}
