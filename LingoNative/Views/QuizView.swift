import SwiftUI
import WebKit
import AVFoundation
import Foundation

struct QuizView: View {
    let session: QuizSession
    @ObservedObject var progress: ProgressStore
    @ObservedObject var settings: SettingsStore

    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: QuizViewModel
    @StateObject private var speaker = SpeechSynthesizer()
    @StateObject private var speechRecognizer = SpeechRecognizerService()
    @StateObject private var soundPlayer = FeedbackSoundPlayer()
    @State private var didRecordCompletion = false
    @State private var emergencyRefillPresentation: EmergencyRefillPresentation?
    @State private var showContextOverlay = false
    @State private var showExitConfirmation = false
    @State private var showEditorNoteEditor = false
    @State private var showEditorNoteOverlay = false
    @State private var editorNoteDraft = ""
    @FocusState private var answerFieldFocused: Bool
    @State private var speakingGraceDeadline: Date?
    @State private var speakingGraceWorkItem: DispatchWorkItem?
    @State private var speakingRecognisedIndices: Set<Int> = []

    private let speakingGraceSeconds: Double = 10

    private struct EmergencyRefillPresentation: Identifiable {
        let id = UUID()
        let session: QuizSession
    }

    init(session: QuizSession, progress: ProgressStore, settings: SettingsStore) {
        self.session = session
        self.progress = progress
        self.settings = settings
        let savedSession = session.completionNodeID.flatMap { progress.savedLessonSession(for: $0) }
        _viewModel = StateObject(
            wrappedValue: QuizViewModel(
                session: session,
                savedSession: savedSession,
                progressStore: progress
            )
        )
    }

    var body: some View {
        Group {
            if isEmergencyRefillReview && viewModel.mistakes >= 3 {
                emergencyRefillFailedView
            } else if viewModel.isFinished {
                completionView
                    .onAppear(perform: recordCompletionIfNeeded)
            } else if settings.heartsEnabled && progress.hearts == 0 && session.completionNodeID != nil {
                outOfHeartsView
            } else if let question = viewModel.currentQuestion {
                questionView(question)
                    .task(id: question.id) {
                        cancelSpeakingGrace()
                        speakingRecognisedIndices = []
                        speechRecognizer.stop()
                        showEditorNoteOverlay = false
                        showContextOverlay = false

                        let shouldAutoplayTargetLanguage =
                            !viewModel.isArabicPairMatchingBoard(question)
                            && (
                                question.direction == .foreignToEnglish
                                || question.type == .speaking
                                || question.type == .listening
                            || question.type == .listenWrite
                            )

                        if !settings.nonHeadphoneModeEnabled,
                           settings.autoplayAudio,
                           shouldAutoplayTargetLanguage {
                            try? await Task.sleep(nanoseconds: 250_000_000)
                            speaker.speak(
                                question.phrase.foreign,
                                course: session.course,
                                rate: settings.speechRate
                            )
                        }
                    }
            } else {
                ContentUnavailableView(
                    "No questions available",
                    systemImage: "questionmark.circle",
                    description: Text("There aren’t any phrases in this practice pool yet.")
                )
            }
        }
        .navigationBarBackButtonHidden(!viewModel.isFinished)
        .toolbar {
            if !viewModel.isFinished {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        speaker.stop()
                        speechRecognizer.stop()
                        viewModel.persistSnapshot(to: progress)
                        showExitConfirmation = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title3.weight(.black))
                            .foregroundStyle(Color.lingoMuted)
                            .frame(width: 32, height: 32)
                    }
                }

                ToolbarItem(placement: .principal) {
                    LessonProgressBar(
                        progress: viewModel.progress,
                        tint: session.course == .french ? Color.lingoBlue : Color.lingoGreen
                    )
                    .frame(width: 214, height: 12)
                }

                if settings.heartsEnabled {
                    ToolbarItem(placement: .topBarTrailing) {
                        Label(
                            isEmergencyRefillReview
                                ? "\(max(0, 3 - viewModel.mistakes))"
                                : "\(progress.hearts)",
                            systemImage: isEmergencyRefillReview
                                ? "xmark.circle.fill"
                                : "heart.fill"
                        )
                        .font(.custom("Fredoka-SemiBold", size: 17))
                        .foregroundStyle(isEmergencyRefillReview ? Color.lingoWrong : .red)
                    }
                }
            }
        }
        .sheet(isPresented: $showExitConfirmation) {
            exitConfirmationView
        }
        .fullScreenCover(item: $emergencyRefillPresentation) { presentation in
            NavigationStack {
                QuizView(
                    session: presentation.session,
                    progress: progress,
                    settings: settings
                )
            }
        }
        .sheet(isPresented: $showEditorNoteEditor) {
            editorNoteEditorSheet
        }
        .overlay {
            editorNoteOverlay
        }
        .overlay {
            contextOverlay
        
        }
        .onAppear {
            viewModel.persistSnapshot(to: progress)

            if settings.enhancedAnswerCheckingEnabled,
               FileManager.default.fileExists(atPath: LocalAIModelFiles.modelURL.path) {
                Task {
                    if let error = await LocalLanguageJudge.shared.prewarm() {
                        print("LingoNative AI prewarm failed: \(error)")
                    }
                }
            }
        }
        .onDisappear {
            Task {
                await LocalLanguageJudge.shared.unload()
            }
        }
        .onChange(of: speechRecognizer.transcript) { _, transcript in
            guard let question = viewModel.currentQuestion,
                  question.type == .speaking else { return }

            viewModel.useTranscript(transcript)

            if session.completionNodeID != nil {
                handleSpeakingTranscript(
                    transcript,
                    question: question
                )
            }

            viewModel.persistSnapshot(to: progress)
        }
        .onChange(of: viewModel.selectedAnswer) { _, _ in
            viewModel.persistSnapshot(to: progress)
        }
        .onChange(of: viewModel.typedAnswer) { _, _ in
            viewModel.persistSnapshot(to: progress)
        }
        .onChange(of: viewModel.selectedWordIndices) { _, _ in
            viewModel.persistSnapshot(to: progress)
        }
        .onChange(of: viewModel.status) { _, newValue in
            guard settings.soundEnabled && settings.soundEffectsEnabled else { return }
            switch newValue {
            case .correct: soundPlayer.playCorrect()
            case .wrong: soundPlayer.playWrong()
            case .unanswered: break
            }
        }
        .sensoryFeedback(trigger: viewModel.status) { _, newValue in
            guard settings.hapticsEnabled else { return nil }
            switch newValue {
            case .correct: return .success
            case .wrong: return .error
            case .unanswered: return nil
            }
        }
    }

    @ViewBuilder
    private func questionView(_ question: QuizQuestion) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                questionHeader(question)

                switch question.type {
                case .introduction:
                    introductionExercise(question)
                case .multipleChoice:
                    multipleChoiceExercise(question)
                case .typing:
                    typingExercise(question)
                case .wordBank:
                    wordBankExercise(question)
                case .fillBlank:
                    fillBlankExercise(question)
                case .listening:
                    listeningExercise(question)
                case .listenWrite:
                    listenAndWriteExercise(question)
                case .speaking:
                    speakingExercise(question)
                case .matching:
                    matchingExercise(question)
                case .lemma:
                    multipleChoiceExercise(question)
                }

                if question.type != .introduction,
                   !viewModel.isArabicPairMatchingBoard(question) {
                    lemmaHints(question)
                }
                Spacer(minLength: 90)
                    .id("quiz-feedback-bottom")
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom) {
            feedbackBar(question: question)
        }
            .onChange(of: viewModel.status) { _, newStatus in
                guard newStatus != .unanswered else { return }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        proxy.scrollTo("quiz-feedback-bottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    private func questionHeader(_ question: QuizQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {

                VStack(alignment: .leading, spacing: 7) {
                    Label(question.type.title.uppercased(), systemImage: question.type.systemImage)
                        .font(.custom("Fredoka-SemiBold", size: 12))
                        .foregroundStyle(
                            session.course == .french
                                ? Color.lingoBlue
                                : Color.lingoGreen
                        )

                    if !question.phrase.context
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty {

                        Button {
                            withAnimation(.easeOut(duration: 0.16)) {
                                showContextOverlay = true
                            }
                        } label: {
                            Image(systemName: "lightbulb.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(Color.lingoGold)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 7) {
                    Text("\(viewModel.currentIndex + 1) / \(viewModel.questions.count)")
                        .font(.custom("Fredoka-Regular", size: 13))
                        .foregroundStyle(Color.lingoMuted)

                    if settings.editorNote(
                        for: question.phrase,
                        course: session.course
                    ) != nil {

                        Button {
                            withAnimation(.easeOut(duration: 0.16)) {
                                showEditorNoteOverlay = true
                            }
                        } label: {
                            Image("editor_note")
                                .resizable()
                                .scaledToFill()
                                .frame(width: 60, height: 60)
                                .clipShape(
                                    RoundedRectangle(
                                        cornerRadius: 10,
                                        style: .continuous
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Text(instruction(for: question))
                .font(.custom("Fredoka-Medium", size: 24))
                .foregroundStyle(Color.lingoInk)

            Button {
                editorNoteDraft = settings.editorNote(
                    for: question.phrase,
                    course: session.course
                ) ?? ""
                showEditorNoteEditor = true
            } label: {
                Label("Editor's Note", systemImage: "square.and.pencil")
                    .font(.custom("Fredoka-Medium", size: 13))
                    .foregroundStyle(Color.lingoMuted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.white)
                    .clipShape(Capsule())
                    .overlay {
                        Capsule()
                            .stroke(Color.lingoLine, lineWidth: 1.5)
                    }
            }
            .buttonStyle(.plain)

            if shouldShowPrompt(question) {
                characterPrompt(question)
            }
        }
    }

    private var editorNoteEditorSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if let question = viewModel.currentQuestion {
                    HStack(spacing: 12) {
                        Image("editor_note")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 58, height: 58)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Editor's Note")
                                .font(.custom("Fredoka-Medium", size: 21))
                                .foregroundStyle(Color.lingoInk)

                            Text(question.phrase.foreign)
                                .font(lessonTextFont(question.phrase.foreign, fredoka: "Fredoka-Regular", size: 15))
                                .foregroundStyle(Color.lingoMuted)
                                .lineLimit(2)
                        }
                    }
                }

                Text("Add anything you want to remember about this phrase — nuance, register, grammar, usage, or a comparison.")
                    .font(.custom("Fredoka-Regular", size: 15))
                    .foregroundStyle(Color.lingoMuted)

                TextEditor(text: $editorNoteDraft)
                    .font(.custom("Fredoka-Regular", size: 17))
                    .foregroundStyle(Color.lingoInk)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .frame(minHeight: 180)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.lingoLine, lineWidth: 2)
                    }

                Spacer()
            }
            .padding(20)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showEditorNoteEditor = false
                    }
                    .font(.custom("Fredoka-Medium", size: 16))
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        if let question = viewModel.currentQuestion {
                            settings.setEditorNote(
                                editorNoteDraft,
                                for: question.phrase,
                                course: session.course
                            )
                        }
                        showEditorNoteEditor = false
                    }
                    .font(.custom("Fredoka-Medium", size: 16))
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
            
            @ViewBuilder
            private var contextOverlay: some View {
                if showContextOverlay,
                   let question = viewModel.currentQuestion {

                    let context = question.phrase.context
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    if !context.isEmpty {
                        ZStack {
                            Color.black.opacity(0.18)
                                .ignoresSafeArea()

                            VStack {
                                Spacer(minLength: 90)

                                HStack(alignment: .top, spacing: 14) {

                                    Image(systemName: "lightbulb.fill")
                                        .font(.system(size: 34))
                                        .foregroundStyle(Color.lingoGold)
                                        .frame(width: 54, height: 54)

                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("CONTEXT")
                                            .font(.custom("Fredoka-SemiBold", size: 12))
                                            .tracking(1)
                                            .foregroundStyle(Color.lingoMuted)

                                        Text(context)
                                            .font(.custom("Fredoka-Regular", size: 17))
                                            .foregroundStyle(Color.lingoInk)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }

                                    Spacer(minLength: 0)
                                }
                                .padding(18)
                                .background(Color.white)
                                .clipShape(
                                    RoundedRectangle(
                                        cornerRadius: 20,
                                        style: .continuous
                                    )
                                )
                                .overlay {
                                    RoundedRectangle(
                                        cornerRadius: 20,
                                        style: .continuous
                                    )
                                    .stroke(Color.lingoLine, lineWidth: 2)
                                }
                                .shadow(
                                    color: .black.opacity(0.14),
                                    radius: 18,
                                    y: 8
                                )
                                .padding(.horizontal, 24)

                                Spacer()
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.16)) {
                                showContextOverlay = false
                            }
                        }
                        .transition(.opacity)
                    }
                }
            }

    @ViewBuilder
    private var editorNoteOverlay: some View {
        if showEditorNoteOverlay,
           let question = viewModel.currentQuestion,
           let note = settings.editorNote(for: question.phrase, course: session.course) {
            ZStack {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()

                VStack {
                    Spacer(minLength: 90)

                    HStack(alignment: .top, spacing: 14) {
                        Image("editor_note")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 66, height: 66)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                        VStack(alignment: .leading, spacing: 8) {
                            Text("EDITOR'S NOTE")
                                .font(.custom("Fredoka-SemiBold", size: 12))
                                .tracking(1)
                                .foregroundStyle(Color.lingoMuted)

                            Text(note)
                                .font(.custom("Fredoka-Regular", size: 17))
                                .foregroundStyle(Color.lingoInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(18)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.lingoLine, lineWidth: 2)
                    }
                    .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
                    .padding(.horizontal, 24)

                    Spacer()
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.16)) {
                    showEditorNoteOverlay = false
                    showContextOverlay = false
                }
            }
            .transition(.opacity)
        }
    }

    // MARK: Arabic transliteration presentation
    private func lessonTextFont(
        _ text: String,
        fredoka: String,
        size: CGFloat
    ) -> Font {
        if session.course == .arabic && containsArabicScript(text) {
            return .custom("NotoSansArabic-Regular", size: size)
        }
        return .custom(fredoka, size: size)
    }

    private func containsArabicScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x0600...0x06FF).contains(value)
                || (0x0750...0x077F).contains(value)
                || (0x08A0...0x08FF).contains(value)
                || (0xFB50...0xFDFF).contains(value)
                || (0xFE70...0xFEFF).contains(value)
        }
    }

    private func characterPrompt(_ question: QuizQuestion) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            RemoteSVGView(url: character(for: question).url)
                .frame(width: 72, height: 92)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 10) {
                    Text(question.prompt)
                        .font(lessonTextFont(question.prompt, fredoka: "Fredoka-Light", size: 20))
                        .foregroundStyle(Color.lingoInk)
                        .fixedSize(horizontal: false, vertical: true)

                    if question.direction == .foreignToEnglish && question.type != .listening {
                        Button {
                            speaker.speak(
                                question.phrase.foreign,
                                course: session.course,
                                rate: settings.speechRate
                            )
                        } label: {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.headline)
                                .foregroundStyle(Color.lingoBlue)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    SpeechBubble(radius: 16)
                        .fill(Color.white)
                }
                .overlay {
                    SpeechBubble(radius: 16)
                        .stroke(Color.lingoLine, lineWidth: 2)
                }
                .shadow(
                    color: .black.opacity(0.07),
                    radius: 0,
                    y: 2
                )

                if session.course == .arabic,
                   question.direction == .foreignToEnglish,
                   let transliteration = question.phrase.transliteration,
                   !transliteration.isEmpty {
                    Text(transliteration)
                        .font(.custom("Fredoka-Regular", size: 14))
                        .foregroundStyle(Color.lingoMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 15)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func character(for question: QuizQuestion) -> AppLessonCharacter {
        let total = question.id.uuidString.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        let characters = AppLessonCharacter.allCases
        return characters[total % characters.count]
    }

    private func instruction(for question: QuizQuestion) -> String {
        if viewModel.isArabicConjugationCheckpoint(question) {
            return "Match the conjugations"
        }
        if viewModel.isArabicLemmaCheckpoint(question) {
            return "Match the recent chunks"
        }

        switch question.type {
        case .introduction: return "Meet this phrase"
        case .multipleChoice:
            return question.direction == .foreignToEnglish ? "What does this mean?" : "Choose the \(session.course.title) translation"
        case .typing: return "Translate into \(session.course.title)"
        case .wordBank:
            return question.direction == .foreignToEnglish
                ? "Build the English translation"
                : "Build the \(session.course.title) sentence"
        case .fillBlank: return "Fill in the missing word"
        case .listening:
            return question.wordBankTokens.isEmpty
                ? "Type what you hear"
                : "Listen, then build the sentence"
        case .listenWrite: return "Listen and write what you hear"
        case .speaking: return "Say this in \(session.course.title)"
        case .matching: return "Tap the matching translation"
        case .lemma: return "What does this chunk mean?"
        }
    }

    private func shouldShowPrompt(_ question: QuizQuestion) -> Bool {
        if viewModel.isArabicPairMatchingBoard(question) {
            return false
        }

        switch question.type {
        case .introduction, .listening, .listenWrite: return false
        default: return true
        }
    }

    private func introductionExercise(_ question: QuizQuestion) -> some View {
        VStack(spacing: 18) {
            HStack(alignment: .bottom, spacing: 12) {
                RemoteSVGView(url: character(for: question).url)
                    .frame(width: 92, height: 118)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(question.phrase.foreign)
                                .font(lessonTextFont(question.phrase.foreign, fredoka: "Fredoka-Medium", size: 24))
                                .foregroundStyle(Color.lingoInk)
                                .fixedSize(horizontal: false, vertical: true)

                            if session.course == .arabic,
                               let transliteration = question.phrase.transliteration,
                               !transliteration.isEmpty {
                                Text(transliteration)
                                    .font(.custom("Fredoka-Regular", size: 14))
                                    .foregroundStyle(Color.lingoMuted)
                            }
                        }
                        Spacer(minLength: 8)
                        Button {
                            speaker.speak(question.phrase.foreign, course: session.course, rate: settings.speechRate)
                        } label: {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(Color.lingoBlue)
                        }
                        .buttonStyle(.plain)
                    }

                    Text(question.phrase.english)
                        .font(.custom("Fredoka-Regular", size: 17))
                        .foregroundStyle(Color.lingoMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.lingoLine, lineWidth: 2)
                }
            }

            if !question.phrase.context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label(question.phrase.context, systemImage: "text.bubble.fill")
                    .font(.custom("Fredoka-Regular", size: 15))
                    .foregroundStyle(Color.lingoInk)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.lingoBlue.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            if !question.phrase.lemmas.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("USEFUL CHUNKS")
                        .font(.custom("Fredoka-SemiBold", size: 12))
                        .tracking(1)
                        .foregroundStyle(Color.lingoMuted)
                    ForEach(question.phrase.lemmas.prefix(4)) { lemma in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(lemma.foreign)
                                    .font(lessonTextFont(lemma.foreign, fredoka: "Fredoka-Medium", size: 15))

                                if session.course == .arabic,
                                   let transliteration = lemma.transliteration,
                                   !transliteration.isEmpty {
                                    Text(transliteration)
                                        .font(.custom("Fredoka-Regular", size: 12))
                                        .foregroundStyle(Color.lingoMuted)
                                }
                            }
                            Spacer()
                            Text(lemma.english)
                                .font(.custom("Fredoka-Regular", size: 13))
                                .foregroundStyle(Color.lingoMuted)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                .padding(14)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private func multipleChoiceExercise(_ question: QuizQuestion) -> some View {
        VStack(spacing: 13) {
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                answerRow(option: option, index: index, question: question)
            }
        }
    }

    @ViewBuilder
    private func matchingExercise(_ question: QuizQuestion) -> some View {
        if viewModel.isArabicConjugationCheckpoint(question) {
            arabicConjugationMatchingExercise(question)
        } else if viewModel.isArabicLemmaCheckpoint(question) {
            arabicLemmaMatchingExercise(question)
        } else {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    let selected = viewModel.selectedAnswer == option
                    let isCorrect = QuizViewModel.answersMatch(option, question.correctAnswer)
                    let border: Color = {
                        switch viewModel.status {
                        case .unanswered: return selected ? Color.lingoBlue : Color.lingoLine
                        case .correct: return isCorrect ? Color.lingoCorrect : Color.lingoLine
                        case .wrong:
                            if selected { return .lingoWrong }
                            return isCorrect ? Color.lingoCorrect : Color.lingoLine
                        }
                    }()

                    Button {
                        viewModel.select(option)
                    } label: {
                        VStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.custom("Fredoka-SemiBold", size: 12))
                                .foregroundStyle(selected ? .white : Color.lingoMuted)
                                .frame(width: 30, height: 30)
                                .background(selected ? Color.lingoBlue : Color(.systemGray6))
                                .clipShape(Circle())

                            Text(option)
                                .font(lessonTextFont(option, fredoka: "Fredoka-Medium", size: 17))
                                .foregroundStyle(Color.lingoInk)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, minHeight: 78)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, minHeight: 144)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(border, lineWidth: selected || viewModel.status != .unanswered ? 3 : 2)
                        }
                    }
                    .buttonStyle(TactileCardButtonStyle())
                    .disabled(viewModel.status != .unanswered || viewModel.isCheckingAlternative)
                }
            }
        }
    }

    private func arabicConjugationMatchingExercise(_ question: QuizQuestion) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(question.phrase.foreign)
                    .font(.custom("NotoSansArabic-Regular", size: 27))
                    .foregroundStyle(Color.lingoInk)
                    .environment(\.layoutDirection, .rightToLeft)

                Text(question.phrase.english)
                    .font(.custom("Fredoka-Medium", size: 17))
                    .foregroundStyle(Color.lingoMuted)
            }

            Text(question.phrase.topicTitle.uppercased())
                .font(.custom("Fredoka-SemiBold", size: 12))
                .tracking(0.8)
                .foregroundStyle(Color.lingoPurple)

            if let usedWith = question.blankedText,
               !usedWith.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(usedWith)
                    .font(.custom("NotoSansArabic-Regular", size: 13))
                    .foregroundStyle(Color.lingoMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.lingoGold.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            arabicLemmaMatchingExercise(question)
        }
    }

    private func arabicLemmaMatchingExercise(_ question: QuizQuestion) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 9) {
                ForEach(question.wordBankTokens.indices, id: \.self) { index in
                    let foreign = question.wordBankTokens[index]
                    let matched = viewModel.selectedWordIndices.contains(index)
                    let selected = viewModel.matchingLeftSelection == index
                    let wrong = viewModel.matchingWrongLeftIndex == index
                    let transliteration = arabicMatchingTransliteration(
                        for: foreign,
                        question: question
                    )

                    Button {
                        viewModel.selectArabicLemmaMatchLeft(
                            index: index,
                            progressStore: progress
                        )
                    } label: {
                        VStack(spacing: 0) {
                            Text(foreign)
                                .font(.custom("NotoSansArabic-Regular", size: 19))
                                .foregroundStyle(Color.lingoInk)
                                .multilineTextAlignment(.center)
                                .environment(\.layoutDirection, .rightToLeft)

                            if let transliteration, !transliteration.isEmpty {
                                Text(transliteration)
                                    .font(.custom("Fredoka-Regular", size: 10.5))
                                    .foregroundStyle(
                                        Color(red: 0.32, green: 0.32, blue: 0.32)
                                    )
                                    .multilineTextAlignment(.center)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.72)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .background(selected ? Color.lingoBlue.opacity(0.10) : Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(
                                    wrong ? Color.lingoWrong : (selected ? Color.lingoBlue : Color.lingoLine),
                                    lineWidth: wrong || selected ? 3 : 2
                                )
                        }
                    }
                    .buttonStyle(TactileCardButtonStyle())
                    .opacity(matched ? 0 : 1)
                    .allowsHitTesting(!matched && viewModel.status == .unanswered)
                }
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 9) {
                ForEach(question.options.indices, id: \.self) { index in
                    let english = question.options[index]
                    let matched = arabicLemmaEnglishIsMatched(
                        question: question,
                        english: english
                    )
                    let selected = viewModel.matchingRightSelection == index
                    let wrong = viewModel.matchingWrongRightIndex == index

                    Button {
                        viewModel.selectArabicLemmaMatchRight(
                            index: index,
                            progressStore: progress
                        )
                    } label: {
                        Text(english)
                            .font(.custom("Fredoka-Medium", size: 14))
                            .foregroundStyle(Color.lingoInk)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, minHeight: 58)
                            .background(selected ? Color.lingoBlue.opacity(0.10) : Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(
                                        wrong ? Color.lingoWrong : (selected ? Color.lingoBlue : Color.lingoLine),
                                        lineWidth: wrong || selected ? 3 : 2
                                    )
                            }
                    }
                    .buttonStyle(TactileCardButtonStyle())
                    .opacity(matched ? 0 : 1)
                    .allowsHitTesting(!matched && viewModel.status == .unanswered)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// Prefer curated corpus transliteration. Conjugation forms currently
    /// contain Arabic + English only, so use Foundation's local Arabic→Latin
    /// transliteration as a zero-network fallback.
    /// Arabic matching cards use only transliteration stored in the data.
    /// Lemma matching reads the phrase corpus; conjugation matching reads
    /// lebanese_200_verbs.json. No machine transliteration fallback.
    private func arabicMatchingTransliteration(
        for foreign: String,
        question: QuizQuestion
    ) -> String? {
        let transliteration = question.phrase.lemmas.first(where: {
            $0.foreign == foreign
        })?.transliteration?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let transliteration, !transliteration.isEmpty else { return nil }
        return transliteration
    }

    private func arabicLemmaEnglishIsMatched(
        question: QuizQuestion,
        english: String
    ) -> Bool {
        guard let lemma = question.phrase.lemmas.first(where: { $0.english == english }),
              let leftIndex = question.wordBankTokens.firstIndex(of: lemma.foreign) else {
            return false
        }
        return viewModel.selectedWordIndices.contains(leftIndex)
    }

    private func typingExercise(_ question: QuizQuestion) -> some View {
        VStack(spacing: 14) {
            if session.course == .arabic && question.direction == .englishToForeign {
                Text(viewModel.typedAnswer.isEmpty ? "Your answer…" : viewModel.typedAnswer)
                    .font(
                        viewModel.typedAnswer.isEmpty
                            ? .custom("Fredoka-Regular", size: 18)
                            : .custom("NotoSansArabic-Regular", size: 24)
                    )
                    .foregroundStyle(
                        viewModel.typedAnswer.isEmpty
                            ? Color.lingoMuted
                            : Color.lingoInk
                    )
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, minHeight: 58, alignment: .trailing)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.lingoLine, lineWidth: 2)
                    }
                    .environment(\.layoutDirection, .rightToLeft)

                Button {
                speaker.stop()
                speaker.speak(
                    question.phrase.foreign,
                    course: session.course,
                    rate: settings.speechRate
                )
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2.fill")
                    Text("HEAR IT")
                }
                .font(.custom("Fredoka-Medium", size: 15))
                .foregroundStyle(
                    settings.soundEnabled
                        ? Color.lingoBlue
                        : Color.lingoMuted
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color.white)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 13,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: 13,
                        style: .continuous
                    )
                    .stroke(Color.lingoLine, lineWidth: 2)
                }
            }
            .buttonStyle(TactileCardButtonStyle())
            .disabled(
                viewModel.status != .unanswered
                    || viewModel.isCheckingAlternative
                    || !settings.soundEnabled
            )
            .accessibilityLabel("Hear Arabic sentence")

            arabicWriteKeyboard
            } else {
                TextField("Type your answer", text: $viewModel.typedAnswer, axis: .vertical)
                    .font(.custom("Fredoka-Regular", size: 17))
                    .foregroundColor(Color.lingoInk)
                    .tint(Color.lingoBlue)
                    .environment(\.colorScheme, .light)
                    .padding(16)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.lingoLine, lineWidth: 2)
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($answerFieldFocused)
                    .disabled(viewModel.status != .unanswered || viewModel.isCheckingAlternative)
            }
        }
    }

    private var arabicWriteKeyboard: some View {
        let rows = [
            ["ض", "ص", "ث", "ق", "ف", "غ", "ع", "ه", "خ", "ح", "ج", "د"],
            ["ش", "س", "ي", "ب", "ل", "ا", "ت", "ن", "م", "ك", "ط"],
            ["ئ", "ء", "ؤ", "ر", "ى", "ة", "و", "ز", "ظ"]
        ]
        let extraKeys = ["أ", "إ", "آ", "ذ"]

        return VStack(spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 4) {
                    ForEach(row, id: \.self) { key in
                        arabicKeyboardKey(key)
                    }
                }
            }

            HStack(spacing: 6) {
                Spacer(minLength: 0)
                ForEach(extraKeys, id: \.self) { key in
                    arabicKeyboardKey(key)
                        .frame(width: 52)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 7) {
                Button {
                    deleteArabicCharacter()
                } label: {
                    Image(systemName: "delete.left.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.lingoInk)
                        .frame(width: 58, height: 44)
                        .background(Color(.systemGray5))
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(TactileCardButtonStyle())
                .disabled(
                    viewModel.status != .unanswered
                        || viewModel.isCheckingAlternative
                        || viewModel.typedAnswer.isEmpty
                )

                Button {
                    appendArabicSpace()
                } label: {
                    Text("SPACE")
                        .font(.custom("Fredoka-Medium", size: 13))
                        .tracking(0.8)
                        .foregroundStyle(Color.lingoInk)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(Color.lingoLine, lineWidth: 1.5)
                        }
                }
                .buttonStyle(TactileCardButtonStyle())
                .disabled(
                    viewModel.status != .unanswered
                        || viewModel.isCheckingAlternative
                        || viewModel.typedAnswer.isEmpty
                        || viewModel.typedAnswer.hasSuffix(" ")
                )
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.lingoLine, lineWidth: 1.5)
        }
    }

    private func arabicKeyboardKey(_ key: String) -> some View {
        Button {
            appendArabicKey(key)
        } label: {
            Text(key)
                .font(.custom("NotoSansArabic-Medium", size: 20))
                .foregroundStyle(Color.lingoInk)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, minHeight: 43)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.lingoLine, lineWidth: 1.5)
                }
        }
        .buttonStyle(TactileCardButtonStyle())
        .disabled(viewModel.status != .unanswered || viewModel.isCheckingAlternative)
    }

    private func appendArabicKey(_ key: String) {
        guard viewModel.status == .unanswered,
              !viewModel.isCheckingAlternative else { return }
        viewModel.typedAnswer.append(contentsOf: key)
    }

    private func appendArabicSpace() {
        guard viewModel.status == .unanswered,
              !viewModel.isCheckingAlternative,
              !viewModel.typedAnswer.isEmpty,
              !viewModel.typedAnswer.hasSuffix(" ") else { return }
        viewModel.typedAnswer.append(" ")
    }

    private func deleteArabicCharacter() {
        guard viewModel.status == .unanswered,
              !viewModel.isCheckingAlternative,
              !viewModel.typedAnswer.isEmpty else { return }
        viewModel.typedAnswer.removeLast()
    }

    private func wordBankExercise(_ question: QuizQuestion) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("DRAG OR TAP WORDS INTO PLACE")
                    .font(.custom("Fredoka-SemiBold", size: 12))
                    .tracking(1)
                    .foregroundStyle(Color.lingoMuted)
                Spacer()
                if !viewModel.selectedWordIndices.isEmpty && viewModel.status == .unanswered {
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            viewModel.clearWordBank()
                        }
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                            .font(.custom("Fredoka-Medium", size: 13))
                    }
                    .buttonStyle(.plain)
                }
            }

            ZStack(alignment: .topLeading) {
                VStack(spacing: 54) {
                    Divider()
                    Divider()
                    Divider()
                }
                .padding(.top, 47)

                if viewModel.selectedWordIndices.isEmpty {
                    Text("Drop words here…")
                        .font(.custom("Fredoka-Regular", size: 16))
                        .foregroundStyle(Color.lingoMuted)
                        .padding(.top, 12)
                        .padding(.leading, 4)
                }

                TokenFlowLayout(
                    spacing: 8,
                    isRightToLeft: session.course == .arabic && question.direction == .englishToForeign
                ) {
                    ForEach(viewModel.selectedWordIndices, id: \.self) { index in
                        answerToken(question: question, index: index)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            .padding(12)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.lingoLine, lineWidth: 2)
            }
            .dropDestination(for: String.self) { items, _ in
                guard viewModel.status == .unanswered,
                      let payload = items.first,
                      let index = wordIndex(from: payload) else { return false }
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    viewModel.placeWordAtEnd(index: index)
                }
                return true
            }

            TokenFlowLayout(
                spacing: 8,
                isRightToLeft: session.course == .arabic && question.direction == .englishToForeign
            ) {
                ForEach(question.wordBankTokens.indices, id: \.self) { index in
                    if !viewModel.selectedWordIndices.contains(index) {
                        bankToken(question: question, index: index)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .dropDestination(for: String.self) { items, _ in
                guard viewModel.status == .unanswered,
                      let payload = items.first,
                      let index = wordIndex(from: payload) else { return false }
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    viewModel.returnWordToBank(index: index)
                }
                return true
            }

            if session.course == .arabic,
               question.direction == .englishToForeign {
                let transliterations = question.wordBankTokens.compactMap {
                    question.phrase.transliteration(forForeignToken: $0)
                }

                if !transliterations.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("TRANSLITERATION")
                            .font(.custom("Fredoka-SemiBold", size: 11))
                            .tracking(1)
                            .foregroundStyle(Color.lingoMuted)

                        TokenFlowLayout(spacing: 8, isRightToLeft: true) {
                            ForEach(question.wordBankTokens.indices, id: \.self) { index in
                                if let transliteration = question.phrase.transliteration(
                                    forForeignToken: question.wordBankTokens[index]
                                ) {
                                    Text(transliteration)
                                        .font(.custom("Fredoka-Regular", size: 14))
                                        .foregroundStyle(Color.lingoMuted)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(Color.white)
                                        .clipShape(
                                            RoundedRectangle(
                                                cornerRadius: 10,
                                                style: .continuous
                                            )
                                        )
                                        .overlay {
                                            RoundedRectangle(
                                                cornerRadius: 10,
                                                style: .continuous
                                            )
                                            .stroke(
                                                Color.lingoLine.opacity(0.85),
                                                lineWidth: 1.5
                                            )
                                        }
                                }
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: 16,
                            style: .continuous
                        )
                    )
                }
            }
        }
    }

    private func bankToken(question: QuizQuestion, index: Int) -> some View {
        Button {
            // Target-language tokens can be spoken with the course voice.
            // English comprehension tokens stay silent rather than using the wrong voice.
            if question.direction == .englishToForeign && session.course != .arabic {
                speaker.speak(
                    question.wordBankTokens[index],
                    course: session.course,
                    rate: settings.speechRate
                )
            }

            // Move it into the answer
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                viewModel.placeWordAtEnd(index: index)
            }
        } label: {
            tokenLabel(
                question.wordBankTokens[index],
                selected: false
            )
        }
        .buttonStyle(TactileCardButtonStyle())
        .disabled(viewModel.status != .unanswered || viewModel.isCheckingAlternative)
        .draggable(wordPayload(index))
    }

    private func answerToken(question: QuizQuestion, index: Int) -> some View {
        Button {
            // Target-language tokens can be spoken with the course voice.
            // English comprehension tokens stay silent rather than using the wrong voice.
            if question.direction == .englishToForeign && session.course != .arabic {
                speaker.speak(
                    question.wordBankTokens[index],
                    course: session.course,
                    rate: settings.speechRate
                )
            }

            // Return it to the word bank
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                viewModel.returnWordToBank(index: index)
            }
        } label: {
            tokenLabel(
                question.wordBankTokens[index],
                selected: true
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.status != .unanswered || viewModel.isCheckingAlternative)
        .draggable(wordPayload(index))
        .dropDestination(for: String.self) { items, _ in
            guard viewModel.status == .unanswered,
                  let payload = items.first,
                  let draggedIndex = wordIndex(from: payload) else {
                return false
            }

            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                viewModel.moveWord(
                    index: draggedIndex,
                    before: index
                )
            }

            return true
        }
    }

    private func tokenLabel(_ text: String, selected: Bool) -> some View {
        Text(text)
            .font(lessonTextFont(text, fredoka: "Fredoka-Medium", size: 16))
            .foregroundStyle(Color.lingoInk)
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(selected ? Color.lingoBlue.opacity(0.10) : Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? Color.lingoBlue : Color.lingoLine, lineWidth: 2)
            }
    }

    private func wordPayload(_ index: Int) -> String { "lingo-word:\(index)" }

    private func wordIndex(from payload: String) -> Int? {
        guard payload.hasPrefix("lingo-word:") else { return nil }
        return Int(payload.dropFirst("lingo-word:".count))
    }

    private func fillBlankExercise(_ question: QuizQuestion) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(question.blankedText ?? "____")
                .font(lessonTextFont(question.blankedText ?? "____", fredoka: "Fredoka-Medium", size: 20))
                .foregroundStyle(Color.lingoInk)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(spacing: 12) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    answerRow(option: option, index: index, question: question)
                }
            }
        }
    }

    private func listenAndWriteExercise(_ question: QuizQuestion) -> some View {
        VStack(spacing: 18) {
            Button {
                speaker.stop()
                speaker.speak(
                    question.phrase.foreign,
                    course: session.course,
                    rate: settings.speechRate
                )
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.lingoBlue.opacity(0.16))
                        .frame(width: 104, height: 104)

                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(Color.lingoBlue)
                }
            }
            .buttonStyle(TactileCardButtonStyle())
            .disabled(viewModel.status != .unanswered || viewModel.isCheckingAlternative)
            .accessibilityLabel("Play sentence")

            if session.course == .arabic {
                Text(viewModel.typedAnswer.isEmpty ? "Your answer…" : viewModel.typedAnswer)
                    .font(
                        viewModel.typedAnswer.isEmpty
                            ? .custom("Fredoka-Regular", size: 18)
                            : .custom("NotoSansArabic-Regular", size: 24)
                    )
                    .foregroundStyle(
                        viewModel.typedAnswer.isEmpty
                            ? Color.lingoMuted
                            : Color.lingoInk
                    )
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, minHeight: 58, alignment: .trailing)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.lingoLine, lineWidth: 2)
                    }
                    .environment(\.layoutDirection, .rightToLeft)

                arabicWriteKeyboard
            } else {
                TextField("Type what you hear", text: $viewModel.typedAnswer, axis: .vertical)
                    .font(.custom("Fredoka-Regular", size: 17))
                    .foregroundColor(Color.lingoInk)
                    .tint(Color.lingoBlue)
                    .environment(\.colorScheme, .light)
                    .padding(16)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.lingoLine, lineWidth: 2)
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($answerFieldFocused)
                    .disabled(viewModel.status != .unanswered || viewModel.isCheckingAlternative)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func listeningExercise(_ question: QuizQuestion) -> some View {
        VStack(spacing: 22) {
            RemoteSVGView(url: character(for: question).url)
                .frame(width: 96, height: 120)
                .accessibilityHidden(true)

            Button {
                speaker.speak(question.phrase.foreign, course: session.course, rate: settings.speechRate)
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color(red: 0.06, green: 0.47, blue: 0.69))
                        .frame(width: 118, height: 118)
                        .offset(y: 8)

                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color.lingoBlue)
                        .frame(width: 118, height: 118)
                        .overlay {
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .stroke(Color.white.opacity(0.16), lineWidth: 2)
                        }

                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 45, weight: .black))
                        .foregroundStyle(.white)
                }
                .padding(.bottom, 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play phrase")

            if question.wordBankTokens.isEmpty {
                TextField("Type what you hear", text: $viewModel.typedAnswer, axis: .vertical)
                    .font(.custom("Fredoka-Regular", size: 17))
                    .foregroundColor(Color.lingoInk)
                    .tint(Color.lingoBlue)
                    .environment(\.colorScheme, .light)
                    .padding(16)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.lingoLine, lineWidth: 2)
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($answerFieldFocused)
                    .disabled(viewModel.status != .unanswered || viewModel.isCheckingAlternative)
            } else {
                wordBankExercise(question)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func speakingExercise(_ question: QuizQuestion) -> some View {
        let visibleWords = cleanedSpeakingText(question.phrase.foreign)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        return VStack(spacing: 16) {

            // MARK: Recognised words

            TokenFlowLayout(
                spacing: 8,
                isRightToLeft: session.course == .arabic
            ) {
                ForEach(Array(visibleWords.enumerated()), id: \.offset) { index, word in
                    let recognised = speakingRecognisedIndices.contains(index)

                    Text(word)
                        .font(lessonTextFont(word, fredoka: "Fredoka-Medium", size: 21))
                        .foregroundStyle(
                            recognised
                                ? Color.lingoPurple
                                : Color.lingoInk
                        )
                        .padding(.horizontal, 5)
                        .padding(.vertical, 5)
                        .background(
                            recognised
                                ? Color.lingoPurple.opacity(0.14)
                                : Color.clear
                        )
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: 7,
                                style: .continuous
                            )
                        )
                        .overlay(alignment: .bottom) {
                            Path { path in
                                path.move(
                                    to: CGPoint(x: 0, y: 0.5)
                                )
                                path.addLine(
                                    to: CGPoint(x: 1000, y: 0.5)
                                )
                            }
                            .stroke(
                                recognised
                                    ? Color.lingoPurple
                                    : Color.lingoMuted.opacity(0.70),
                                style: StrokeStyle(
                                    lineWidth: 1,
                                    dash: [1.5, 3.0]
                                )
                            )
                            .frame(height: 1)
                            .clipped()
                            .offset(y: 4)
                        }
                }
            }
            .padding(18)
            .frame(
                maxWidth: .infinity,
                alignment: .leading
            )
            .background(
                Color.lingoPurple.opacity(0.06)
            )
            .background(.ultraThinMaterial)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 20,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: 20,
                    style: .continuous
                )
                .stroke(
                    Color.lingoPurple.opacity(0.30),
                    lineWidth: 2
                )
            }

            if speechRecognizer.isRecording {
                Label(
                    "Listening…",
                    systemImage: "waveform"
                )
                .font(.custom("Fredoka-Medium", size: 15))
                .foregroundStyle(Color.lingoPurple)
            }

            if speakingGraceDeadline != nil {
                Text("Keep going…")
                    .font(.custom("Fredoka-Medium", size: 15))
                    .foregroundStyle(Color.lingoPurple)
            }

            if viewModel.status == .unanswered,
               let error = speechRecognizer.errorMessage,
               error != "Recognition request was canceled" {

                Text(error)
                    .font(.custom("Fredoka-Regular", size: 13))
                    .foregroundStyle(Color.lingoWrong)
                    .multilineTextAlignment(.center)
            }

            Button {
                if speechRecognizer.isRecording {
                    speechRecognizer.stop()
                } else {
                    speaker.stop()

                    Task {
                        await speechRecognizer.start(
                            localeIdentifier:
                                session.course.speechLocaleIdentifier
                        )
                    }
                }
            } label: {
                HStack(spacing: 9) {
                    Image(
                        systemName:
                            speechRecognizer.isRecording
                                ? "stop.fill"
                                : "mic.fill"
                    )

                    Text(
                        speechRecognizer.isRecording
                            ? "STOP"
                            : "SPEAK"
                    )
                }
                .font(.custom("Fredoka-Medium", size: 17))
                .foregroundStyle(Color.lingoPurple)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    Color.lingoPurple.opacity(0.07)
                )
                .background(.ultraThinMaterial)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 18,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: 18,
                        style: .continuous
                    )
                    .stroke(
                        Color.lingoPurple.opacity(0.48),
                        lineWidth: 2
                    )
                }
            }
            .buttonStyle(.plain)
            .disabled(viewModel.status != .unanswered || viewModel.isCheckingAlternative)

            HStack(spacing: 12) {

                Button {
                    cancelSpeakingGrace()
                    speechRecognizer.stop()

                    speaker.speak(
                        question.phrase.foreign,
                        course: session.course,
                        rate: settings.speechRate
                    )
                } label: {
                    Label(
                        "Hear it",
                        systemImage: "speaker.wave.2.fill"
                    )
                    .font(.custom("Fredoka-Medium", size: 15))
                    .foregroundStyle(Color.lingoBlue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        Color.lingoBlue.opacity(0.06)
                    )
                    .background(.ultraThinMaterial)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: 18,
                            style: .continuous
                        )
                    )
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: 18,
                            style: .continuous
                        )
                        .stroke(
                            Color.lingoBlue.opacity(0.38),
                            lineWidth: 2
                        )
                    }
                }
                .buttonStyle(.plain)

                Button {
                    skipSpeakingAsCorrect()
                } label: {
                    Text("SKIP")
                        .font(.custom("Fredoka-Medium", size: 15))
                        .foregroundStyle(Color.lingoMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            Color(.systemGray6)
                        )
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: 18,
                                style: .continuous
                            )
                        )
                        .overlay {
                            RoundedRectangle(
                                cornerRadius: 18,
                                style: .continuous
                            )
                            .stroke(
                                Color(.systemGray4),
                                lineWidth: 2
                            )
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Speaking recognition

    /// Mirrors LanguageTrainer's SpeakView.handleTranscript(_:) matching flow:
    /// canonical target tokens + canonical transcript set + cumulative recognised
    /// indices + important-word success + 75% grace threshold.
    private func handleSpeakingTranscript(
        _ raw: String,
        question: QuizQuestion
    ) {
        guard viewModel.status == .unanswered else { return }

        let canonicalTokens =
            LessonSpeakNormalizer.sentenceCanonicalTokensAlignedToWords(
                cleanedSpeakingText(question.phrase.foreign),
                course: session.course
            )

        let heardSet =
            LessonSpeakNormalizer.transcriptTokenSet(
                raw,
                course: session.course
            )

        var newRecognised = speakingRecognisedIndices

        for (index, token) in canonicalTokens.enumerated() {
            guard !token.isEmpty else { continue }
            guard !newRecognised.contains(index) else { continue }

            if heardSet.contains(token) {
                newRecognised.insert(index)
            }
        }

        speakingRecognisedIndices = newRecognised

        let realIndices = canonicalTokens.indices.filter {
            !canonicalTokens[$0].isEmpty
        }

        let totalWords = realIndices.count

        guard totalWords > 0 else { return }

        let recognisedWords = realIndices.filter {
            speakingRecognisedIndices.contains($0)
        }.count

        let remainingWords = totalWords - recognisedWords

        if remainingWords == 0 {
            finishSpeakingRecognition()
            return
        }

        let allowedMissing = totalWords > 10 ? 2 : 1

        if speakingGraceWorkItem == nil,
           remainingWords <= allowedMissing {

            beginSpeakingGrace()
        }
    }

    private func finishSpeakingRecognition() {
        guard viewModel.status == .unanswered else { return }

        cancelSpeakingGrace()
        speechRecognizer.stop()

        viewModel.acceptSpeakingRecognition(
            progressStore: progress,
            settings: settings
        )
    }

    private func skipSpeakingAsCorrect() {
        guard viewModel.status == .unanswered else { return }

        cancelSpeakingGrace()
        speechRecognizer.stop()

        viewModel.acceptSpeakingRecognition(
            progressStore: progress,
            settings: settings
        )
    }

    private func beginSpeakingGrace() {
        guard speakingGraceWorkItem == nil else { return }

        speakingGraceDeadline =
            Date().addingTimeInterval(speakingGraceSeconds)

        let workItem = DispatchWorkItem {
            guard viewModel.status == .unanswered,
                  let question = viewModel.currentQuestion,
                  question.type == .speaking,
                  session.completionNodeID != nil else {

                speakingGraceWorkItem = nil
                speakingGraceDeadline = nil
                return
            }

            speakingGraceWorkItem = nil
            speakingGraceDeadline = nil

            speechRecognizer.stop()

            viewModel.acceptSpeakingRecognition(
                progressStore: progress,
                settings: settings
            )
        }

        speakingGraceWorkItem = workItem

        DispatchQueue.main.asyncAfter(
            deadline: .now() + speakingGraceSeconds,
            execute: workItem
        )
    }

    private func cancelSpeakingGrace() {
        speakingGraceWorkItem?.cancel()
        speakingGraceWorkItem = nil
        speakingGraceDeadline = nil
    }

    private func cleanedSpeakingText(_ text: String) -> String {
        var output = SpeechSynthesizer.stripParentheses(text)
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        output = output.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )

        return output
    }

    @ViewBuilder
    private func lemmaHints(_ question: QuizQuestion) -> some View {
        if settings.showLemmaHints && !question.phrase.lemmas.isEmpty && viewModel.status == .unanswered {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(question.phrase.lemmas) { lemma in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(lemma.foreign)
                                    .font(lessonTextFont(lemma.foreign, fredoka: "Fredoka-Medium", size: 15))

                                if session.course == .arabic,
                                   let transliteration = lemma.transliteration,
                                   !transliteration.isEmpty {
                                    Text(transliteration)
                                        .font(.custom("Fredoka-Regular", size: 12))
                                        .foregroundStyle(Color.lingoMuted)
                                }
                            }
                            Spacer()
                            Text(lemma.english)
                                .font(.custom("Fredoka-Regular", size: 13))
                                .foregroundStyle(Color.lingoMuted)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                Label("Hint: lemmas & chunks", systemImage: "lightbulb.fill")
                    .font(.custom("Fredoka-Medium", size: 15))
                    .foregroundStyle(Color.lingoGold)
            }
            .padding(14)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func answerRow(option: String, index: Int, question: QuizQuestion) -> some View {
        let selected = viewModel.selectedAnswer == option
        let isCorrect = QuizViewModel.answersMatch(option, question.correctAnswer)

        let border: Color = {
            switch viewModel.status {
            case .unanswered: return selected ? Color.lingoBlue : Color.lingoLine
            case .correct: return isCorrect ? Color.lingoCorrect : Color.lingoLine
            case .wrong:
                if selected { return .lingoWrong }
                if isCorrect { return .lingoCorrect }
                return .lingoLine
            }
        }()

        return Button {
            viewModel.select(option)
        } label: {
            HStack(alignment: .center, spacing: 14) {
                Text(String(UnicodeScalar(65 + index)!))
                    .font(.custom("Fredoka-SemiBold", size: 12))
                    .foregroundStyle(selected ? .white : Color.lingoMuted)
                    .frame(width: 32, height: 32)
                    .background(selected ? Color.lingoBlue : Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                Text(option)
                    .font(lessonTextFont(option, fredoka: "Fredoka-Medium", size: 17))
                    .foregroundStyle(Color.lingoInk)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(border, lineWidth: selected || viewModel.status != .unanswered ? 3 : 2)
            }
        }
        .buttonStyle(TactileCardButtonStyle())
        .disabled(viewModel.status != .unanswered || viewModel.isCheckingAlternative)
    }

    @ViewBuilder
    private func feedbackBar(question: QuizQuestion) -> some View {
        VStack(spacing: 12) {
            if viewModel.status == .correct {
                HStack(spacing: 12) {
                    RemoteSVGView(url: CloneVisualAsset.mascot.url)
                        .frame(width: 50, height: 50)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        if viewModel.isArabicConjugationCheckpoint(question) {
                            Text("Nicely done!")
                                .font(.custom("Fredoka-Medium", size: 17))

                            Text("Conjugations matched")
                                .font(.custom("Fredoka-Regular", size: 15))
                        } else if viewModel.isArabicLemmaCheckpoint(question) {
                            Text("Nicely done!")
                                .font(.custom("Fredoka-Medium", size: 17))

                            Text("Recent chunks matched")
                                .font(.custom("Fredoka-Regular", size: 15))
                        } else if viewModel.aiAlternativeAccepted {
                            Text("Correct")
                                .font(.custom("Fredoka-Medium", size: 17))

                            Text("Alternative answer:")
                                .font(.custom("Fredoka-Regular", size: 13))
                                .foregroundStyle(Color.lingoMuted)

                            Text(question.correctAnswer)
                                .font(lessonTextFont(question.correctAnswer, fredoka: "Fredoka-Medium", size: 15))
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(question.type == .introduction ? "Phrase introduced!" : "Nicely done!")
                                .font(.custom("Fredoka-Medium", size: 17))

                            Text(question.phrase.english)
                                .font(.custom("Fredoka-Regular", size: 15))
                        }
                    }

                    Spacer()

                    if !viewModel.isArabicPairMatchingBoard(question) {
                        Button {
                            speaker.speak(
                                question.phrase.foreign,
                                course: session.course,
                                rate: settings.speechRate
                            )
                        } label: {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .foregroundStyle(Color.lingoGreenDark)

            } else if viewModel.status == .wrong {
                HStack(alignment: .top, spacing: 12) {
                    RemoteSVGView(url: CloneVisualAsset.mascotBad.url)
                        .frame(width: 50, height: 50)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Not quite")
                            .font(.custom("Fredoka-Medium", size: 17))

                        Text("Correct answer:")
                            .font(.custom("Fredoka-Regular", size: 13))

                        Text(question.correctAnswer)
                            .font(lessonTextFont(question.correctAnswer, fredoka: "Fredoka-Medium", size: 15))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(Color.lingoWrong)
            }

            if viewModel.status == .unanswered {
                if viewModel.isCheckingAlternative {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Checking your alternative…")
                            .font(.custom("Fredoka-Regular", size: 14))
                            .foregroundStyle(Color.lingoMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !viewModel.isArabicPairMatchingBoard(question),
                   !(question.type == .speaking && session.completionNodeID != nil) {
                    Button(
                        question.type == .introduction
                            ? "GOT IT"
                            : (viewModel.isCheckingAlternative ? "CHECKING…" : "CHECK")
                    ) {
                        speechRecognizer.stop()
                        answerFieldFocused = false

                        if question.type == .introduction {
                            viewModel.acknowledgeIntroduction(
                                progressStore: progress
                            )
                        } else {
                            Task {
                                await viewModel.checkEnhanced(
                                    progressStore: progress,
                                    settings: settings
                                )
                            }
                        }
                    }
                    .font(.custom("Fredoka-Medium", size: 18))
                    .buttonStyle(DuoButtonStyle(
                        fill: viewModel.responseIsReady
                            ? Color.lingoGreen
                            : Color(.systemGray4),
                        shadow: viewModel.responseIsReady
                            ? Color.lingoGreenDark
                            : Color(.systemGray3)
                    ))
                    .disabled(!viewModel.responseIsReady || viewModel.isCheckingAlternative)
                }

            } else if viewModel.aiAlternativeAccepted {
                Button("I got this wrong") {
                    cancelSpeakingGrace()
                    speechRecognizer.stop()

                    viewModel.markAIAlternativeWrong(
                        progressStore: progress,
                        settings: settings
                    )
                    viewModel.continueAfterFeedback(progressStore: progress)
                }
                .font(.custom("Fredoka-Medium", size: 15))
                .foregroundStyle(Color.lingoWrong)
                .buttonStyle(.plain)
                .padding(.vertical, 4)

                Button("NEXT") {
                    cancelSpeakingGrace()
                    speechRecognizer.stop()

                    viewModel.confirmAIAlternativeCorrect(
                        progressStore: progress
                    )
                    viewModel.continueAfterFeedback(progressStore: progress)
                }
                .font(.custom("Fredoka-Medium", size: 18))
                .buttonStyle(DuoButtonStyle(
                    fill: Color.lingoGreen,
                    shadow: Color.lingoGreenDark
                ))

            } else if viewModel.canOverrideWrong {

                Button("I got this right") {
                    cancelSpeakingGrace()
                    speechRecognizer.stop()

                    viewModel.overridePendingWrongAsCorrect(
                        progressStore: progress
                    )
                }
                .font(.custom("Fredoka-Medium", size: 15))
                .foregroundStyle(Color.lingoGreenDark)
                .buttonStyle(.plain)
                .padding(.vertical, 4)

                Button("CONTINUE") {
                    cancelSpeakingGrace()
                    speechRecognizer.stop()

                    viewModel.confirmPendingWrong(
                        progressStore: progress,
                        settings: settings
                    )

                    viewModel.continueAfterFeedback(
                        progressStore: progress
                    )
                }
                .font(.custom("Fredoka-Medium", size: 18))
                .buttonStyle(DuoButtonStyle(
                    fill: Color.lingoWrong,
                    shadow: Color(red: 0.73, green: 0.20, blue: 0.20)
                ))
            } else {
                Button(viewModel.status == .wrong ? "CONTINUE" : "NEXT") {
                    cancelSpeakingGrace()
                    speechRecognizer.stop()
                    viewModel.continueAfterFeedback(progressStore: progress)
                }
                .font(.custom("Fredoka-Medium", size: 18))
                .buttonStyle(DuoButtonStyle(
                    fill: viewModel.status == .correct
                        ? Color.lingoGreen
                        : Color.lingoWrong,
                    shadow: viewModel.status == .correct
                        ? Color.lingoGreenDark
                        : Color(red: 0.73, green: 0.20, blue: 0.20)
                ))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(feedbackBackground)
        .overlay(alignment: .top) { Divider() }
    }

    private var feedbackBackground: Color {
        switch viewModel.status {
        case .correct: return Color.lingoCorrect.opacity(0.14)
        case .wrong: return Color.lingoWrong.opacity(0.10)
        case .unanswered: return Color(.systemBackground)
        }
    }

    private var completionView: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            ConfettiOverlay()

            VStack(spacing: 24) {
                Spacer()
                RemoteSVGView(url: CloneVisualAsset.finish.url)
                    .frame(width: 150, height: 150)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text(
                        isEmergencyRefillReview
                            ? "Hearts refilled!"
                            : (session.completionNodeID == nil ? "Practice complete!" : "Lesson complete!")
                    )
                        .font(.custom("Fredoka-Medium", size: 34))
                        .foregroundStyle(Color.lingoInk)
                    Text(completionMessage)
                        .font(.custom("Fredoka-Regular", size: 15))
                        .foregroundStyle(Color.lingoMuted)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 12) {
                    completionStatCard(title: "TOTAL XP", value: "+\(viewModel.earnedXP)", icon: "bolt.fill", tint: Color.lingoGold)
                    completionStatCard(title: "HEARTS", value: "\(progress.hearts)", icon: "heart.fill", tint: .red)
                }

                if viewModel.mistakes > 0 {
                    Label("\(viewModel.mistakes) mistake\(viewModel.mistakes == 1 ? "" : "s") rescheduled", systemImage: "brain.head.profile.fill")
                        .font(.custom("Fredoka-Medium", size: 15))
                        .foregroundStyle(Color.lingoWrong)
                }

                Spacer()
                Button("CONTINUE") { dismiss() }
                    .font(.custom("Fredoka-Medium", size: 18))
                    .buttonStyle(DuoButtonStyle())
            }
            .padding(24)
        }
    }

    private var completionMessage: String {
        if isEmergencyRefillReview {
            return "All 5 hearts are back."
        }
        if session.completionNodeID != nil {
            return "Nice work."
        }
        if session.title == PracticeMode.listening.title {
            return "Listening practice complete."
        }
        return "Practice complete."
    }

    private func completionStatCard(title: String, value: String, icon: String, tint: Color) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.custom("Fredoka-SemiBold", size: 12))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(tint)
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(value)
            }
            .font(.custom("Fredoka-Medium", size: 20))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(.white)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(tint, lineWidth: 2)
        }
    }

    private var isEmergencyRefillReview: Bool {
        session.completionNodeID == nil && session.title == "Emergency Refill"
    }

    private func startEmergencyRefillReview() {
        let currentPhraseIDs = Set(session.phrasePool.map(\.id))

        let learned = session.allPhrases.filter { phrase in
            progress.learningStage(course: session.course, phrase: phrase) != .unseen
        }

        let previousLessonMaterial = learned.filter { phrase in
            session.isUnitReview || !currentPhraseIDs.contains(phrase.id)
        }

        // Bootstrap safety: on a brand-new course there may literally be no earlier
        // lesson yet. In that one edge case, use already-introduced current material
        // rather than trapping the learner permanently at zero hearts.
        let eligible = previousLessonMaterial.isEmpty ? learned : previousLessonMaterial

        guard !eligible.isEmpty else {
            progress.refillHearts()
            return
        }

        let now = Date()
        let ranked = eligible.sorted { lhs, rhs in
            let left = progress.stats(course: session.course, phrase: lhs)
            let right = progress.stats(course: session.course, phrase: rhs)

            let leftRecentMiss = left.lastReviewWasCorrect == false
            let rightRecentMiss = right.lastReviewWasCorrect == false
            if leftRecentMiss != rightRecentMiss {
                return leftRecentMiss && !rightRecentMiss
            }

            let leftDue = left.memory?.isDue(at: now) ?? true
            let rightDue = right.memory?.isDue(at: now) ?? true
            if leftDue != rightDue {
                return leftDue && !rightDue
            }

            let leftRecall = left.recallProbability(at: now)
            let rightRecall = right.recallProbability(at: now)
            if abs(leftRecall - rightRecall) > 0.0001 {
                return leftRecall < rightRecall
            }

            if abs(left.accuracy - right.accuracy) > 0.0001 {
                return left.accuracy < right.accuracy
            }

            return left.wrong > right.wrong
        }

        let candidateCount = min(20, ranked.count)
        let candidateWindow = Array(ranked.prefix(candidateCount))
        let reviewCount = min(10, candidateWindow.count)
        let chosen = Array(candidateWindow.shuffled().prefix(reviewCount))

        let reviewSession = QuizSession(
            course: session.course,
            title: "Emergency Refill",
            subtitle: "Previous lessons · 3 strikes",
            phrasePool: chosen,
            allPhrases: session.allPhrases,
            sessionSize: max(1, chosen.count),
            exerciseTypes: session.exerciseTypes,
            completionNodeID: nil
        )

        // Item-based presentation is atomic: SwiftUI cannot present the cover
        // until it has the actual non-nil review session to render.
        emergencyRefillPresentation = EmergencyRefillPresentation(
            session: reviewSession
        )
    }

    private var emergencyRefillFailedView: some View {
        VStack(spacing: 22) {
            Spacer()

            RemoteSVGView(url: CloneVisualAsset.mascotBad.url)
                .frame(width: 120, height: 120)
                .accessibilityHidden(true)

            Text("Review failed")
                .font(.custom("Fredoka-Medium", size: 34))
                .foregroundStyle(Color.lingoInk)

            Text("Three mistakes — start the review again to refill all 5 hearts.")
                .font(.custom("Fredoka-Regular", size: 16))
                .foregroundStyle(Color.lingoMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 22)

            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { _ in
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.lingoWrong)
                }
            }

            Spacer()

            Button("TRY AGAIN") {
                speaker.stop()
                speechRecognizer.stop()
                viewModel.restartSession(progressStore: progress)
                didRecordCompletion = false
            }
            .font(.custom("Fredoka-Medium", size: 18))
            .buttonStyle(
                DuoButtonStyle(
                    fill: Color.lingoWrong,
                    shadow: Color(red: 0.72, green: 0.13, blue: 0.16)
                )
            )
        }
        .padding(24)
        .background(Color(.systemGroupedBackground))
    }

    private var outOfHeartsView: some View {
        VStack(spacing: 20) {
            Spacer()
            RemoteSVGView(url: CloneVisualAsset.mascotBad.url)
                .frame(width: 120, height: 120)
                .accessibilityHidden(true)
            Text("Out of hearts")
                .font(.custom("Fredoka-Medium", size: 34))
                .foregroundStyle(Color.lingoInk)
            Text("Spend XP for one heart, or complete a review of previous lessons to refill all 5. Three mistakes and the review starts again.")
                .font(.custom("Fredoka-Regular", size: 15))
                .foregroundStyle(Color.lingoMuted)
                .multilineTextAlignment(.center)

            if progress.xp >= 100 {
                Button("SPEND 100 XP · +1 HEART") { _ = progress.buyHeart() }
                    .font(.custom("Fredoka-Medium", size: 18))
                    .buttonStyle(DuoButtonStyle(fill: Color.lingoGold, shadow: Color.lingoOrange))
            } else {
                Text("You need \(100 - progress.xp) more XP to buy a heart.")
                    .font(.custom("Fredoka-Regular", size: 13))
                    .foregroundStyle(Color.lingoMuted)
            }

            Spacer()
            Button("REVIEW TO REFILL · +5 HEARTS") {
                startEmergencyRefillReview()
            }
                .font(.custom("Fredoka-Medium", size: 18))
                .buttonStyle(DuoButtonStyle(fill: .red, shadow: Color(red: 0.72, green: 0.13, blue: 0.16)))
        }
        .padding(24)
        .background(Color(.systemGroupedBackground))
    }

    private var exitConfirmationView: some View {
        VStack(spacing: 18) {
            RemoteSVGView(url: CloneVisualAsset.mascotSad.url)
                .frame(width: 100, height: 100)
                .accessibilityHidden(true)
            Text("Wait, don’t go!")
                .font(.custom("Fredoka-Medium", size: 24))
                .foregroundStyle(Color.lingoInk)
            Text(session.completionNodeID == nil
                 ? "End this practice session?"
                 : "Your exact lesson position is saved, so you can come straight back to it.")
                .font(.custom("Fredoka-Regular", size: 15))
                .foregroundStyle(Color.lingoMuted)
                .multilineTextAlignment(.center)

            Button("KEEP LEARNING") { showExitConfirmation = false }
                .font(.custom("Fredoka-Medium", size: 18))
                .buttonStyle(DuoButtonStyle())
            Button("SAVE & EXIT") {
                speaker.stop()
                speechRecognizer.stop()
                viewModel.persistSnapshot(to: progress)
                showExitConfirmation = false
                dismiss()
            }
            .font(.custom("Fredoka-Medium", size: 15))
            .foregroundStyle(Color.lingoWrong)
        }
        .padding(24)
        .presentationDetents([.height(390)])
        .presentationDragIndicator(.visible)
    }

    private func recordCompletionIfNeeded() {
        guard !didRecordCompletion else { return }
        didRecordCompletion = true
        if settings.soundEffectsEnabled { soundPlayer.playCompletion() }

        if isEmergencyRefillReview {
            progress.refillHearts()
            progress.recordPracticeSession(
                earnedXP: viewModel.earnedXP,
                restoreHeart: false
            )
        } else if let nodeID = session.completionNodeID {
            progress.complete(nodeID: nodeID, earnedXP: viewModel.earnedXP)
        } else {
            progress.recordPracticeSession(earnedXP: viewModel.earnedXP, restoreHeart: settings.heartsEnabled)
        }
    }
}

private struct SpeechBubble: Shape {
    private let radius: CGFloat
    private let tailSize: CGFloat

    init(radius: CGFloat = 16) {
        self.radius = radius
        self.tailSize = 20
    }

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(
                to: CGPoint(
                    x: rect.minX,
                    y: rect.maxY - radius
                )
            )

            path.addLine(
                to: CGPoint(
                    x: rect.minX,
                    y: rect.maxY - rect.height / 2
                )
            )

            path.addCurve(
                to: CGPoint(
                    x: rect.minX,
                    y: rect.maxY - rect.height / 2 - tailSize
                ),
                control1: CGPoint(
                    x: rect.minX - tailSize,
                    y: rect.maxY - rect.height / 2
                ),
                control2: CGPoint(
                    x: rect.minX,
                    y: rect.maxY - rect.height / 2 - tailSize / 2
                )
            )

            path.addArc(
                center: CGPoint(
                    x: rect.minX + radius,
                    y: rect.minY + radius
                ),
                radius: radius,
                startAngle: .degrees(180),
                endAngle: .degrees(270),
                clockwise: false
            )

            path.addArc(
                center: CGPoint(
                    x: rect.maxX - radius,
                    y: rect.minY + radius
                ),
                radius: radius,
                startAngle: .degrees(270),
                endAngle: .degrees(0),
                clockwise: false
            )

            path.addArc(
                center: CGPoint(
                    x: rect.maxX - radius,
                    y: rect.maxY - radius
                ),
                radius: radius,
                startAngle: .degrees(0),
                endAngle: .degrees(90),
                clockwise: false
            )

            path.addArc(
                center: CGPoint(
                    x: rect.minX + radius,
                    y: rect.maxY - radius
                ),
                radius: radius,
                startAngle: .degrees(90),
                endAngle: .degrees(180),
                clockwise: false
            )
        }
    }
}

private enum LessonSpeakNormalizer {
    static let stopWords: Set<String> = [
        "je", "j", "tu", "il", "elle", "on", "nous", "vous", "ils", "elles",
        "le", "la", "les", "un", "une", "des", "du", "de", "d",
        "ce", "cet", "cette", "ces",
        "et", "ou", "mais", "que", "qui",
        "ne", "n", "pas", "y", "en",
        "mon", "ton", "son", "notre", "votre", "leur", "leurs",
        "au", "aux"
    ]

    static let numberMap: [String: String] = [
        "zero": "0",
        "zéro": "0",
        "un": "1", "une": "1",
        "deux": "2",
        "trois": "3",
        "quatre": "4",
        "cinq": "5",
        "six": "6",
        "sept": "7",
        "huit": "8",
        "neuf": "9",
        "dix": "10",
        "onze": "11",
        "douze": "12",
        "treize": "13",
        "quatorze": "14",
        "quinze": "15",
        "seize": "16",
        "vingt": "20",
        "trente": "30",
        "quarante": "40",
        "cinquante": "50",
        "soixante": "60",
        "cent": "100"
    ]

    // MARK: French speech-to-text tolerance
    //
    // This is deliberately more permissive than written-answer checking.
    // The aim is to judge what the learner SAID, not which spelling Apple
    // Speech chose for an identical (or intentionally tolerated) sound.
    //
    // Accented e is intentionally preserved by frenchLookupKey so forms such
    // as "parle" and "parlé" are NOT accidentally treated as the same sound.

    private static let frenchHomophoneGroups: [[String]] = [
        // Function words, contractions and grammatical forms
        ["a", "à", "as"],
        ["au", "eau", "haut"],
        ["aux", "eaux", "hauts"],
        ["ou", "où"],
        ["du", "dû"],
        ["la", "là", "l'a"],
        ["ma", "m'a"],
        ["ta", "t'a", "tas", "t'as"],
        ["ça", "sa", "s'a"],
        ["ce", "se"],
        ["on", "ont"],
        ["son", "sont"],
        ["mon", "m'ont", "mont"],
        ["ton", "t'ont", "thon"],
        ["leur", "leurs"],
        ["ni", "n'y"],
        ["si", "s'y"],
        ["quel", "quelle", "qu'elle"],
        ["quels", "quelles", "qu'elles"],
        ["quand", "quant", "qu'en"],
        ["sans", "sang", "cent", "sens", "sent", "s'en", "100"],
        ["dans", "d'en"],
        ["tant", "temps", "t'en"],
        ["ment", "m'en"],
        ["en", "an"],
        ["les", "l'ai"],
        ["l'est", "lait", "laid", "laie"],
        ["c'est", "sais", "sait"],
        ["mais", "mes", "met", "mets"],
        ["peu", "peux", "peut"],
        ["faux", "faut"],
        ["vaux", "vaut"],
        ["veux", "veut"],
        ["sur", "sûr"],

        // High-frequency verb forms
        ["fais", "fait"],
        ["dis", "dit"],
        ["lis", "lit"],
        ["ris", "rit"],
        ["vis", "vit"],
        ["suis", "suit"],
        ["écris", "écrit"],
        ["conduis", "conduit"],
        ["construis", "construit"],
        ["produis", "produit"],
        ["traduis", "traduit"],
        ["fuis", "fuit"],
        ["cuis", "cuit"],
        ["nuis", "nuit"],
        ["prends", "prend"],
        ["comprends", "comprend"],
        ["apprends", "apprend"],
        ["attends", "attend"],
        ["entends", "entend"],
        ["descends", "descend"],
        ["rends", "rend"],
        ["réponds", "répond"],
        ["perds", "perd"],
        ["vends", "vend"],
        ["tends", "tend"],
        ["défends", "défend"],
        ["pars", "part"],
        ["sors", "sort"],
        ["dors", "dort"],
        ["cours", "court"],
        ["meurs", "meurt"],
        ["sers", "sert"],
        ["mens", "ment"],
        ["bats", "bat"],
        ["bois", "boit"],
        ["crois", "croit", "croix"],
        ["vois", "voit", "voie", "voix"],
        ["dois", "doit", "doigt", "doigts"],
        ["reçois", "reçoit"],
        ["aperçois", "aperçoit"],
        ["connais", "connaît"],
        ["reconnais", "reconnaît"],
        ["parais", "paraît"],
        ["plais", "plaît"],
        ["nais", "naît"],
        ["viens", "vient"],
        ["tiens", "tient"],
        ["deviens", "devient"],
        ["reviens", "revient"],
        ["retiens", "retient"],
        ["conviens", "convient"],

        // Everyday lexical homophones
        ["air", "aire", "ère"],
        ["amande", "amende"],
        ["ancre", "encre"],
        ["auteur", "hauteur"],
        ["bal", "balle"],
        ["bon", "bond"],
        ["boue", "bout"],
        ["cane", "canne"],
        ["chaîne", "chêne"],
        ["chair", "cher", "chère", "chaire"],
        ["champ", "chant"],
        ["chœur", "cœur", "coeur"],
        ["compte", "conte", "comte"],
        ["cou", "coup", "coût", "cout"],
        ["cour", "cours", "court"],
        ["date", "datte"],
        ["dessin", "dessein"],
        ["différend", "différent"],
        ["fer", "faire"],
        ["foi", "foie", "fois"],
        ["fond", "fonds", "font"],
        ["guerre", "guère"],
        ["hôtel", "autel"],
        ["mal", "malle"],
        ["mer", "mère", "maire"],
        ["mur", "mûr"],
        ["nom", "non"],
        ["paire", "pair", "père"],
        ["pause", "pose"],
        ["peau", "pot", "pots"],
        ["poids", "pois"],
        ["point", "poing"],
        ["porc", "port"],
        ["reine", "renne", "rêne"],
        ["repaire", "repère"],
        ["sain", "sein", "saint", "seing", "ceint"],
        ["saut", "seau", "sot", "sceau"],
        ["scène", "Seine", "saine"],
        ["signe", "cygne"],
        ["tante", "tente"],
        ["tôt", "taux"],
        ["toi", "toit", "toits"],
        ["moi", "mois"],
        ["ver", "verre", "vert", "vers"],
        ["vin", "vain", "vingt", "20"],
        ["pain", "pin", "peint", "peins"],
        ["faim", "fin", "feint", "feins"],
        ["plein", "plaint"],
        ["plan", "plant"],
        ["prix", "pris"],
        ["près", "prêt", "prêts"],
        ["roux", "roue"],
        ["salle", "sale"]
    ]

    // Near-homophones / recurring STT confusions that we intentionally accept.
    // These are NOT claims that the words are linguistically identical.
    private static let frenchNearSpeechGroups: [[String]] = [
        ["dessus", "dessous"],
        ["du", "deux"],
        ["œufs", "eu", "eux"],
        ["des", "dès"],
        ["et", "est", "es", "ai"],
        ["ces", "ses", "sais", "sait", "c'est"],
        ["tes", "t'es"],
        ["un", "hein", "en", "an", "1"],
        ["si", "six", "6"],
        ["tout", "tous"],
        ["cou", "coup"],
        ["plutôt", "plus tôt"],
        ["plus", "plu"]
    ]

    // Common regular -er verbs. For these stems:
    //   parle / parles / parlent are equivalent in speech;
    //   parler / parlé / parlée / parlés / parlées / parlez are equivalent.
    // The two families remain separate, so "parle" != "parlé".
    private static let frenchRegularERStems: [String] = [
        "accept", "accompagn", "ajout", "aid", "aim", "annonc", "apport",
        "arrêt", "assur", "bavard", "boug", "cach", "chang", "cherch",
        "command", "commenc", "compar", "compt", "continu", "coup",
        "cuisin", "dans", "demand", "donn", "écout", "embrass", "emport",
        "entr", "expliqu", "ferm", "gard", "goût", "habit", "imagin",
        "invit", "jou", "laiss", "lav", "mang", "march", "montr",
        "occup", "oubli", "parl", "partag", "pass", "pens", "plac",
        "port", "prépar", "quitt", "racont", "regard", "remplac", "rentr",
        "réserv", "rest", "retourn", "sign", "sembl", "termin", "tomb",
        "touch", "travaill", "trouv", "utilis", "visit", "voyag"
    ]

    // Common stem-changing -er presents whose audible e/es/ent forms are
    // still identical to one another.
    private static let frenchStemChangingPresentGroups: [[String]] = [
        ["achète", "achètes", "achètent"],
        ["appelle", "appelles", "appellent"],
        ["amène", "amènes", "amènent"],
        ["emmène", "emmènes", "emmènent"],
        ["espère", "espères", "espèrent"],
        ["préfère", "préfères", "préfèrent"],
        ["répète", "répètes", "répètent"],
        ["lève", "lèves", "lèvent"],
        ["jette", "jettes", "jettent"],
        ["essaie", "essaies", "essaient"],
        ["paye", "payes", "payent"],
        ["paie", "paies", "paient"],
        ["envoie", "envoies", "envoient"],
        ["nettoie", "nettoies", "nettoient"]
    ]

    // Generic silent-plural tolerance is useful in spoken French, but these
    // frequent words must keep their final s/x because dropping it would
    // collapse genuinely different pronunciations such as ce/ces or le/les.
    private static let frenchKeepFinalSOrX: Set<String> = [
        "ces", "des", "les", "mes", "ses", "tes",
        "plus", "tous", "six", "dix", "fils", "ours", "os", "bus", "virus"
    ]

    private static let frenchVariantToCanonical: [String: String] = {
        var map: [String: String] = [:]

        func register(_ forms: [String], canonical: String? = nil) {
            guard let first = forms.first else { return }
            let canonicalKey = frenchLookupKey(canonical ?? first)
            guard !canonicalKey.isEmpty else { return }

            for form in forms {
                let key = frenchLookupKey(form)
                if !key.isEmpty {
                    map[key] = canonicalKey
                }
            }
        }

        for group in frenchHomophoneGroups {
            register(group)
        }

        for group in frenchNearSpeechGroups {
            register(group)
        }

        for group in frenchStemChangingPresentGroups {
            register(group)
        }

        for stem in frenchRegularERStems {
            register(
                [stem + "e", stem + "es", stem + "ent"],
                canonical: stem + "e"
            )
            register(
                [
                    stem + "er",
                    stem + "é",
                    stem + "ée",
                    stem + "és",
                    stem + "ées",
                    stem + "ez"
                ],
                canonical: stem + "er"
            )
        }

        return map
    }()

    static func canonicalToken(
        _ raw: String,
        course: LanguageCourse? = nil
    ) -> String {
        var word = stripOptionalAgreementNotation(raw).lowercased()

        let containsArabic = word.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x0600...0x06FF).contains(value)
                || (0x0750...0x077F).contains(value)
                || (0x08A0...0x08FF).contains(value)
        }

        if containsArabic {
            word = word.replacingOccurrences(of: "ـ", with: "")
            word = word.replacingOccurrences(
                of: "[\u{064B}-\u{065F}\u{0670}\u{06D6}-\u{06ED}]",
                with: "",
                options: .regularExpression
            )
            word = word.replacingOccurrences(
                of: "[أإآٱ]",
                with: "ا",
                options: .regularExpression
            )
            word = word.replacingOccurrences(of: "ى", with: "ي")
            word = word.replacingOccurrences(
                of: "[^\u{0621}-\u{063A}\u{0641}-\u{064A}0-9]",
                with: "",
                options: .regularExpression
            )
            return word
        }

        if course == .french {
            word = frenchLookupKey(word)

            if let canonical = frenchVariantToCanonical[word] {
                word = canonical
            }

            // Feminine/plural agreement after -é is silent in speech:
            // garé / garée / garés / garées all sound the same.
            word = frenchSilentAgreementKey(word)

            if let number = numberMap[word] {
                return number
            }

            // -ais / -ait / -aient are the same ending in normal spoken French
            // when attached to the same stem (imperfect and conditional).
            word = frenchAISFamilyKey(word)

            // Most noun/adjective plural -s/-x is silent in French. Keep a
            // short exception list for high-frequency words where this would
            // create a false pronunciation match.
            if word.count > 3,
               !frenchKeepFinalSOrX.contains(word),
               word.hasSuffix("s") || word.hasSuffix("x") {
                word.removeLast()
            }

            return word
        }

        // Preserve the app's previous behaviour for Spanish / other Latin text.
        word = word.folding(
            options: .diacriticInsensitive,
            locale: .current
        )

        word = word.replacingOccurrences(of: "’", with: "'")
        word = word.replacingOccurrences(of: "'", with: "")

        word = word.replacingOccurrences(
            of: "[^a-z0-9]",
            with: "",
            options: .regularExpression
        )

        if let number = numberMap[word] {
            word = number
        }

        if word.count > 3,
           word.hasSuffix("s") || word.hasSuffix("x") {
            word.removeLast()
        }

        return word
    }

    static func transcriptTokenSet(
        _ transcript: String,
        course: LanguageCourse? = nil
    ) -> Set<String> {
        var cleaned = transcript
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")

        if course == .french {
            cleaned = collapseFrenchSpacedContractions(cleaned)
        } else {
            cleaned = cleaned.folding(
                options: .diacriticInsensitive,
                locale: .current
            )
        }

        cleaned = cleaned
            .replacingOccurrences(
                of: "[.,!?/()«»…:;]",
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "\\s+",
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let parts = cleaned
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        let canonical = parts
            .map { canonicalToken($0, course: course) }
            .filter { !$0.isEmpty }

        return Set(canonical)
    }

    static func sentenceCanonicalTokensAlignedToWords(
        _ sentence: String,
        course: LanguageCourse? = nil
    ) -> [String] {
        sentence
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .map { canonicalToken($0, course: course) }
    }

    static func importantIndices(for canonicalTokens: [String]) -> [Int] {
        canonicalTokens.enumerated().compactMap { index, token in
            guard !token.isEmpty else { return nil }
            return stopWords.contains(token) ? nil : index
        }
    }

    private static func frenchLookupKey(_ raw: String) -> String {
        raw
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "œ", with: "oe")
            .replacingOccurrences(of: "æ", with: "ae")
            .replacingOccurrences(of: "ç", with: "c")
            .replacingOccurrences(
                of: "[^a-zàâäéèêëîïôöùûüÿ0-9]",
                with: "",
                options: .regularExpression
            )
    }

    private static func stripOptionalAgreementNotation(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"(?i)\((e|s|es)\)"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func frenchSilentAgreementKey(_ word: String) -> String {
        if word.hasSuffix("ées") {
            return String(word.dropLast(3)) + "é"
        }
        if word.hasSuffix("ée") || word.hasSuffix("és") {
            return String(word.dropLast(2)) + "é"
        }
        return word
    }

    private static func frenchAISFamilyKey(_ word: String) -> String {
        guard word.count > 5 else { return word }

        if word.hasSuffix("aient") {
            return String(word.dropLast(5)) + "ais"
        }

        if word.hasSuffix("ait") {
            return String(word.dropLast(3)) + "ais"
        }

        return word
    }

    private static func collapseFrenchSpacedContractions(_ raw: String) -> String {
        var text = raw

        // Apple Speech occasionally emits "c est", "j ai", "qu en", etc.
        // Collapse these back into one token so they align with the target
        // token ("c'est", "j'ai", "qu'en"...).
        text = text.replacingOccurrences(
            of: "\\b([cdjlmnst])\\s+([\\p{L}]+)\\b",
            with: "$1'$2",
            options: .regularExpression
        )

        text = text.replacingOccurrences(
            of: "\\b(qu|jusqu|lorsqu|puisqu)\\s+([\\p{L}]+)\\b",
            with: "$1'$2",
            options: .regularExpression
        )

        return text
    }
}

private struct TokenFlowLayout: Layout {
    var spacing: CGFloat = 8
    var isRightToLeft: Bool = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = isRightToLeft ? bounds.maxX : bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if isRightToLeft {
                if x < bounds.maxX && x - size.width < bounds.minX {
                    x = bounds.maxX
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                subview.place(
                    at: CGPoint(x: x - size.width, y: y),
                    proposal: ProposedViewSize(size)
                )
                x -= size.width + spacing
            } else {
                if x > bounds.minX && x + size.width > bounds.maxX {
                    x = bounds.minX
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                subview.place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }

            rowHeight = max(rowHeight, size.height)
        }
    }
}

private enum AppLessonCharacter: String, CaseIterable {
    case girl, boy, woman, man, robot, zombie
    var url: URL { cloneAssetURL("\(rawValue).svg") }
}

private enum CloneVisualAsset: String {
    case mascot = "mascot.svg"
    case mascotBad = "mascot_bad.svg"
    case mascotSad = "mascot_sad.svg"
    case finish = "finish.svg"
    var url: URL { cloneAssetURL(rawValue) }
}

private func cloneAssetURL(_ filename: String) -> URL {
    URL(string: "https://raw.githubusercontent.com/sanidhyy/duolingo-clone/268221c205148c07bfb22f9adf3b46bdcd048d9a/public/\(filename)")!
}

private struct RemoteSVGView: UIViewRepresentable {
    let url: URL

    final class Coordinator { var loadedURL: URL? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.isUserInteractionEnabled = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        let source = url.absoluteString
        let html = """
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
        <body style="margin:0;background:transparent;overflow:hidden;display:flex;align-items:center;justify-content:center;">
        <img src="\(source)" style="width:100%;height:100%;object-fit:contain;" />
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }
}

private final class FeedbackSoundPlayer: ObservableObject {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    private var correctPlayer: AVAudioPlayer?

    private let sampleRate = 44_100.0
    private let format: AVAudioFormat

    init() {
        format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        )!

        engine.attach(player)

        engine.connect(
            player,
            to: engine.mainMixerNode,
            format: format
        )
    }

    deinit {
        correctPlayer?.stop()
        player.stop()
        engine.stop()
    }

    func playCorrect() {
        guard let url = Bundle.main.url(
            forResource: "duolingo-correct",
            withExtension: "mp3"
        ) else {
            print("Could not find duolingo-correct.mp3")
            return
        }

        do {
            let audioSession = AVAudioSession.sharedInstance()

            try audioSession.setCategory(
                .ambient,
                mode: .default
            )

            try audioSession.setActive(true)

            correctPlayer?.stop()

            correctPlayer = try AVAudioPlayer(
                contentsOf: url
            )

            correctPlayer?.prepareToPlay()
            correctPlayer?.play()

        } catch {
            print(
                "Correct sound error: \(error.localizedDescription)"
            )
        }
    }

    func playWrong() {
        playTone(
            frequency: 220,
            duration: 0.18,
            amplitude: 0.14
        )
    }

    func playCompletion() {
        playTone(
            frequency: 1_046.5,
            duration: 0.32,
            amplitude: 0.17
        )
    }

    private func playTone(
        frequency: Double,
        duration: Double,
        amplitude: Float
    ) {
        let frameCount = AVAudioFrameCount(
            sampleRate * duration
        )

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ),
        let channel = buffer.floatChannelData?[0] else {
            return
        }

        buffer.frameLength = frameCount

        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate

            let fade = min(
                1,
                min(
                    t / 0.02,
                    (duration - t) / 0.04
                )
            )

            channel[frame] =
                amplitude *
                Float(max(0, fade)) *
                sin(
                    Float(
                        2 *
                        Double.pi *
                        frequency *
                        t
                    )
                )
        }

        do {
            let audioSession = AVAudioSession.sharedInstance()

            try audioSession.setCategory(
                .ambient,
                mode: .default
            )

            try audioSession.setActive(true)

            player.stop()
            engine.stop()
            engine.reset()
            engine.prepare()

            try engine.start()

            guard engine.isRunning else {
                return
            }

            player.scheduleBuffer(
                buffer,
                at: nil,
                options: .interrupts
            )

            player.play()

        } catch {
            print(
                "Feedback sound error: \(error.localizedDescription)"
            )
        }
    }
}

private struct LessonProgressBar: View {
    let progress: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            let clamped = max(0, min(1, progress))
            let fillWidth = geometry.size.width * CGFloat(clamped)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.systemGray5))

                Capsule()
                    .fill(tint)
                    .frame(width: fillWidth)
                    .overlay(alignment: .topLeading) {
                        if fillWidth > 18 {
                            Capsule()
                                .fill(Color.white.opacity(0.24))
                                .frame(width: max(8, fillWidth - 12), height: 3)
                                .padding(.leading, 6)
                                .padding(.top, 2)
                        }
                    }
            }
        }
    }
}

private struct TactileCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: configuration.isPressed ? 4 : 0)
            .shadow(
                color: .black.opacity(configuration.isPressed ? 0.04 : 0.11),
                radius: 0,
                y: configuration.isPressed ? 1 : 0.5
            )
            .scaleEffect(configuration.isPressed ? 0.995 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private struct ConfettiParticle: Identifiable {
    let id = UUID()
    let x: CGFloat
    let delay: Double
    let duration: Double
    let rotation: Double
    let hue: Double
    let size: CGFloat
}

private struct ConfettiOverlay: View {
    @State private var animate = false
    private let particles: [ConfettiParticle] = (0..<90).map { _ in
        ConfettiParticle(
            x: CGFloat.random(in: 0.02...0.98),
            delay: Double.random(in: 0...0.9),
            duration: Double.random(in: 1.7...3.0),
            rotation: Double.random(in: 180...900),
            hue: Double.random(in: 0...1),
            size: CGFloat.random(in: 5...11)
        )
    }

    var body: some View {
        GeometryReader { geometry in
            ForEach(particles) { particle in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hue: particle.hue, saturation: 0.78, brightness: 0.95))
                    .frame(width: particle.size, height: particle.size * 1.55)
                    .rotationEffect(.degrees(animate ? particle.rotation : 0))
                    .position(
                        x: geometry.size.width * particle.x,
                        y: animate ? geometry.size.height + 30 : -30
                    )
                    .animation(.easeIn(duration: particle.duration).delay(particle.delay), value: animate)
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .onAppear { animate = true }
    }
}
