// QuickActionsStore.swift
// Persistent store for Quick Actions and Presets (mirrors storageDefaults.js)

import Foundation
import Combine

class QuickActionsStore: ObservableObject {
    static let shared = QuickActionsStore()

    @Published var actions: [QuickAction] = []
    @Published var presets: [PresetValue] = []

    private let actionsKey = "quick_actions"
    private let presetsKey = "presets_global"

    private init() {
        loadActions()
        loadPresets()
    }

    // MARK: - Quick Actions

    func loadActions() {
        if let data = UserDefaults.standard.data(forKey: actionsKey),
           let decoded = try? JSONDecoder().decode([QuickAction].self, from: data) {
            actions = decoded
        }
    }

    func saveActions() {
        if let encoded = try? JSONEncoder().encode(actions) {
            UserDefaults.standard.set(encoded, forKey: actionsKey)
        }
    }

    func addAction(_ action: QuickAction) {
        actions.insert(action, at: 0)
        saveActions()
    }

    func updateAction(_ action: QuickAction) {
        if let idx = actions.firstIndex(where: { $0.id == action.id }) {
            actions[idx] = action
            saveActions()
        }
    }

    func deleteAction(id: String) {
        actions.removeAll { $0.id == id }
        saveActions()
    }

    // MARK: - Presets

    func loadPresets() {
        if let data = UserDefaults.standard.data(forKey: presetsKey),
           let decoded = try? JSONDecoder().decode([PresetValue].self, from: data) {
            presets = decoded
        }
    }

    func savePresets() {
        if let encoded = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(encoded, forKey: presetsKey)
        }
    }

    func addPreset(_ preset: PresetValue) {
        presets.insert(preset, at: 0)
        savePresets()
    }

    func updatePreset(_ preset: PresetValue) {
        if let idx = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[idx] = preset
            savePresets()
        }
    }

    func deletePreset(id: String) {
        presets.removeAll { $0.id == id }
        savePresets()
    }
}
