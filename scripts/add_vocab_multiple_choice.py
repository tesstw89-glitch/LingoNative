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

if "private enum VocabPracticeMode" not in view:
    fail("Practice Vocab is not installed yet. Run: python3 scripts/add_vocab_practice.py")

if "case multipleChoice" in view and "multipleChoiceAnswerList" in view:
    print("✓ Vocab Multiple Choice is already installed")
    raise SystemExit(0)

# 1) Add the mode.
view = replace_once(
    view,
    '''private enum VocabPracticeMode {\n    case write\n    case listenWrite\n''',
    '''private enum VocabPracticeMode {\n    case multipleChoice\n    case write\n    case listenWrite\n''',
    "VocabPracticeMode case",
)

view = replace_once(
    view,
    '''        switch self {\n        case .write: return "Write"\n        case .listenWrite: return "Listen & Write"\n        }\n''',
    '''        switch self {\n        case .multipleChoice: return "Multiple Choice"\n        case .write: return "Write"\n        case .listenWrite: return "Listen & Write"\n        }\n''',
    "mode title",
)

view = replace_once(
    view,
    '''        switch self {\n        case .write: return "See the meaning and write the lemma"\n        case .listenWrite: return "Hear the lemma and type what you hear"\n        }\n''',
    '''        switch self {\n        case .multipleChoice: return "See the meaning and choose the lemma"\n        case .write: return "See the meaning and write the lemma"\n        case .listenWrite: return "Hear the lemma and type what you hear"\n        }\n''',
    "mode subtitle",
)

view = replace_once(
    view,
    '''        switch self {\n        case .write: return "square.and.pencil"\n        case .listenWrite: return "headphones.circle.fill"\n        }\n''',
    '''        switch self {\n        case .multipleChoice: return "checklist"\n        case .write: return "square.and.pencil"\n        case .listenWrite: return "headphones.circle.fill"\n        }\n''',
    "mode icon",
)

# 2) Add chooser option.
view = replace_once(
    view,
    '''                option(.write, tint: .lingoBlue)\n                option(.listenWrite, tint: .lingoGold)\n''',
    '''                option(.multipleChoice, tint: .lingoGreen)\n                option(.write, tint: .lingoBlue)\n                option(.listenWrite, tint: .lingoGold)\n''',
    "chooser option",
)

# 3) Add state for the four choices and the current selection.
view = replace_once(
    view,
    '''    @State private var typedAnswer = ""\n    @State private var feedback: VocabFeedback?\n''',
    '''    @State private var typedAnswer = ""\n    @State private var choiceOptions: [Lemma] = []\n    @State private var selectedChoiceID: String?\n    @State private var feedback: VocabFeedback?\n''',
    "multiple choice state",
)

# 4) Give Multiple Choice its own prompt rather than the listening card.
view = replace_once(
    view,
    '''                if mode == .write {\n                    VStack(spacing: 7) {\n                        Text("WRITE THIS IN \\(course.title.uppercased())")\n''',
    '''                if mode == .write || mode == .multipleChoice {\n                    VStack(spacing: 7) {\n                        Text(mode == .multipleChoice\n                             ? "CHOOSE THIS IN \\(course.title.uppercased())"\n                             : "WRITE THIS IN \\(course.title.uppercased())")\n''',
    "multiple choice prompt",
)

# 5) Show answer cards for MC; keep text/Arabic keyboard for the two writing modes.
view = replace_once(
    view,
    '''                answerInput\n\n                if let feedback {\n''',
    '''                if mode == .multipleChoice {\n                    multipleChoiceAnswerList\n                } else {\n                    answerInput\n                }\n\n                if let feedback {\n''',
    "multiple choice answer UI",
)

# 6) Make CHECK readiness use the selected card for MC.
view = replace_once(
    view,
    '''    private var answerReady: Bool {\n        !typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty\n    }\n''',
    '''    private var answerReady: Bool {\n        if mode == .multipleChoice {\n            return selectedChoiceID != nil\n        }\n        return !typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty\n    }\n\n    private var multipleChoiceAnswerList: some View {\n        VStack(spacing: 10) {\n            ForEach(choiceOptions) { option in\n                let selected = selectedChoiceID == option.id\n\n                Button {\n                    guard feedback == nil else { return }\n                    selectedChoiceID = option.id\n                } label: {\n                    HStack(alignment: .center, spacing: 14) {\n                        VStack(alignment: course == .arabic ? .trailing : .leading, spacing: 3) {\n                            Text(option.foreign)\n                                .font(course == .arabic\n                                      ? .custom("NotoSansArabic-Regular", size: 22)\n                                      : .custom("Fredoka-Medium", size: 17))\n                                .foregroundStyle(Color.lingoInk)\n                                .multilineTextAlignment(course == .arabic ? .trailing : .leading)\n                                .frame(maxWidth: .infinity, alignment: course == .arabic ? .trailing : .leading)\n\n                            if course == .arabic,\n                               let transliteration = option.transliteration,\n                               !transliteration.isEmpty {\n                                Text(transliteration)\n                                    .font(.custom("Fredoka-Regular", size: 13))\n                                    .foregroundStyle(Color.lingoMuted)\n                                    .frame(maxWidth: .infinity, alignment: .trailing)\n                            }\n                        }\n\n                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")\n                            .font(.title3)\n                            .foregroundStyle(selected ? Color.lingoGreen : Color.lingoMuted)\n                    }\n                    .padding(.horizontal, 16)\n                    .padding(.vertical, 14)\n                    .frame(maxWidth: .infinity, minHeight: 62)\n                    .background(Color.white)\n                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))\n                    .overlay {\n                        RoundedRectangle(cornerRadius: 15, style: .continuous)\n                            .stroke(selected ? Color.lingoGreen : Color.lingoLine, lineWidth: selected ? 3 : 2)\n                    }\n                }\n                .buttonStyle(.plain)\n                .disabled(feedback != nil)\n            }\n        }\n    }\n''',
    "multiple choice readiness and cards",
)

# 7) Populate four options each question and keep Listen & Write autoplay intact.
view = replace_once(
    view,
    '''    private func loadCurrent() {\n        typedAnswer = ""\n        feedback = nil\n        guard mode == .listenWrite, let current else { return }\n\n        Task { @MainActor in\n''',
    '''    private func loadCurrent() {\n        typedAnswer = ""\n        selectedChoiceID = nil\n        choiceOptions = []\n        feedback = nil\n\n        guard let current else { return }\n\n        if mode == .multipleChoice {\n            var seenTargets = Set<String>()\n            seenTargets.insert(PracticeTextNormalizer.key(current.foreign))\n\n            let distractors = lemmas.shuffled().filter { candidate in\n                guard candidate.id != current.id else { return false }\n                let key = PracticeTextNormalizer.key(candidate.foreign)\n                guard !key.isEmpty else { return false }\n                return seenTargets.insert(key).inserted\n            }\n\n            choiceOptions = ([current] + Array(distractors.prefix(3))).shuffled()\n            return\n        }\n\n        guard mode == .listenWrite else { return }\n\n        Task { @MainActor in\n''',
    "multiple choice option generation",
)

# 8) Check selected lemma for MC, or typed answer for the writing modes.
view = replace_once(
    view,
    '''    private func check(_ lemma: Lemma) {\n        guard feedback == nil, answerReady else { return }\n        if QuizViewModel.answersMatch(typedAnswer, lemma.foreign) {\n            correctCount += 1\n            feedback = .correct\n        } else {\n            feedback = .wrong\n        }\n    }\n''',
    '''    private func check(_ lemma: Lemma) {\n        guard feedback == nil, answerReady else { return }\n\n        let isCorrect: Bool\n        if mode == .multipleChoice {\n            isCorrect = selectedChoiceID == lemma.id\n        } else {\n            isCorrect = QuizViewModel.answersMatch(typedAnswer, lemma.foreign)\n        }\n\n        if isCorrect {\n            correctCount += 1\n            feedback = .correct\n        } else {\n            feedback = .wrong\n        }\n    }\n''',
    "multiple choice checking",
)

# 9) Sanity checks.
for needle in [
    "case multipleChoice",
    "option(.multipleChoice, tint: .lingoGreen)",
    "private var multipleChoiceAnswerList",
    "choiceOptions = ([current] + Array(distractors.prefix(3))).shuffled()",
    "isCorrect = selectedChoiceID == lemma.id",
]:
    if needle not in view:
        fail(f"Sanity check failed: {needle}")

VIEW.write_text(view, encoding="utf-8")

print("✓ Added Multiple Choice to Practice Vocab")
print("✓ Practice Vocab now offers: Multiple Choice, Write, Listen & Write")
print("✓ Multiple Choice shows English → 4 target-language lemma/chunk choices")
print("✓ Arabic choices show Arabic + curated transliteration")
print("✓ Multiple Choice remains lemma-only and does not affect phrase mastery/FSRS")
print("\nNext: build with ⌘B and open Practice → Practice Vocab → Multiple Choice.")
