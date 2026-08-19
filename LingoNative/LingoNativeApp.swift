import SwiftUI

@main
struct LingoNativeApp: App {
    @StateObject private var progress = ProgressStore()

    var body: some Scene {
        WindowGroup {
            ContentView(progress: progress)
        }
    }
}
