import SwiftUI
import UIKit

/// 记录详情页：回放音频、编辑标题与文本、复制、导出 .txt、系统分享。
/// 数据从 store 实时读取，录音页的"精转"回写会自动反映到这里。
struct RecordingDetailView: View {
    let itemID: UUID

    @EnvironmentObject private var store: RecordingStore
    @StateObject private var player = AudioPlayer()

    @State private var editedTitle = ""
    @State private var editedText = ""
    @State private var seeded = false
    @State private var showCopied = false
    @State private var shareItem: ShareItem?

    private var item: RecordingItem? {
        store.item(id: itemID)
    }

    var body: some View {
        Group {
            if let item {
                detailContent(item)
            } else {
                ContentUnavailableView(
                    "detail.deleted",
                    systemImage: "trash"
                )
            }
        }
        .navigationTitle("tab.history")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard let item, !seeded else { return }
            seeded = true
            editedTitle = item.title
            editedText = item.transcript
            player.load(url: store.audioURL(for: item))
        }
        .onDisappear {
            player.stop()
        }
        .sheet(item: $shareItem) { share in
            ActivityView(url: share.url)
        }
    }

    @ViewBuilder
    private func detailContent(_ item: RecordingItem) -> some View {
        VStack(spacing: 16) {
            // 标题（可编辑，改完即存）
            TextField("detail.titlePlaceholder", text: $editedTitle)
                .font(.title3.weight(.semibold))
                .onChange(of: editedTitle) { _, newValue in
                    guard var current = self.item, current.title != newValue else { return }
                    current.title = newValue
                    store.update(current)
                }

            // 回放控制
            VStack(spacing: 8) {
                HStack(spacing: 16) {
                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 44))
                    }
                    .accessibilityLabel(Text(player.isPlaying ? "detail.pause" : "detail.play"))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(Formatting.duration(player.currentTime)) / \(Formatting.duration(player.duration))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Slider(
                    value: Binding(
                        get: { player.currentTime },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...max(player.duration, 0.1)
                )
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )

            // 转写文本（可编辑，改完即存）
            TextEditor(text: $editedText)
                .frame(maxHeight: .infinity)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.3))
                )
                .overlay {
                    if editedText.isEmpty {
                        Text("detail.transcriptPlaceholder")
                            .foregroundStyle(.secondary)
                            .padding()
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: editedText) { _, newValue in
                    guard var current = self.item, current.transcript != newValue else { return }
                    current.transcript = newValue
                    store.update(current)
                }

            // 操作行：复制 / 分享 / 导出
            HStack(spacing: 12) {
                Button {
                    UIPasteboard.general.string = editedText
                    showCopied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        showCopied = false
                    }
                } label: {
                    Label(showCopied ? "detail.copied" : "detail.copy",
                          systemImage: showCopied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                ShareLink(item: editedText) {
                    Label("detail.share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    exportTextFile(item)
                } label: {
                    Label("detail.export", systemImage: "arrow.down.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
    }

    /// 把文本写成临时 .txt 文件后调起系统分享（分享文件本体而非文本片段）
    private func exportTextFile(_ item: RecordingItem) {
        let baseName = item.title.isEmpty ? "transcript" : item.title
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(baseName + ".txt")
        do {
            try editedText.write(to: url, atomically: true, encoding: .utf8)
            shareItem = ShareItem(url: url)
        } catch {
            // 写临时文件失败时退化为分享文本
            UIPasteboard.general.string = editedText
        }
    }
}

/// .sheet(item:) 需要 Identifiable 的包装
private struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// UIActivityViewController 的 SwiftUI 包装（分享文件用）
private struct ActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
