//
//  EngineHostApp.swift
//  EngineHost
//
//  Minimal SwiftUI host app for the engine smoke tests. It links the full
//  vendored KataGo engine (libkatago.a + KataGoSwift + MLX) and the KataGoGTP
//  bridge, giving the smoke tests the same in-app process environment the
//  engine actually runs in (the CoreML inference path uses Swift Concurrency +
//  GCD, which is unstable in a hostless XCTest bundle). It does nothing on its
//  own; the tests drive the engine.
//

import SwiftUI

@main
struct EngineHostApp: App {
    var body: some Scene {
        WindowGroup {
            Text("GoLearner engine host")
                .padding()
        }
    }
}
