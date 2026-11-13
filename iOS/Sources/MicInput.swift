import AVFoundation
import Speech
import SwiftUI

/// Speech to text into the composer (Vietnamese by default, the phone's language otherwise).
@MainActor @Observable
final class SpeechDictation {
    private(set) var listening = false
    private(set) var error: String?
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?

    /// Starts listening; `onText` receives the whole transcript so far each time it changes.
    func start(onText: @escaping @MainActor (String) -> Void) async {
        error = nil
        guard await Self.authorize() else {
            error = "Hãy cho phép Olaz dùng Micro và Nhận dạng giọng nói trong Cài đặt."
            return
        }
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "vi-VN")) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            error = "Nhận dạng giọng nói đang không khả dụng."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker, .mixWithOthers])
            try session.setActive(true)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            let audio = AVAudioEngine()
            let input = audio.inputNode
            let format = input.outputFormat(forBus: 0)
            Self.feed(input, format: format, into: request)
            audio.prepare()
            try audio.start()
            self.engine = audio
            self.request = request
            listening = true
            task = Self.recognize(recognizer, request) { [weak self] text, done in
                Task { @MainActor in
                    if let text { onText(text) }
                    if done { self?.stop() }
                }
            }
        } catch {
            self.error = "Không mở được micro."
            stop()
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        request?.endAudio()
        task?.finish()
        engine = nil
        request = nil
        task = nil
        listening = false
    }

    // The audio tap and the recognizer call back on their own threads, so their closures are made outside the
    // main actor (a main-actor closure called there would trap).
    nonisolated private static func feed(_ input: AVAudioInputNode, format: AVAudioFormat,
                                         into request: SFSpeechAudioBufferRecognitionRequest) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
    }

    nonisolated private static func recognize(_ recognizer: SFSpeechRecognizer, _ request: SFSpeechAudioBufferRecognitionRequest,
                                              update: @escaping @Sendable (String?, Bool) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, failure in
            update(result?.bestTranscription.formattedString, failure != nil || result?.isFinal == true)
        }
    }

    nonisolated private static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}

/// Records a voice note (AAC .m4a) to send.
@MainActor @Observable
final class VoiceRecorder {
    private(set) var recording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var error: String?
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var timer: Timer?

    func start() async {
        error = nil
        guard await AVAudioApplication.requestRecordPermission() else {
            error = "Hãy cho phép Olaz dùng Micro trong Cài đặt."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .mixWithOthers])
            try session.setActive(true)
            let folder = Outbox.folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
                .replacingOccurrences(of: ":", with: "-")
            let url = folder.appendingPathComponent("Ghi am \(stamp).m4a")
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                                           AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.record() else { throw CocoaError(.fileWriteUnknown) }
            self.recorder = recorder
            recording = true
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.elapsed = self?.recorder?.currentTime ?? 0 }
            }
        } catch {
            self.error = "Không ghi âm được."
            cancel()
        }
    }

    /// Stops and returns the file (nil when shorter than a second).
    func finish() -> URL? {
        let url = recorder?.url
        let long = (recorder?.currentTime ?? 0) >= 1
        recorder?.stop()
        reset()
        return long ? url : nil
    }

    func cancel() {
        recorder?.stop()
        recorder?.deleteRecording()
        reset()
    }

    private func reset() {
        timer?.invalidate()
        timer = nil
        recorder = nil
        recording = false
        elapsed = 0
    }
}
