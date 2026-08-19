import SwiftUI
import Foundation

@main
struct LingoNativeApp: App {
    @StateObject private var progress: ProgressStore
    @StateObject private var settings: SettingsStore

    init() {
        let defaults = UserDefaults.standard
        let resetMarker = "learningEngineReset.2026-08-19.v2"

        if !defaults.bool(forKey: resetMarker) {
            [
                "completedNodeIDs",
                "hearts",
                "xp",
                "phraseProgress.v2",
                "bookmarkedPhraseKeys",
                "dailyActivity.v2",
                "savedLessonSessions.v1",
                "learningAttempts.v1",
                "adaptiveLearnerModels.v1"
            ].forEach { defaults.removeObject(forKey: $0) }

            defaults.set(true, forKey: resetMarker)
        }

        // The lesson allocator now spreads related phrases across a unit's lessons instead
        // of taking consecutive source-file chunks. Discard only old in-progress snapshots
        // so they cannot resurrect the previous phrase grouping; keep learning history intact.
        let lessonAllocationMarker = "lessonAllocationReset.2026-08-19.v1"
        if !defaults.bool(forKey: lessonAllocationMarker) {
            defaults.removeObject(forKey: "savedLessonSessions.v1")
            defaults.set(true, forKey: lessonAllocationMarker)
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
