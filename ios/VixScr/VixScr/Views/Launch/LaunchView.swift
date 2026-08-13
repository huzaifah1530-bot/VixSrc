import SwiftUI

/// Cold-start splash: just a plain black screen that fades out once the
/// real UI is ready. No spinner, no logo, no text — the app fades in from
/// black naturally, matching the system launch screen colour.
/// Only shown on cold start (new process); background→foreground resumes
/// skip this entirely via the process-lifetime flag in VelaApp.
struct LaunchView: View {
    var body: some View {
        Color.black.ignoresSafeArea()
    }
}
