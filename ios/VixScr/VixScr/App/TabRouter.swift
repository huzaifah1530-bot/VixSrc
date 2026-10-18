import Foundation
import Observation

/// The app's top-level destinations, one per native tab.
enum AppTab: Hashable {
    case home
    case anime
    case favorites
    case settings
}

/// Lets any view request a tab switch without threading a closure through
/// every intermediate view. Tapping the already-active Home tab fires
/// `.velaClearSearch` — the standard Apple "re-tap to return to root" pattern.
@Observable
final class TabRouter {
    @ObservationIgnored private var _selection: AppTab = .home

    var selection: AppTab {
        get {
            access(keyPath: \.selection)
            return _selection
        }
        set {
            let old = _selection
            withMutation(keyPath: \.selection) {
                _selection = newValue
            }
            // Re-tapping the active Home tab = clear search / go to root.
            if newValue == .home, old == .home {
                NotificationCenter.default.post(name: .velaClearSearch, object: nil)
            }
            if newValue == .anime, old == .anime {
                NotificationCenter.default.post(name: .velaClearAnimeSearch, object: nil)
            }
        }
    }
}

extension Notification.Name {
    static let velaClearSearch = Notification.Name("vela.clearSearch")
    static let velaClearAnimeSearch = Notification.Name("vela.clearAnimeSearch")
}
