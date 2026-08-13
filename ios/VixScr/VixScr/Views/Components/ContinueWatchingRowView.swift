import SwiftUI

/// The "Continue watching" shelf with an Apple-quality reorder animation.
///
/// When the user taps a card:
///   1. The card lifts (scale 1.04) instantly — a tactile "pick up" signal.
///   2. A spring animation reorders the array, moving the tapped card to
///      position 0. SwiftUI's layout engine translates each card to its new
///      position simultaneously.
///   3. `matchedGeometryEffect` interpolates every card's frame through the
///      spring so the tapped card visibly sweeps over the others rather than
///      teleporting. Other cards glide right to make room.
///   4. After the spring settles, the lift releases and `onSelect` opens the
///      player — so the completed reorder is visible before the sheet appears.
///
/// The spring (response 0.52, damping 0.74) matches the feel of Apple's own
/// "Up Next" row in the TV app — snappy, confident, no bounciness.
struct ContinueWatchingRowView: View {
    let title: String
    let subtitle: String
    /// The authoritative sorted list from AppStore. Changes here (e.g. a new
    /// item added from another tab) are synced into local `displayItems` while
    /// preserving any in-flight reorder animation.
    let sourceItems: [MediaItem]
    let store: AppStore
    let onSelect: (MediaItem) -> Void

    /// Local copy — reordered immediately on tap so the animation fires
    /// without waiting for AppStore to write-back.
    @State private var displayItems: [MediaItem] = []
    /// Id of the card currently "in flight" (drives the lift scale effect).
    @State private var liftedId: String? = nil
    /// Shared namespace for matchedGeometryEffect across all cards in this row.
    @Namespace private var cardSpace

    private let reorderSpring = Animation.spring(response: 0.52, dampingFraction: 0.74)
    /// Card width mirrors PosterCard's sizing logic.
    private var cardHeight: CGFloat {
        let width: CGFloat = store.cardSize == .compact ? 124 : 154
        return width * 1.5
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Row header — identical to MediaRowView
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(displayItems) { item in
                        PosterCard(
                            item: item,
                            isFavorite: store.isFavorite(item),
                            compact: store.cardSize == .compact,
                            onTap: { handleTap(item) }
                        )
                        // matchedGeometryEffect binds each card to its
                        // stable id in cardSpace. When displayItems reorders,
                        // SwiftUI interpolates every card's frame through the
                        // spring — the tapped card sweeps to position 0 while
                        // the others shift right in the same animation block.
                        .matchedGeometryEffect(id: item.id, in: cardSpace)
                        // Lift: selected card scales up before reorder fires.
                        .scaleEffect(liftedId == item.id ? 1.04 : 1.0)
                        // Ensure the in-flight card renders above its neighbours.
                        .zIndex(liftedId == item.id ? 1 : 0)
                        // Animate the scale change with the same spring so
                        // it settles together with the positional move.
                        .animation(reorderSpring, value: liftedId)
                    }
                }
                .padding(.horizontal, 20)
                // Fixed minimum height prevents the row from collapsing
                // during the geometry transition.
                .frame(minHeight: cardHeight + 16)
            }
        }
        .onAppear {
            displayItems = sourceItems
        }
        // Sync with external changes (new item opened from Favourites tab,
        // deep link, etc.). We only replace displayItems when the set of ids
        // changes — a pure tap-driven reorder is handled locally and must
        // not be clobbered while the animation is still in flight.
        .onChange(of: sourceItems) { _, newItems in
            let newIds = newItems.map(\.id)
            let currentIds = displayItems.map(\.id)
            guard newIds != currentIds else { return }
            withAnimation(reorderSpring) {
                displayItems = newItems
            }
        }
    }

    // MARK: - Tap handler

    private func handleTap(_ item: MediaItem) {
        guard displayItems.first?.id != item.id else {
            // Already #1 — open the player immediately.
            onSelect(item)
            return
        }

        // Phase 1 — instant lift pop (no animation delay).
        liftedId = item.id

        // Phase 2 — spring reorder. matchedGeometryEffect interpolates
        // each card's frame through this same spring, producing the "fly
        // over everything" arc automatically.
        withAnimation(reorderSpring) {
            guard let idx = displayItems.firstIndex(where: { $0.id == item.id }) else { return }
            displayItems.move(fromOffsets: IndexSet(integer: idx), toOffset: 0)
        }

        // Phase 3 — release lift + open player once the spring has settled.
        // Delay ≈ response × 1.15 gives the animation time to complete.
        let settleDuration = 0.52 * 1.15
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(settleDuration * 1_000_000_000))
            withAnimation(.easeOut(duration: 0.15)) {
                liftedId = nil
            }
            onSelect(item)
        }
    }
}
