import SwiftUI
import Observation

/// App-wide status pill for work the user asked for (Sync Now, refreshes).
/// Background work never calls this, so the pill only appears when someone
/// is waiting on the result.
@MainActor @Observable
final class StatusPillCenter {
    static let shared = StatusPillCenter()

    enum Phase: Equatable { case busy, success, failure }

    struct Pill: Identifiable, Equatable {
        let id: UUID
        var text: String
        var phase: Phase
    }

    private(set) var pill: Pill?
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    /// A busy pill hides on its own after this long, so a caller that never
    /// finishes (or a request that hangs) can't leave it on screen.
    private static let busyTimeout: Double = 20

    private init() {}

    /// Shows a busy pill and returns the id to pass to `finish`. A newer pill
    /// replaces an older one in place; the older id's `finish` is then ignored.
    @discardableResult
    func begin(_ text: String) -> UUID {
        let id = UUID()
        pill = Pill(id: id, text: text, phase: .busy)
        scheduleHide(id, after: Self.busyTimeout)
        return id
    }

    func finish(_ id: UUID, success: Bool, text: String) {
        guard pill?.id == id else { return }
        pill = Pill(id: id, text: text, phase: success ? .success : .failure)
        // Failures stay longer so the reason can actually be read.
        scheduleHide(id, after: success ? 1.4 : 3)
    }

    private func scheduleHide(_ id: UUID, after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.pill?.id == id else { return }
            self.pill = nil
        }
    }
}

extension View {
    /// Overlays the shared status pill at the top of this view, just below
    /// the status bar / Dynamic Island. Attach once, near the root.
    @MainActor
    func statusPillHost() -> some View {
        overlay(alignment: .top) {
            StatusPillOverlay()
        }
    }
}

private struct StatusPillOverlay: View {
    private var center: StatusPillCenter { .shared }

    var body: some View {
        ZStack(alignment: .top) {
            if let pill = center.pill {
                StatusPillView(pill: pill)
                    .padding(.top, 6)
                    .padding(.horizontal, 24)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: center.pill)
        // Purely informational: taps go straight through to the app.
        .allowsHitTesting(false)
    }
}

private struct StatusPillView: View {
    let pill: StatusPillCenter.Pill

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                if pill.phase == .busy {
                    ProgressView()
                        .controlSize(.small)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                } else {
                    Image(systemName: pill.phase == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(pill.phase == .success ? Color.green : Color.yellow)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: pill.phase)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .frame(width: 18, height: 18)

            Text(pill.text)
                .font(.subheadline.weight(.bold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .contentTransition(.opacity)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .vixGlass(.strong, cornerRadius: 999)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
