import SwiftUI

struct ContentView: View {
    @ObservedObject var progress: ProgressStore
    @ObservedObject var settings: SettingsStore

    var body: some View {
        NavigationStack {
            CoursePickerView(progress: progress, settings: settings)
        }
        .tint(Color.lingoGreen)
        .preferredColorScheme(settings.darkModeEnabled ? .dark : .light)
    }
}
