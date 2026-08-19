import SwiftUI

struct SettingsView: View {
    let course: LanguageCourse
    @ObservedObject var progress: ProgressStore
    @ObservedObject var settings: SettingsStore

    @State private var showResetConfirmation = false

    var body: some View {
        Form {
            Section("Practice sessions") {
                Picker("Questions", selection: $settings.sessionLength) {
                    ForEach([5, 10, 15, 20], id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }

                Stepper("Daily goal: \(settings.dailyGoalXP) XP", value: $settings.dailyGoalXP, in: 10...200, step: 10)
            }

            Section("Exercise mix") {
                ForEach(ExerciseType.allCases) { type in
                    Toggle(isOn: binding(for: type)) {
                        Label(type.title, systemImage: type.systemImage)
                    }
                }
                Text("At least one exercise type stays enabled. Speaking permission is only requested when a speaking question is actually used.")
                    .font(.caption)
                    .foregroundStyle(Color.lingoMuted)
            }

            Section("Audio & hints") {
                Toggle("Auto-play listening questions", isOn: $settings.autoplayAudio)
                Toggle("Show lemma/chunk hints", isOn: $settings.showLemmaHints)
                Toggle("Haptic feedback", isOn: $settings.hapticsEnabled)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Speech speed")
                    Slider(value: $settings.speechRate, in: 0.35...0.58)
                }
            }

            Section("Hearts") {
                Toggle("Use hearts in lessons", isOn: $settings.heartsEnabled)
                if settings.heartsEnabled {
                    HStack {
                        Label("\(progress.hearts) / 5", systemImage: "heart.fill")
                            .foregroundStyle(.red)
                        Spacer()
                        Button("Refill") {
                            progress.refillHearts()
                        }
                        .disabled(progress.hearts == 5)
                    }
                }
            }

            Section("Course") {
                LabeledContent("Current language", value: "\(course.flag) \(course.title)")
                LabeledContent("Content", value: "Opinions & Reactions")
                LabeledContent("Storage", value: "On device")
            }

            Section("Reset") {
                Button("Reset settings") {
                    settings.reset()
                }
                Button("Reset all progress", role: .destructive) {
                    showResetConfirmation = true
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Reset all learning progress?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset everything", role: .destructive) {
                progress.resetAllProgress()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears lesson completion, XP, streaks, phrase mastery, bookmarks and hearts on this device.")
        }
    }

    private func binding(for type: ExerciseType) -> Binding<Bool> {
        Binding(
            get: { settings.enabledExerciseTypes.contains(type) },
            set: { newValue in
                let contains = settings.enabledExerciseTypes.contains(type)
                if newValue != contains {
                    settings.toggleExercise(type)
                }
            }
        )
    }
}
