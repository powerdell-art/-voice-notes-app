import SwiftUI

/// 录音页：大按钮录音（暂停/继续）、计时、电平条、实时字幕滚动；
/// 停止后自动对整段录音做文件精转，完成后回写记录。
struct RecordView: View {
    @EnvironmentObject private var store: RecordingStore
    @EnvironmentObject private var settings: SettingsStore

    @StateObject private var recorder = AudioRecorder()
    @StateObject private var transcriber = Transcriber()

    @State private var errorMessage: String?
    @State private var lastSavedItem: RecordingItem?
    @State private var isRefining = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // 计时
                Text(Formatting.duration(recorder.elapsed))
                    .font(.system(size: 48, weight: .light, design: .monospaced))
                    .padding(.top, 8)

                // 电平条
                LevelBar(level: recorder.level)
                    .padding(.horizontal, 32)

                // 实时字幕区
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(transcriber.liveText.isEmpty
                             ? L10n.string("record.livePlaceholder")
                             : transcriber.liveText)
                            .foregroundStyle(transcriber.liveText.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .id("liveText")
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    )
                    .onChange(of: transcriber.liveText) {
                        withAnimation {
                            proxy.scrollTo("liveText", anchor: .bottom)
                        }
                    }
                }
                .padding(.horizontal)

                if isRefining {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("record.refining")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let item = lastSavedItem, recorder.state == .idle {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("record.saved")
                        NavigationLink {
                            RecordingDetailView(itemID: item.id)
                        } label: {
                            Text("record.viewDetail")
                        }
                    }
                    .font(.footnote)
                }

                // 控制区
                HStack(spacing: 40) {
                    // 暂停/继续（只在录音或暂停时出现）
                    ZStack {
                        if recorder.state != .idle {
                            Button {
                                togglePauseResume()
                            } label: {
                                Image(systemName: recorder.state == .paused ? "play.fill" : "pause.fill")
                                    .font(.title2)
                                    .frame(width: 56, height: 56)
                                    .background(Circle().fill(Color(uiColor: .secondarySystemBackground)))
                            }
                            .accessibilityLabel(Text(recorder.state == .paused ? "record.resume" : "record.pause"))
                        }
                    }
                    .frame(width: 56, height: 56)

                    // 主按钮：开始 / 停止
                    Button {
                        if recorder.state == .idle {
                            Task { await startRecording() }
                        } else {
                            stopRecording()
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .strokeBorder(Color.red, lineWidth: 3)
                                .frame(width: 84, height: 84)
                            if recorder.state == .idle {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 68, height: 68)
                            } else {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.red)
                                    .frame(width: 36, height: 36)
                            }
                        }
                    }
                    .accessibilityLabel(Text(recorder.state == .idle ? "record.start" : "record.stop"))
                }
                .padding(.bottom, 24)
            }
            .navigationTitle("tab.record")
            // 系统打断（来电等）导致录音侧自动暂停时，把转写侧一并暂停
            .onChange(of: recorder.state) { _, newState in
                if newState == .paused, transcriber.isLive {
                    transcriber.pauseLive()
                }
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

    // MARK: - 操作

    private func startRecording() async {
        // 权限在用户点"开始录音"时才请求，不在启动时弹
        let speechOK = await Transcriber.requestSpeechAuthorization()
        guard speechOK else {
            errorMessage = L10n.string("error.speechDenied")
            return
        }
        let micOK = await Transcriber.requestMicrophoneAuthorization()
        guard micOK else {
            errorMessage = L10n.string("error.micDenied")
            return
        }

        lastSavedItem = nil
        do {
            try transcriber.beginLive(localeIdentifier: settings.localeIdentifier)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        // 闭包持有 transcriber 对象引用；停止录音时 onBuffer 置空即断开
        recorder.onBuffer = { buffer in
            transcriber.appendBuffer(buffer)
        }
        do {
            try recorder.start(to: store.newAudioURL())
        } catch {
            transcriber.endLive()
            errorMessage = error.localizedDescription
        }
    }

    private func togglePauseResume() {
        switch recorder.state {
        case .recording:
            recorder.pause()
            transcriber.pauseLive()
        case .paused:
            do {
                try recorder.resume()
                transcriber.resumeLive()
            } catch {
                errorMessage = error.localizedDescription
            }
        case .idle:
            break
        }
    }

    private func stopRecording() {
        guard let url = recorder.stop() else { return }
        let finalDuration = recorder.elapsed
        let liveTranscript = transcriber.endLive()
        recorder.onBuffer = nil

        let item = RecordingItem(
            id: UUID(),
            title: defaultTitle(),
            duration: finalDuration,
            audioFileName: url.lastPathComponent,
            transcript: liveTranscript,
            createdAt: Date(),
            localeIdentifier: settings.localeIdentifier
        )
        store.add(item)
        lastSavedItem = item

        // 精转：对整段文件再转一次，质量高于实时结果，完成后回写
        isRefining = true
        Task {
            defer { isRefining = false }
            guard let refined = try? await transcriber.transcribeFile(
                at: url,
                localeIdentifier: item.localeIdentifier
            ), !refined.isEmpty else { return }
            guard var current = store.item(id: item.id) else { return }
            current.transcript = refined
            store.update(current)
            if lastSavedItem?.id == item.id {
                lastSavedItem = current
            }
        }
    }

    private func defaultTitle() -> String {
        let date = Date().formatted(date: .abbreviated, time: .shortened)
        return "\(L10n.string("record.defaultTitle")) \(date)"
    }
}

/// 电平条：0...1 映射宽度，接近满格时变红
private struct LevelBar: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(level > 0.85 ? Color.red : Color.green)
                    .frame(width: geometry.size.width * CGFloat(min(max(level, 0), 1)))
            }
        }
        .frame(height: 8)
    }
}
