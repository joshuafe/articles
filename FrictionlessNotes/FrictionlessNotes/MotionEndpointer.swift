//
//  MotionEndpointer.swift
//  FrictionlessNotes
//
//  Stop is a physical signal, driven by device POSE — independent of what the
//  mic hears (a pocket isn't acoustically silent, so VAD must not gate the
//  stop). Three "you put it away" signals:
//    • face-down            — gravity points out the screen
//    • pocket               — proximity sensor covered
//    • lowered & still       — steep angle held stationary (at your side / set down)
//  Plus an absolute silence cap. Simulator has no motion/proximity — the debug
//  bar remains the fallback there.
//

import CoreMotion
import UIKit

@MainActor
final class MotionEndpointer {

    var onSignal: ((EndpointSignal) -> Void)?

    /// Retained for source compatibility with the store; no longer gates stops.
    var isVadSilent: () -> Bool = { true }

    private let motion = CMMotionManager()
    private var faceDownSince: Date?
    private var loweredStillSince: Date?
    private var proximitySince: Date?
    private var silenceStarted: Date?
    private var stopped = false

    // Tunables — adjust if it stops too eagerly or not eagerly enough.
    private let faceDownHold: TimeInterval = 0.7      // screen-down this long → stop
    private let loweredStillHold: TimeInterval = 1.4  // steep + still this long → stop
    private let pocketHold: TimeInterval = 0.9        // proximity covered this long → stop
    private let silenceCap: TimeInterval = 90         // hard ceiling on one capture
    private let steepThreshold = 0.78                 // |gravity| on x or y axis
    private let faceDownThreshold = 0.75              // gravity.z (screen toward ground)
    private let stillThreshold = 0.06                 // userAcceleration magnitude

    func begin() {
        faceDownSince = nil
        loweredStillSince = nil
        proximitySince = nil
        silenceStarted = nil
        stopped = false

        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 0.1
            motion.startDeviceMotionUpdates(to: .main) { dm, _ in
                guard let dm else { return }
                MainActor.assumeIsolated { [weak self] in
                    self?.evaluate(dm)
                }
            }
        }

        UIDevice.current.isProximityMonitoringEnabled = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(proximityChanged),
            name: UIDevice.proximityStateDidChangeNotification, object: nil)
    }

    func end() {
        motion.stopDeviceMotionUpdates()
        UIDevice.current.isProximityMonitoringEnabled = false
        NotificationCenter.default.removeObserver(self)
        faceDownSince = nil
        loweredStillSince = nil
        proximitySince = nil
        silenceStarted = nil
    }

    func noteSilence(_ silent: Bool) {
        if silent {
            if silenceStarted == nil { silenceStarted = .now }
            else if Date.now.timeIntervalSince(silenceStarted!) > silenceCap {
                fire(.silenceCapped)
            }
        } else {
            silenceStarted = nil
        }
    }

    private func fire(_ signal: EndpointSignal) {
        guard !stopped else { return }
        stopped = true
        onSignal?(signal)
    }

    private func evaluate(_ dm: CMDeviceMotion) {
        guard !stopped else { return }
        let g = dm.gravity
        let now = Date.now

        // Face-down: screen pointing at the ground.
        if g.z > faceDownThreshold {
            if faceDownSince == nil { faceDownSince = now }
            else if now.timeIntervalSince(faceDownSince!) > faceDownHold {
                fire(.disposalDetected); return
            }
        } else {
            faceDownSince = nil
        }

        // Lowered to a steep angle (pocket / at your side / propped) AND held still.
        let steep = abs(g.x) > steepThreshold || abs(g.y) > steepThreshold
        let a = dm.userAcceleration
        let still = sqrt(a.x*a.x + a.y*a.y + a.z*a.z) < stillThreshold
        if steep && still {
            if loweredStillSince == nil { loweredStillSince = now }
            else if now.timeIntervalSince(loweredStillSince!) > loweredStillHold {
                fire(.disposalDetected); return
            }
        } else {
            loweredStillSince = nil
        }
    }

    @objc private func proximityChanged() {
        if UIDevice.current.proximityState {
            proximitySince = .now
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(self?.pocketHold ?? 0.9))
                guard let self, self.proximitySince != nil,
                      UIDevice.current.proximityState else { return }
                self.fire(.pocketed)
            }
        } else {
            proximitySince = nil
        }
    }
}
