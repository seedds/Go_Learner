//
//  GoLearnerApp.swift
//  GoLearner
//
//  An iPhone Go app powered by the KataGo neural network running on the
//  Apple Neural Engine via Core ML.
//

import SwiftUI

@main
struct GoLearnerApp: App {
    @State private var game = GameState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(game)
        }
    }
}
