import SwiftUI
import Foundation

@main
struct LingoNativeApp: App {
    @StateObject private var progress: ProgressStore
    @StateObject private var settings: SettingsStore

    init() {
        let defaults = UserDefaults.standard
        let resetMarker = "learningEngineReset.2026-08-19.v1"

        if !defaults.bool(forKey: resetMarker) {
            [
                "completedNodeIDs",
                "hearts",
                "xp",
                "phraseProgress.v2",
                "bookmarkedPhraseKeys",
                "dailyActivity.v2",
                "savedLessonSessions.v1"
            ].forEach { defaults.removeObject(forKey: $0) }

            defaults.set(true, forKey: resetMarker)
        }

        _progress = StateObject(wrappedValue: ProgressStore(defaults: defaults))
        _settings = StateObject(wrappedValue: SettingsStore(defaults: defaults))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(progress: progress, settings: settings)
        }
    }
}
