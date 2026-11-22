import UIKit

/// App-wide interface orientation mask. The player narrows it to force a
/// rotation, which works even with the device's rotation lock on, because
/// the request targets the interface rather than the device sensor.
@MainActor
enum OrientationLock {
    static var mask: UIInterfaceOrientationMask = .all

    /// Bumped by every request, so a delayed unlock can tell whether a newer
    /// request replaced the one that scheduled it.
    private static var generation = 0

    private static var activeScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    /// Whether the interface is currently portrait (or not yet known).
    static var isPortrait: Bool {
        guard let scene = activeScene else { return true }
        let orientation = scene.effectiveGeometry.interfaceOrientation
        return orientation == .unknown || orientation.isPortrait
    }

    /// Restricts the interface to `mask` and asks the scene to rotate there.
    static func rotate(to mask: UIInterfaceOrientationMask) {
        generation += 1
        self.mask = mask
        guard let scene = activeScene else { return }
        // No error handler: a closure formed here would be main-actor isolated
        // and UIKit gives no guarantee about the thread it reports errors on.
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask), errorHandler: nil)
        updateSupportedOrientations(in: scene)
    }

    /// Turns the interface one quarter further in the same direction on every
    /// call: portrait → landscape → upside down → other landscape → portrait.
    /// iPhones without a home button can't show upside down, so that step
    /// goes straight on to the other landscape.
    static func rotateStep(clockwise: Bool) {
        // Clockwise as the picture turns relative to the device.
        var order: [UIInterfaceOrientation] = [.portrait, .landscapeRight, .portraitUpsideDown, .landscapeLeft]
        if !clockwise { order.reverse() }
        let supportsUpsideDown = UIDevice.current.userInterfaceIdiom == .pad
        let current = activeScene?.effectiveGeometry.interfaceOrientation ?? .portrait
        var index = order.firstIndex(of: current) ?? order.firstIndex(of: .portrait) ?? 0
        repeat {
            index = (index + 1) % order.count
        } while order[index] == .portraitUpsideDown && !supportsUpsideDown
        rotate(to: mask(for: order[index]))
    }

    private static func mask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        switch orientation {
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        case .portraitUpsideDown: return .portraitUpsideDown
        default: return .portrait
        }
    }

    /// Returns to portrait, then lifts the restriction once the rotation has
    /// had time to run, so the rest of the app rotates freely again.
    static func rotateToPortraitThenUnlock() {
        rotate(to: .portrait)
        let request = generation
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard OrientationLock.generation == request else { return }
            OrientationLock.mask = .all
            if let scene = OrientationLock.activeScene { OrientationLock.updateSupportedOrientations(in: scene) }
        }
    }

    /// The fullscreen player is presented modally, so every controller in the
    /// presentation chain re-reads its supported orientations.
    private static func updateSupportedOrientations(in scene: UIWindowScene) {
        var controller = scene.keyWindow?.rootViewController
        while let current = controller {
            current.setNeedsUpdateOfSupportedInterfaceOrientations()
            controller = current.presentedViewController
        }
    }
}

/// Supplies `OrientationLock.mask` to UIKit. Wire with
/// `@UIApplicationDelegateAdaptor(VelaAppDelegate.self)` on the App struct.
final class VelaAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        // UIKit calls this on the main thread.
        MainActor.assumeIsolated { OrientationLock.mask }
    }
}
