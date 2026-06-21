// ContentView.swift
// Tab bar container - mirrors app.json tabBar config

import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            ScanView()
                .tabItem {
                    Label("扫描", systemImage: "dot.radiowaves.left.and.right")
                }

            QuickActionsView()
                .tabItem {
                    Label("快捷", systemImage: "bolt.fill")
                }

            NavigationStack {
                LogView()
                    .navigationTitle("通信日志")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem {
                Label("日志", systemImage: "doc.text")
            }
        }
        .tint(.blue)
    }
}

#Preview {
    ContentView().environmentObject(BLEManager())
}
