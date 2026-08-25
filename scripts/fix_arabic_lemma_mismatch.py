from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
VM = ROOT / "LingoNative/ViewModels/QuizViewModel.swift"
VIEW = ROOT / "LingoNative/Views/QuizView.swift"


def fail(message: str) -> None:
    raise SystemExit(f"\n❌ {message}\n")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        fail(f"Could not apply {label}; expected 1 match, found {count}.")
    return text.replace(old, new, 1)


if not VM.exists() or not VIEW.exists():
    fail("Could not find QuizViewModel.swift and QuizView.swift")

vm = VM.read_text()
view = VIEW.read_text()

# 1) Arabic normal lesson questions should use full-phrase formats only.
# Lemma/chunk work already has its own Arabic checkpoint boards.
old_candidates = '''        let candidates = ExerciseType.userSelectableCases.filter {
            $0 != .typing && $0 != .introduction && $0 != .matching
                && enabled.contains($0)
                && ($0 != .lemma || !phrase.lemmas.isEmpty)
        }'''
new_candidates = '''        let candidates = ExerciseType.userSelectableCases.filter {
            $0 != .typing && $0 != .introduction && $0 != .matching && $0 != .lemma
                && enabled.contains($0)
        }'''
vm = replace_once(
    vm,
    old_candidates,
    new_candidates,
    "Arabic normal-pool lemma removal",
)

# Bump lesson flow so an already-generated Arabic queue containing lemma questions is discarded.
match = re.search(r"private static let lessonFlowVersionBase = (\d+)", vm)
if not match:
    fail("Could not find lessonFlowVersionBase")
version = int(match.group(1))
if version < 13:
    vm = vm[:match.start(1)] + "13" + vm[match.end(1):]

# 2) Keep explicit Lemma practice correct: script, transliteration and TTS must all
# refer to the lemma prompt rather than mixing it with the full parent phrase.
anchor = '''    private func character(for question: QuizQuestion) -> AppLessonCharacter {
        let total = question.id.uuidString.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        let characters = AppLessonCharacter.allCases
        return characters[total % characters.count]
    }
'''
helper = anchor + '''
    private func spokenText(for question: QuizQuestion) -> String {
        question.type == .lemma ? question.prompt : question.phrase.foreign
    }

    private func displayedTransliteration(for question: QuizQuestion) -> String? {
        if question.type == .lemma {
            return question.phrase.lemmas.first(where: {
                $0.foreign == question.prompt
            })?.transliteration
        }
        return question.phrase.transliteration
    }
'''
if "private func spokenText(for question: QuizQuestion)" not in view:
    view = replace_once(view, anchor, helper, "lemma display helpers")

old_speech = '''speaker.speak(
                                question.phrase.foreign,
                                course: session.course,
                                rate: settings.speechRate
                            )'''
new_speech = '''speaker.speak(
                                spokenText(for: question),
                                course: session.course,
                                rate: settings.speechRate
                            )'''
if old_speech in view:
    view = view.replace(old_speech, new_speech)
elif new_speech not in view:
    fail("Could not find any phrase TTS calls to align for lemma practice")

old_translit = '''                if session.course == .arabic,
                   question.direction == .foreignToEnglish,
                   let transliteration = question.phrase.transliteration,
                   !transliteration.isEmpty {
                    Text(transliteration)'''
new_translit = '''                if session.course == .arabic,
                   question.direction == .foreignToEnglish,
                   let transliteration = displayedTransliteration(for: question),
                   !transliteration.isEmpty {
                    Text(transliteration)'''
view = replace_once(
    view,
    old_translit,
    new_translit,
    "lemma transliteration alignment",
)

VM.write_text(vm)
VIEW.write_text(view)

print("✓ Arabic normal lessons no longer randomly select lemma-only questions")
print("✓ Arabic chunk/conjugation matching checkpoints are untouched")
print("✓ Explicit Lemma practice now keeps Arabic script, transliteration and TTS aligned")
print("✓ Saved lesson queues are invalidated so old lemma questions disappear")
print("\nNext: build with ⌘B and start a fresh Arabic lesson.")
