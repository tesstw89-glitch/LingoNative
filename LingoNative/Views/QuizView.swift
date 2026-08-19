import SwiftUI

struct QuizView: View {
    let course: LanguageCourse
    let unit: LearningUnit
    let node: LessonNode
    @ObservedObject var progress: ProgressStore

    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: QuizViewModel
    @State private var didRecordCompletion = false

    init(
        course: LanguageCourse,
        unit: LearningUnit,
        node: LessonNode,
        allPhrases: [PhraseEntry],
        progress: ProgressStore
    ) {
        self.course = course
        self.unit = unit
        self.node = node
        self.progress = progress
        _viewModel = StateObject(
            wrappedValue: QuizViewModel(
                course: course,
                unit: unit,
                node: node,
                allPhrases: allPhrases
            )
        )
    }

    var body: some View {
        Group {
            if viewModel.isFinished {
                completionView
                    .onAppear(perform: recordCompletionIfNeeded)
            } else if progress.hearts == 0 {
                outOfHeartsView
            } else if let question = viewModel.currentQuestion {
                questionView(question)
            }
        }
        .navigationBarBackButtonHidden(!viewModel.isFinished)
        .toolbar {
            if !viewModel.isFinished {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline.weight(.black))
                            .foregroundStyle(.lingoMuted)
                    }
                }

                ToolbarItem(placement: .principal) {
                    ProgressView(value: viewModel.progress)
                        .tint(.lingoGreen)
                        .frame(width: 180)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Label("\(progress.hearts)", systemImage: "heart.fill")
                        .font(.headline.weight(.black))
                        .foregroundStyle(.red)
                }
            }
        }
        .sensoryFeedback(trigger: viewModel.status) { _, newValue in
            switch newValue {
            case .correct: return .success
            case .wrong: return .error
            case .unanswered: return nil
            }
        }
    }

    @ViewBuilder
    private func questionView(_ question: QuizQuestion) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text(unit.title)
                    .font(.caption.weight(.black))
                    .foregroundStyle(.lingoGreen)
                    .lineLimit(2)

                Text(question.direction == .foreignToEnglish
                     ? "What does this mean?"
                     : "Translate into \(course.title)")
                    .font(.title2.weight(.black))
                    .foregroundStyle(.lingoInk)

                Text(question.prompt)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.lingoInk)
                    .padding(.top, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    answerRow(option: option, index: index, question: question)
                }
            }

            Spacer()
        }
        .padding(20)
        .safeAreaInset(edge: .bottom) {
            feedbackBar(question: question)
        }
    }

    private func answerRow(option: String, index: Int, question: QuizQuestion) -> some View {
        let selected = viewModel.selectedAnswer == option
        let isCorrect = option == question.correctAnswer

        let border: Color = {
            switch viewModel.status {
            case .unanswered:
                return selected ? .lingoBlue : .lingoLine
            case .correct:
                return isCorrect ? .lingoCorrect : .lingoLine
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
                    .foregroundStyle(selected ? .white : .lingoMuted)
                    .frame(width: 28, height: 28)
                    .background(selected ? Color.lingoBlue : Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text(option)
                    .font(.body.weight(.bold))
                    .foregroundStyle(.lingoInk)
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
                }
                .foregroundStyle(.lingoGreenDark)
            } else if viewModel.status == .wrong {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 10) {
                        Image(systemName: "xmark.circle.fill")
                        Text("Not quite")
                            .font(.headline.weight(.black))
                    }
                    Text("Correct answer: \(question.correctAnswer)")
                        .font(.subheadline.weight(.bold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.lingoWrong)
            }

            if viewModel.status == .unanswered {
                Button("CHECK") {
                    viewModel.check(progressStore: progress)
                }
                .buttonStyle(DuoButtonStyle(
                    fill: viewModel.selectedAnswer == nil ? Color(.systemGray4) : .lingoGreen,
                    shadow: viewModel.selectedAnswer == nil ? Color(.systemGray3) : .lingoGreenDark
                ))
                .disabled(viewModel.selectedAnswer == nil)
            } else {
                Button(viewModel.status == .correct ? "CONTINUE" : "TRY AGAIN") {
                    viewModel.continueAfterFeedback()
                }
                .buttonStyle(DuoButtonStyle(
                    fill: viewModel.status == .correct ? .lingoGreen : .lingoWrong,
                    shadow: viewModel.status == .correct ? .lingoGreenDark : Color(red: 0.73, green: 0.20, blue: 0.20)
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
                Image(systemName: "trophy.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.lingoGold)
            }

            VStack(spacing: 8) {
                Text("Lesson complete!")
                    .font(.largeTitle.weight(.black))
                    .foregroundStyle(.lingoInk)
                Text("Fresh questions will be drawn next time you practise this node.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.lingoMuted)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                StatPill(systemImage: "bolt.fill", value: "+\(viewModel.earnedXP) XP", tint: .lingoGold)
                StatPill(systemImage: "xmark.circle.fill", value: "\(viewModel.mistakes)", tint: .lingoWrong)
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
                .foregroundStyle(.lingoInk)
            Text("For this prototype, refill them instantly and carry on.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.lingoMuted)
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
        progress.complete(nodeID: node.id, earnedXP: viewModel.earnedXP)
    }
}
