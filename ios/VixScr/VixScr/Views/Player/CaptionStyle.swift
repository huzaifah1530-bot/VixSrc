import SwiftUI

// Vela's own caption appearance, edited in the player's Settings panel and
// in Settings › Playback › Caption Style. Applies to every caption Vela
// draws (stream tracks, side-loaded and auto-generated).

enum CaptionTextColor: String, CaseIterable, Identifiable {
    case white, yellow, cyan, green, magenta
    static let storageKey = "vela_caption_color"
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .white: return .white
        case .yellow: return Color(red: 1, green: 0.9, blue: 0.2)
        case .cyan: return Color(red: 0.35, green: 0.9, blue: 1)
        case .green: return Color(red: 0.4, green: 0.95, blue: 0.45)
        case .magenta: return Color(red: 1, green: 0.45, blue: 0.9)
        }
    }
}

enum CaptionBackground: String, CaseIterable, Identifiable {
    case none, light, dark, solid
    static let storageKey = "vela_caption_background"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "None"
        case .light: return "Light"
        case .dark: return "Dark"
        case .solid: return "Solid"
        }
    }
    var opacity: Double {
        switch self {
        case .none: return 0
        case .light: return 0.35
        case .dark: return 0.7
        case .solid: return 1
        }
    }
}

enum CaptionFont: String, CaseIterable, Identifiable {
    case standard, rounded, serif, mono
    static let storageKey = "vela_caption_font"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .standard: return "Default"
        case .rounded: return "Rounded"
        case .serif: return "Serif"
        case .mono: return "Mono"
        }
    }
    var design: Font.Design {
        switch self {
        case .standard: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        case .mono: return .monospaced
        }
    }
}

enum CaptionEdge: String, CaseIterable, Identifiable {
    case shadow, outline, none
    static let storageKey = "vela_caption_edge"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .shadow: return "Shadow"
        case .outline: return "Outline"
        case .none: return "None"
        }
    }
}

enum CaptionWeight {
    static let storageKey = "vela_caption_bold"
}

/// One caption line in the current style. Used by the player and previews.
struct StyledCaptionText: View {
    let text: String
    /// Base point size before the Caption Size setting.
    var baseSize: CGFloat = 16

    @AppStorage(CaptionSize.storageKey) private var scale = CaptionSize.medium.rawValue
    @AppStorage(CaptionTextColor.storageKey) private var color = CaptionTextColor.white
    @AppStorage(CaptionBackground.storageKey) private var background = CaptionBackground.light
    @AppStorage(CaptionFont.storageKey) private var font = CaptionFont.standard
    @AppStorage(CaptionEdge.storageKey) private var edge = CaptionEdge.shadow
    @AppStorage(CaptionWeight.storageKey) private var bold = true

    var body: some View {
        Text(text)
            .font(.system(size: baseSize * CGFloat(scale), weight: bold ? .semibold : .regular, design: font.design))
            .foregroundStyle(color.color)
            .multilineTextAlignment(.center)
            .modifier(CaptionEdgeModifier(edge: edge))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.black.opacity(background.opacity), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct CaptionEdgeModifier: ViewModifier {
    let edge: CaptionEdge

    @ViewBuilder
    func body(content: Content) -> some View {
        switch edge {
        case .none:
            content
        case .shadow:
            content
                .shadow(color: .black, radius: 2)
                .shadow(color: .black.opacity(0.8), radius: 4)
        case .outline:
            content
                .shadow(color: .black, radius: 0.6)
                .shadow(color: .black, radius: 0.6)
                .shadow(color: .black, radius: 0.6)
        }
    }
}

/// Preview + choices, as chips. Lives inside the player's Settings panel.
struct CaptionStyleEditor: View {
    @AppStorage(CaptionSize.storageKey) private var scale = CaptionSize.medium.rawValue
    @AppStorage(CaptionTextColor.storageKey) private var color = CaptionTextColor.white
    @AppStorage(CaptionBackground.storageKey) private var background = CaptionBackground.light
    @AppStorage(CaptionFont.storageKey) private var font = CaptionFont.standard
    @AppStorage(CaptionEdge.storageKey) private var edge = CaptionEdge.shadow
    @AppStorage(CaptionWeight.storageKey) private var bold = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CaptionPreview()

            chipRow("Size", options: CaptionSize.allCases, selection: $scale, value: { $0.rawValue }) { Text($0.label) }
            colorRow
            chipRow("Background", options: CaptionBackground.allCases, selection: $background, value: { $0 }) { Text($0.label) }
            chipRow("Font", options: CaptionFont.allCases, selection: $font, value: { $0 }) {
                Text($0.label).font(.system(.footnote, design: $0.design).weight(.semibold))
            }
            chipRow("Edge", options: CaptionEdge.allCases, selection: $edge, value: { $0 }) { Text($0.label) }

            Toggle(isOn: $bold.animation(.snappy)) {
                Text("Bold").font(.subheadline.weight(.semibold))
            }
            .tint(.white.opacity(0.85))

            Button("Reset to Default") {
                withAnimation(.snappy) {
                    scale = CaptionSize.medium.rawValue
                    color = .white
                    background = .light
                    font = .standard
                    edge = .shadow
                    bold = true
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.8))
        }
        .foregroundStyle(.white)
    }

    private var colorRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Text Colour").font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
            HStack(spacing: 12) {
                ForEach(CaptionTextColor.allCases) { option in
                    Button {
                        withAnimation(.snappy) { color = option }
                    } label: {
                        Circle()
                            .fill(option.color)
                            .frame(width: 28, height: 28)
                            .overlay(Circle().stroke(.white, lineWidth: color == option ? 2.5 : 0).padding(-4))
                            .frame(width: 40, height: 40)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.label)
                    .accessibilityAddTraits(color == option ? .isSelected : [])
                }
            }
        }
    }

    private func chipRow<Option: Identifiable, Value: Equatable, RowLabel: View>(
        _ title: String, options: [Option], selection: Binding<Value>, value: @escaping (Option) -> Value,
        @ViewBuilder label: @escaping (Option) -> RowLabel
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(options) { option in
                        let selected = selection.wrappedValue == value(option)
                        Button {
                            withAnimation(.snappy) { selection.wrappedValue = value(option) }
                        } label: {
                            label(option)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(selected ? .black : .white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(selected ? Color.white : Color.white.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
        }
    }
}

/// A sample caption over a dark gradient, so changes show immediately.
struct CaptionPreview: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.28), Color(white: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
            StyledCaptionText(text: "This is how captions will look.", baseSize: 15)
                .padding(.horizontal, 12)
        }
        .frame(height: 92)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Settings › Playback › Caption Style.
struct CaptionStyleSettingsView: View {
    @AppStorage(CaptionSize.storageKey) private var scale = CaptionSize.medium.rawValue
    @AppStorage(CaptionTextColor.storageKey) private var color = CaptionTextColor.white
    @AppStorage(CaptionBackground.storageKey) private var background = CaptionBackground.light
    @AppStorage(CaptionFont.storageKey) private var font = CaptionFont.standard
    @AppStorage(CaptionEdge.storageKey) private var edge = CaptionEdge.shadow
    @AppStorage(CaptionWeight.storageKey) private var bold = true

    var body: some View {
        Form {
            Section {
                CaptionPreview()
                    .listRowInsets(EdgeInsets())
            }
            Section {
                Picker("Size", selection: $scale) {
                    ForEach(CaptionSize.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Text Colour", selection: $color) {
                    ForEach(CaptionTextColor.allCases) { Text($0.label).tag($0) }
                }
                Picker("Background", selection: $background) {
                    ForEach(CaptionBackground.allCases) { Text($0.label).tag($0) }
                }
                Picker("Font", selection: $font) {
                    ForEach(CaptionFont.allCases) { Text($0.label).tag($0) }
                }
                Picker("Edge", selection: $edge) {
                    ForEach(CaptionEdge.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Bold", isOn: $bold)
            } footer: {
                Text("Applies to every caption Vela shows: the video's own tracks, side-loaded subtitles and auto-generated captions.")
            }
            Section {
                Button("Reset to Default") {
                    scale = CaptionSize.medium.rawValue
                    color = .white
                    background = .light
                    font = .standard
                    edge = .shadow
                    bold = true
                }
            }
        }
        .navigationTitle("Caption Style")
        .navigationBarTitleDisplayMode(.inline)
    }
}
