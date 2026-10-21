import SwiftUI

/// Per-show custom intro: start / end boxes under Reload and Save. They
/// replace TheIntroDB / AniSkip times for every episode. Both 00:00 = off.
/// Same rules as desktop components/IntroTimes.tsx.
struct IntroTimesTable: View {
    let showKey: String
    let title: String
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

    private var parsed: (start: Double?, end: Double?) { (Self.parse(start), Self.parse(end)) }
    private var isOff: Bool { parsed.start == 0 && parsed.end == 0 }
    private var isInvalid: Bool {
        guard let s = parsed.start, let e = parsed.end else { return true }
        return !isOff && e <= s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Intro start").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("Intro end").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                GridRow {
                    timeField("Intro start", text: $start, field: .start)
                    timeField("Intro end", text: $end, field: .end)
                }
            }
            Text(isInvalid
                 ? "Use mm:ss, with the end after the start."
                 : isOff ? "Off: using TheIntroDB / AniSkip times when they exist. Both 00:00 = off."
                         : "Skip Intro uses these times for every episode of this show.")
                .font(.caption)
                .foregroundStyle(isInvalid ? Color.red : Color.secondary)
        }
        .padding(14)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear(perform: loadSaved)
        .onChange(of: showKey) { _, _ in loadSaved() }
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

    private func loadSaved() {
        let o = store.introOverrides[showKey]
        start = Self.clock(o?.start)
        end = Self.clock(o?.end)
    }

    private func commit() {
        guard !isInvalid, let s = parsed.start, let e = parsed.end else { return }
        if isOff {
            store.introOverrides[showKey] = nil
        } else {
            store.introOverrides[showKey] = IntroOverride(title: title, start: s, end: e)
        }
        start = Self.clock(s)
        end = Self.clock(e)
        onChange()
    }
}
