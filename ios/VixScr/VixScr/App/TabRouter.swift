import Observation

/// The app's top-level destinations, one per native tab.
enum AppTab: Hashable {
    case home
    case favorites
    case settings
}

/// Lets any view request a tab switch (e.g. the "Add TMDB Key" button deep
/// inside `HeroView` needs to jump to the Settings tab) without threading a
/// closure through every intermediate view.
@Observable
final class TabRouter {
    var selection: AppTab = .home
}
