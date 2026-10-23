import Foundation
import AVFoundation

/// 详情页的音频回放：AVAudioPlayer 的轻封装，带进度发布与 seek。
@MainActor
final class AudioPlayer: NSObject, ObservableObject {

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var tickTask: Task<Void, Never>?

    func load(url: URL) {
        stopTicker()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.delegate = self
            newPlayer.prepareToPlay()
            player = newPlayer
            duration = newPlayer.duration
        } catch {
            player = nil
        }
    }

    func togglePlayPause() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            stopTicker()
        } else {
            player.play()
            isPlaying = true
            startTicker()
        }
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = min(max(time, 0), player.duration)
        player.currentTime = clamped
        currentTime = clamped
    }

    func stop() {
        player?.stop()
        isPlaying = false
        currentTime = 0
        stopTicker()
    }

    private func startTicker() {
        stopTicker()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, let player = self.player else { break }
                self.currentTime = player.currentTime
            }
        }
    }

    private func stopTicker() {
        tickTask?.cancel()
        tickTask = nil
    }

    /// 播放自然结束时由 delegate（非隔离上下文）跳回主线程收尾
    fileprivate func handleFinished() {
        isPlaying = false
        currentTime = 0
        stopTicker()
    }
}

// AVAudioPlayerDelegate 的回调不在主线程，用 nonisolated 方法转跳回 MainActor
extension AudioPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.handleFinished()
        }
    }
}
