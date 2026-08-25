# LingoNative

A native SwiftUI iPhone language-learning app inspired by the interaction model of the open-source Duolingo clone by sanidhyy, rebuilt as a local-first single-user app.

## Current course content

- French — Opinions & Reactions: 5,150 phrases across 333 context units
- Spanish — Opinions & Reactions: 2,845 phrases across 95 context units

The bundled phrase corpora are decoded locally from JSON. No account, backend, subscription or remote database is required.

## App structure

- **Learn** — Duolingo-style winding unit path with sequential lesson unlocking
- **Practice** — mixed practice, saved phrases, mistakes, weak spots, typing, listening, speaking, matching and lemma/chunk drills
- **Browse** — full-text phrase/context search, bookmarks, phrase details, audio and phrase history
- **Stats** — XP, streaks, accuracy, completed lessons, daily quests, seven-day activity and phrase mastery
- **Settings** — session length, daily XP goal, exercise mix, audio speed, autoplay, hints, haptics, hearts and local reset controls

## Exercise engine

Guided lessons and practice sessions can mix:

1. Multiple-choice translation
2. Free typing
3. Word-bank sentence building
4. Fill-the-gap questions
5. Listening + typing using `AVSpeechSynthesizer`
6. Speaking/pronunciation using Apple Speech recognition
7. Translation matching cards
8. Lemma/chunk questions when lemma metadata is present

Exercises and phrases are randomised. Incorrect questions are appended to the end of the current session so they return again before completion.

## Local progress

`UserDefaults` stores:

- completed lesson nodes
- XP and hearts
- correct/wrong counts per phrase
- phrase mastery and last-practised date
- bookmarks
- daily activity and streak data
- app settings

Everything is device-local.

## Run

Open `LingoNative.xcodeproj` in Xcode, choose an iPhone simulator or device, and run the `LingoNative` scheme.

The deployment target is iOS 17+.

Speaking practice requests microphone and speech-recognition permission only when that feature is used.

## Attribution

The learning-path concept and visual direction are based on the MIT-licensed `sanidhyy/duolingo-clone`. The SwiftUI implementation and language-data architecture are separate native code written for this project. See `ATTRIBUTION.md`.
