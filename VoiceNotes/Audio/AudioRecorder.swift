import Foundation
import AVFoundation

/// 线程安全的电平值容器：音频线程写、主线程（计时器）读。
private final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var _level: Float = 0
    var level: Float {
        lock.lock()
        defer { lock.unlock() }
        return _level
    }
    func update(_ value: Float) {
        lock.lock()
        _level = value
        lock.unlock()
    }
}

/// 录音引擎。
///
/// 实现说明：用 AVAudioEngine 而不是 AVAudioRecorder——
/// AVAudioRecorder 拿不到原始音频流，无法同时喂给 Speech 做实时转写；
/// 用引擎采集同一路音频，一份写 AAC/m4a 落盘、一份回调给 Transcriber。
/// 暂停/继续 = 暂停/恢复引擎，时长按段累计；来电等系统打断时自动暂停（已录部分不丢）。
@MainActor
final class AudioRecorder: ObservableObject {

    enum RecorderState: Equatable {
        case idle, recording, paused
    }

    @Published private(set) var state: RecorderState = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    /// 0...1 归一化电平，驱动 UI 电平条
    @Published private(set) var level: Float = 0

    /// 每帧音频回调（在音频线程触发），供 Transcriber 追加到识别请求
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private let levelMeter = LevelMeter()

    private var tickTask: Task<Void, Never>?
    private var accumulated: TimeInterval = 0
    private var segmentStart: Date?
    private var interruptionObserver: NSObjectProtocol?

    var isRecording: Bool { state == .recording }

    // MARK: - 开始 / 暂停 / 继续 / 停止

    func start(to url: URL) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        // AAC/m4a 落盘：采样率与通道数跟随输入格式，AVAudioFile 负责把 PCM 编码为 AAC
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: inputFormat.channelCount,
            AVEncoderBitRateKey: 64_000
        ]
        audioFile = try AVAudioFile(forWriting: url, settings: settings)
        outputURL = url
        accumulated = 0
        elapsed = 0
        levelMeter.update(0)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // 音频线程：写文件 + 喂识别 + 算电平，都不能阻塞太久
            try? self.audioFile?.write(from: buffer)
            self.onBuffer?(buffer)
            self.levelMeter.update(Self.rmsLevel(of: buffer))
        }

        engine.prepare()
        try engine.start()

        segmentStart = Date()
        state = .recording
        startTicking()
        observeInterruptions()
    }

    func pause() {
        guard state == .recording else { return }
        engine.pause()
        if let start = segmentStart {
            accumulated += Date().timeIntervalSince(start)
            segmentStart = nil
        }
        elapsed = accumulated
        levelMeter.update(0)
        level = 0
        state = .paused
    }

    func resume() throws {
        guard state == .paused else { return }
        try AVAudioSession.sharedInstance().setActive(true)
        try engine.start()
        segmentStart = Date()
        state = .recording
    }

    /// 停止并返回录音文件 URL（失败或未录过返回 nil）
    @discardableResult
    func stop() -> URL? {
        guard state != .idle else { return nil }
        if let start = segmentStart {
            accumulated += Date().timeIntervalSince(start)
            segmentStart = nil
        }
        elapsed = accumulated
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        audioFile = nil // 置空即关闭文件、刷盘
        state = .idle
        level = 0
        levelMeter.update(0)
        tickTask?.cancel()
        tickTask = nil
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        let url = outputURL
        outputURL = nil
        return url
    }

    // MARK: - 计时与电平

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { break }
                self.tick()
            }
        }
    }

    private func tick() {
        if state == .recording, let start = segmentStart {
            elapsed = accumulated + Date().timeIntervalSince(start)
        } else {
            elapsed = accumulated
        }
        level = levelMeter.level
    }

    // MARK: - 系统打断（来电/闹钟等）自动暂停

    private func observeInterruptions() {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw),
                  type == .began else { return }
            Task { @MainActor [weak self] in
                guard let self, self.state == .recording else { return }
                self.pause()
                // 注：转写侧的暂停由 RecordView 通过 onChange(of: recorder.state) 同步
            }
        }
    }

    // MARK: - 电平计算

    /// 由音频帧算 RMS 并映射到 0...1（约 -50dB 对应 0，0dB 对应 1）
    nonisolated private static func rmsLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        let data = channelData[0]
        var sum: Float = 0
        for i in 0..<count {
            let sample = data[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(count))
        let db = 20 * log10(max(rms, 0.000_01))
        let normalized = (db + 50) / 50
        return min(max(normalized, 0), 1)
    }
}
