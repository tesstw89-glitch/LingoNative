import SwiftUI

struct QuizView: View {
    let session: QuizSession
    @ObservedObject var progress: ProgressStore
    @ObservedObject var settings: SettingsStore

    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: QuizViewModel
    @StateObject private var speaker = SpeechSynthesizer()
    @StateObject private var speechRecognizer = SpeechRecognizerService()
    @State private var didRecordCompletion = false
    @FocusState private var answerFieldFocused: Bool

    init(session: QuizSession, progress: ProgressStore, settings: SettingsStore) {
        self.session = session
        self.progress = progress
        self.settings = settings
        _viewModel = StateObject(wrappedValue: QuizViewModel(session: session))
    }

    var body: some View {
        Group {
            if viewModel.isFinished {
                completionView
                    .onAppear(perform: recordCompletionIfNeeded)
            } else if settings.heartsEnabled && progress.hearts == 0 {
                outOfHeartsView
            } else if let question = viewModel.currentQuestion {
                questionView(question)
                    .task(id: question.id) {
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
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline.weight(.black))
                            .foregroundStyle(Color.lingoMuted)
                    }
                }

                ToolbarItem(placement: .principal) {
                    ProgressView(value: viewModel.progress)
                        .tint(session.course == .french ? Color.lingoBlue : Color.lingoGreen)
                        .frame(width: 170)
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
        .onChange(of: speechRecognizer.transcript) { _, transcript in
            if viewModel.currentQuestion?.type == .speaking {
                viewModel.useTranscript(transcript)
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

                lemmaHints(question)
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
        VStack(alignment: .leading, spacing: 8) {
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
            }
        }
    }

    private func instruction(for question: QuizQuestion) -> String {
        switch question.type {
        case .multipleChoice:
            return question.direction == .foreignToEnglish ? "What does this mean?" : "Choose the \(session.course.title) translation"
        case .typing:
            return question.direction == .foreignToEnglish ? "Type the English meaning" : "Translate into \(session.course.title)"
        case .wordBank:
            return "Build the \(session.course.title) sentence"
        case .fillBlank:
            return "Fill in the missing word"
        case .listening:
            return "Type what you hear"
        case .speaking:
            return "Say this in \(session.course.title)"
        case .matching:
            return "Tap the matching translation"
        case .lemma:
            return "What does this chunk mean?"
        }
    }

    private func shouldShowPrompt(_ question: QuizQuestion) -> Bool {
        switch question.type {
        case .listening: return false
        default: return true
        }
    }

    private func multipleChoiceExercise(_ question: QuizQuestion) -> some View {
        VStack(spacing: 12) {
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                answerRow(option: option, index: index, question: question)
            }
        }
    }


    private func matchingExercise(_ question: QuizQuestion) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
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
                    VStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.black))
                            .foregroundStyle(selected ? .white : Color.lingoMuted)
                            .frame(width: 28, height: 28)
                            .background(selected ? Color.lingoBlue : Color(.systemGray6))
                            .clipShape(Circle())
                        Text(option)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Color.lingoInk)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, minHeight: 72)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, minHeight: 130)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(border, lineWidth: selected || viewModel.status != .unanswered ? 3 : 2)
                    }
                }
                .buttonStyle(.plain)
                .disabled(viewModel.status != .unanswered)
            }
        }
    }

    private func typingExercise(_ question: QuizQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Type your answer", text: $viewModel.typedAnswer, axis: .vertical)
                .font(.body.weight(.semibold))
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

            Text("Punctuation and capitalisation don’t count against you; accents still do.")
                .font(.caption)
                .foregroundStyle(Color.lingoMuted)
        }
    }

    private func wordBankExercise(_ question: QuizQuestion) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Text(viewModel.wordBankAnswer.isEmpty ? "Tap the words below…" : viewModel.wordBankAnswer)
                    .font(.body.weight(.bold))
                    .foregroundStyle(viewModel.wordBankAnswer.isEmpty ? Color.lingoMuted : Color.lingoInk)
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                if !viewModel.selectedWordIndices.isEmpty && viewModel.status == .unanswered {
                    Button {
                        viewModel.clearWordBank()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(15)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.lingoLine, lineWidth: 2)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 10)], spacing: 10) {
                ForEach(question.wordBankTokens.indices, id: \.self) { index in
                    let selected = viewModel.selectedWordIndices.contains(index)
                    Button {
                        viewModel.toggleWord(index: index)
                    } label: {
                        Text(question.wordBankTokens[index])
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(selected ? Color.lingoMuted : Color.lingoInk)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .background(selected ? Color(.systemGray6) : Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(selected ? Color.clear : Color.lingoLine, lineWidth: 2)
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.status != .unanswered)
                    .opacity(selected ? 0.45 : 1)
                }
            }
        }
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
        VStack(spacing: 20) {
            Button {
                speaker.speak(question.phrase.foreign, course: session.course, rate: settings.speechRate)
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.lingoBlue)
                        .frame(width: 104, height: 104)
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)

            TextField("Type what you hear", text: $viewModel.typedAnswer, axis: .vertical)
                .font(.body.weight(.semibold))
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
        .frame(maxWidth: .infinity)
    }

    private func speakingExercise(_ question: QuizQuestion) -> some View {
        VStack(spacing: 16) {
            Button {
                if speechRecognizer.isRecording {
                    speechRecognizer.stop()
                } else {
                    Task {
                        await speechRecognizer.start(localeIdentifier: session.course.speechLocaleIdentifier)
                    }
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(speechRecognizer.isRecording ? Color.lingoWrong : Color.lingoPurple)
                        .frame(width: 104, height: 104)
                    Image(systemName: speechRecognizer.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .disabled(viewModel.status != .unanswered)

            Text(speechRecognizer.isRecording ? "Listening… tap to stop" : "Tap the microphone and speak")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.lingoMuted)

            TextField("Your speech will appear here", text: $viewModel.typedAnswer, axis: .vertical)
                .font(.body.weight(.semibold))
                .padding(16)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.lingoLine, lineWidth: 2)
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(viewModel.status != .unanswered)

            if let error = speechRecognizer.errorMessage {
                Text(error)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.lingoWrong)
                    .multilineTextAlignment(.center)
            }

            Button("Hear the target") {
                speaker.speak(question.phrase.foreign, course: session.course, rate: settings.speechRate)
            }
            .font(.subheadline.weight(.black))
        }
        .frame(maxWidth: .infinity)
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
            case .unanswered:
                return selected ? Color.lingoBlue : Color.lingoLine
            case .correct:
                return isCorrect ? Color.lingoCorrect : Color.lingoLine
            case .wrong:
                if selected { return .lingoWrong }
                if isCorrect { return .lingoCorrect }
                return .lingoLine
            }
        }()

        return Button {
            viewModel.select(option)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Text(String(UnicodeScalar(65 + index)!))
                    .font(.caption.weight(.black))
                    .foregroundStyle(selected ? .white : Color.lingoMuted)
                    .frame(width: 28, height: 28)
                    .background(selected ? Color.lingoBlue : Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text(option)
                    .font(.body.weight(.bold))
                    .foregroundStyle(Color.lingoInk)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(border, lineWidth: selected || viewModel.status != .unanswered ? 3 : 2)
            }
        }
        .buttonStyle(.plain)
        .disabled(viewModel.status != .unanswered)
    }

    @ViewBuilder
    private func feedbackBar(question: QuizQuestion) -> some View {
        VStack(spacing: 12) {
            if viewModel.status == .correct {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Correct!")
                        .font(.headline.weight(.black))
                    Spacer()
                    Button {
                        speaker.speak(question.phrase.foreign, course: session.course, rate: settings.speechRate)
                    } label: {
                        Image(systemName: "speaker.wave.2.fill")
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(Color.lingoGreenDark)
            } else if viewModel.status == .wrong {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 10) {
                        Image(systemName: "xmark.circle.fill")
                        Text("Not quite")
                            .font(.headline.weight(.black))
                        Spacer()
                        Button {
                            speaker.speak(question.phrase.foreign, course: session.course, rate: settings.speechRate)
                        } label: {
                            Image(systemName: "speaker.wave.2.fill")
                        }
                        .buttonStyle(.plain)
                    }
                    Text("Correct answer: \(question.correctAnswer)")
                        .font(.subheadline.weight(.bold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(Color.lingoWrong)
            }

            if viewModel.status == .unanswered {
                Button("CHECK") {
                    speechRecognizer.stop()
                    answerFieldFocused = false
                    viewModel.check(progressStore: progress, settings: settings)
                }
                .buttonStyle(DuoButtonStyle(
                    fill: viewModel.responseIsReady ? Color.lingoGreen : Color(.systemGray4),
                    shadow: viewModel.responseIsReady ? Color.lingoGreenDark : Color(.systemGray3)
                ))
                .disabled(!viewModel.responseIsReady)
            } else {
                Button("CONTINUE") {
                    speechRecognizer.stop()
                    viewModel.continueAfterFeedback()
                }
                .buttonStyle(DuoButtonStyle(
                    fill: viewModel.status == .correct ? Color.lingoGreen : Color.lingoWrong,
                    shadow: viewModel.status == .correct ? Color.lingoGreenDark : Color(red: 0.73, green: 0.20, blue: 0.20)
                ))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var completionView: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.lingoGold.opacity(0.18))
                    .frame(width: 150, height: 150)
                Image(systemName: session.completionNodeID == nil ? "sparkles" : "trophy.fill")
                    .font(.system(size: 68))
                    .foregroundStyle(Color.lingoGold)
            }

            VStack(spacing: 8) {
                Text(session.completionNodeID == nil ? "Practice complete!" : "Lesson complete!")
                    .font(.largeTitle.weight(.black))
                    .foregroundStyle(Color.lingoInk)
                Text("Mistakes were recycled into the session, and a fresh set will be drawn next time.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.lingoMuted)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                StatPill(systemImage: "bolt.fill", value: "+\(viewModel.earnedXP) XP", tint: Color.lingoGold)
                StatPill(systemImage: "xmark.circle.fill", value: "\(viewModel.mistakes)", tint: Color.lingoWrong)
            }

            Spacer()

            Button("CONTINUE") {
                dismiss()
            }
            .buttonStyle(DuoButtonStyle())
        }
        .padding(24)
        .background(Color(.systemGroupedBackground))
    }

    private var outOfHeartsView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "heart.slash.fill")
                .font(.system(size: 72))
                .foregroundStyle(.red)
            Text("Out of hearts")
                .font(.largeTitle.weight(.black))
                .foregroundStyle(Color.lingoInk)
            Text("This is your app, so there’s no shop or waiting timer. Refill and carry on.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.lingoMuted)
                .multilineTextAlignment(.center)
            Spacer()
            Button("REFILL HEARTS") {
                progress.refillHearts()
            }
            .buttonStyle(DuoButtonStyle(fill: .red, shadow: Color(red: 0.72, green: 0.13, blue: 0.16)))
        }
        .padding(24)
        .background(Color(.systemGroupedBackground))
    }

    private func recordCompletionIfNeeded() {
        guard !didRecordCompletion else { return }
        didRecordCompletion = true
        if let nodeID = session.completionNodeID {
            progress.complete(nodeID: nodeID, earnedXP: viewModel.earnedXP)
        } else {
            progress.recordPracticeSession(earnedXP: viewModel.earnedXP)
        }
    }
}
