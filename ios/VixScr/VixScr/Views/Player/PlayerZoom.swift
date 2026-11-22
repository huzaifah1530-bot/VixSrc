import SwiftUI
import UIKit

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
