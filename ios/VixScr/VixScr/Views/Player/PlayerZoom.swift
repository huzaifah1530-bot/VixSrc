import SwiftUI
import UIKit
import AVFoundation
import Observation

/// Pinch-zoom state the player keeps between items and launches.
struct PlayerZoomState: Codable, Equatable {
    var scale: CGFloat = 1
    /// Pan as a fraction of the canvas size, so it survives rotation.
    var panX: CGFloat = 0
    var panY: CGFloat = 0
    /// Snapped to "fill". The scale is recomputed for each aspect ratio and
    /// screen size instead of reusing the stored number.
    var filled = false

    static let storageKey = "vela_player_zoom"

    static func load() -> PlayerZoomState {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let state = try? JSONDecoder().decode(PlayerZoomState.self, from: data) else { return PlayerZoomState() }
        return state
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

/// One update from the window-level pinch recognizer.
struct PlayerPinchEvent {
    var state: UIGestureRecognizer.State
    /// Scale change since the previous event (the recognizer is reset to 1
    /// after each report), so re-anchoring never jumps.
    var scaleDelta: CGFloat
    /// Centroid of the touches in the player canvas' coordinates.
    var location: CGPoint
    var size: CGSize
    var touches: Int
}

/// Geometry for zooming an aspect-fit picture with `scaleEffect` + `offset`
/// applied around the canvas center.
enum PlayerZoomMath {
    static let minScale: CGFloat = 0.5
    static let maxScale: CGFloat = 3
    /// How far past the upper limit the fingers may stretch the raw scale.
    static let overshoot: CGFloat = 0.6
    /// Rubber-band factor applied to scale beyond the upper limit.
    static let resistance: CGFloat = 0.45
    /// Release within ±7% of 1× or of the fill scale snaps to it.
    static let snapTolerance: CGFloat = 0.07

    /// Size of the aspect-fit picture inside the canvas. Unknown video sizes
    /// are treated as matching the canvas.
    static func fittedSize(video: CGSize, canvas: CGSize) -> CGSize {
        guard video.width > 0, video.height > 0, canvas.width > 0, canvas.height > 0 else { return canvas }
        let ratio = min(canvas.width / video.width, canvas.height / video.height)
        return CGSize(width: video.width * ratio, height: video.height * ratio)
    }

    /// Scale at which the aspect-fit picture covers the whole canvas.
    static func fillScale(video: CGSize, canvas: CGSize) -> CGFloat {
        let fitted = fittedSize(video: video, canvas: canvas)
        guard fitted.width > 0, fitted.height > 0 else { return 1 }
        return max(1, max(canvas.width / fitted.width, canvas.height / fitted.height))
    }

    /// 3×, or the fill scale when an unusually wide picture needs more.
    static func upperLimit(fill: CGFloat) -> CGFloat { max(maxScale, fill) }

    static func clampRaw(_ raw: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(raw, minScale), upper + overshoot)
    }

    /// Scale shown on screen for a raw finger scale, with resistance above
    /// the upper limit.
    static func displayed(raw: CGFloat, upper: CGFloat) -> CGFloat {
        let value = max(minScale, raw)
        return value > upper ? upper + (value - upper) * resistance : value
    }

    /// Keeps the picture covering the canvas along any axis where it is
    /// larger than the canvas, and centered along any axis where it is not.
    static func clampedOffset(_ offset: CGSize, scale: CGFloat, video: CGSize, canvas: CGSize) -> CGSize {
        let fitted = fittedSize(video: video, canvas: canvas)
        func axis(_ value: CGFloat, content: CGFloat, view: CGFloat) -> CGFloat {
            let slack = (content - view) / 2
            guard slack > 0.5 else { return 0 }
            return min(max(value, -slack), slack)
        }
        return CGSize(width: axis(offset.width, content: fitted.width * scale, view: canvas.width),
                      height: axis(offset.height, content: fitted.height * scale, view: canvas.height))
    }
}

/// Live zoom for one player surface. Kept in its own observable object so a
/// pinch only redraws the video layer and the zoom badge: redrawing the whole
/// player on every finger movement made pinching feel laggy.
@MainActor
@Observable
final class PlayerZoomModel {
    /// What is shown, with rubber-banding past the upper limit.
    private(set) var scale: CGFloat = 1
    private(set) var offset: CGSize = .zero
    private(set) var filled = false
    private(set) var badge: String?

    @ObservationIgnored private var raw: CGFloat = 1
    @ObservationIgnored private(set) var isPinching = false
    @ObservationIgnored private var anchor: CGPoint?
    @ObservationIgnored private var touches = 0
    @ObservationIgnored private var badgeTask: Task<Void, Never>?
    @ObservationIgnored var canvasSize: CGSize = .zero
    @ObservationIgnored private(set) var videoSize: CGSize = .zero

    private let spring = Animation.spring(response: 0.38, dampingFraction: 0.84)

    var fillScale: CGFloat { PlayerZoomMath.fillScale(video: videoSize, canvas: canvasSize) }

    func handlePinch(_ event: PlayerPinchEvent) {
        switch event.state {
        case .began:
            isPinching = true
            raw = scale
            anchor = event.location
            touches = event.touches
            showBadge(Self.label(scale), autoHide: false)
        case .changed:
            guard isPinching else { return }
            let canvas = event.size.width > 0 ? event.size : canvasSize
            let upper = PlayerZoomMath.upperLimit(fill: PlayerZoomMath.fillScale(video: videoSize, canvas: canvas))
            let oldScale = max(scale, PlayerZoomMath.minScale)
            raw = PlayerZoomMath.clampRaw(raw * event.scaleDelta, upper: upper)
            let newScale = PlayerZoomMath.displayed(raw: raw, upper: upper)
            // A finger lifting or landing moves the centroid; re-anchor
            // instead of treating that jump as a pan.
            let previous = event.touches == touches ? (anchor ?? event.location) : event.location
            let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            // The content point under the previous centroid stays under the
            // current one, which also pans with two fingers.
            let contentX = (previous.x - center.x - offset.width) / oldScale
            let contentY = (previous.y - center.y - offset.height) / oldScale
            let proposed = CGSize(width: event.location.x - center.x - newScale * contentX,
                                  height: event.location.y - center.y - newScale * contentY)
            scale = newScale
            offset = PlayerZoomMath.clampedOffset(proposed, scale: newScale, video: videoSize, canvas: canvas)
            filled = false
            anchor = event.location
            touches = event.touches
            showBadge(Self.label(newScale), autoHide: false)
        case .ended, .cancelled, .failed:
            guard isPinching else { return }
            isPinching = false
            anchor = nil
            settle()
        default:
            break
        }
    }

    /// Release: spring into range, or snap to fill / the original frame.
    private func settle() {
        let fill = fillScale
        let upper = PlayerZoomMath.upperLimit(fill: fill)
        let shown = scale
        let tolerance = PlayerZoomMath.snapTolerance
        let canFill = fill > 1.01
        let nearFill = canFill && abs(shown - fill) <= fill * tolerance
        let nearOne = abs(shown - 1) <= tolerance

        var target = shown
        var isFilled = false
        var text = Self.label(shown)
        var snapped = false
        if shown < 1 {
            target = 1
            text = "Original"
        } else if shown > upper {
            target = upper
            isFilled = canFill && abs(upper - fill) < 0.001
            text = isFilled ? "Zoomed to fill" : Self.label(upper)
        } else if nearFill && (!nearOne || abs(shown - fill) < abs(shown - 1)) {
            target = fill
            isFilled = true
            text = "Zoomed to fill"
            snapped = true
        } else if nearOne {
            target = 1
            text = "Original"
            snapped = true
        }

        // Scaling about the center keeps the same spot in view.
        let ratio = shown > 0 ? target / shown : 1
        let newOffset = PlayerZoomMath.clampedOffset(
            CGSize(width: offset.width * ratio, height: offset.height * ratio),
            scale: target, video: videoSize, canvas: canvasSize)
        withAnimation(spring) {
            scale = target
            offset = newOffset
            filled = isFilled
        }
        raw = target
        if snapped { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        showBadge(text)
        save()
    }

    /// Settings › Zoom to Fill.
    func setFill(_ on: Bool) {
        guard on != filled || (on && abs(scale - fillScale) > 0.001) else { return }
        let target: CGFloat = on ? fillScale : 1
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            scale = target
            offset = .zero
            filled = on
        }
        raw = target
        showBadge(on ? "Zoomed to fill" : "Original")
        save()
    }

    /// Re-fits the stored zoom to the current canvas and picture (new item,
    /// rotation, inline ↔ fullscreen). A filled zoom is recomputed, since
    /// the fill scale depends on both sizes.
    func reapply() {
        guard !isPinching else { return }
        let state = PlayerZoomState.load()
        let fill = fillScale
        let upper = PlayerZoomMath.upperLimit(fill: fill)
        let newScale = state.filled ? fill : min(max(state.scale, 1), upper)
        let pan = CGSize(width: state.panX * canvasSize.width, height: state.panY * canvasSize.height)
        scale = newScale
        raw = newScale
        filled = state.filled
        offset = PlayerZoomMath.clampedOffset(pan, scale: newScale, video: videoSize, canvas: canvasSize)
    }

    /// A pinch cut short by the view going away.
    func cancelPinch() {
        guard isPinching else { return }
        isPinching = false
        anchor = nil
        reapply()
    }

    private func save() {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        PlayerZoomState(scale: scale,
                        panX: offset.width / canvasSize.width,
                        panY: offset.height / canvasSize.height,
                        filled: filled).save()
    }

    private static func label(_ scale: CGFloat) -> String {
        String(format: "%.1f×", Double(scale))
    }

    private func showBadge(_ text: String, autoHide: Bool = true) {
        badgeTask?.cancel()
        if badge == nil {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) { badge = text }
        } else if badge != text {
            // Live pinch updates change every frame; only snaps animate.
            if autoHide {
                withAnimation(.snappy(duration: 0.2)) { badge = text }
            } else {
                badge = text
            }
        }
        guard autoHide else { return }
        badgeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { self.badge = nil }
        }
    }

    func stop() {
        badgeTask?.cancel()
        cancelPinch()
    }

    /// Polls the item's presentation size on the main actor. KVO on the
    /// player item could call back off the main thread.
    func watchVideoSize(of manager: VideoPlayerManager) async {
        var lastItem: ObjectIdentifier?
        var first = true
        while !Task.isCancelled {
            let item = manager.player?.currentItem
            let id = item.map { ObjectIdentifier($0) }
            let size = item?.presentationSize ?? .zero
            if first || id != lastItem {
                // New item: reapply where the viewer left the zoom.
                first = false
                lastItem = id
                videoSize = size
                reapply()
            } else if size.width > 0, size.height > 0, size != videoSize {
                videoSize = size
                reapply()
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }
}

/// The video layer with the live zoom applied. Its own view, so only it
/// redraws while pinching.
struct ZoomedVideoLayer: View {
    let zoom: PlayerZoomModel
    let player: AVPlayer?
    let isFullscreen: Bool
    let manager: VideoPlayerManager

    var body: some View {
        VideoPlayerLayer(player: player, isFullscreen: isFullscreen, manager: manager)
            .scaleEffect(zoom.scale, anchor: .center)
            .offset(zoom.offset)
            .allowsHitTesting(false)
    }
}

/// "1.6×" / "Zoomed to fill" / "Original", in the 2× badge's style.
struct ZoomBadge: View {
    let zoom: PlayerZoomModel

    var body: some View {
        if let badge = zoom.badge {
            Text(badge)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .contentTransition(.numericText())
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .vixGlass(.strong, cornerRadius: 999)
                .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.8)))
                .accessibilityLabel("Zoom \(badge)")
        }
    }
}
