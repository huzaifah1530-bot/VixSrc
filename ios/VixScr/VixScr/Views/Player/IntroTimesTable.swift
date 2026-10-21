import SwiftUI

/// Intro start / end for a show, under Reload and Save. With no custom
/// times the boxes show the intro found for the playing episode
/// (TheIntroDB / AniSkip), which can differ per episode; 00:00 → 00:00
/// when nothing is found. Typing new times saves a custom intro used for
/// every episode; the reset button goes back to the found times.
/// Same rules as desktop components/IntroTimes.tsx.
struct IntroTimesTable: View {
    let showKey: String
    let title: String
    /// The intro found for the episode that's playing, if any.
    var found: SkipSegment?
    /// Called after a change is saved so the playing episode picks it up.
    var onChange: () -> Void = {}

    @Environment(AppStore.self) private var store
    @State private var start = "00:00"
    @State private var end = "00:00"
    @FocusState private var focused: Field?

    private enum Field { case start, end }

    /// "1:30", "01:02:03" or "90" → seconds; nil when it isn't a time.
    static func parse(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return 0 }
        let parts = t.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count, numbers.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        return Double(numbers.reduce(0) { $0 * 60 + $1 })
    }

    static func clock(_ seconds: Double?) -> String {
        let s = Int(seconds ?? 0)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

    private var custom: IntroOverride? {
        guard let o = store.introOverrides[showKey], o.isComplete else { return nil }
        return o
    }
    private var shownStart: Double { custom?.start ?? found?.start ?? 0 }
    private var shownEnd: Double { custom?.end ?? found?.end ?? 0 }

    private var parsed: (start: Double?, end: Double?) { (Self.parse(start), Self.parse(end)) }
    private var isZero: Bool { parsed.start == 0 && parsed.end == 0 }
    private var isInvalid: Bool {
        guard let s = parsed.start, let e = parsed.end else { return true }
        return !isZero && e <= s
    }

    private var hint: String {
        if isInvalid { return "Use mm:ss, with the end after the start." }
        if custom != nil { return "Custom: used for every episode of this show." }
        if found != nil { return "Found for this episode (can differ per episode). Edit to set your own for all episodes." }
        return "No intro found for this episode. Enter times to set one for all episodes."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Intro start").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("Intro end").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Color.clear.frame(width: 28, height: 1)
                }
                GridRow {
                    timeField("Intro start", text: $start, field: .start)
                    timeField("Intro end", text: $end, field: .end)
                    Button(action: reset) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.footnote.weight(.semibold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderless)
                    .disabled(custom == nil)
                    .opacity(custom == nil ? 0.3 : 1)
                    .accessibilityLabel("Reset to found intro times")
                }
            }
            Text(hint)
                .font(.caption)
                .foregroundStyle(isInvalid ? Color.red : Color.secondary)
        }
        .padding(14)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear(perform: showCurrent)
        .onChange(of: showKey) { _, _ in showCurrent() }
        .onChange(of: found) { _, _ in if focused == nil { showCurrent() } }
        .onChange(of: focused) { old, new in if old != nil && new == nil { commit() } }
    }

    private func timeField(_ label: String, text: Binding<String>, field: Field) -> some View {
        TextField("00:00", text: text)
            .keyboardType(.numbersAndPunctuation)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.body.monospacedDigit())
            .multilineTextAlignment(.center)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .focused($focused, equals: field)
            .submitLabel(.done)
            .onSubmit(commit)
            .accessibilityLabel("\(label), minutes and seconds")
    }

    private func showCurrent() {
        start = Self.clock(shownStart)
        end = Self.clock(shownEnd)
    }

    private func reset() {
        store.introOverrides[showKey] = nil
        showCurrent()
        onChange()
    }

    private func commit() {
        guard !isInvalid, let s = parsed.start, let e = parsed.end else { return }
        // Unchanged from what's shown: nothing to save.
        if s.rounded() == shownStart.rounded() && e.rounded() == shownEnd.rounded() { showCurrent(); return }
        if isZero { reset(); return }
        store.introOverrides[showKey] = IntroOverride(title: title, start: s, end: e)
        showCurrent()
        onChange()
    }
}
