import SwiftUI

@MainActor
final class SettingsStore: ObservableObject {
    @Published var sessionLength: Int { didSet { save() } }
    @Published var heartsEnabled: Bool { didSet { save() } }
    @Published var autoplayAudio: Bool { didSet { save() } }
    @Published var hapticsEnabled: Bool { didSet { save() } }
    @Published var showLemmaHints: Bool { didSet { save() } }
    @Published var dailyGoalXP: Int { didSet { save() } }
    @Published var speechRate: Double { didSet { save() } }
    @Published var enabledExerciseTypes: Set<ExerciseType> { didSet { save() } }

    private let defaults: UserDefaults
    private let key = "lingoNative.settings.v2"

    private struct Payload: Codable {
        var sessionLength: Int
        var heartsEnabled: Bool
        var autoplayAudio: Bool
        var hapticsEnabled: Bool
        var showLemmaHints: Bool
        var dailyGoalXP: Int
        var speechRate: Double
        var enabledExerciseTypes: Set<ExerciseType>
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: key),
           let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            sessionLength = payload.sessionLength
            heartsEnabled = payload.heartsEnabled
            autoplayAudio = payload.autoplayAudio
            hapticsEnabled = payload.hapticsEnabled
            showLemmaHints = payload.showLemmaHints
            dailyGoalXP = payload.dailyGoalXP
            speechRate = payload.speechRate
            enabledExerciseTypes = payload.enabledExerciseTypes
        } else {
            sessionLength = 10
            heartsEnabled = true
            autoplayAudio = true
            hapticsEnabled = true
            showLemmaHints = true
            dailyGoalXP = 50
            speechRate = 0.46
            enabledExerciseTypes = Set(ExerciseType.allCases)
        }
    }

    func reset() {
        sessionLength = 10
        heartsEnabled = true
        autoplayAudio = true
        hapticsEnabled = true
        showLemmaHints = true
        dailyGoalXP = 50
        speechRate = 0.46
        enabledExerciseTypes = Set(ExerciseType.allCases)
        save()
    }

    func toggleExercise(_ type: ExerciseType) {
        if enabledExerciseTypes.contains(type) {
            guard enabledExerciseTypes.count > 1 else { return }
            enabledExerciseTypes.remove(type)
        } else {
            enabledExerciseTypes.insert(type)
        }
    }

    private func save() {
        let payload = Payload(
            sessionLength: sessionLength,
            heartsEnabled: heartsEnabled,
            autoplayAudio: autoplayAudio,
            hapticsEnabled: hapticsEnabled,
            showLemmaHints: showLemmaHints,
            dailyGoalXP: dailyGoalXP,
            speechRate: speechRate,
            enabledExerciseTypes: enabledExerciseTypes
        )
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: key)
        }
    }
}
