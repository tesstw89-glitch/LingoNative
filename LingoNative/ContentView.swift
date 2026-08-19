import SwiftUI

struct ContentView: View {
    @ObservedObject var progress: ProgressStore

    var body: some View {
        NavigationStack {
            CoursePickerView(progress: progress)
        }
        .tint(.lingoGreen)
    }
}
