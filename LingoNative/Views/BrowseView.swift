import SwiftUI

// MARK: - Browse term tools

private struct BrowsePhraseHit: Identifiable {
    let source: PhraseEntry
    let display: PhraseEntry

    var id: String { source.id }
}

private struct BrowseLemmaHit: Identifiable {
    let sourcePhrase: PhraseEntry
    let sourceLemma: Lemma
    let displayLemma: Lemma
    let lemmaIndex: Int

    var id: String {
        "\(sourcePhrase.id):lemma:\(lemmaIndex)"
    }
}

private struct BrowseSearchResults {
    let phrases: [BrowsePhraseHit]
    let lemmas: [BrowseLemmaHit]
}

private struct BrowseEditItem: Identifiable {
    enum Kind {
        case phrase
        case lemma
    }

    let kind: Kind
    let phrase: PhraseEntry
    let lemma: Lemma?

    var id: String {
        switch kind {
        case .phrase:
            return "phrase:\(phrase.id)"
        case .lemma:
            let lemmaID = lemma?.id ?? ""
            return "lemma:\(phrase.id):\(lemmaID)"
        }
    }
}

struct BrowseView: View {
    let corpus: Corpus
    @ObservedObject var progress: ProgressStore
    @ObservedObject var settings: SettingsStore

    @ObservedObject private var edits = TermEditStore.shared

    @State private var query = ""
    @State private var bookmarksOnly = false
    @State private var selectedTopicID: String?
    @State private var displayedEntries: [PhraseEntry] = []
    @State private var contextText = ""
    @State private var showContext = false
    @State private var editingItem: BrowseEditItem?

    private var activeEntries: [PhraseEntry] {
        displayedEntries.isEmpty
            ? corpus.entries
            : displayedEntries
    }

    private var searchResults: BrowseSearchResults {
        let trimmed = query
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let needle = trimmed.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )

        var phraseHits: [BrowsePhraseHit] = []
        var lemmaHits: [BrowseLemmaHit] = []

        for index in corpus.entries.indices {
            let source = corpus.entries[index]
            let display = activeEntries.indices.contains(index)
                ? activeEntries[index]
                : source

            if let selectedTopicID,
               source.topicID != selectedTopicID {
                continue
            }

            if bookmarksOnly
                && !progress.isBookmarked(
                    course: corpus.course,
                    phrase: source
                ) {
                continue
            }

            if trimmed.isEmpty {
                phraseHits.append(
                    BrowsePhraseHit(
                        source: source,
                        display: display
                    )
                )
                continue
            }

            if phraseMatches(display, needle: needle) {
                phraseHits.append(
                    BrowsePhraseHit(
                        source: source,
                        display: display
                    )
                )
            }

            for lemmaIndex in source.lemmas.indices {
                let sourceLemma = source.lemmas[lemmaIndex]
                let displayLemma =
                    display.lemmas.indices.contains(lemmaIndex)
                    ? display.lemmas[lemmaIndex]
                    : sourceLemma

                if lemmaMatches(
                    displayLemma,
                    needle: needle
                ) {
                    lemmaHits.append(
                        BrowseLemmaHit(
                            sourcePhrase: source,
                            sourceLemma: sourceLemma,
                            displayLemma: displayLemma,
                            lemmaIndex: lemmaIndex
                        )
                    )
                }
            }
        }

        return BrowseSearchResults(
            phrases: phraseHits,
            lemmas: lemmaHits
        )
    }

    var body: some View {
        let results = searchResults

        List {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.lingoMuted)

                    TextField(
                        "Search \(corpus.course.title), English or context",
                        text: $query
                    )
                    .font(.custom("Fredoka-Regular", size: 16))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.lingoMuted.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.vertical, 2)
            }

            Section {
                Menu {
                    Button {
                        selectedTopicID = nil
                    } label: {
                        if selectedTopicID == nil {
                            Label("All topics", systemImage: "checkmark")
                        } else {
                            Text("All topics")
                        }
                    }

                    Divider()

                    ForEach(corpus.topics) { topic in
                        Button {
                            selectedTopicID = topic.id
                        } label: {
                            Label(
                                topic.title,
                                systemImage: selectedTopicID == topic.id
                                    ? "checkmark"
                                    : topic.icon
                            )
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill")
                            .foregroundStyle(
                                corpus.course == .french
                                    ? Color.lingoBlue
                                    : Color.lingoGreen
                            )

                        Text("Topic")
                            .font(.custom("Fredoka-Regular", size: 16))
                            .foregroundStyle(Color.lingoInk)

                        Spacer()

                        Text(
                            corpus.topics.first(
                                where: { $0.id == selectedTopicID }
                            )?.title ?? "All topics"
                        )
                        .font(.custom("Fredoka-Regular", size: 15))
                        .foregroundStyle(Color.lingoMuted)
                        .lineLimit(1)

                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.lingoMuted)
                    }
                }
                .buttonStyle(.plain)

                Toggle(isOn: $bookmarksOnly) {
                    Label(
                        "Bookmarked only",
                        systemImage: "bookmark.fill"
                    )
                    .font(.custom("Fredoka-Regular", size: 16))
                }
            }

            if !results.phrases.isEmpty {
                Section {
                    ForEach(results.phrases) { hit in
                        phraseResultRow(hit)
                    }
                } header: {
                    Text(
                        "\(results.phrases.count) phrase\(results.phrases.count == 1 ? "" : "s")"
                    )
                    .font(.custom("Fredoka-SemiBold", size: 13))
                }
            }

            if !query
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty,
               !results.lemmas.isEmpty {

                Section {
                    ForEach(results.lemmas) { hit in
                        lemmaResultRow(hit)
                    }
                } header: {
                    Text(
                        "\(results.lemmas.count) lemma\(results.lemmas.count == 1 ? "" : "s") / chunk\(results.lemmas.count == 1 ? "" : "s")"
                    )
                    .font(.custom("Fredoka-SemiBold", size: 13))
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search \(corpus.course.title), English or context"
        )
        .navigationTitle("Browse")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            rebuildDisplayedEntries()
        }
        .onChange(of: edits.revision) { _, _ in
            rebuildDisplayedEntries()
        }
        .alert(
            "Context",
            isPresented: $showContext
        ) {
            Button("Close", role: .cancel) { }
        } message: {
            Text(contextText)
        }
        .sheet(item: $editingItem) { item in
            BrowseTermEditorSheet(
                course: corpus.course,
                item: item,
                edits: edits
            ) {
                TopicCorpusCache.shared.removeAll()
                CourseCorpusCache.shared.release(
                    course: corpus.course
                )
            }
        }
    }

    private func phraseResultRow(
        _ hit: BrowsePhraseHit
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            NavigationLink {
                PhraseDetailView(
                    course: corpus.course,
                    phrase: hit.source,
                    progress: progress,
                    settings: settings
                )
            } label: {
                phraseTextBlock(hit.display)
            }
            .buttonStyle(.plain)

            VStack(spacing: 6) {
                if !hit.source.context
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty {
                    Button {
                        showContext(hit.source.context)
                    } label: {
                        browseToolIcon(
                            "lightbulb.fill",
                            color: .lingoGold
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show context")
                }

                StarButton(
                    course: corpus.course,
                    phrase: hit.source
                )

                Button {
                    editingItem = BrowseEditItem(
                        kind: .phrase,
                        phrase: hit.source,
                        lemma: nil
                    )
                } label: {
                    browseToolIcon(
                        "square.and.pencil",
                        color: .lingoBlue
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit phrase")
            }
        }
        .padding(.vertical, 4)
    }

    private func phraseTextBlock(
        _ phrase: PhraseEntry
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(phrase.foreign)
                .font(
                    corpus.course == .arabic
                        ? .custom(
                            "NotoSansArabic-Regular",
                            size: 19
                        )
                        : .custom(
                            "Fredoka-Medium",
                            size: 17
                        )
                )
                .foregroundStyle(Color.lingoInk)
                .frame(
                    maxWidth: .infinity,
                    alignment: corpus.course == .arabic
                        ? .trailing
                        : .leading
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
    }

    private func lemmaResultRow(
        _ hit: BrowseLemmaHit
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            NavigationLink {
                PhraseDetailView(
                    course: corpus.course,
                    phrase: hit.sourcePhrase,
                    progress: progress,
                    settings: settings
                )
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(hit.displayLemma.foreign)
                        .font(
                            corpus.course == .arabic
                                ? .custom(
                                    "NotoSansArabic-Regular",
                                    size: 19
                                )
                                : .custom(
                                    "Fredoka-Medium",
                                    size: 17
                                )
                        )
                        .foregroundStyle(Color.lingoInk)
                        .frame(
                            maxWidth: .infinity,
                            alignment: corpus.course == .arabic
                                ? .trailing
                                : .leading
                        )

                    if corpus.course == .arabic,
                       let transliteration =
                        hit.displayLemma.transliteration,
                       !transliteration.isEmpty {
                        Text(transliteration)
                            .font(
                                .custom(
                                    "Fredoka-Regular",
                                    size: 12
                                )
                            )
                            .foregroundStyle(Color.lingoMuted)
                    }

                    Text(hit.displayLemma.english)
                        .font(.custom("Fredoka-Regular", size: 15))
                        .foregroundStyle(Color.lingoMuted)

                    Text("From: \(hit.sourcePhrase.foreign)")
                        .font(.custom("Fredoka-Regular", size: 12))
                        .foregroundStyle(Color.lingoMuted)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)

            VStack(spacing: 6) {
                if !hit.sourcePhrase.context
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty {
                    Button {
                        showContext(
                            hit.sourcePhrase.context
                        )
                    } label: {
                        browseToolIcon(
                            "lightbulb.fill",
                            color: .lingoGold
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show context")
                }

                StarButton(
                    course: corpus.course,
                    lemma: hit.sourceLemma
                )

                Button {
                    editingItem = BrowseEditItem(
                        kind: .lemma,
                        phrase: hit.sourcePhrase,
                        lemma: hit.sourceLemma
                    )
                } label: {
                    browseToolIcon(
                        "square.and.pencil",
                        color: .lingoBlue
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit lemma or chunk")
            }
        }
        .padding(.vertical, 4)
    }

    private func browseToolIcon(
        _ systemName: String,
        color: Color
    ) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 40, height: 40)
            .background(Color.black.opacity(0.055))
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 12,
                    style: .continuous
                )
            )
    }

    private func showContext(
        _ text: String
    ) {
        contextText = text
        showContext = true
    }

    private func rebuildDisplayedEntries() {
        displayedEntries = edits.applying(
            course: corpus.course,
            to: corpus.entries
        )
    }

    private func phraseMatches(
        _ phrase: PhraseEntry,
        needle: String
    ) -> Bool {
        folded(phrase.foreign).contains(needle)
            || folded(phrase.english).contains(needle)
            || folded(phrase.context).contains(needle)
            || folded(phrase.transliteration ?? "")
                .contains(needle)
    }

    private func lemmaMatches(
        _ lemma: Lemma,
        needle: String
    ) -> Bool {
        folded(lemma.foreign).contains(needle)
            || folded(lemma.english).contains(needle)
            || folded(lemma.transliteration ?? "")
                .contains(needle)
    }

    private func folded(
        _ text: String
    ) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }
}

private struct PhraseDetailView: View {
    let course: LanguageCourse
    let phrase: PhraseEntry

    @ObservedObject var progress: ProgressStore
    @ObservedObject var settings: SettingsStore
    @ObservedObject private var edits = TermEditStore.shared

    @StateObject private var speaker = SpeechSynthesizer()
    @State private var showContext = false
    @State private var editingItem: BrowseEditItem?

    private var displayPhrase: PhraseEntry {
        edits.applying(
            course: course,
            to: phrase
        )
    }

    private var stats: PhraseProgress {
        progress.stats(
            course: course,
            phrase: phrase
        )
    }

    var body: some View {
        let shown = displayPhrase

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(shown.context)
                        .font(.custom("Fredoka-SemiBold", size: 13))
                        .foregroundStyle(
                            course == .french
                                ? Color.lingoBlue
                                : Color.lingoGreen
                        )

                    Text(shown.foreign)
                        .font(
                            course == .arabic
                                ? .custom(
                                    "NotoSansArabic-Regular",
                                    size: 36
                                )
                                : .custom(
                                    "Fredoka-Medium",
                                    size: 34
                                )
                        )
                        .foregroundStyle(Color.lingoInk)
                        .frame(
                            maxWidth: .infinity,
                            alignment: course == .arabic
                                ? .trailing
                                : .leading
                        )

                    if course == .arabic,
                       let transliteration = shown.transliteration,
                       !transliteration.isEmpty {
                        Text(transliteration)
                            .font(.custom("Fredoka-Regular", size: 16))
                            .foregroundStyle(Color.lingoMuted)
                    }

                    Text(shown.english)
                        .font(.custom("Fredoka-Regular", size: 20))
                        .foregroundStyle(Color.lingoMuted)
                }

                HStack(spacing: 10) {
                    Button {
                        speaker.speak(
                            shown.foreign,
                            course: course,
                            rate: settings.speechRate
                        )
                    } label: {
                        browseDetailAction(
                            "speaker.wave.2.fill",
                            label: "Listen",
                            color: .lingoBlue
                        )
                    }
                    .buttonStyle(.plain)

                    if !shown.context
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty {
                        Button {
                            showContext = true
                        } label: {
                            browseDetailAction(
                                "lightbulb.fill",
                                label: "Context",
                                color: .lingoGold
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    StarButton(
                        course: course,
                        phrase: phrase
                    )

                    Button {
                        editingItem = BrowseEditItem(
                            kind: .phrase,
                            phrase: phrase,
                            lemma: nil
                        )
                    } label: {
                        browseDetailAction(
                            "square.and.pencil",
                            label: "Edit",
                            color: .lingoBlue
                        )
                    }
                    .buttonStyle(.plain)

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
                        .foregroundStyle(Color.lingoGold)
                        .frame(width: 40, height: 40)
                        .background(Color.black.opacity(0.055))
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: 12,
                                style: .continuous
                            )
                        )
                    }
                    .buttonStyle(.plain)
                }

                if !shown.lemmas.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("LEMMAS & CHUNKS")
                            .font(.custom("Fredoka-SemiBold", size: 13))
                            .foregroundStyle(Color.lingoMuted)

                        ForEach(
                            Array(shown.lemmas.enumerated()),
                            id: \.offset
                        ) { index, lemma in
                            let sourceLemma =
                                phrase.lemmas.indices.contains(index)
                                ? phrase.lemmas[index]
                                : lemma

                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(lemma.foreign)
                                        .font(
                                            course == .arabic
                                                ? .custom(
                                                    "NotoSansArabic-Regular",
                                                    size: 19
                                                )
                                                : .custom(
                                                    "Fredoka-Medium",
                                                    size: 17
                                                )
                                        )
                                        .foregroundStyle(Color.lingoInk)

                                    if course == .arabic,
                                       let transliteration =
                                        lemma.transliteration,
                                       !transliteration.isEmpty {
                                        Text(transliteration)
                                            .font(
                                                .custom(
                                                    "Fredoka-Regular",
                                                    size: 12
                                                )
                                            )
                                            .foregroundStyle(Color.lingoMuted)
                                    }

                                    Text(lemma.english)
                                        .font(.custom("Fredoka-Regular", size: 15))
                                        .foregroundStyle(Color.lingoMuted)
                                }

                                Spacer()

                                StarButton(
                                    course: course,
                                    lemma: sourceLemma
                                )

                                Button {
                                    editingItem = BrowseEditItem(
                                        kind: .lemma,
                                        phrase: phrase,
                                        lemma: sourceLemma
                                    )
                                } label: {
                                    Image(systemName: "square.and.pencil")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(Color.lingoBlue)
                                        .frame(width: 40, height: 40)
                                        .background(Color.black.opacity(0.055))
                                        .clipShape(
                                            RoundedRectangle(
                                                cornerRadius: 12,
                                                style: .continuous
                                            )
                                        )
                                }
                                .buttonStyle(.plain)
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
        .alert(
            "Context",
            isPresented: $showContext
        ) {
            Button("Close", role: .cancel) { }
        } message: {
            Text(shown.context)
        }
        .sheet(item: $editingItem) { item in
            BrowseTermEditorSheet(
                course: course,
                item: item,
                edits: edits
            ) {
                TopicCorpusCache.shared.removeAll()
                CourseCorpusCache.shared.release(
                    course: course
                )
            }
        }
    }

    private func browseDetailAction(
        _ systemName: String,
        label: String,
        color: Color
    ) -> some View {
        VStack(spacing: 3) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
            Text(label)
                .font(.custom("Fredoka-Regular", size: 9))
        }
        .foregroundStyle(color)
        .frame(width: 48, height: 42)
        .background(Color.black.opacity(0.055))
        .clipShape(
            RoundedRectangle(
                cornerRadius: 12,
                style: .continuous
            )
        )
    }
}

private struct BrowseTermEditorSheet: View {
    let course: LanguageCourse
    let item: BrowseEditItem
    @ObservedObject var edits: TermEditStore
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var foreignDraft: String
    @State private var englishDraft: String

    init(
        course: LanguageCourse,
        item: BrowseEditItem,
        edits: TermEditStore,
        onSaved: @escaping () -> Void
    ) {
        self.course = course
        self.item = item
        self.edits = edits
        self.onSaved = onSaved

        let originalForeign: String
        let originalEnglish: String
        let key: String

        switch item.kind {
        case .phrase:
            originalForeign = item.phrase.foreign
            originalEnglish = item.phrase.english
            key = TermEditStore.phraseKey(
                course: course,
                phraseID: item.phrase.id
            )

        case .lemma:
            let lemma = item.lemma
                ?? Lemma(foreign: "", english: "")
            originalForeign = lemma.foreign
            originalEnglish = lemma.english
            key = TermEditStore.lemmaKey(
                course: course,
                foreign: originalForeign,
                english: originalEnglish
            )
        }

        let current = edits.effectiveText(
            key: key,
            foreign: originalForeign,
            english: originalEnglish
        )

        _foreignDraft = State(
            initialValue: current.foreign
        )
        _englishDraft = State(
            initialValue: current.english
        )
    }

    private var originalForeign: String {
        switch item.kind {
        case .phrase:
            return item.phrase.foreign
        case .lemma:
            return item.lemma?.foreign ?? ""
        }
    }

    private var originalEnglish: String {
        switch item.kind {
        case .phrase:
            return item.phrase.english
        case .lemma:
            return item.lemma?.english ?? ""
        }
    }

    private var editKey: String {
        switch item.kind {
        case .phrase:
            return TermEditStore.phraseKey(
                course: course,
                phraseID: item.phrase.id
            )
        case .lemma:
            return TermEditStore.lemmaKey(
                course: course,
                foreign: originalForeign,
                english: originalEnglish
            )
        }
    }

    private var canSave: Bool {
        !foreignDraft
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        && !englishDraft
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(originalForeign)
                        .font(
                            course == .arabic
                                ? .custom(
                                    "NotoSansArabic-Regular",
                                    size: 18
                                )
                                : .custom(
                                    "Fredoka-Medium",
                                    size: 16
                                )
                        )

                    Text(originalEnglish)
                        .font(.custom("Fredoka-Regular", size: 14))
                        .foregroundStyle(Color.lingoMuted)
                } header: {
                    Text("Original")
                }

                Section {
                    TextField(
                        course.title,
                        text: $foreignDraft,
                        axis: .vertical
                    )
                    .font(
                        course == .arabic
                            ? .custom(
                                "NotoSansArabic-Regular",
                                size: 19
                            )
                            : .custom(
                                "Fredoka-Regular",
                                size: 17
                            )
                    )
                    .multilineTextAlignment(
                        course == .arabic
                            ? .trailing
                            : .leading
                    )

                    TextField(
                        "English",
                        text: $englishDraft,
                        axis: .vertical
                    )
                    .font(.custom("Fredoka-Regular", size: 17))
                } header: {
                    Text("Edit")
                } footer: {
                    Text(
                        "This changes the term in LingoNative on this device. The bundled source corpus remains untouched."
                    )
                }

                if edits.hasEdit(forKey: editKey) {
                    Section {
                        Button(
                            "Restore original",
                            role: .destructive
                        ) {
                            edits.removeEdit(
                                forKey: editKey
                            )
                            onSaved()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(
                item.kind == .phrase
                    ? "Edit phrase"
                    : "Edit lemma / chunk"
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(
                    placement: .cancellationAction
                ) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(
                    placement: .confirmationAction
                ) {
                    Button("Save") {
                        save()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        let foreign = foreignDraft
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let english = englishDraft
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch item.kind {
        case .phrase:
            edits.setPhrase(
                course: course,
                phraseID: item.phrase.id,
                originalForeign: item.phrase.foreign,
                originalEnglish: item.phrase.english,
                foreign: foreign,
                english: english
            )

        case .lemma:
            guard let lemma = item.lemma else {
                return
            }

            edits.setLemma(
                course: course,
                originalForeign: lemma.foreign,
                originalEnglish: lemma.english,
                foreign: foreign,
                english: english
            )
        }

        onSaved()
        dismiss()
    }
}
