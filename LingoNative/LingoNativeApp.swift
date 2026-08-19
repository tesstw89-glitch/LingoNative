import SwiftUI

@main
struct LingoNativeApp: App {
    @StateObject private var progress = ProgressStore()
    @StateObject private var settings = SettingsStore()

    var body: some Scene {
        WindowGroup {
            ContentView(progress: progress, settings: settings)
        }
    }
}
