import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            RecordView()
                .tabItem {
                    Label("tab.record", systemImage: "mic.fill")
                }

            HistoryView()
                .tabItem {
                    Label("tab.history", systemImage: "list.bullet")
                }

            SettingsView()
                .tabItem {
                    Label("tab.settings", systemImage: "gearshape")
                }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(RecordingStore())
        .environmentObject(SettingsStore())
}
