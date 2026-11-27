import SwiftUI

/// The walkthrough shown the first time a title's settings open. One step
/// per option; "Skip" leaves that option off. Closing early keeps what was
/// chosen so far and leaves the rest off.
struct TitleSetupFlow: View {
    let context: TitleContext
    let initial: TitleSettings
    /// (settings, wants to record a segment now).
    let onFinish: (TitleSettings, Bool) -> Void

    @State private var settings: TitleSettings
    @State private var step: Step = .welcome
    @State private var forward = true
    @State private var captionChoice: CaptionChoice
    @State private var offset: Double
    @State private var audioChoice: AudioChoice
    @State private var skipChoice: SkipChoice?
    @State private var showAllLanguages = false

    enum Step: Int, CaseIterable { case welcome, captions, timing, audio, skipping, done }
    enum SkipChoice { case online, record }

    init(context: TitleContext, initial: TitleSettings, onFinish: @escaping (TitleSettings, Bool) -> Void) {
        self.context = context
        self.initial = initial
        self.onFinish = onFinish
        _settings = State(initialValue: initial)
        _captionChoice = State(initialValue: initial.caption.choice)
        _offset = State(initialValue: initial.captionTiming.offset)
        _audioChoice = State(initialValue: initial.audio.choice)
    }

    private var kind: TitleKind { context.kind }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                page
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
                    ))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            bottomBar
        }
        .background(VixTheme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack {
            if step != .welcome && step != .done {
                Button {
                    go(Step(rawValue: step.rawValue - 1) ?? .welcome, forward: false)
                } label: {
                    Image(systemName: "chevron.left").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Back")
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { s in
                    Capsule()
                        .fill(s == step ? Color.white : Color.white.opacity(0.25))
                        .frame(width: s == step ? 18 : 7, height: 7)
                }
            }
            .animation(.snappy, value: step)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
            Spacer()
            Button {
                finish(record: false)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.white.opacity(0.14)))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close setup")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
    }

    private var bottomBar: some View {
        VStack(spacing: 4) {
            Button(action: primaryAction) {
                Text(primaryTitle)
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Color.white, in: Capsule())
            }
            .buttonStyle(.plain)
            if let skip = skipTitle {
                Button(skip, action: skipAction)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(minHeight: 44)
            } else {
                Color.clear.frame(height: 44)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: return "Set Up \(kind.noun)"
        case .captions: return "Use \(shortTitle(captionChoice.title))"
        case .timing: return offset == 0 ? "Keep In Sync" : "Use \(CaptionTiming.describe(offset))"
        case .audio: return "Use \(shortTitle(audioChoice.title))"
        case .skipping:
            switch skipChoice {
            case .online: return "Use Found Timestamps"
            case .record: return "Record a Segment"
            case nil: return "Choose an Option"
            }
        case .done: return skipChoice == .record ? "Start Recording" : "Done"
        }
    }

    private var skipTitle: String? {
        switch step {
        case .welcome: return "Not Now"
        case .done: return nil
        default: return "Skip"
        }
    }

    private func shortTitle(_ text: String) -> String {
        text.count > 24 ? String(text.prefix(22)) + "…" : text
    }

    // MARK: Steps

    @ViewBuilder private var page: some View {
        switch step {
        case .welcome: welcomePage
        case .captions: captionsPage
        case .timing: timingPage
        case .audio: audioPage
        case .skipping: skippingPage
        case .done: donePage
        }
    }

    private var welcomePage: some View {
        SetupPage(symbol: "slider.horizontal.3", tint: .blue,
                  title: kind.settingsTitle,
                  message: "Choose how \(context.title) plays: its captions, \(kind == .anime ? "sub or dub" : "audio"), and what to skip. Each choice applies to \(kind.scopePhrase), and you can skip any of them.") {
            VStack(alignment: .leading, spacing: 18) {
                featureRow("captions.bubble.fill", "Default Captions", "The same captions every time, in the language you want.")
                featureRow("clock.arrow.2.circlepath", "Caption Timing", "Move captions earlier or later when they're out of sync.")
                featureRow(kind == .anime ? "person.wave.2.fill" : "speaker.wave.2.fill",
                           kind == .anime ? "Sub or Dub" : "Default Audio",
                           kind == .anime ? "Always open the version you watch." : "Pick the audio language when there's a choice.")
                featureRow("forward.end.fill", "Your Own Skip Buttons",
                           "Mark an intro or outro once and Vela finds it in every episode, by picture or sound.")
            }
            .padding(.top, 6)
        }
    }

    private var captionsPage: some View {
        SetupPage(symbol: "captions.bubble.fill", tint: .orange, title: "Default Captions",
                  message: "Turned on whenever you play \(kind.scopePhrase).") {
            let sections = TitleChoices.captions(for: context)
            VStack(spacing: 18) {
                ForEach(visibleSections(sections)) { section in
                    choiceGroup(section, selection: $captionChoice, title: \.title)
                }
                if !showAllLanguages, sections.contains(where: { $0.options.count > 5 }) {
                    Button("Show All Languages") { withAnimation { showAllLanguages = true } }
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
    }

    private var timingPage: some View {
        SetupPage(symbol: "clock.arrow.2.circlepath", tint: .teal, title: "Caption Timing",
                  message: "If captions show before or after the lines are spoken, move them here. You can change this while watching from \(kind.settingsTitle).") {
            CaptionOffsetControl(offset: $offset)
                .padding(16)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var audioPage: some View {
        SetupPage(symbol: kind == .anime ? "person.wave.2.fill" : "speaker.wave.2.fill", tint: .pink,
                  title: kind == .anime ? "Sub or Dub" : "Default Audio",
                  message: kind == .anime
                    ? "Which version opens when you play an episode."
                    : "The audio language to play when a server offers more than one.") {
            VStack(spacing: 18) {
                ForEach(visibleSections(TitleChoices.audio(for: context))) { section in
                    choiceGroup(section, selection: $audioChoice, title: \.title)
                }
            }
        }
    }

    private var skippingPage: some View {
        SetupPage(symbol: "forward.end.fill", tint: .green, title: "Skipping",
                  message: "Choose where Skip buttons come from for \(kind.scopePhrase).") {
            VStack(spacing: 12) {
                optionCard(selected: skipChoice == .online, symbol: "globe", title: "Found Online",
                           detail: "Use intro and credits timestamps from SkipDB, TheIntroDB and AniSkip when they have this title.") {
                    skipChoice = .online
                }
                optionCard(selected: skipChoice == .record, symbol: "waveform.and.magnifyingglass", title: "Record My Own",
                           detail: kind.hasEpisodes
                            ? "Pick an episode and mark the part to skip. Vela recognises it in every other episode by its picture or sound, even when it moves."
                            : "Mark the part to skip and give its button a name.") {
                    skipChoice = .record
                }
            }
        }
    }

    private var donePage: some View {
        SetupPage(symbol: "checkmark.circle.fill", tint: .green, title: "All Set",
                  message: skipChoice == .record
                    ? "Next, pick \(kind.hasEpisodes ? "an episode and " : "")the part to skip."
                    : "Change any of this later in \(kind.settingsTitle), under the player.") {
            VStack(alignment: .leading, spacing: 12) {
                summaryRow("Captions", settings.caption.enabled ? settings.caption.choice.title : nil)
                summaryRow("Caption Timing", settings.captionTiming.enabled ? CaptionTiming.describe(settings.captionTiming.offset) : nil)
                summaryRow(kind == .anime ? "Sub or Dub" : "Audio", settings.audio.enabled ? settings.audio.choice.title : nil)
                summaryRow("Skipping", settings.skipping.enabled
                           ? (settings.skipping.source == .recorded ? "My segments" : "Found online") : nil)
            }
            .padding(16)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    // MARK: Pieces

    private func visibleSections<Value>(_ sections: [ChoiceSection<Value>]) -> [ChoiceSection<Value>] {
        guard !showAllLanguages else { return sections }
        return sections.map { ChoiceSection(title: $0.title, footer: $0.footer, options: Array($0.options.prefix(5))) }
    }

    private func choiceGroup<Value: Hashable>(_ section: ChoiceSection<Value>, selection: Binding<Value>,
                                              title: KeyPath<Value, String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !section.title.isEmpty {
                Text(section.title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            VStack(spacing: 0) {
                ForEach(Array(section.options.enumerated()), id: \.element) { index, option in
                    if index > 0 { Divider().padding(.leading, 16) }
                    Button {
                        selection.wrappedValue = option
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        HStack {
                            Text(option[keyPath: title]).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: selection.wrappedValue == option ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selection.wrappedValue == option ? Color.accentColor : Color.secondary)
                                .font(.title3)
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 50)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection.wrappedValue == option ? .isSelected : [])
                }
            }
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func featureRow(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func optionCard(selected: Bool, symbol: String, title: String, detail: String,
                            action: @escaping () -> Void) -> some View {
        Button {
            action()
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.title2)
                    .frame(width: 34)
                    .foregroundStyle(selected ? Color.accentColor : .white)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.12 : 0.06))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func summaryRow(_ title: String, _ value: String?) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value ?? "Off").foregroundStyle(value == nil ? .secondary : .primary)
        }
        .font(.subheadline)
    }

    // MARK: Actions

    private func go(_ next: Step, forward: Bool = true) {
        self.forward = forward
        showAllLanguages = false
        withAnimation(.spring(response: 0.4, dampingFraction: 0.88)) { step = next }
    }

    private func advance() {
        go(Step(rawValue: step.rawValue + 1) ?? .done)
    }

    private func primaryAction() {
        switch step {
        case .welcome:
            advance()
        case .captions:
            settings.caption = CaptionDefault(enabled: true, choice: captionChoice)
            advance()
        case .timing:
            settings.captionTiming = CaptionTiming(enabled: offset != 0, offset: offset)
            advance()
        case .audio:
            settings.audio = AudioDefault(enabled: true, choice: audioChoice)
            advance()
        case .skipping:
            guard let skipChoice else { return }
            settings.skipping.enabled = true
            settings.skipping.source = skipChoice == .online ? .online : .recorded
            advance()
        case .done:
            finish(record: skipChoice == .record)
        }
    }

    /// Skipping a step turns that option off.
    private func skipAction() {
        switch step {
        case .welcome:
            finish(record: false)
            return
        case .captions: settings.caption.enabled = false
        case .timing: settings.captionTiming.enabled = false
        case .audio: settings.audio.enabled = false
        case .skipping:
            settings.skipping.enabled = false
            skipChoice = nil
        case .done: break
        }
        advance()
    }

    private func finish(record: Bool) {
        onFinish(settings, record)
    }
}

/// One walkthrough page: a big symbol, title and message, then its content,
/// scrolling when it doesn't fit (small phones, large text).
private struct SetupPage<Content: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: symbol)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 84, height: 84)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(.top, 18)
                    .accessibilityHidden(true)
                VStack(spacing: 10) {
                    Text(title)
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text(message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                content
                    .frame(maxWidth: 520)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}
