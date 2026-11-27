import SwiftUI

// MARK: - Choices

/// A titled group of choices for a picker.
struct ChoiceSection<Value: Hashable>: Identifiable {
    let title: String
    let footer: String?
    let options: [Value]
    var id: String { title }
}

@MainActor
enum TitleChoices {
    /// Caption choices: what the playing video has, then common languages,
    /// then on-device generated captions.
    static func captions(for context: TitleContext) -> [ChoiceSection<CaptionChoice>] {
        let manager = context.playerManager
        var inVideo: [CaptionChoice] = []
        for option in manager.subtitleOptions {
            let code = MediaLanguage.code(of: option) ?? "und"
            let choice = CaptionChoice.language(code: code, label: option.displayName)
            if !inVideo.contains(choice) { inVideo.append(choice) }
        }
        for track in manager.externalSubtitles {
            let code = MediaLanguage.code(fromLabel: track.label) ?? "und"
            let choice = CaptionChoice.language(code: code, label: track.label)
            if !inVideo.contains(choice) { inVideo.append(choice) }
        }
        let inVideoCodes = Set(inVideo.compactMap { choice -> String? in
            if case .language(let code, _) = choice { return code }
            return nil
        })
        let languages = MediaLanguage.common
            .filter { !inVideoCodes.contains($0) }
            .map { CaptionChoice.language(code: $0, label: nil) }
        var generated: [CaptionChoice] = []
        if manager.canGenerateCaptions {
            generated.append(.generated(locale: "en-US"))
            if context.kind == .anime {
                generated.append(.generated(locale: "ja-JP"))
                generated.append(.generated(locale: "ja-JP->en"))
            }
        }

        var sections = [ChoiceSection(title: "", footer: nil, options: [CaptionChoice.off])]
        if !inVideo.isEmpty {
            sections.append(ChoiceSection(title: "In This Video", footer: "The exact track is used when an episode has it; otherwise any track in its language.", options: inVideo))
        }
        sections.append(ChoiceSection(title: inVideo.isEmpty ? "Languages" : "Other Languages",
                                      footer: "Used whenever an episode has captions in that language.", options: languages))
        if !generated.isEmpty {
            sections.append(ChoiceSection(title: "Auto-generated", footer: "Made on this iPhone from the video's sound.", options: generated))
        }
        return sections
    }

    /// Audio choices: Sub / Dub for anime, track languages for the rest.
    static func audio(for context: TitleContext) -> [ChoiceSection<AudioChoice>] {
        if context.kind == .anime {
            return [ChoiceSection(title: "", footer: "Used when an episode has it; otherwise Vela plays what's available.",
                                  options: [.animeTrack("Sub"), .animeTrack("Dub")])]
        }
        var inVideo: [AudioChoice] = []
        for option in context.playerManager.audioOptions {
            let code = MediaLanguage.code(of: option) ?? "und"
            let choice = AudioChoice.language(code: code, label: option.displayName)
            if !inVideo.contains(choice) { inVideo.append(choice) }
        }
        let codes = Set(inVideo.compactMap { choice -> String? in
            if case .language(let code, _) = choice { return code }
            return nil
        })
        let languages = MediaLanguage.common.filter { !codes.contains($0) }.map { AudioChoice.language(code: $0, label: nil) }
        var sections: [ChoiceSection<AudioChoice>] = []
        if !inVideo.isEmpty {
            sections.append(ChoiceSection(title: "In This Video", footer: nil, options: inVideo))
        }
        sections.append(ChoiceSection(title: inVideo.isEmpty ? "Languages" : "Other Languages",
                                      footer: "Applies when a server offers more than one audio track.", options: languages))
        return sections
    }
}

/// A list of choices with a checkmark, for Form pages.
struct ChoiceList<Value: Hashable>: View {
    let sections: [ChoiceSection<Value>]
    @Binding var selection: Value
    let title: (Value) -> String
    var onPick: () -> Void = {}

    var body: some View {
        ForEach(sections) { section in
            Section {
                ForEach(section.options, id: \.self) { option in
                    Button {
                        selection = option
                        onPick()
                    } label: {
                        HStack {
                            Text(title(option)).foregroundStyle(.primary)
                            Spacer()
                            if option == selection {
                                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityAddTraits(option == selection ? .isSelected : [])
                }
            } header: {
                if !section.title.isEmpty { Text(section.title) }
            } footer: {
                if let footer = section.footer { Text(footer) }
            }
        }
    }
}

// MARK: - Caption timing

/// Moves captions earlier or later in tenth-second steps.
struct CaptionOffsetControl: View {
    @Binding var offset: Double

    var body: some View {
        VStack(spacing: 14) {
            Text(CaptionTiming.describe(offset))
                .font(.title2.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
                .animation(.snappy, value: offset)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)

            HStack(spacing: 8) {
                step("−1 s", by: -1)
                step("−0.1", by: -0.1)
                step("+0.1", by: 0.1)
                step("+1 s", by: 1)
            }

            Slider(value: Binding(get: { offset }, set: { offset = (($0 * 10).rounded()) / 10 }),
                   in: -10...10) {
                Text("Caption timing")
            } minimumValueLabel: {
                Text("Earlier").font(.caption2)
            } maximumValueLabel: {
                Text("Later").font(.caption2)
            }
            .accessibilityValue(CaptionTiming.describe(offset))

            if offset != 0 {
                Button("Reset to In Sync") { offset = 0 }
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.vertical, 6)
    }

    private func step(_ title: String, by amount: Double) -> some View {
        Button {
            let next = ((offset + amount) * 10).rounded() / 10
            offset = min(max(next, CaptionTiming.range.lowerBound), CaptionTiming.range.upperBound)
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(Color.white.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(amount < 0 ? "Earlier by \(abs(amount)) seconds" : "Later by \(amount) seconds")
    }
}

// MARK: - Confidence

/// "How sure must Vela be?" from Loose to Strict, for segment matching.
struct MatchConfidenceControl: View {
    @Binding var value: Double
    /// Called when the finger lifts, for saving once instead of per step.
    var onEditingEnded: () -> Void = {}

    private var label: String {
        switch value {
        case ..<0.25: "Loose"
        case ..<0.45: "Relaxed"
        case ..<0.6: "Balanced"
        case ..<0.8: "Careful"
        default: "Strict"
        }
    }

    private var detail: String {
        switch value {
        case ..<0.45: "Finds the part even when it's re-cut, re-coloured or louder. May skip something that only looks or sounds alike."
        case ..<0.6: "The default. Finds the same footage or music in every episode."
        default: "Only near-identical footage or sound. Use this if Vela skips the wrong thing."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Match Confidence").font(.subheadline.weight(.semibold))
                Spacer()
                Text(label).font(.subheadline).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: 0...1) {
                Text("Match confidence")
            } minimumValueLabel: {
                Text("Loose").font(.caption2)
            } maximumValueLabel: {
                Text("Strict").font(.caption2)
            } onEditingChanged: { editing in
                if !editing { onEditingEnded() }
            }
            .accessibilityValue(label)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// How closely a caption track's name must fit, for default captions.
struct CaptionConfidenceControl: View {
    @Binding var value: Double

    private var detail: String {
        switch value {
        case ..<0.3: "Any track in the language, including forced or signs-only tracks."
        case ..<0.8: "Any full track in the language. Prefers names like the one you picked (English CC, English [SDH])."
        default: "Only the track you picked, by name. Captions stay off in episodes that don't have it."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Match Confidence").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int((value * 100).rounded()))%").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: 0...1, step: 0.05) {
                Text("Caption match confidence")
            } minimumValueLabel: {
                Text("Any").font(.caption2)
            } maximumValueLabel: {
                Text("Exact").font(.caption2)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Entry card

/// The row under a player that opens the title's settings page. Replaces the
/// old Intro start / end boxes.
struct TitleSettingsCard: View {
    let item: MediaItem
    let makeContext: () -> TitleContext?

    private var kind: TitleKind { TitleKind(item: item) }

    var body: some View {
        NavigationLink {
            if let context = makeContext() {
                TitleSettingsView(context: context)
            } else {
                ContentUnavailableView(kind.settingsTitle, systemImage: "exclamationmark.triangle",
                                       description: Text("Open the title again to change its settings."))
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(kind.settingsTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens settings for \(kind.scopePhrase)")
    }
}

/// "1:32" / "1:02:03".
func clockString(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "--:--" }
    let s = max(0, Int(seconds.rounded(.down)))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}

/// "1:32.4", for marking segment edges.
func preciseClockString(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "--:--" }
    let tenths = Int((max(0, seconds) * 10).rounded())
    let whole = tenths / 10
    let base = whole >= 3600 ? String(format: "%d:%02d:%02d", whole / 3600, (whole % 3600) / 60, whole % 60)
                             : String(format: "%d:%02d", whole / 60, whole % 60)
    return "\(base).\(tenths % 10)"
}

/// "1 min 32 s".
func durationString(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded()))
    if s < 60 { return "\(s) s" }
    return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s"
}
