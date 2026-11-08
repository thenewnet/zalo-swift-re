import AVFoundation
import UIKit

/// Keeps the app (and so every account's WebSocket) running in the background by playing silence.
///
/// iOS suspends an app a few seconds after it leaves the screen, which would stop Zalo Web in every account
/// and with it all notifications. This option is opt-in because it costs battery. It's meant for a
/// personally sideloaded build; the App Store would not accept it.
@MainActor
final class BackgroundKeepAlive {
    static let shared = BackgroundKeepAlive()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var running = false
    private var graceTask: UIBackgroundTaskIdentifier = .invalid

    private init() {
        engine.attach(player)
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                               queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            if type == .ended {
                MainActor.assumeIsolated { self?.restartIfNeeded() }
            }
        }
    }

    func start() {
        guard !running else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let format = engine.mainMixerNode.outputFormat(forBus: 0)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) else { return }
            buffer.frameLength = buffer.frameCapacity // zero-filled: silence
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            running = true
        } catch {
            running = false
        }
    }

    func stop() {
        guard running else { return }
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        running = false
    }

    private func restartIfNeeded() {
        guard running else { return }
        running = false
        start()
    }

    /// Without keep-alive, ask iOS for the usual short grace period so pending messages still arrive.
    func beginGracePeriod() {
        guard graceTask == .invalid else { return }
        graceTask = UIApplication.shared.beginBackgroundTask(withName: "zmulti.grace") { [weak self] in
            MainActor.assumeIsolated { self?.endGracePeriod() }
        }
    }

    func endGracePeriod() {
        guard graceTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(graceTask)
        graceTask = .invalid
    }
}
