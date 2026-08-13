import SwiftUI

/// Mirrors `#filterBar` — All / Movies / TV / Favourites chip row.
struct FilterBar: View {
    @Binding var selected: AppStore.ContentFilter

    private let options: [(AppStore.ContentFilter, String)] = [
        (.all, "All"), (.movie, "Movies"), (.tv, "TV"), (.favorites, "Favourites")
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options, id: \.0) { option, label in
                    let isActive = selected == option
                    Button(label.uppercased()) { selected = option }
                        .font(.system(size: 11, weight: .black))
                        .tracking(1)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .foregroundStyle(isActive ? .black : .white)
                        .background(isActive ? Color.white : Color.white.opacity(0.1), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(isActive ? 0 : 0.2), lineWidth: 1))
                }
            }
        }
    }
}
