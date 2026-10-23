import SwiftUI
import Speech

/// 设置页：识别语言切换、设备端识别支持情况、隐私说明、关于。
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        NavigationStack {
            Form {
                Section("settings.language.section") {
                    Picker("settings.language", selection: $settings.localeIdentifier) {
                        Text("settings.language.zh").tag("zh-CN")
                        Text("settings.language.en").tag("en-US")
                    }

                    HStack {
                        Text("settings.onDevice")
                        Spacer()
                        Text(onDeviceSupported ? "settings.supported" : "settings.notSupported")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section("settings.privacy.section") {
                    Text("settings.privacy.text")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("settings.about.section") {
                    LabeledContent("settings.version", value: appVersion)
                    LabeledContent("settings.developer", value: "Dongzhou")
                }
            }
            .navigationTitle("tab.settings")
        }
    }

    /// 当前所选语言是否支持设备端识别
    private var onDeviceSupported: Bool {
        Transcriber.supportsOnDevice(localeIdentifier: settings.localeIdentifier)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}
