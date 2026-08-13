import SwiftUI

/// All / Movies / TV / Favourites filter, using the native segmented
/// `Picker` style (the same control iOS uses in Photos, Mail's mailbox
/// filters, etc.) instead of custom capsule chips.
struct FilterBar: View {
    @Binding var selected: AppStore.ContentFilter

    var body: some View {
        Picker("Filter", selection: $selected) {
            Text("All").tag(AppStore.ContentFilter.all)
            Text("Movies").tag(AppStore.ContentFilter.movie)
            Text("TV").tag(AppStore.ContentFilter.tv)
            Text("Favourites").tag(AppStore.ContentFilter.favorites)
        }
        .pickerStyle(.segmented)
    }
}
