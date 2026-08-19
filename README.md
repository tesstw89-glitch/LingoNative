# LingoNative

A native SwiftUI iPhone prototype inspired by the learning-path structure of `sanidhyy/duolingo-clone`, rebuilt for the user's French and Spanish everyday-language corpora.

## What is included

- Native SwiftUI app target (iOS 17+)
- French / Spanish course picker
- Opinions & Reactions prototype course
- Duolingo-style winding learning path
- Units generated from source headings/contexts
- Dynamic 10-question sessions drawn from each unit's phrase pool
- Alternating target-language → English and English → target-language multiple choice
- Same-unit distractors first, with whole-course fallback
- Sequential lesson unlocking
- Hearts and XP
- Local progress persistence with `UserDefaults`
- Correct / incorrect haptic feedback
- 5,150 French phrases and 2,845 Spanish phrases bundled as JSON

## Open in Xcode

1. Unzip `LingoNative.zip`.
2. Open `LingoNative.xcodeproj` in Xcode.
3. Select an iPhone simulator or your iPhone.
4. In **Signing & Capabilities**, select your Apple Development team if Xcode asks for one.
5. Run.

The bundle identifier is currently `com.example.LingoNative`; change it in the target settings if installing on a physical device.

## Corpus mapping

### French
Each numbered heading in `opinions_reactions_fr_complete_clean.txt` becomes a Unit. The source wording and order are preserved. French entries do not contain lemma metadata in this source file, so `lemmas` is an empty array.

### Spanish
Each distinct `context` value in `opinions_reactions_es_madrid_clean_with_headings.json` becomes a Unit. Existing phrase, English, lemma and context data are preserved.

### Lesson nodes
A Unit receives roughly one lesson node per 10 source phrases. A node does **not** permanently own a fixed subset. Opening a node generates a fresh random session from the Unit's phrase pool.

## Deliberately not in v0.1

- Login/accounts
- Cloud sync
- Stripe/subscriptions
- Typing exercises
- Word-bank exercises
- TTS/listening exercises
- Lemma popovers
- Spaced-repetition weighting
- Admin/editor UI

Those can be layered on after the native path + quiz loop feels right.

## Attribution

The interaction structure was informed by the MIT-licensed `sanidhyy/duolingo-clone` repository. This prototype is a native SwiftUI reimplementation rather than a direct source-code conversion.
