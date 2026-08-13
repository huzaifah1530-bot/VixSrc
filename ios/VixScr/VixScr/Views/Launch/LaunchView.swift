import SwiftUI

/// Mirrors `loading.html` — a brief branded splash shown while the real UI
/// spins up, so the app never shows a blank frame on launch.
struct LaunchView: View {
    var body: some View {
        ZStack {
            VixTheme.backgroundGradient.ignoresSafeArea()

            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(.white)
                    Image(systemName: "play.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.black)
                }
                .frame(width: 72, height: 72)
                .shadow(color: .white.opacity(0.18), radius: 38)

                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.1)

                VStack(spacing: 6) {
                    Text("Starting VixScr")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(.white)
                    Text("Loading your catalogue...")
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }
}
