import SwiftUI

struct BrowseView: View {
    let corpus: Corpus
    @ObservedObject var progress: ProgressStore
    @ObservedObject var settings: SettingsStore

    @State private var query = ""
    @State private var bookmarksOnly = false
    @StateObject private var speaker = SpeechSynthesizer()

    private var filteredEntries: [PhraseEntry] {
        corpus.entries.filter { entry in
            if bookmarksOnly && !progress.isBookmarked(course: corpus.course, phrase: entry) {
                return false
            }

            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return true }

            let needle = trimmed.lowercased()

            return entry.foreign.lowercased().contains(needle)
                || entry.english.lowercased().contains(needle)
                || entry.context.lowercased().contains(needle)
                || (entry.transliteration?.lowercased().contains(needle) ?? false)
                || entry.lemmas.contains {
                    $0.foreign.lowercased().contains(needle)
                        || $0.english.lowercased().contains(needle)
                        || ($0.transliteration?.lowercased().contains(needle) ?? false)
                }
        }
    }

    var body: some View {
        List {
            Section {
                Toggle(isOn: $bookmarksOnly) {
                    Label("Bookmarked only", systemImage: "bookmark.fill")
                        .font(.custom("Fredoka-Regular", size: 16))
                }
            }

            Section {
                ForEach(filteredEntries) { phrase in
                    NavigationLink {
                        PhraseDetailView(
                            course: corpus.course,
                            phrase: phrase,
                            progress: progress,
                            settings: settings
                        )
                    } label: {
                        phraseRow(phrase)
                    }
                }
            } header: {
                Text("\(filteredEntries.count) phrases")
                    .font(.custom("Fredoka-SemiBold", size: 13))
            }
        }
        .listStyle(.insetGrouped)
        .searchable(
            text: $query,
            prompt: "Search phrase, translation or context"
        )
        .navigationTitle("Browse")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func phraseRow(_ phrase: PhraseEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(phrase.foreign)
                    .font(
                        corpus.course == .arabic
                            ? .custom("NotoSansArabic-Regular", size: 19)
                            : .custom("Fredoka-Medium", size: 17)
                    )
                    .foregroundStyle(Color.lingoInk)
                    .frame(
                        maxWidth: .infinity,
                        alignment: corpus.course == .arabic ? .trailing : .leading
                    )

                if corpus.course == .arabic,
                   let transliteration = phrase.transliteration,
                   !transliteration.isEmpty {
                    Text(transliteration)
                        .font(.custom("Fredoka-Regular", size: 13))
                        .foregroundStyle(Color.lingoMuted)
                }

                Text(phrase.english)
                    .font(.custom("Fredoka-Regular", size: 15))
                    .foregroundStyle(Color.lingoMuted)

                Text(phrase.context)
                    .font(.custom("Fredoka-Regular", size: 13))
                    .foregroundStyle(
                        corpus.course == .french
                            ? Color.lingoBlue
                            : Color.lingoGreen
                    )
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if progress.isBookmarked(course: corpus.course, phrase: phrase) {
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(Color.lingoGold)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PhraseDetailView: View {
    let course: LanguageCourse
    let phrase: PhraseEntry

    @ObservedObject var progress: ProgressStore
    @ObservedObject var settings: SettingsStore

    @StateObject private var speaker = SpeechSynthesizer()

    private var stats: PhraseProgress {
        progress.stats(course: course, phrase: phrase)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {

                // Phrase
                VStack(alignment: .leading, spacing: 10) {
                    Text(phrase.context)
                        .font(.custom("Fredoka-SemiBold", size: 13))
                        .foregroundStyle(
                            course == .french
                                ? Color.lingoBlue
                                : Color.lingoGreen
                        )

                    Text(phrase.foreign)
                        .font(
                            course == .arabic
                                ? .custom("NotoSansArabic-Regular", size: 36)
                                : .custom("Fredoka-Medium", size: 34)
                        )
                        .foregroundStyle(Color.lingoInk)
                        .frame(
                            maxWidth: .infinity,
                            alignment: course == .arabic ? .trailing : .leading
                        )

                    if course == .arabic,
                       let transliteration = phrase.transliteration,
                       !transliteration.isEmpty {
                        Text(transliteration)
                            .font(.custom("Fredoka-Regular", size: 16))
                            .foregroundStyle(Color.lingoMuted)
                    }

                    Text(phrase.english)
                        .font(.custom("Fredoka-Regular", size: 20))
                        .foregroundStyle(Color.lingoMuted)
                }

                // Listen + bookmark
                HStack(spacing: 12) {
                    Button {
                        speaker.speak(
                            phrase.foreign,
                            course: course,
                            rate: settings.speechRate
                        )
                    } label: {
                        Label(
                            "Listen",
                            systemImage: "speaker.wave.2.fill"
                        )
                        .font(.custom("Fredoka-Medium", size: 16))
                    }
                    .buttonStyle(
                        DuoButtonStyle(
                            fill: Color.lingoBlue,
                            shadow: Color(
                                red: 0.08,
                                green: 0.47,
                                blue: 0.70
                            )
                        )
                    )

                    Button {
                        progress.toggleBookmark(
                            course: course,
                            phrase: phrase
                        )
                    } label: {
                        Image(
                            systemName:
                                progress.isBookmarked(
                                    course: course,
                                    phrase: phrase
                                )
                                ? "bookmark.fill"
                                : "bookmark"
                        )
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 48)
                    }
                    .buttonStyle(
                        DuoButtonStyle(
                            fill: Color.lingoGold,
                            shadow: Color(
                                red: 0.82,
                                green: 0.59,
                                blue: 0.05
                            ),
                            foreground: Color.lingoInk
                        )
                    )
                }

                // Lemmas
                if !phrase.lemmas.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("LEMMAS & CHUNKS")
                            .font(.custom("Fredoka-SemiBold", size: 13))
                            .foregroundStyle(Color.lingoMuted)

                        ForEach(phrase.lemmas) { lemma in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(lemma.foreign)
                                        .font(
                                            course == .arabic
                                                ? .custom("NotoSansArabic-Regular", size: 19)
                                                : .custom("Fredoka-Medium", size: 17)
                                        )
                                        .foregroundStyle(Color.lingoInk)

                                    if course == .arabic,
                                       let transliteration = lemma.transliteration,
                                       !transliteration.isEmpty {
                                        Text(transliteration)
                                            .font(.custom("Fredoka-Regular", size: 12))
                                            .foregroundStyle(Color.lingoMuted)
                                    }
                                }

                                Spacer()

                                Text(lemma.english)
                                    .font(.custom("Fredoka-Regular", size: 15))
                                    .foregroundStyle(Color.lingoMuted)
                                    .multilineTextAlignment(.trailing)
                            }
                            .padding(12)
                            .background(Color.white)
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: 12,
                                    style: .continuous
                                )
                            )
                        }
                    }
                }

                // History
                VStack(alignment: .leading, spacing: 12) {
                    Text("YOUR HISTORY")
                        .font(.custom("Fredoka-SemiBold", size: 13))
                        .foregroundStyle(Color.lingoMuted)

                    HStack(spacing: 10) {
                        StatPill(
                            systemImage: "eye.fill",
                            value: "\(stats.seen)",
                            tint: Color.lingoBlue
                        )

                        StatPill(
                            systemImage: "checkmark.circle.fill",
                            value: "\(stats.correct)",
                            tint: Color.lingoGreen
                        )

                        StatPill(
                            systemImage: "xmark.circle.fill",
                            value: "\(stats.wrong)",
                            tint: Color.lingoWrong
                        )
                    }

                    ProgressView(value: stats.mastery)
                        .tint(Color.lingoGreen)

                    Text("Mastery \(Int(stats.mastery * 100))%")
                        .font(.custom("Fredoka-Regular", size: 13))
                        .foregroundStyle(Color.lingoMuted)
                }
                .padding(16)
                .background(Color.white)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 18,
                        style: .continuous
                    )
                )
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Phrase")
        .navigationBarTitleDisplayMode(.inline)
    }
}
