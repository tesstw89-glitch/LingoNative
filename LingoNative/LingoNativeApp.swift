import SwiftUI
import Foundation
import UIKit
import llama
@main
struct LingoNativeApp: App {
    @StateObject private var progress: ProgressStore
    @StateObject private var settings: SettingsStore
    @StateObject private var starStore = StarStore()

    init() {
        let inputTextColor = UIColor(red: 0.24, green: 0.27, blue: 0.29, alpha: 1.0)
        UITextField.appearance().textColor = inputTextColor
        UITextView.appearance().textColor = inputTextColor

        NotificationCenter.default.addObserver(
            forName: UITextField.textDidBeginEditingNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let field = notification.object as? UITextField else { return }
            field.overrideUserInterfaceStyle = .light
            field.textColor = inputTextColor
            field.tintColor = UIColor(red: 0.12, green: 0.64, blue: 0.90, alpha: 1.0)
        }

        NotificationCenter.default.addObserver(
            forName: UITextView.textDidBeginEditingNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let textView = notification.object as? UITextView else { return }
            textView.overrideUserInterfaceStyle = .light
            textView.textColor = inputTextColor
            textView.tintColor = UIColor(red: 0.12, green: 0.64, blue: 0.90, alpha: 1.0)
        }

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
                .environmentObject(starStore)
        }
    }
}
