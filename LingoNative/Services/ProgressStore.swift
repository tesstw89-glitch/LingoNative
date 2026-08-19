import Foundation

@MainActor
final class ProgressStore: ObservableObject {
    @Published private(set) var completedNodeIDs: Set<String>
    @Published private(set) var hearts: Int
    @Published private(set) var xp: Int

    private let defaults: UserDefaults
    private let completedKey = "completedNodeIDs"
    private let heartsKey = "hearts"
    private let xpKey = "xp"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.completedNodeIDs = Set(defaults.stringArray(forKey: completedKey) ?? [])

        if defaults.object(forKey: heartsKey) == nil {
            self.hearts = 5
        } else {
            self.hearts = defaults.integer(forKey: heartsKey)
        }

        self.xp = defaults.integer(forKey: xpKey)
    }

    func isCompleted(_ nodeID: String) -> Bool {
        completedNodeIDs.contains(nodeID)
    }

    func complete(nodeID: String, earnedXP: Int) {
        completedNodeIDs.insert(nodeID)
        xp += earnedXP
        persist()
    }

    @discardableResult
    func loseHeart() -> Int {
        hearts = max(0, hearts - 1)
        persist()
        return hearts
    }

    func refillHearts() {
        hearts = 5
        persist()
    }

    func resetAllProgress() {
        completedNodeIDs = []
        hearts = 5
        xp = 0
        persist()
    }

    private func persist() {
        defaults.set(Array(completedNodeIDs), forKey: completedKey)
        defaults.set(hearts, forKey: heartsKey)
        defaults.set(xp, forKey: xpKey)
    }
}
