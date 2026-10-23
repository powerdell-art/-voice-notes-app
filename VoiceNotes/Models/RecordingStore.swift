import Foundation

/// 记录数据层：Codable + FileManager 实现。
///
/// 选型说明（为什么不用 SwiftData）：
/// v1 数据量小、无关联查询，全部记录的元数据存一个 JSON 索引文件足够，
/// 且没有数据库迁移风险、行为可预测；音频文件单独存 Documents/Audio 目录。
/// 将来数据模型复杂化后再迁 SwiftData 不迟。
@MainActor
final class RecordingStore: ObservableObject {

    @Published private(set) var items: [RecordingItem] = []

    private let fileManager = FileManager.default

    private var documentsURL: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 音频文件目录（不存在时惰性创建）
    var audioDirectoryURL: URL {
        let dir = documentsURL.appendingPathComponent("Audio", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private var indexURL: URL {
        documentsURL.appendingPathComponent("recordings.json")
    }

    init() {
        load()
    }

    // MARK: - 读写

    func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([RecordingItem].self, from: data) else {
            items = []
            return
        }
        items = decoded.sorted { $0.createdAt > $1.createdAt }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(items) {
            // 原子写入，避免写一半损坏索引
            try? data.write(to: indexURL, options: [.atomic])
        }
    }

    // MARK: - 路径

    /// 新录音的落盘 URL
    func newAudioURL() -> URL {
        audioDirectoryURL.appendingPathComponent(UUID().uuidString + ".m4a")
    }

    func audioURL(for item: RecordingItem) -> URL {
        audioDirectoryURL.appendingPathComponent(item.audioFileName)
    }

    // MARK: - 增删改

    func add(_ item: RecordingItem) {
        items.append(item)
        items.sort { $0.createdAt > $1.createdAt }
        persist()
    }

    func update(_ item: RecordingItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        persist()
    }

    func item(id: UUID) -> RecordingItem? {
        items.first { $0.id == id }
    }

    /// 删除记录并一并删除音频文件
    func delete(_ item: RecordingItem) {
        try? fileManager.removeItem(at: audioURL(for: item))
        items.removeAll { $0.id == item.id }
        persist()
    }

    // MARK: - 导入外部音频

    /// 把外部音频文件复制进沙盒并建一条记录（转写由调用方随后触发）。
    /// - Parameter sourceURL: fileImporter 给的 URL，可能是 security-scoped。
    func importAudio(from sourceURL: URL, localeIdentifier: String) throws -> RecordingItem {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { sourceURL.stopAccessingSecurityScopedResource() }
        }
        let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        let fileName = UUID().uuidString + "." + ext
        let destination = audioDirectoryURL.appendingPathComponent(fileName)
        try fileManager.copyItem(at: sourceURL, to: destination)

        let item = RecordingItem(
            id: UUID(),
            title: sourceURL.deletingPathExtension().lastPathComponent,
            duration: 0, // 由调用方异步读出真实时长后 update
            audioFileName: fileName,
            transcript: "",
            createdAt: Date(),
            localeIdentifier: localeIdentifier
        )
        add(item)
        return item
    }
}
