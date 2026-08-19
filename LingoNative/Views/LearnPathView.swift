import SwiftUI

struct LearnPathView: View {
    let course: LanguageCourse
    @ObservedObject var progress: ProgressStore

    @State private var corpus: Corpus?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let corpus {
                ScrollView {
                    LazyVStack(spacing: 34) {
                        header(corpus: corpus)

                        ForEach(Array(corpus.units.enumerated()), id: \.element.id) { index, unit in
                            UnitSectionView(
                                unit: unit,
                                unitIndex: index,
                                course: course,
                                allUnits: corpus.units,
                                allPhrases: corpus.entries,
                                progress: progress
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 60)
                }
                .background(Color(.systemGroupedBackground))
            } else if let loadError {
                ContentUnavailableView(
                    "Couldn’t load the course",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else {
                ProgressView("Building your path…")
            }
        }
        .navigationTitle(course.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    Label("\(progress.hearts)", systemImage: "heart.fill")
                        .foregroundStyle(.red)
                    Label("\(progress.xp)", systemImage: "bolt.fill")
                        .foregroundStyle(.lingoGold)
                }
                .font(.subheadline.weight(.black))
            }
        }
        .task {
            guard corpus == nil else { return }
            do {
                corpus = try CorpusLoader.load(course: course)
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private func header(corpus: Corpus) -> some View {
        VStack(spacing: 8) {
            Text(course.flag)
                .font(.system(size: 48))
            Text("Opinions & Reactions")
                .font(.title2.weight(.black))
                .foregroundStyle(.lingoInk)
            Text("\(corpus.entries.count) phrases · \(corpus.units.count) units")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.lingoMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}
