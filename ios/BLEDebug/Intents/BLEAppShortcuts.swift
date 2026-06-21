// BLEAppShortcuts.swift
// Registers intents with Siri / Shortcuts App

import AppIntents

struct BLEAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunBLEQuickActionIntent(),
            phrases: [
                "用 \(.applicationName) 执行快捷操作",
                "用 \(.applicationName) 发送 BLE 指令",
                "用 \(.applicationName) 执行 BLE 快捷操作",
            ],
            shortTitle: "执行 BLE 快捷操作",
            systemImageName: "bolt.fill"
        )
    }
}
