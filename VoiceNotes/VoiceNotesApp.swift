import SwiftUI

@main
struct VoiceNotesApp: App {
    @StateObject private var store = RecordingStore()
    @StateObject private var settings = SettingsStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(settings)
        }
    }
}
