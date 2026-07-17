//
//  GoLearnerApp.swift
//  GoLearner
//
//  An iPhone Go app powered by the KataGo neural network running on the
//  Apple Neural Engine via Core ML.
//

import SwiftUI
import SwiftData

@main
struct GoLearnerApp: App {
    @State private var game = GameState()
    private let container = GoLearnerApp.makeContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(game)
        }
        .modelContainer(container)
    }

    /// Build the SwiftData container, falling back to a fresh store if the
    /// on-disk store can't be opened/migrated. Losing the local library is
    /// preferable to a launch crash; games can be re-imported from SGF.
    private static func makeContainer() -> ModelContainer {
        let schema = Schema([SavedGame.self])
        do {
            return try ModelContainer(for: schema)
        } catch {
            let url = URL.applicationSupportDirectory.appending(path: "default.store")
            try? FileManager.default.removeItem(at: url)
            return try! ModelContainer(for: schema)
        }
    }
}
