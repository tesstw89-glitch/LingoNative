import SwiftUI

struct CourseHomeView: View {
    let course: LanguageCourse
    @ObservedObject var progress: ProgressStore
    @ObservedObject var settings: SettingsStore

    @State private var corpus: Corpus?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let corpus {
                TabView {
                    LearnPathView(corpus: corpus, progress: progress, settings: settings)
                        .tabItem { Label("Learn", systemImage: "house.fill") }

                    PracticeHubView(corpus: corpus, progress: progress, settings: settings)
                        .tabItem { Label("Practice", systemImage: "dumbbell.fill") }

                    BrowseView(corpus: corpus, progress: progress, settings: settings)
                        .tabItem { Label("Browse", systemImage: "books.vertical.fill") }

                    StatsView(corpus: corpus, progress: progress, settings: settings)
                        .tabItem { Label("Stats", systemImage: "chart.bar.fill") }

                    SettingsView(course: course, progress: progress, settings: settings)
                        .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                }
                .tint(course == .french ? Color.lingoBlue : Color.lingoGreen)
            } else if let loadError {
                ContentUnavailableView(
                    "Couldn’t load the course",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else {
                ProgressView("Building your course…")
            }
        }
        .navigationTitle("\(course.flag) \(course.title)")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard corpus == nil else { return }
            do {
                corpus = try CorpusLoader.load(course: course)
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}
