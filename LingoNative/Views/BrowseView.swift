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
                || entry.lemmas.contains { $0.foreign.lowercased().contains(needle) || $0.english.lowercased().contains(needle) }
        }
    }

    var body: some View {
        List {
            Section {
                Toggle(isOn: $bookmarksOnly) {
                    Label("Bookmarked only", systemImage: "bookmark.fill")
                }
            }

            Section("\(filteredEntries.count) phrases") {
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
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "Search phrase, translation or context")
        .navigationTitle("Browse")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func phraseRow(_ phrase: PhraseEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(phrase.foreign)
                    .font(.body.weight(.bold))
                    .foregroundStyle(Color.lingoInk)
                Text(phrase.english)
                    .font(.subheadline)
                    .foregroundStyle(Color.lingoMuted)
                Text(phrase.context)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(corpus.course == .french ? Color.lingoBlue : Color.lingoGreen)
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
                VStack(alignment: .leading, spacing: 10) {
                    Text(phrase.context)
                        .font(.caption.weight(.black))
                        .foregroundStyle(course == .french ? Color.lingoBlue : Color.lingoGreen)
                    Text(phrase.foreign)
                        .font(.largeTitle.weight(.black))
                        .foregroundStyle(Color.lingoInk)
                    Text(phrase.english)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.lingoMuted)
                }

                HStack(spacing: 12) {
                    Button {
                        speaker.speak(phrase.foreign, course: course, rate: settings.speechRate)
                    } label: {
                        Label("Listen", systemImage: "speaker.wave.2.fill")
                    }
                    .buttonStyle(DuoButtonStyle(fill: Color.lingoBlue, shadow: Color(red: 0.08, green: 0.47, blue: 0.70)))

                    Button {
                        progress.toggleBookmark(course: course, phrase: phrase)
                    } label: {
                        Image(systemName: progress.isBookmarked(course: course, phrase: phrase) ? "bookmark.fill" : "bookmark")
                            .font(.headline)
                            .frame(width: 48)
                    }
                    .buttonStyle(DuoButtonStyle(fill: Color.lingoGold, shadow: Color(red: 0.82, green: 0.59, blue: 0.05), foreground: Color.lingoInk))
                }

                if !phrase.lemmas.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("LEMMAS & CHUNKS")
                            .font(.caption.weight(.black))
                            .foregroundStyle(Color.lingoMuted)
                        ForEach(phrase.lemmas) { lemma in
                            HStack(alignment: .top) {
                                Text(lemma.foreign)
                                    .font(.body.weight(.bold))
                                Spacer()
                                Text(lemma.english)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.lingoMuted)
                                    .multilineTextAlignment(.trailing)
                            }
                            .padding(12)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("YOUR HISTORY")
                        .font(.caption.weight(.black))
                        .foregroundStyle(Color.lingoMuted)
                    HStack(spacing: 10) {
                        StatPill(systemImage: "eye.fill", value: "\(stats.seen)", tint: Color.lingoBlue)
                        StatPill(systemImage: "checkmark.circle.fill", value: "\(stats.correct)", tint: Color.lingoGreen)
                        StatPill(systemImage: "xmark.circle.fill", value: "\(stats.wrong)", tint: Color.lingoWrong)
                    }
                    ProgressView(value: stats.mastery)
                        .tint(Color.lingoGreen)
                    Text("Mastery \(Int(stats.mastery * 100))%")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.lingoMuted)
                }
                .padding(16)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Phrase")
        .navigationBarTitleDisplayMode(.inline)
    }
}
