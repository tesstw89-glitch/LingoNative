from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VIEW = ROOT / "LingoNative/Views/PracticeHubView.swift"


def fail(message: str) -> None:
    raise SystemExit(f"\n❌ {message}\n")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        fail(f"Could not apply {label}; expected 1 match, found {count}.")
    return text.replace(old, new, 1)


if not VIEW.exists():
    fail(f"Missing {VIEW.relative_to(ROOT)}")

view = VIEW.read_text(encoding="utf-8")

# 1) Add the Practice Vocab card beneath the existing practice modes.
old_list = '''                    ForEach(PracticeMode.allCases) { mode in
                        practiceLink(mode)
                    }
'''
new_list = '''                    ForEach(PracticeMode.allCases) { mode in
                        practiceLink(mode)
                    }

                    vocabPracticeLink
'''
view = replace_once(view, old_list, new_list, "Practice Vocab card insertion")

# 2) Add the card/destination using the already-deduplicated corpus-wide lemmaPool.
anchor = '''    private var heartsCard: some View {'''
card = '''    private var vocabPracticeLink: some View {
        let count = lemmaPool.count

        return NavigationLink {
            VocabPracticeChooserView(
                course: corpus.course,
                lemmas: lemmaPool,
                sessionLength: settings.sessionLength,
                speechRate: settings.speechRate,
                onFinished: { completedCount in
                    progress.recordPracticeSession(
                        earnedXP: max(10, completedCount * 5),
                        restoreHeart: settings.heartsEnabled
                    )
                }
            )
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "text.book.closed.fill")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color.lingoBlue)
                    .frame(width: 52, height: 52)
                    .background(Color.lingoBlue.opacity(0.13))
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Practice Vocab")
                        .font(.custom("Fredoka-Medium", size: 18))
                        .foregroundStyle(Color.lingoInk)
                    Text("Write or listen & write · lemmas only")
                        .font(.custom("Fredoka-Regular", size: 15))
                        .foregroundStyle(Color.lingoMuted)
                    Text("\\(count) lemma\\(count == 1 ? \"\" : \"s\") available")
                        .font(.custom("Fredoka-Medium", size: 13))
                        .foregroundStyle(Color.lingoBlue)
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(Color.lingoMuted)
            }
            .padding(15)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.lingoLine, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .opacity(count == 0 ? 0.5 : 1)
    }

'''
if "private var vocabPracticeLink" not in view:
    if anchor not in view:
        fail("Could not find heartsCard insertion point.")
    view = view.replace(anchor, card + anchor, 1)

# 3) Add dedicated lemma-only practice UI. This deliberately does NOT create fake
# PhraseEntry values, so phrase learning stages/FSRS are not polluted by vocab drills.
marker = '''// MARK: - LanguageTrainer-style speaking drill'''
implementation = r'''// MARK: - Lemma-only vocab practice

private enum VocabPracticeMode {
    case write
    case listenWrite

    var title: String {
        switch self {
        case .write: return "Write"
        case .listenWrite: return "Listen & Write"
        }
    }

    var subtitle: String {
        switch self {
        case .write: return "See the meaning and write the lemma"
        case .listenWrite: return "Hear the lemma and type what you hear"
        }
    }

    var systemImage: String {
        switch self {
        case .write: return "square.and.pencil"
        case .listenWrite: return "headphones.circle.fill"
        }
    }
}

private struct VocabPracticeChooserView: View {
    let course: LanguageCourse
    let lemmas: [Lemma]
    let sessionLength: Int
    let speechRate: Double
    let onFinished: (Int) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("PRACTICE VOCAB")
                        .font(.custom("Fredoka-SemiBold", size: 13))
                        .tracking(1.1)
                        .foregroundStyle(Color.lingoMuted)
                    Text("Lemmas & chunks only")
                        .font(.custom("Fredoka-Medium", size: 24))
                        .foregroundStyle(Color.lingoInk)
                    Text("\(lemmas.count) available across your \(course.title) corpus")
                        .font(.custom("Fredoka-Regular", size: 15))
                        .foregroundStyle(Color.lingoMuted)
                }

                option(.write, tint: .lingoBlue)
                option(.listenWrite, tint: .lingoGold)
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Practice Vocab")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func option(_ mode: VocabPracticeMode, tint: Color) -> some View {
        NavigationLink {
            LanguageTrainerVocabPracticeView(
                mode: mode,
                course: course,
                lemmas: lemmas,
                sessionLength: sessionLength,
                speechRate: speechRate,
                onFinished: onFinished
            )
        } label: {
            HStack(spacing: 16) {
                Image(systemName: mode.systemImage)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(tint)
                    .frame(width: 54, height: 54)
                    .background(tint.opacity(0.13))
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(mode.title)
                        .font(.custom("Fredoka-Medium", size: 19))
                        .foregroundStyle(Color.lingoInk)
                    Text(mode.subtitle)
                        .font(.custom("Fredoka-Regular", size: 15))
                        .foregroundStyle(Color.lingoMuted)
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(Color.lingoMuted)
            }
            .padding(16)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.lingoLine, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct LanguageTrainerVocabPracticeView: View {
    let mode: VocabPracticeMode
    let course: LanguageCourse
    let lemmas: [Lemma]
    let sessionLength: Int
    let speechRate: Double
    let onFinished: (Int) -> Void

    @StateObject private var speaker = SpeechSynthesizer()
    @State private var queue: [Lemma] = []
    @State private var index = 0
    @State private var typedAnswer = ""
    @State private var feedback: VocabFeedback?
    @State private var correctCount = 0
    @State private var isDone = false
    @State private var didReportRun = false

    private enum VocabFeedback: Equatable {
        case correct
        case wrong
    }

    private var current: Lemma? {
        queue.indices.contains(index) ? queue[index] : nil
    }

    var body: some View {
        Group {
            if isDone {
                doneView
            } else if let current {
                mainView(current)
            } else {
                ContentUnavailableView("No vocab available", systemImage: "text.book.closed")
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(mode.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if queue.isEmpty { startQueue() }
        }
        .onDisappear {
            speaker.stop()
        }
    }

    private func mainView(_ current: Lemma) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack {
                    Text("Question \(index + 1) / \(queue.count)")
                        .font(.custom("Fredoka-Regular", size: 15))
                        .foregroundStyle(Color.lingoMuted)
                    Spacer()
                    Text("VOCAB")
                        .font(.custom("Fredoka-SemiBold", size: 12))
                        .tracking(1)
                        .foregroundStyle(Color.lingoBlue)
                }

                if mode == .write {
                    VStack(spacing: 7) {
                        Text("WRITE THIS IN \(course.title.uppercased())")
                            .font(.custom("Fredoka-SemiBold", size: 12))
                            .tracking(1)
                            .foregroundStyle(Color.lingoMuted)
                        Text(current.english)
                            .font(.custom("Fredoka-Medium", size: 22))
                            .foregroundStyle(Color.lingoInk)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.lingoLine, lineWidth: 2)
                    }
                } else {
                    VStack(spacing: 12) {
                        Text("TYPE WHAT YOU HEAR")
                            .font(.custom("Fredoka-SemiBold", size: 12))
                            .tracking(1)
                            .foregroundStyle(Color.lingoMuted)

                        Button {
                            speaker.stop()
                            speaker.speak(current.foreign, course: course, rate: speechRate)
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .fill(Color.lingoGold.opacity(0.16))
                                    .frame(width: 104, height: 104)
                                Image(systemName: "speaker.wave.3.fill")
                                    .font(.system(size: 40, weight: .bold))
                                    .foregroundStyle(Color.lingoGold)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.lingoLine, lineWidth: 2)
                    }
                }

                answerInput

                if let feedback {
                    feedbackCard(feedback, lemma: current)
                }

                Button(feedback == nil ? "CHECK" : (index == queue.count - 1 ? "FINISH" : "NEXT")) {
                    if feedback == nil {
                        check(current)
                    } else {
                        advance()
                    }
                }
                .font(.custom("Fredoka-Medium", size: 18))
                .buttonStyle(DuoButtonStyle(
                    fill: feedback == nil
                        ? (answerReady ? Color.lingoGreen : Color(.systemGray4))
                        : Color.lingoGreen,
                    shadow: feedback == nil
                        ? (answerReady ? Color.lingoGreenDark : Color(.systemGray3))
                        : Color.lingoGreenDark
                ))
                .disabled(feedback == nil && !answerReady)
            }
            .padding(20)
            .padding(.bottom, 30)
        }
    }

    @ViewBuilder
    private var answerInput: some View {
        if course == .arabic {
            VStack(spacing: 12) {
                Text(typedAnswer.isEmpty ? "Your answer…" : typedAnswer)
                    .font(
                        typedAnswer.isEmpty
                            ? .custom("Fredoka-Regular", size: 18)
                            : .custom("NotoSansArabic-Regular", size: 24)
                    )
                    .foregroundStyle(typedAnswer.isEmpty ? Color.lingoMuted : Color.lingoInk)
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

                if feedback == nil {
                    arabicKeyboard
                }
            }
        } else {
            TextField("Type your answer", text: $typedAnswer, axis: .vertical)
                .font(.custom("Fredoka-Regular", size: 17))
                .foregroundColor(Color.lingoInk)
                .tint(Color.lingoBlue)
                .padding(16)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.lingoLine, lineWidth: 2)
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(feedback != nil)
        }
    }

    private var answerReady: Bool {
        !typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func feedbackCard(_ result: VocabFeedback, lemma: Lemma) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(
                    result == .correct ? "Correct" : "Not quite",
                    systemImage: result == .correct ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .font(.custom("Fredoka-Medium", size: 17))
                .foregroundStyle(result == .correct ? Color.lingoGreenDark : Color.lingoWrong)
                Spacer()
                Button {
                    speaker.stop()
                    speaker.speak(lemma.foreign, course: course, rate: speechRate)
                } label: {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.title3)
                        .foregroundStyle(Color.lingoBlue)
                }
                .buttonStyle(.plain)
            }

            Text(lemma.foreign)
                .font(course == .arabic
                      ? .custom("NotoSansArabic-Regular", size: 24)
                      : .custom("Fredoka-Medium", size: 20))
                .foregroundStyle(Color.lingoInk)
                .fixedSize(horizontal: false, vertical: true)

            if course == .arabic,
               let transliteration = lemma.transliteration,
               !transliteration.isEmpty {
                Text(transliteration)
                    .font(.custom("Fredoka-Regular", size: 14))
                    .foregroundStyle(Color.lingoMuted)
            }

            Text(lemma.english)
                .font(.custom("Fredoka-Regular", size: 15))
                .foregroundStyle(Color.lingoMuted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(result == .correct ? Color.lingoCorrect.opacity(0.12) : Color.lingoWrong.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var doneView: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(Color.lingoGreen)
            Text("Vocab practice complete!")
                .font(.custom("Fredoka-Medium", size: 30))
                .foregroundStyle(Color.lingoInk)
            Text("\(correctCount) / \(queue.count) correct")
                .font(.custom("Fredoka-Regular", size: 17))
                .foregroundStyle(Color.lingoMuted)
            Button("PRACTISE AGAIN") {
                startQueue()
            }
            .font(.custom("Fredoka-Medium", size: 17))
            .buttonStyle(DuoButtonStyle(
                fill: .lingoBlue,
                shadow: Color.lingoBlue.opacity(0.65)
            ))
            Spacer()
        }
        .padding(24)
    }

    private func startQueue() {
        speaker.stop()
        didReportRun = false

        var seen = Set<String>()
        let eligible = lemmas.shuffled().filter { lemma in
            let foreign = lemma.foreign.trimmingCharacters(in: .whitespacesAndNewlines)
            let english = lemma.english.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !foreign.isEmpty, !english.isEmpty else { return false }

            // Listen & Write does not need duplicate audio prompts for the same target form.
            let key = mode == .listenWrite
                ? PracticeTextNormalizer.key(foreign)
                : PracticeTextNormalizer.key(foreign) + "||" + PracticeTextNormalizer.key(english)
            return seen.insert(key).inserted
        }

        queue = Array(eligible.prefix(min(max(1, sessionLength), eligible.count)))
        index = 0
        correctCount = 0
        isDone = queue.isEmpty
        typedAnswer = ""
        feedback = nil
        if !queue.isEmpty { loadCurrent() }
    }

    private func loadCurrent() {
        typedAnswer = ""
        feedback = nil
        guard mode == .listenWrite, let current else { return }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard self.feedback == nil,
                  self.current?.id == current.id else { return }
            speaker.speak(current.foreign, course: course, rate: speechRate)
        }
    }

    private func check(_ lemma: Lemma) {
        guard feedback == nil, answerReady else { return }
        if QuizViewModel.answersMatch(typedAnswer, lemma.foreign) {
            correctCount += 1
            feedback = .correct
        } else {
            feedback = .wrong
        }
    }

    private func advance() {
        speaker.stop()
        if index + 1 >= queue.count {
            isDone = true
            reportRunIfNeeded()
        } else {
            index += 1
            loadCurrent()
        }
    }

    private func reportRunIfNeeded() {
        guard !didReportRun else { return }
        didReportRun = true
        onFinished(queue.count)
    }

    // MARK: Arabic vocab keyboard

    private var arabicKeyboard: some View {
        let rows = [
            ["ض", "ص", "ث", "ق", "ف", "غ", "ع", "ه", "خ", "ح", "ج", "د"],
            ["ش", "س", "ي", "ب", "ل", "ا", "ت", "ن", "م", "ك", "ط"],
            ["ئ", "ء", "ؤ", "ر", "ى", "ة", "و", "ز", "ظ"]
        ]

        return VStack(spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 4) {
                    ForEach(row, id: \.self) { key in
                        arabicKey(label: key, inserts: key)
                    }
                }
            }

            HStack(spacing: 6) {
                Spacer(minLength: 0)
                ForEach(["أ", "إ", "آ", "ذ"], id: \.self) { key in
                    arabicKey(label: key, inserts: key)
                        .frame(width: 48)
                }
                arabicKey(label: "◌ّ", inserts: "ّ")
                    .frame(width: 48)
                Spacer(minLength: 0)
            }

            HStack(spacing: 7) {
                Button {
                    guard !typedAnswer.isEmpty else { return }
                    typedAnswer.removeLast()
                } label: {
                    Image(systemName: "delete.left.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.lingoInk)
                        .frame(width: 58, height: 44)
                        .background(Color(.systemGray5))
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(typedAnswer.isEmpty)

                Button {
                    guard !typedAnswer.isEmpty, !typedAnswer.hasSuffix(" ") else { return }
                    typedAnswer.append(" ")
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
                .buttonStyle(.plain)
                .disabled(typedAnswer.isEmpty || typedAnswer.hasSuffix(" "))
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

    private func arabicKey(label: String, inserts value: String) -> some View {
        Button {
            typedAnswer.append(contentsOf: value)
        } label: {
            Text(label)
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
        .buttonStyle(.plain)
    }
}

'''

if "private enum VocabPracticeMode" not in view:
    if marker not in view:
        fail("Could not find speaking-drill insertion marker.")
    view = view.replace(marker, implementation + marker, 1)

for needle in [
    "vocabPracticeLink",
    "private enum VocabPracticeMode",
    "LanguageTrainerVocabPracticeView",
    "case .listenWrite: return \"Listen & Write\"",
    "arabicKey(label: \"◌ّ\", inserts: \"ّ\")",
    "QuizViewModel.answersMatch(typedAnswer, lemma.foreign)",
]:
    if needle not in view:
        fail(f"Sanity check failed: {needle}")

VIEW.write_text(view, encoding="utf-8")

print("✓ Added Practice Vocab to the Practice hub")
print("✓ Practice Vocab opens a choice: Write or Listen & Write")
print("✓ Both modes use lemmas/chunks only, across the whole selected-language corpus")
print("✓ Write shows English and asks for the target-language lemma")
print("✓ Listen & Write plays the lemma and hides the translation until feedback")
print("✓ Arabic vocab practice uses the custom Arabic keyboard, including shadda")
print("✓ Arabic feedback shows curated transliteration when available")
print("✓ Vocab practice awards practice XP but does not alter phrase mastery/FSRS")
print("\nNext: build with ⌘B and open Practice → Practice Vocab.")
