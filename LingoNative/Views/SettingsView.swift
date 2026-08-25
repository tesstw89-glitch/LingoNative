import SwiftUI

struct SettingsView: View {
    let course: LanguageCourse
    @ObservedObject var progress: ProgressStore
    @ObservedObject var settings: SettingsStore

    @StateObject private var localAIModel = LocalAIModelStore.shared
    @State private var showResetConfirmation = false
    @State private var aiTestIsRunning = false
    @State private var aiColdResult: LocalAIJudgeResult?
    @State private var aiWarmResult: LocalAIJudgeResult?
    @State private var aiTestMessage: String?

    var body: some View {
        Form {

            // MARK: - Practice sessions

            Section {
                Picker(selection: $settings.sessionLength) {
                    ForEach([5, 10, 15, 20], id: \.self) { count in
                        Text("\(count)")
                            .font(.custom("Fredoka-Regular", size: 16))
                            .tag(count)
                    }
                } label: {
                    Text("Questions")
                        .font(.custom("Fredoka-Regular", size: 16))
                }

                Stepper(
                    value: $settings.dailyGoalXP,
                    in: 10...200,
                    step: 10
                ) {
                    Text("Daily goal: \(settings.dailyGoalXP) XP")
                        .font(.custom("Fredoka-Regular", size: 16))
                }

            } header: {
                Text("Practice sessions")
                    .font(.custom("Fredoka-SemiBold", size: 13))
            }

            // MARK: - Appearance

            Section {
                Toggle(isOn: $settings.darkModeEnabled) {
                    Text("Dark mode")
                        .font(.custom("Fredoka-Regular", size: 16))
                }

                Text("Choose the app appearance independently from your iPhone's light or dark mode setting.")
                    .font(.custom("Fredoka-Regular", size: 13))
                    .foregroundStyle(Color.lingoMuted)

            } header: {
                Text("Appearance")
                    .font(.custom("Fredoka-SemiBold", size: 13))
            }

            // MARK: - Exercise mix

            Section {
                ForEach(ExerciseType.userSelectableCases) { type in
                    Toggle(isOn: binding(for: type)) {
                        Label(type.title, systemImage: type.systemImage)
                            .font(.custom("Fredoka-Regular", size: 16))
                    }
                }

                Text("New phrases are always introduced before testing. These switches control the exercise mix once a phrase is ready for that level of recall.")
                    .font(.custom("Fredoka-Regular", size: 13))
                    .foregroundStyle(Color.lingoMuted)

            } header: {
                Text("Exercise mix")
                    .font(.custom("Fredoka-SemiBold", size: 13))
            }

            // MARK: - Enhanced answer checking

            Section {
                Toggle(isOn: $settings.enhancedAnswerCheckingEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Enhanced answer checking")
                            .font(.custom("Fredoka-Regular", size: 16))

                        Text("Accept natural alternative translations")
                            .font(.custom("Fredoka-Regular", size: 13))
                            .foregroundStyle(Color.lingoMuted)
                    }
                }
                .disabled(!localAIModel.isInstalled)

                switch localAIModel.state {
                case .installed:
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.lingoCorrect)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Qwen3 4B ready")
                                .font(.custom("Fredoka-Medium", size: 15))
                            Text("Runs entirely on this device")
                                .font(.custom("Fredoka-Regular", size: 13))
                                .foregroundStyle(Color.lingoMuted)
                        }
                    }

                    Button {
                        runLocalAITest()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Test cold + warm answer checking")
                                    .font(.custom("Fredoka-Medium", size: 15))
                                Text("Runs two grades back-to-back on this iPhone")
                                    .font(.custom("Fredoka-Regular", size: 13))
                                    .foregroundStyle(Color.lingoMuted)
                            }
                            Spacer()
                            Image(systemName: "cpu")
                        }
                    }
                    .disabled(aiTestIsRunning)

                    if aiTestIsRunning {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Running cold test, then warm test…")
                                .font(.custom("Fredoka-Regular", size: 13))
                                .foregroundStyle(Color.lingoMuted)
                        }
                    }

                    if let cold = aiColdResult {
                        benchmarkRow(title: "Cold", result: cold)
                    }

                    if let warm = aiWarmResult {
                        benchmarkRow(title: "Warm", result: warm)
                    }

                    if let aiTestMessage {
                        Text(aiTestMessage)
                            .font(.custom("Fredoka-Regular", size: 13))
                            .foregroundStyle(Color.lingoMuted)
                            .textSelection(.enabled)
                    }

                    Button(role: .destructive) {
                        localAIModel.removeModel()
                        aiColdResult = nil
                        aiWarmResult = nil
                        aiTestMessage = nil
                    } label: {
                        Text("Remove AI model")
                            .font(.custom("Fredoka-Medium", size: 15))
                    }
                    .disabled(aiTestIsRunning)

                case .downloading:
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Downloading Qwen3 4B…")
                                .font(.custom("Fredoka-Medium", size: 15))
                            Spacer()
                            Text("\(Int(localAIModel.downloadProgress * 100))%")
                                .font(.custom("Fredoka-Regular", size: 13))
                                .foregroundStyle(Color.lingoMuted)
                        }

                        ProgressView(value: localAIModel.downloadProgress)
                    }

                    Button(role: .destructive) {
                        localAIModel.cancelDownload()
                    } label: {
                        Text("Cancel download")
                            .font(.custom("Fredoka-Medium", size: 15))
                    }

                case .failed(let message):
                    Label("Download failed", systemImage: "exclamationmark.triangle.fill")
                        .font(.custom("Fredoka-Medium", size: 15))
                        .foregroundStyle(Color.lingoWrong)

                    Text(message)
                        .font(.custom("Fredoka-Regular", size: 13))
                        .foregroundStyle(Color.lingoMuted)

                    Button {
                        localAIModel.downloadModel()
                    } label: {
                        Text("Try again")
                            .font(.custom("Fredoka-Medium", size: 15))
                    }

                case .notInstalled:
                    Button {
                        localAIModel.downloadModel()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Download AI model")
                                    .font(.custom("Fredoka-Medium", size: 16))
                                Text("About \(LocalAIModelStore.approximateDownloadSize) · Wi-Fi only")
                                    .font(.custom("Fredoka-Regular", size: 13))
                                    .foregroundStyle(Color.lingoMuted)
                            }
                            Spacer()
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.title3)
                        }
                    }
                }

                Text("The model is only used when the normal answer checker cannot confirm a translation. Your answers stay on your iPhone; the one-time model download comes from Hugging Face.")
                    .font(.custom("Fredoka-Regular", size: 13))
                    .foregroundStyle(Color.lingoMuted)

            } header: {
                Text("Answer checking")
                    .font(.custom("Fredoka-SemiBold", size: 13))
            }

            // MARK: - Audio & hints

            Section {
                Toggle(isOn: $settings.soundEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Sound")
                            .font(.custom("Fredoka-Regular", size: 16))
                        Text("Turn off all app audio while testing")
                            .font(.custom("Fredoka-Regular", size: 13))
                            .foregroundStyle(Color.lingoMuted)
                    }
                }

                Toggle(isOn: $settings.elevenLabsEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Use ElevenLabs for Arabic")
                            .font(.custom("Fredoka-Regular", size: 16))
                        Text("Off uses the free Apple Arabic voice")
                            .font(.custom("Fredoka-Regular", size: 13))
                            .foregroundStyle(Color.lingoMuted)
                    }
                }

                Toggle(isOn: $settings.autoplayAudio) {
                    Text("Auto-play listening questions")
                        .font(.custom("Fredoka-Regular", size: 16))
                }

                Toggle(isOn: $settings.soundEffectsEnabled) {
                    Text("Sound effects")
                        .font(.custom("Fredoka-Regular", size: 16))
                }

                Toggle(isOn: $settings.showLemmaHints) {
                    Text("Show lemma/chunk hints")
                        .font(.custom("Fredoka-Regular", size: 16))
                }

                Toggle(isOn: $settings.hapticsEnabled) {
                    Text("Haptic feedback")
                        .font(.custom("Fredoka-Regular", size: 16))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Speech speed")
                        .font(.custom("Fredoka-Regular", size: 16))

                    Slider(
                        value: $settings.speechRate,
                        in: 0.35...0.58
                    )
                }

            } header: {
                Text("Audio & hints")
                    .font(.custom("Fredoka-SemiBold", size: 13))
            }

            // MARK: - Hearts

            Section {
                Toggle(isOn: $settings.heartsEnabled) {
                    Text("Use hearts in lessons")
                        .font(.custom("Fredoka-Regular", size: 16))
                }

                if settings.heartsEnabled {
                    HStack {
                        Label(
                            "\(progress.hearts) / 5",
                            systemImage: "heart.fill"
                        )
                        .font(.custom("Fredoka-Medium", size: 16))
                        .foregroundStyle(.red)

                        Spacer()

                        Button {
                            progress.refillHearts()
                        } label: {
                            Text("Refill")
                                .font(.custom("Fredoka-Medium", size: 16))
                        }
                        .disabled(progress.hearts == 5)
                    }

                    if progress.hearts < 5 {
                        Button {
                            _ = progress.buyHeart()
                        } label: {
                            Text("Buy +1 heart for 100 XP")
                                .font(.custom("Fredoka-Medium", size: 16))
                        }
                        .disabled(progress.xp < 100)
                    }
                }

            } header: {
                Text("Hearts")
                    .font(.custom("Fredoka-SemiBold", size: 13))
            }

            // MARK: - Course

            Section {
                settingsRow(
                    title: "Current language",
                    value: "\(course.flag) \(course.title)"
                )

                settingsRow(
                    title: "Content",
                    value: "Rotating everyday topics"
                )

                settingsRow(
                    title: "Retention",
                    value: "FSRS spaced review"
                )

                settingsRow(
                    title: "Storage",
                    value: "On device"
                )

            } header: {
                Text("Course")
                    .font(.custom("Fredoka-SemiBold", size: 13))
            }

            // MARK: - Reset

            Section {
                Button {
                    settings.reset()
                } label: {
                    Text("Reset settings")
                        .font(.custom("Fredoka-Medium", size: 16))
                }

                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Text("Reset all progress")
                        .font(.custom("Fredoka-Medium", size: 16))
                }

            } header: {
                Text("Reset")
                    .font(.custom("Fredoka-SemiBold", size: 13))
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            localAIModel.refresh()
        }
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
            Text("This clears lesson completion, saved lesson position, FSRS retention history, XP, streaks, phrase mastery, bookmarks and hearts on this device.")
        }
    }

    private func runLocalAITest() {
        guard !aiTestIsRunning else { return }

        aiTestIsRunning = true
        aiColdResult = nil
        aiWarmResult = nil
        aiTestMessage = nil

        Task { @MainActor in
            await LocalLanguageJudge.shared.unload()

            let cold = await LocalLanguageJudge.shared.judge(
                language: "French",
                register: "informal everyday spoken French",
                english: "Now that is completely my thing.",
                reference: "Ça, c’est totalement mon truc.",
                learner: "Là, c’est vraiment mon truc.",
                context: ""
            )
            aiColdResult = cold

            if let error = cold.errorMessage {
                aiTestMessage = "Cold test failed: \(error)"
                aiTestIsRunning = false
                await LocalLanguageJudge.shared.unload()
                return
            }

            let warm = await LocalLanguageJudge.shared.judge(
                language: "French",
                register: "informal everyday spoken French",
                english: "Now that is completely my thing.",
                reference: "Ça, c’est totalement mon truc.",
                learner: "Là, c’est vraiment mon truc.",
                context: ""
            )
            aiWarmResult = warm

            if let error = warm.errorMessage {
                aiTestMessage = "Warm test failed: \(error)"
            } else if cold.verdict == "ACCEPT", warm.verdict == "ACCEPT" {
                aiTestMessage = "Both grades ran entirely on this iPhone. The warm number is the useful estimate for an already-loaded lesson model."
            } else {
                aiTestMessage = "The timing test completed, but this known natural alternative should be ACCEPT on both passes."
            }

            aiTestIsRunning = false
            await LocalLanguageJudge.shared.unload()
        }
    }

    private func benchmarkRow(title: String, result: LocalAIJudgeResult) -> some View {
        let accepted = result.verdict == "ACCEPT"
        return HStack(spacing: 10) {
            Image(systemName: accepted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(accepted ? Color.lingoCorrect : Color.lingoWrong)

            Text(title)
                .font(.custom("Fredoka-Medium", size: 15))

            Spacer()

            Text("\(result.verdict ?? "ERROR") · \(String(format: "%.1f", result.elapsedSeconds))s")
                .font(.custom("Fredoka-Medium", size: 15))
                .foregroundStyle(accepted ? Color.lingoCorrect : Color.lingoWrong)
        }
    }

    private func settingsRow(
        title: String,
        value: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.custom("Fredoka-Regular", size: 15))
                .foregroundStyle(Color.lingoInk)

            Spacer(minLength: 12)

            Text(value)
                .font(.custom("Fredoka-Medium", size: 15))
                .foregroundStyle(Color.lingoMuted)
                .multilineTextAlignment(.trailing)
        }
    }

    private func binding(for type: ExerciseType) -> Binding<Bool> {
        Binding(
            get: {
                settings.enabledExerciseTypes.contains(type)
            },
            set: { newValue in
                let contains =
                    settings.enabledExerciseTypes.contains(type)

                if newValue != contains {
                    settings.toggleExercise(type)
                }
            }
        )
    }
}
