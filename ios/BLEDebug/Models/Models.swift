// Models.swift
// BLE Debug - iOS Native App
// Data models mirroring the WeChat miniapp structure

import Foundation
import CoreBluetooth

// MARK: - BLE Device

struct BLEDevice: Identifiable, Hashable {
    let id: String          // deviceId (UUID string on iOS)
    var name: String
    var rssi: Int
    var advertisedServices: [String]
    var peripheral: CBPeripheral?

    init(peripheral: CBPeripheral, rssi: Int, advertisedServices: [String] = []) {
        self.id = peripheral.identifier.uuidString
        self.name = peripheral.name ?? ""
        self.rssi = rssi
        self.advertisedServices = advertisedServices
        self.peripheral = peripheral
    }

    var displayName: String {
        name.isEmpty ? "未知设备" : name
    }

    var rssiLabel: String { "\(rssi) dBm" }

    var rssiStrength: RSSIStrength {
        if rssi >= -60 { return .strong }
        if rssi >= -70 { return .medium }
        if rssi >= -80 { return .weak }
        return .veryWeak
    }

    static func == (lhs: BLEDevice, rhs: BLEDevice) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum RSSIStrength {
    case strong, medium, weak, veryWeak
}

// MARK: - BLE Service

struct BLEService: Identifiable {
    let id: String          // UUID string
    var isPrimary: Bool
    var characteristics: [BLECharacteristic]
    var isExpanded: Bool = false

    init(cbService: CBService) {
        self.id = cbService.uuid.uuidString
        self.isPrimary = cbService.isPrimary
        self.characteristics = []
    }

    var shortUUID: String {
        if id.count == 4 { return id.uppercased() }
        return String(id.prefix(8)).uppercased()
    }
}

// MARK: - BLE Characteristic

struct BLECharacteristic: Identifiable {
    let id: String          // UUID string
    var serviceId: String
    var canRead: Bool
    var canWrite: Bool
    var canWriteWithoutResponse: Bool
    var canNotify: Bool
    var canIndicate: Bool

    init(cbChar: CBCharacteristic, serviceId: String) {
        self.id = cbChar.uuid.uuidString
        self.serviceId = serviceId
        self.canRead              = cbChar.properties.contains(.read)
        self.canWrite             = cbChar.properties.contains(.write)
        self.canWriteWithoutResponse = cbChar.properties.contains(.writeWithoutResponse)
        self.canNotify            = cbChar.properties.contains(.notify)
        self.canIndicate          = cbChar.properties.contains(.indicate)
    }

    var propertyBadges: [PropertyBadge] {
        var badges: [PropertyBadge] = []
        if canRead              { badges.append(.read) }
        if canWrite             { badges.append(.write) }
        if canWriteWithoutResponse { badges.append(.writeNoResp) }
        if canNotify            { badges.append(.notify) }
        if canIndicate          { badges.append(.indicate) }
        return badges
    }

    var shortUUID: String {
        if id.count == 4 { return id.uppercased() }
        return String(id.prefix(8)).uppercased()
    }
}

enum PropertyBadge: String {
    case read       = "Read"
    case write      = "Write"
    case writeNoResp = "WriteNoResp"
    case notify     = "Notify"
    case indicate   = "Indicate"
}

// MARK: - Log Entry

enum LogDirection: String, CaseIterable {
    case send  = "send"
    case recv  = "recv"
    case info  = "info"
    case error = "error"

    var label: String {
        switch self {
        case .send:  return "→ TX"
        case .recv:  return "← RX"
        case .info:  return "ℹ INFO"
        case .error: return "✕ ERR"
        }
    }

    var color: String {
        switch self {
        case .send:  return "logSend"
        case .recv:  return "logRecv"
        case .info:  return "logInfo"
        case .error: return "logError"
        }
    }
}

struct LogEntry: Identifiable {
    let id: UUID = UUID()
    let time: String
    let direction: LogDirection
    let uuid: String
    let data: String

    var copyText: String {
        let uuidPart = uuid.isEmpty ? "" : "\(uuid) "
        return "[\(time)] \(direction.rawValue.uppercased().padding(toLength: 5, withPad: " ", startingAt: 0)) \(uuidPart)\(data)"
    }

    static func make(direction: LogDirection, uuid: String = "", data: String) -> LogEntry {
        let now = Date()
        let cal = Calendar.current
        let h   = cal.component(.hour,        from: now)
        let m   = cal.component(.minute,      from: now)
        let s   = cal.component(.second,      from: now)
        let ms  = Int(now.timeIntervalSince1970 * 1000) % 1000
        let time = String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
        return LogEntry(time: time, direction: direction, uuid: uuid, data: data)
    }
}

// MARK: - Quick Action (persistent)

struct QuickAction: Identifiable, Codable {
    var id: String = UUID().uuidString
    var name: String
    var deviceName: String = ""
    var deviceMac: String = ""       // peripheral UUID string
    var serviceUuid: String = ""
    var charUuid: String
    var writeType: WriteType = .hex
    var value: String
    var color: ActionColor = .blue
    // 写入后等待 Notify 响应
    var waitForNotify: Bool = false
    var notifyCharUuid: String = ""  // 留空则用 charUuid 本身

    enum WriteType: String, Codable, CaseIterable {
        case hex  = "hex"
        case text = "text"
    }

    enum ActionColor: String, Codable, CaseIterable {
        case blue, green, orange, red, purple, teal

        var label: String {
            switch self {
            case .blue:   return "蓝"
            case .green:  return "绿"
            case .orange: return "橙"
            case .red:    return "红"
            case .purple: return "紫"
            case .teal:   return "青"
            }
        }

        var background: String {
            switch self {
            case .blue:   return "#e8f0fe"
            case .green:  return "#e8f5e9"
            case .orange: return "#fff3e0"
            case .red:    return "#ffebee"
            case .purple: return "#f3e5f5"
            case .teal:   return "#e0f2f1"
            }
        }
    }
}

// MARK: - Preset Value

struct PresetValue: Identifiable, Codable {
    var id: String = UUID().uuidString
    var name: String
    var value: String
    var type: QuickAction.WriteType
}

// MARK: - Write Input Model

enum WriteInputType: String, CaseIterable {
    case hex  = "HEX"
    case text = "TEXT"
}
