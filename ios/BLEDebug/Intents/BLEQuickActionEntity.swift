// BLEQuickActionEntity.swift
// AppIntents entity - represents a saved QuickAction

import AppIntents
import Foundation

// MARK: - Entity

struct BLEQuickActionEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "BLE 快捷操作"
    static var defaultQuery = BLEQuickActionQuery()

    var id: String
    var name: String
    var charUuid: String
    var serviceUuid: String
    var writeType: String   // "hex" | "text"
    var value: String
    var deviceName: String
    var deviceMac: String

    var displayRepresentation: DisplayRepresentation {
        let subtitle = "\(writeType.uppercased()): \(value)"
        return DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(subtitle)"
        )
    }

    /// Convert from persisted QuickAction model
    init(from action: QuickAction) {
        self.id          = action.id
        self.name        = action.name
        self.charUuid    = action.charUuid
        self.serviceUuid = action.serviceUuid
        self.writeType   = action.writeType.rawValue
        self.value       = action.value
        self.deviceName  = action.deviceName
        self.deviceMac   = action.deviceMac
    }
}

// MARK: - Query

struct BLEQuickActionQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [BLEQuickActionEntity] {
        QuickActionsStore.shared.actions
            .filter { identifiers.contains($0.id) }
            .map { BLEQuickActionEntity(from: $0) }
    }

    func suggestedEntities() async throws -> [BLEQuickActionEntity] {
        QuickActionsStore.shared.actions.map { BLEQuickActionEntity(from: $0) }
    }
}
