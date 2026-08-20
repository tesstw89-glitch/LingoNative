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
    @State private var showExitConfirmation = false
    @FocusState private var answerFieldFocused: Bool
    @State private var speakingGraceDeadline: Date?
    @State private var speakingGraceWorkItem: DispatchWorkItem?
    @State private var speakingRecognisedIndices: Set<Int> = []

    private let speakingGraceSeconds: Double = 10

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
            if viewModel.isFinished {
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

                        if question.type == .listening && settings.autoplayAudio {
                            try? await Task.sleep(nanoseconds: 250_000_000)
                            speaker.speak(question.phrase.foreign, course: session.course, rate: settings.speechRate)
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
                        Label("\(progress.hearts)", systemImage: "heart.fill")
                            .font(.headline.weight(.black))
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .sheet(isPresented: $showExitConfirmation) {
            exitConfirmationView
        }
        .onAppear {
            viewModel.persistSnapshot(to: progress)
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
            guard settings.soundEffectsEnabled else { return }
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
                case .speaking:
                    speakingExercise(question)
                case .matching:
                    matchingExercise(question)
                case .lemma:
                    multipleChoiceExercise(question)
                }

                if question.type != .introduction {
                    lemmaHints(question)
                }
                Spacer(minLength: 90)
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom) {
            feedbackBar(question: question)
        }
    }

    private func questionHeader(_ question: QuizQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(question.type.title.uppercased(), systemImage: question.type.systemImage)
                    .font(.caption.weight(.black))
                    .foregroundStyle(session.course == .french ? Color.lingoBlue : Color.lingoGreen)
                Spacer()
                Text("\(viewModel.currentIndex + 1) / \(viewModel.questions.count)")
                    .font(.caption.weight(.black))
                    .foregroundStyle(Color.lingoMuted)
            }

            Text(instruction(for: question))
                .font(.title2.weight(.black))
                .foregroundStyle(Color.lingoInk)

            if shouldShowPrompt(question) {
                characterPrompt(question)
            }
        }
    }

    private func characterPrompt(_ question: QuizQuestion) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            RemoteSVGView(url: character(for: question).url)
                .frame(width: 72, height: 92)
                .accessibilityHidden(true)

            HStack(alignment: .top, spacing: 10) {
                Text(question.prompt)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.lingoInk)
                    .fixedSize(horizontal: false, vertical: true)

                if question.direction == .foreignToEnglish && question.type != .listening {
                    Button {
                        speaker.speak(question.phrase.foreign, course: session.course, rate: settings.speechRate)
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
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.lingoLine, lineWidth: 2)
            }
            .shadow(color: .black.opacity(0.07), radius: 0, y: 3)
        }
    }

    private func character(for question: QuizQuestion) -> AppLessonCharacter {
        let total = question.id.uuidString.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        let characters = AppLessonCharacter.allCases
        return characters[total % characters.count]
    }

    private func instruction(for question: QuizQuestion) -> String {
        switch question.type {
        case .introduction: return "Meet this phrase"
        case .multipleChoice:
            return question.direction == .foreignToEnglish ? "What does this mean?" : "Choose the \(session.course.title) translation"
        case .typing: return "Translate into \(session.course.title)"
        case .wordBank: return "Build the \(session.course.title) sentence"
        case .fillBlank: return "Fill in the missing word"
        case .listening:
            return question.wordBankTokens.isEmpty
                ? "Type what you hear"
                : "Listen, then build the sentence"
        case .speaking: return "Say this in \(session.course.title)"
        case .matching: return "Tap the matching translation"
        case .lemma: return "What does this chunk mean?"
        }
    }

    private func shouldShowPrompt(_ question: QuizQuestion) -> Bool {
        switch question.type {
        case .introduction, .listening: return false
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
                        Text(question.phrase.foreign)
                            .font(.title2.weight(.black))
                            .foregroundStyle(Color.lingoInk)
                            .fixedSize(horizontal: false, vertical: true)
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
                        .font(.headline.weight(.bold))
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
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.lingoInk)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.lingoBlue.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            if !question.phrase.lemmas.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("USEFUL CHUNKS")
                        .font(.caption2.weight(.black))
                        .tracking(1)
                        .foregroundStyle(Color.lingoMuted)
                    ForEach(question.phrase.lemmas.prefix(4)) { lemma in
                        HStack {
                            Text(lemma.foreign).font(.subheadline.weight(.bold))
                            Spacer()
                            Text(lemma.english)
                                .font(.caption.weight(.semibold))
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

    private func matchingExercise(_ question: QuizQuestion) -> some View {
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
                            .font(.caption.weight(.black))
                            .foregroundStyle(selected ? .white : Color.lingoMuted)
                            .frame(width: 30, height: 30)
                            .background(selected ? Color.lingoBlue : Color(.systemGray6))
                            .clipShape(Circle())

                        Text(option)
                            .font(.body.weight(.black))
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
                .disabled(viewModel.status != .unanswered)
            }
        }
    }

    private func typingExercise(_ question: QuizQuestion) -> some View {
        TextField("Type your answer", text: $viewModel.typedAnswer, axis: .vertical)
            .font(.body.weight(.semibold))
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
            .disabled(viewModel.status != .unanswered)
    }

    private func wordBankExercise(_ question: QuizQuestion) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("DRAG OR TAP WORDS INTO PLACE")
                    .font(.caption2.weight(.black))
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
                            .font(.caption.weight(.black))
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
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.lingoMuted)
                        .padding(.top, 12)
                        .padding(.leading, 4)
                }

                TokenFlowLayout(spacing: 8) {
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

            TokenFlowLayout(spacing: 8) {
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
        }
    }

    private func bankToken(question: QuizQuestion, index: Int) -> some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                viewModel.placeWordAtEnd(index: index)
            }
        } label: {
            tokenLabel(question.wordBankTokens[index], selected: false)
        }
        .buttonStyle(TactileCardButtonStyle())
        .disabled(viewModel.status != .unanswered)
        .draggable(wordPayload(index))
    }

    private func answerToken(question: QuizQuestion, index: Int) -> some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                viewModel.returnWordToBank(index: index)
            }
        } label: {
            tokenLabel(question.wordBankTokens[index], selected: true)
        }
        .buttonStyle(TactileCardButtonStyle())
        .disabled(viewModel.status != .unanswered)
        .draggable(wordPayload(index))
        .dropDestination(for: String.self) { items, _ in
            guard viewModel.status == .unanswered,
                  let payload = items.first,
                  let draggedIndex = wordIndex(from: payload) else { return false }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                viewModel.moveWord(index: draggedIndex, before: index)
            }
            return true
        }
    }

    private func tokenLabel(_ text: String, selected: Bool) -> some View {
        Text(text)
            .font(.subheadline.weight(.bold))
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
                .font(.title3.weight(.bold))
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
            .buttonStyle(TactileCardButtonStyle())
            .accessibilityLabel("Play phrase")

            if question.wordBankTokens.isEmpty {
                TextField("Type what you hear", text: $viewModel.typedAnswer, axis: .vertical)
                    .font(.body.weight(.semibold))
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
                    .disabled(viewModel.status != .unanswered)
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

            TokenFlowLayout(spacing: 8) {
                ForEach(Array(visibleWords.enumerated()), id: \.offset) { index, word in
                    let recognised = speakingRecognisedIndices.contains(index)

                    Text(word)
                        .font(.system(size: 21, weight: .bold, design: .rounded))
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
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.lingoPurple)
            }

            if speakingGraceDeadline != nil {
                Text("Keep going…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.lingoPurple)
            }

            if viewModel.status == .unanswered,
               let error = speechRecognizer.errorMessage,
               error != "Recognition request was canceled" {

                Text(error)
                    .font(.caption.weight(.semibold))
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
                .font(.headline.weight(.black))
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
            .disabled(viewModel.status != .unanswered)

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
                    .font(.subheadline.weight(.black))
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
                        .font(.subheadline.weight(.black))
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
                cleanedSpeakingText(question.phrase.foreign)
            )

        let heardSet =
            LessonSpeakNormalizer.transcriptTokenSet(raw)

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
                            Text(lemma.foreign)
                                .font(.subheadline.weight(.bold))
                            Spacer()
                            Text(lemma.english)
                                .font(.caption)
                                .foregroundStyle(Color.lingoMuted)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                Label("Hint: lemmas & chunks", systemImage: "lightbulb.fill")
                    .font(.subheadline.weight(.bold))
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
                    .font(.caption.weight(.black))
                    .foregroundStyle(selected ? .white : Color.lingoMuted)
                    .frame(width: 32, height: 32)
                    .background(selected ? Color.lingoBlue : Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                Text(option)
                    .font(.body.weight(.black))
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
        .disabled(viewModel.status != .unanswered)
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
                        Text(question.type == .introduction ? "Phrase introduced!" : "Nicely done!")
                            .font(.headline.weight(.black))

                        Text(question.phrase.english)
                            .font(.subheadline)
                    }

                    Spacer()

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
                .foregroundStyle(Color.lingoGreenDark)

            } else if viewModel.status == .wrong {
                HStack(alignment: .top, spacing: 12) {
                    RemoteSVGView(url: CloneVisualAsset.mascotBad.url)
                        .frame(width: 50, height: 50)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Not quite")
                            .font(.headline.weight(.black))

                        Text("Correct answer: \(question.correctAnswer)")
                            .font(.subheadline.weight(.bold))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(Color.lingoWrong)
            }

            if viewModel.status == .unanswered {
                if !(question.type == .speaking && session.completionNodeID != nil) {
                    Button(question.type == .introduction ? "GOT IT" : "CHECK") {
                        speechRecognizer.stop()
                        answerFieldFocused = false

                        if question.type == .introduction {
                            viewModel.acknowledgeIntroduction(
                                progressStore: progress
                            )
                        } else {
                            viewModel.check(
                                progressStore: progress,
                                settings: settings
                            )
                        }
                    }
                    .buttonStyle(DuoButtonStyle(
                        fill: viewModel.responseIsReady
                            ? Color.lingoGreen
                            : Color(.systemGray4),
                        shadow: viewModel.responseIsReady
                            ? Color.lingoGreenDark
                            : Color(.systemGray3)
                    ))
                    .disabled(!viewModel.responseIsReady)
                }

            } else {
                Button(viewModel.status == .wrong ? "CONTINUE" : "NEXT") {
                    cancelSpeakingGrace()
                    speechRecognizer.stop()
                    viewModel.continueAfterFeedback(progressStore: progress)
                }
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
                    Text(session.completionNodeID == nil ? "Practice complete!" : "Lesson complete!")
                        .font(.largeTitle.weight(.black))
                        .foregroundStyle(Color.lingoInk)
                    Text(completionMessage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.lingoMuted)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 12) {
                    completionStatCard(title: "TOTAL XP", value: "+\(viewModel.earnedXP)", icon: "bolt.fill", tint: Color.lingoGold)
                    completionStatCard(title: "HEARTS", value: "\(progress.hearts)", icon: "heart.fill", tint: .red)
                }

                if viewModel.mistakes > 0 {
                    Label("\(viewModel.mistakes) mistake\(viewModel.mistakes == 1 ? "" : "s") rescheduled", systemImage: "brain.head.profile.fill")
                        .font(.subheadline.weight(.black))
                        .foregroundStyle(Color.lingoWrong)
                }

                Spacer()
                Button("CONTINUE") { dismiss() }
                    .buttonStyle(DuoButtonStyle())
            }
            .padding(24)
        }
    }

    private var completionMessage: String {
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
                .font(.caption2.weight(.black))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(tint)
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(value)
            }
            .font(.title3.weight(.black))
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

    private var outOfHeartsView: some View {
        VStack(spacing: 20) {
            Spacer()
            RemoteSVGView(url: CloneVisualAsset.mascotBad.url)
                .frame(width: 120, height: 120)
                .accessibilityHidden(true)
            Text("Out of hearts")
                .font(.largeTitle.weight(.black))
                .foregroundStyle(Color.lingoInk)
            Text("Spend XP for a heart, or use the emergency refill. Practice sessions never cost hearts and restore one when you finish.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.lingoMuted)
                .multilineTextAlignment(.center)

            if progress.xp >= 100 {
                Button("SPEND 100 XP · +1 HEART") { _ = progress.buyHeart() }
                    .buttonStyle(DuoButtonStyle(fill: Color.lingoGold, shadow: Color.lingoOrange))
            } else {
                Text("You need \(100 - progress.xp) more XP to buy a heart.")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.lingoMuted)
            }

            Spacer()
            Button("EMERGENCY REFILL") { progress.refillHearts() }
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
                .font(.title2.weight(.black))
                .foregroundStyle(Color.lingoInk)
            Text(session.completionNodeID == nil
                 ? "End this practice session?"
                 : "Your exact lesson position is saved, so you can come straight back to it.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.lingoMuted)
                .multilineTextAlignment(.center)

            Button("KEEP LEARNING") { showExitConfirmation = false }
                .buttonStyle(DuoButtonStyle())
            Button("SAVE & EXIT") {
                speaker.stop()
                speechRecognizer.stop()
                viewModel.persistSnapshot(to: progress)
                showExitConfirmation = false
                dismiss()
            }
            .font(.subheadline.weight(.black))
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

        if let nodeID = session.completionNodeID {
            progress.complete(nodeID: nodeID, earnedXP: viewModel.earnedXP)
        } else {
            progress.recordPracticeSession(earnedXP: viewModel.earnedXP, restoreHeart: settings.heartsEnabled)
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

    static let homophones: [String: [String]] = [
        "a": ["a", "à"],
        "un": ["un", "en", "an"],
        "au": ["au", "aux"],
        "ces": ["ces", "c est", "c'est", "sais", "sait", "ses"],
        "ca": ["ça", "sa"],
        "cent": ["cent", "sens", "sent"],
        "sang": ["sang", "sans"],
        "on": ["on", "ont"],
        "ou": ["ou", "où"],
        "peu": ["peu", "peux", "peut"],
        "quand": ["quand", "quant", "qu en", "qu'en"],
        "si": ["si", "six"],
        "son": ["son", "sont"],
        "sou": ["sou", "sous"],
        "ta": ["ta", "t a", "t'a", "tas", "t as", "t'as"],
        "tes": ["tes", "t es", "t'es"],
        "tu": ["tu", "tue"],
        "vin": ["vin", "vain", "vingt"],
        "vers": ["vers", "vert"]
    ]

    private static let variantToCanonical: [String: String] = {
        var map: [String: String] = [:]
        for (canonical, variants) in homophones {
            for variant in variants {
                map[variant] = canonical
            }
        }
        return map
    }()

    static func canonicalToken(_ raw: String) -> String {
        var word = raw.lowercased()

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

        if let canonical = variantToCanonical[word] {
            word = canonical
        }

        if word.count > 3,
           word.hasSuffix("s") || word.hasSuffix("x") {
            word.removeLast()
        }

        return word
    }

    static func transcriptTokenSet(_ transcript: String) -> Set<String> {
        let cleaned = transcript
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: "’", with: "'")
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
            .map { canonicalToken($0) }
            .filter { !$0.isEmpty }

        return Set(canonical)
    }

    static func sentenceCanonicalTokensAlignedToWords(_ sentence: String) -> [String] {
        sentence
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .map { canonicalToken($0) }
    }

    static func importantIndices(for canonicalTokens: [String]) -> [Int] {
        canonicalTokens.enumerated().compactMap { index, token in
            guard !token.isEmpty else { return nil }
            return stopWords.contains(token) ? nil : index
        }
    }
}

private struct TokenFlowLayout: Layout {
    var spacing: CGFloat = 8

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
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
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
        player.stop()
        engine.stop()
    }

    func playCorrect() {
        playTone(
            frequency: 880,
            duration: 0.12,
            amplitude: 0.16
        )
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
                y: configuration.isPressed ? 1 : 5
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
