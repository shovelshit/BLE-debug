// RunBLEQuickActionIntent.swift
// AppIntent — runs a saved BLE quick action from Shortcuts / Siri

import AppIntents
import CoreBluetooth
import Foundation

// MARK: - Result struct (returned to Shortcuts App)

struct BLEActionResult: TransientAppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "BLE 执行结果"

    @Property(title: "操作名称")   var actionName: String
    @Property(title: "发送数据 HEX") var sentHex: String
    @Property(title: "响应数据 HEX") var receivedHex: String
    @Property(title: "响应数据 ASCII") var receivedAscii: String
    @Property(title: "执行成功")   var success: Bool
    @Property(title: "说明")       var message: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(actionName)",
            subtitle: "\(success ? "✅" : "❌") \(message)"
        )
    }

    init() {
        actionName   = ""
        sentHex      = ""
        receivedHex  = ""
        receivedAscii = ""
        success      = false
        message      = ""
    }
}

// MARK: - Intent

struct RunBLEQuickActionIntent: AppIntent {

    static var title: LocalizedStringResource = "执行 BLE 快捷操作"
    static var description = IntentDescription(
        "连接蓝牙设备并执行已保存的 BLE 写入快捷操作，返回执行结果。",
        categoryName: "BLE 调试"
    )

    // MARK: - Parameter

    @Parameter(title: "快捷操作", description: "选择要执行的 BLE 快捷操作")
    var action: BLEQuickActionEntity

    // MARK: - Perform

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<BLEActionResult> {
        let store  = QuickActionsStore.shared
        guard let model = store.actions.first(where: { $0.id == action.id }) else {
            throw BLEIntentError.actionNotFound
        }

        // Parse data
        let data: Data
        do {
            data = model.writeType == .hex
                ? try DataHelpers.hexToData(model.value)
                : DataHelpers.textToData(model.value)
        } catch {
            throw BLEIntentError.invalidData(model.value)
        }

        let ble = BLEManager.shared

        // ── 0. 等待蓝牙就绪（App 首次启动时 CBCentralManager 需要一点时间初始化）──
        try await ble.waitForBluetoothReady(timeout: 6)

        // ── 1. Connect if needed ───────────────────────────────────────────
        let needConnect = ble.connectedDevice == nil ||
            (!model.deviceMac.isEmpty && ble.connectedDevice?.id != model.deviceMac)

        if needConnect {
            if ble.connectedDevice != nil { ble.disconnect() }

            guard !model.deviceMac.isEmpty else {
                throw BLEIntentError.noDeviceConfigured(model.name)
            }

            // 优先用 retrievePeripherals 直接取回已知设备（不需要扫描）
            // 这对"已经配对/连接过"的设备非常快，无需等待扫描
            if let knownPeripheral = ble.retrievePeripheral(uuid: model.deviceMac) {
                let device = BLEDevice(peripheral: knownPeripheral, rssi: -80)
                try await connect(device: device, ble: ble)
            } else {
                // 兜底：扫描发现（全新设备或系统缓存已清除）
                ble.startScan()
                let peripheral = try await waitForPeripheral(uuid: model.deviceMac, ble: ble, timeout: 10)
                ble.stopScan()
                let device = BLEDevice(peripheral: peripheral, rssi: -80)
                try await connect(device: device, ble: ble)
            }
        }

        // ── 2. Discover services if needed ────────────────────────────────
        if ble.services.isEmpty {
            try await discoverServices(ble: ble)
        }

        // ── 3. Resolve service UUID ────────────────────────────────────────
        let serviceId: String
        let withResponse: Bool
        if !model.serviceUuid.isEmpty {
            serviceId    = model.serviceUuid
            withResponse = ble.services
                .first  { $0.id == serviceId }?
                .characteristics.first { $0.id == model.charUuid }?.canWrite ?? true
        } else {
            guard let svc = ble.services.first(where: { s in
                s.characteristics.contains { $0.id == model.charUuid }
            }) else {
                throw BLEIntentError.characteristicNotFound(model.charUuid)
            }
            serviceId    = svc.id
            withResponse = svc.characteristics.first { $0.id == model.charUuid }?.canWrite ?? true
        }

        // ── 4. Write ───────────────────────────────────────────────────────
        try await write(data: data, serviceId: serviceId, charId: model.charUuid,
                        withResponse: withResponse, ble: ble)

        let hexStr = DataHelpers.toHex(data)
        ble.addLog(.send, uuid: model.charUuid, data: "[快捷指令] \(model.name): \(hexStr)")

        // ── 5. 等待 Notify 响应（如已配置）────────────────────────────────
        var receivedHex   = ""
        var receivedAscii = ""

        if model.waitForNotify {
            let notifyCharId = model.notifyCharUuid.trimmingCharacters(in: .whitespaces)
                .isEmpty ? model.charUuid : model.notifyCharUuid

            // 找响应特征值所属 service
            let notifySvcId: String
            if !model.serviceUuid.isEmpty && notifyCharId == model.charUuid {
                notifySvcId = serviceId
            } else if let svc = ble.services.first(where: { s in
                s.characteristics.contains { $0.id == notifyCharId }
            }) {
                notifySvcId = svc.id
            } else {
                // 找不到，跳过等待
                notifySvcId = ""
            }

            if !notifySvcId.isEmpty {
                let respResult = await withCheckedContinuation { cont in
                    ble.readOnceNotify(serviceId: notifySvcId, charId: notifyCharId,
                                       timeout: 5.0) { cont.resume(returning: $0) }
                }
                switch respResult {
                case .success(let respData):
                    receivedHex   = DataHelpers.toHex(respData)
                    receivedAscii = DataHelpers.toASCII(respData)
                    ble.addLog(.recv, uuid: notifyCharId,
                               data: "[快捷指令响应] \(model.name): \(receivedHex)")
                case .failure(let err):
                    ble.addLog(.info, uuid: notifyCharId,
                               data: "[快捷指令] 等待响应: \(err.localizedDescription)")
                }
            }
        }

        // ── 6. 构建返回结果 ────────────────────────────────────────────────
        var result = BLEActionResult()
        result.actionName    = model.name
        result.sentHex       = hexStr
        result.receivedHex   = receivedHex
        result.receivedAscii = receivedAscii
        result.success       = true

        let dialogMsg: String
        if model.waitForNotify {
            if receivedHex.isEmpty {
                result.message = "写入成功，未收到响应"
                dialogMsg = "✅ 「\(model.name)」发送 \(hexStr)，未收到响应"
            } else {
                result.message = "写入成功，响应: \(receivedHex)"
                dialogMsg = "✅ 「\(model.name)」发送 \(hexStr)\n收到响应: \(receivedHex)"
            }
        } else {
            result.message = "写入成功"
            dialogMsg = "✅ 已执行「\(model.name)」— \(hexStr)"
        }

        return .result(value: result, dialog: "\(dialogMsg)")
    }

    // MARK: - Async helpers

    private func waitForPeripheral(uuid: String, ble: BLEManager, timeout: Double) async throws -> CBPeripheral {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let dev = await MainActor.run(body: { ble.discoveredDevices.first { $0.id == uuid } }) {
                if let p = dev.peripheral { return p }
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw BLEIntentError.deviceNotFound(uuid)
    }

    private func connect(device: BLEDevice, ble: BLEManager) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            Task { @MainActor in
                ble.connect(to: device) { result in
                    switch result {
                    case .success:          cont.resume()
                    case .failure(let e):   cont.resume(throwing: e)
                    }
                }
            }
        }
    }

    private func discoverServices(ble: BLEManager) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            Task { @MainActor in
                ble.discoverServices { result in
                    switch result {
                    case .success:          cont.resume()
                    case .failure(let e):   cont.resume(throwing: e)
                    }
                }
            }
        }
    }

    private func write(data: Data, serviceId: String, charId: String,
                       withResponse: Bool, ble: BLEManager) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            Task { @MainActor in
                ble.writeCharacteristic(serviceId: serviceId, charId: charId,
                                         data: data, withResponse: withResponse) { result in
                    switch result {
                    case .success:          cont.resume()
                    case .failure(let e):   cont.resume(throwing: e)
                    }
                }
            }
        }
    }
}

// MARK: - Errors

enum BLEIntentError: LocalizedError {
    case actionNotFound
    case invalidData(String)
    case noDeviceConfigured(String)
    case deviceNotFound(String)
    case characteristicNotFound(String)

    var errorDescription: String? {
        switch self {
        case .actionNotFound:
            return "未找到该快捷操作，可能已被删除。"
        case .invalidData(let v):
            return "数据格式错误：\(v)"
        case .noDeviceConfigured(let name):
            return "「\(name)」未配置设备 UUID，请先在 App 中编辑并填写设备地址。"
        case .deviceNotFound(let uuid):
            return "扫描超时，未找到设备 \(uuid)，请确认设备已开启并在蓝牙范围内。"
        case .characteristicNotFound(let uuid):
            return "未找到特征值 \(uuid)，请确认服务已发现。"
        }
    }
}
