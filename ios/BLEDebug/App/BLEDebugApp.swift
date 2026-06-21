// BLEDebugApp.swift
// App entry point

import SwiftUI

@main
struct BLEDebugApp: App {
    // Use shared singleton so AppIntents can access the same instance
    @StateObject private var bleManager = BLEManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bleManager)
        }
    }
}
