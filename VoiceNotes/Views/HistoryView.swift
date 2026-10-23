import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// 历史页：列表 + 搜索 + 左滑删除 + 导入外部音频转写。
struct HistoryView: View {
    @EnvironmentObject private var store: RecordingStore
    @EnvironmentObject private var settings: SettingsStore

    @StateObject private var fileTranscriber = Transcriber()

    @State private var searchText = ""
    @State private var showImporter = false
    @State private var importingItemID: UUID?
    @State private var errorMessage: String?

    private var filteredItems: [RecordingItem] {
        if searchText.isEmpty { return store.items }
        return store.items.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.transcript.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    ContentUnavailableView(
                        "history.empty.title",
                        systemImage: "waveform",
                        description: Text("history.empty.message")
                    )
                } else {
                    List {
                        ForEach(filteredItems) { item in
                            NavigationLink {
                                RecordingDetailView(itemID: item.id)
                            } label: {
                                row(for: item)
                            }
                        }
                        .onDelete { offsets in
                            offsets
                                .map { filteredItems[$0] }
                                .forEach { store.delete($0) }
                        }
                    }
                }
            }
            .navigationTitle("tab.history")
            .searchable(text: $searchText, prompt: Text("history.search.prompt"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showImporter = true
                    } label: {
                        Label("history.import", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            .alert(
                L10n.string("error.title"),
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("error.ok") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private func row(for item: RecordingItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 8) {
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                Text(Formatting.duration(item.duration))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if importingItemID == item.id {
                HStack(spacing: 6) {
                    ProgressView()
                    Text("history.transcribing")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if item.transcript.isEmpty {
                Text("history.noTranscript")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text(item.transcript)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 导入并转写

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await importAndTranscribe(url) }
        }
    }

    private func importAndTranscribe(_ sourceURL: URL) async {
        let speechOK = await Transcriber.requestSpeechAuthorization()
        guard speechOK else {
            errorMessage = L10n.string("error.speechDenied")
            return
        }
        do {
            let item = try store.importAudio(
                from: sourceURL,
                localeIdentifier: settings.localeIdentifier
            )
            importingItemID = item.id
            defer { importingItemID = nil }

            let localURL = store.audioURL(for: item)

            // 补上真实时长
            let asset = AVURLAsset(url: localURL)
            if let duration = try? await asset.load(.duration), duration.seconds.isFinite {
                var updated = item
                updated.duration = duration.seconds
                store.update(updated)
            }

            let text = try await fileTranscriber.transcribeFile(
                at: localURL,
                localeIdentifier: item.localeIdentifier
            )
            if var current = store.item(id: item.id) {
                current.transcript = text
                store.update(current)
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? L10n.string("error.importFailed")
        }
    }
}
