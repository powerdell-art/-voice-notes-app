import Foundation
import Speech
import AVFoundation

enum TranscriptionError: Error, LocalizedError {
    case speechNotAuthorized
    case microphoneNotAuthorized
    case recognizerUnavailable
    case exportFailed
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .speechNotAuthorized:
            return L10n.string("error.speechDenied")
        case .microphoneNotAuthorized:
            return L10n.string("error.micDenied")
        case .recognizerUnavailable:
            return L10n.string("error.recognizerUnavailable")
        case .exportFailed:
            return L10n.string("error.exportFailed")
        case .recognitionFailed:
            return L10n.string("error.recognitionFailed")
        }
    }
}

/// 线程安全的识别请求容器：追加音频帧发生在音频线程，请求的新建/销毁在主线程。
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: SFSpeechAudioBufferRecognitionRequest?
    var request: SFSpeechAudioBufferRecognitionRequest? {
        lock.lock()
        defer { lock.unlock() }
        return _request
    }
    func set(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        _request = request
        lock.unlock()
    }
}

/// 语音转写：基于苹果 Speech 框架。
///
/// - 实时转写：SFSpeechAudioBufferRecognitionRequest，由录音引擎逐帧喂音频；
/// - 文件转写：SFSpeechURLRecognitionRequest；文件超过 50 秒时按时间切片逐段转写再拼接
///   （识别请求有单次时长上限，长文件直转会被系统中断）；
/// - 实时流同样每约 50 秒滚动重启一次请求，把已确认文本固化成分段，避免长任务被系统掐断；
/// - 设备支持时设置 requiresOnDeviceRecognition，强制设备端识别、音频不离开手机；
///   不支持时回退苹果服务器识别（usesOnDevice 为 false，设置页会如实提示用户）。
@MainActor
final class Transcriber: ObservableObject {

    @Published private(set) var liveText: String = ""
    @Published private(set) var isLive: Bool = false
    /// 当前实时会话是否在用设备端识别
    @Published private(set) var usesOnDevice: Bool = false

    private var recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let requestBox = RequestBox()

    private var finalSegments: [String] = []
    private var currentPartial: String = ""
    private var rollTask: Task<Void, Never>?

    /// 文件转写切片长度（秒）
    private static let chunkSeconds: TimeInterval = 50
    /// 实时识别滚动重启间隔
    private static let rollInterval: Duration = .seconds(50)

    // MARK: - 权限

    static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    static func requestMicrophoneAuthorization() async -> Bool {
        // iOS 17 的 async 录音权限 API
        await AVAudioApplication.requestRecordPermission()
    }

    /// 某种语言是否支持设备端识别（设置页展示用）
    static func supportsOnDevice(localeIdentifier: String) -> Bool {
        SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))?.supportsOnDeviceRecognition ?? false
    }

    // MARK: - 实时转写

    func beginLive(localeIdentifier: String) throws {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw TranscriptionError.speechNotAuthorized
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }
        self.recognizer = recognizer
        finalSegments = []
        currentPartial = ""
        liveText = ""
        isLive = true
        startRequest()
        startRollTimer()
    }

    /// 录音引擎每帧调用（音频线程）：把帧追加到当前识别请求
    nonisolated func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        requestBox.request?.append(buffer)
    }

    /// 录音暂停时同步暂停识别：把当前未确认文本固化为分段
    func pauseLive() {
        commitPartial()
        requestBox.request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        requestBox.set(nil)
        rollTask?.cancel()
        rollTask = nil
    }

    /// 录音继续时开一个新请求接着识别
    func resumeLive() {
        guard isLive, recognizer != nil else { return }
        startRequest()
        startRollTimer()
    }

    /// 结束实时转写，返回全文
    @discardableResult
    func endLive() -> String {
        commitPartial()
        requestBox.request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        requestBox.set(nil)
        rollTask?.cancel()
        rollTask = nil
        isLive = false
        return liveText
    }

    private func startRequest() {
        guard let recognizer else { return }
        recognitionTask?.cancel()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
            usesOnDevice = true
        } else {
            // 设备/语言不支持设备端识别：回退服务器识别，状态如实暴露给 UI
            usesOnDevice = false
        }
        requestBox.set(request)

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    self.currentPartial = result.bestTranscription.formattedString
                    self.refreshLiveText()
                    if result.isFinal {
                        self.commitPartial()
                    }
                }
                if error != nil {
                    // 当前请求已结束：保住已识别文本；滚动计时器会开新请求续上，
                    // 最终文本还有停止后的"文件精转"兜底。
                    self.requestBox.set(nil)
                }
            }
        }
    }

    private func startRollTimer() {
        rollTask?.cancel()
        rollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.rollInterval)
                guard let self, self.isLive else { break }
                self.rollSegment()
            }
        }
    }

    /// 滚动重启：固化当前段落，结束旧请求，开新请求（录音不中断）
    private func rollSegment() {
        commitPartial()
        requestBox.request?.endAudio()
        recognitionTask?.cancel()
        startRequest()
    }

    private func commitPartial() {
        let trimmed = currentPartial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            finalSegments.append(trimmed)
        }
        currentPartial = ""
        refreshLiveText()
    }

    private func refreshLiveText() {
        var parts = finalSegments
        if !currentPartial.isEmpty {
            parts.append(currentPartial)
        }
        liveText = parts.joined(separator: " ")
    }

    // MARK: - 文件转写（录完精转 / 导入转写共用）

    /// 转写一个已落盘的音频文件。长文件自动按 50 秒切片逐段转写后拼接。
    func transcribeFile(at url: URL, localeIdentifier: String) async throws -> String {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw TranscriptionError.speechNotAuthorized
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds

        // 短文件（或读不到时长）直接整段转
        guard duration > Self.chunkSeconds else {
            return try await recognizeFile(url, with: recognizer)
        }

        var texts: [String] = []
        var start: TimeInterval = 0
        let tempDir = FileManager.default.temporaryDirectory
        while start < duration {
            let length = min(Self.chunkSeconds, duration - start)
            let segmentURL = tempDir.appendingPathComponent("segment-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: segmentURL) }
            try await exportSegment(asset: asset, start: start, length: length, to: segmentURL)
            let text = try await recognizeFile(segmentURL, with: recognizer)
            if !text.isEmpty {
                texts.append(text)
            }
            start += length
        }
        return texts.joined(separator: "\n")
    }

    /// 用 AVAssetExportSession 按时间范围导出一个切片为 m4a 临时文件
    private func exportSegment(asset: AVAsset, start: TimeInterval, length: TimeInterval, to url: URL) async throws {
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.exportFailed
        }
        exporter.outputURL = url
        exporter.outputFileType = .m4a
        let timescale: CMTimeScale = 600
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: timescale),
            duration: CMTime(seconds: length, preferredTimescale: timescale)
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    continuation.resume(throwing: exporter.error ?? TranscriptionError.exportFailed)
                default:
                    continuation.resume(throwing: TranscriptionError.exportFailed)
                }
            }
        }
    }

    /// 对单个文件做一次识别，等待最终结果
    private func recognizeFile(_ url: URL, with recognizer: SFSpeechRecognizer) async throws -> String {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            var resumed = false
            let resumeOnce: (Result<String, Error>) -> Void = { result in
                if resumed { return }
                resumed = true
                continuation.resume(with: result)
            }
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    resumeOnce(.failure(error))
                    return
                }
                if let result, result.isFinal {
                    resumeOnce(.success(result.bestTranscription.formattedString))
                }
            }
        }
    }
}
