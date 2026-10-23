import Foundation

/// 一条录音记录的元数据。音频本体是沙盒里的文件，这里只存相对文件名。
struct RecordingItem: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    /// 时长（秒）
    var duration: TimeInterval
    /// 音频文件名（相对 Documents/Audio 目录）
    var audioFileName: String
    /// 转写全文
    var transcript: String
    var createdAt: Date
    /// 识别语言，如 "zh-CN" / "en-US"
    var localeIdentifier: String
}
