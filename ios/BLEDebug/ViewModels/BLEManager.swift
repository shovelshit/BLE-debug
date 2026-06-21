// BLEManager.swift
// Central CoreBluetooth manager - mirrors app.js globalData + BLE logic

import Foundation
import CoreBluetooth
import Combine

// MARK: - BLEManager

@MainActor
class BLEManager: NSObject, ObservableObject {

    // MARK: Shared singleton (used by AppIntents)
    static let shared = BLEManager()

    // MARK: Published State
    @Published var bluetoothState: BluetoothState = .unknown
    @Published var isScanning: Bool = false
    @Published var discoveredDevices: [BLEDevice] = []
    @Published var connectedDevice: BLEDevice? = nil
    @Published var services: [BLEService] = []
    @Published var logs: [LogEntry] = []

    // MARK: Internal
    private var centralManager: CBCentralManager!
    private var peripheralMap: [UUID: CBPeripheral] = [:]
    private var rssiMap: [UUID: Int] = [:]
    // Waiters for bluetooth powered-on
    private var _bluetoothReadyWaiters: [WaiterToken] = []
    private var pendingConnection: CBPeripheral? = nil

    // Characteristic value callbacks
    private var readCallback: ((Result<Data, Error>) -> Void)? = nil
    private var notifyCallbacks: [String: (Data) -> Void] = [:]

    // MARK: Init
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Wait for Bluetooth Ready

    /// 等待蓝牙进入 poweredOn，最多等 timeout 秒。已经是 on 则立即返回。
    func waitForBluetoothReady(timeout: Double = 5.0) async throws {
        if bluetoothState == .on { return }
        // 蓝牙状态已经确定为非 on（off/unsupported/unauthorized），直接报错
        if bluetoothState != .unknown {
            throw BLEError.operationFailed(bluetoothState.label)
        }
        // 用一个 actor-isolated 的 Bool 标记此 continuation 是否已被 resume，避免超时与正常回调竞争
        let token = WaiterToken()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            token.cont = cont
            _bluetoothReadyWaiters.append(token)
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                // 超时时尝试 resume；若已被 didUpdateState 消费则 token.cont 已为 nil
                if let c = token.cont {
                    token.cont = nil
                    self._bluetoothReadyWaiters.removeAll { $0 === token }
                    c.resume(throwing: BLEError.operationFailed("等待蓝牙超时，请确认蓝牙已开启"))
                }
            }
        }
    }

    /// 用于 waitForBluetoothReady 的 continuation 包装，避免超时与回调竞争
    private final class WaiterToken {
        var cont: CheckedContinuation<Void, Error>?
    }

    // MARK: - Retrieve known peripheral (no scan needed)

    /// 通过 UUID 直接取回已知外设（不需要扫描），供 AppIntent 使用
    func retrievePeripheral(uuid: String) -> CBPeripheral? {
        guard let uid = UUID(uuidString: uuid) else { return nil }
        let found = centralManager.retrievePeripherals(withIdentifiers: [uid])
        if let p = found.first {
            peripheralMap[uid] = p
        }
        return found.first
    }

    // MARK: - Scan

    func startScan() {
        guard bluetoothState == .on else {
            addLog(.info, data: "蓝牙未开启，无法扫描")
            return
        }
        discoveredDevices = []
        peripheralMap = [:]
        rssiMap = [:]
        isScanning = true
        addLog(.info, data: "开始扫描设备...")
        centralManager.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }

    func stopScan() {
        centralManager.stopScan()
        isScanning = false
        addLog(.info, data: "扫描结束，发现 \(discoveredDevices.count) 个设备")
    }

    // MARK: - Connect

    func connect(to device: BLEDevice, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let peripheral = peripheralMap[UUID(uuidString: device.id)!] else {
            completion(.failure(BLEError.peripheralNotFound))
            return
        }
        addLog(.info, data: "正在连接: \(device.displayName) (\(device.id))")
        pendingConnection = peripheral
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)

        // Store completion in connectionCompletion
        self._connectionCompletion = { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.connectedDevice = device
                self.services = []
                self.addLog(.info, data: "已连接: \(device.displayName)")
                completion(.success(()))
            case .failure(let err):
                self.addLog(.error, data: "连接失败: \(err.localizedDescription)")
                completion(.failure(err))
            }
        }
    }

    private var _connectionCompletion: ((Result<Void, Error>) -> Void)? = nil

    func disconnect() {
        guard let device = connectedDevice,
              let peripheral = peripheralMap[UUID(uuidString: device.id) ?? UUID()] else { return }
        centralManager.cancelPeripheralConnection(peripheral)
        connectedDevice = nil
        services = []
        addLog(.info, data: "已断开: \(device.displayName)")
    }

    // MARK: - Discover Services

    func discoverServices(completion: @escaping (Result<[BLEService], Error>) -> Void) {
        guard let device = connectedDevice,
              let peripheral = peripheralMap[UUID(uuidString: device.id) ?? UUID()] else {
            completion(.failure(BLEError.notConnected))
            return
        }
        addLog(.info, data: "发现服务: \(device.displayName)")
        _servicesCompletion = completion
        peripheral.discoverServices(nil)
    }

    private var _servicesCompletion: ((Result<[BLEService], Error>) -> Void)? = nil
    private var _pendingServiceCount: Int = 0
    private var _completedServiceCount: Int = 0

    // MARK: - Read Characteristic

    func readCharacteristic(serviceId: String, charId: String, completion: @escaping (Result<Data, Error>) -> Void) {
        guard let device = connectedDevice,
              let peripheral = peripheralMap[UUID(uuidString: device.id) ?? UUID()] else {
            completion(.failure(BLEError.notConnected))
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid.uuidString == serviceId }),
              let characteristic = service.characteristics?.first(where: { $0.uuid.uuidString == charId }) else {
            completion(.failure(BLEError.characteristicNotFound))
            return
        }
        readCallback = completion
        peripheral.readValue(for: characteristic)
    }

    // MARK: - Write Characteristic

    func writeCharacteristic(serviceId: String, charId: String, data: Data, withResponse: Bool,
                              completion: @escaping (Result<Void, Error>) -> Void) {
        guard let device = connectedDevice,
              let peripheral = peripheralMap[UUID(uuidString: device.id) ?? UUID()] else {
            completion(.failure(BLEError.notConnected))
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid.uuidString == serviceId }),
              let characteristic = service.characteristics?.first(where: { $0.uuid.uuidString == charId }) else {
            completion(.failure(BLEError.characteristicNotFound))
            return
        }
        _writeCompletion = completion
        let type: CBCharacteristicWriteType = withResponse ? .withResponse : .withoutResponse
        peripheral.writeValue(data, for: characteristic, type: type)
        if !withResponse {
            // writeWithoutResponse doesn't trigger didWriteValueFor
            _writeCompletion?(.success(()))
            _writeCompletion = nil
        }
    }

    private var _writeCompletion: ((Result<Void, Error>) -> Void)? = nil

    // MARK: - Notify

    func setNotify(serviceId: String, charId: String, enabled: Bool,
                   onData: ((Data) -> Void)? = nil,
                   completion: @escaping (Result<Void, Error>) -> Void) {
        guard let device = connectedDevice,
              let peripheral = peripheralMap[UUID(uuidString: device.id) ?? UUID()] else {
            completion(.failure(BLEError.notConnected))
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid.uuidString == serviceId }),
              let characteristic = service.characteristics?.first(where: { $0.uuid.uuidString == charId }) else {
            completion(.failure(BLEError.characteristicNotFound))
            return
        }
        _notifyCompletion = completion
        if enabled, let cb = onData {
            notifyCallbacks[charId] = cb
        } else {
            notifyCallbacks.removeValue(forKey: charId)
        }
        peripheral.setNotifyValue(enabled, for: characteristic)
    }

    private var _notifyCompletion: ((Result<Void, Error>) -> Void)? = nil

    // MARK: - Read Once via Notify
    // 开启 Notify → 收到第一包数据 → 自动关闭 → 回调
    private var _readOnceCallbacks: [String: (Result<Data, Error>) -> Void] = [:]

    func readOnceNotify(serviceId: String, charId: String,
                        timeout: Double = 5.0,
                        completion: @escaping (Result<Data, Error>) -> Void) {
        guard let device = connectedDevice,
              let peripheral = peripheralMap[UUID(uuidString: device.id) ?? UUID()] else {
            completion(.failure(BLEError.notConnected)); return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid.uuidString == serviceId }),
              let characteristic = service.characteristics?.first(where: { $0.uuid.uuidString == charId }) else {
            completion(.failure(BLEError.characteristicNotFound)); return
        }
        _readOnceCallbacks[charId] = completion
        peripheral.setNotifyValue(true, for: characteristic)

        // 超时自动撤销
        Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if let cb = self._readOnceCallbacks.removeValue(forKey: charId) {
                peripheral.setNotifyValue(false, for: characteristic)
                cb(.failure(BLEError.operationFailed("等待响应超时（\(Int(timeout))s）")))
            }
        }
    }

    // MARK: - Logs

    func addLog(_ direction: LogDirection, uuid: String = "", data: String) {
        let entry = LogEntry.make(direction: direction, uuid: uuid, data: data)
        logs.insert(entry, at: 0)
        if logs.count > 200 { logs.removeLast() }
    }

    func clearLogs() {
        logs = []
    }
}

// MARK: - Bluetooth State

extension BLEManager {
    enum BluetoothState {
        case unknown, on, off, unsupported, unauthorized

        var isOn: Bool { self == .on }

        var label: String {
            switch self {
            case .unknown:      return "未知"
            case .on:           return "已开启"
            case .off:          return "未开启"
            case .unsupported:  return "不支持"
            case .unauthorized: return "未授权"
            }
        }
    }
}

// MARK: - BLE Errors

enum BLEError: LocalizedError {
    case peripheralNotFound
    case notConnected
    case characteristicNotFound
    case invalidData
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .peripheralNotFound:      return "未找到设备"
        case .notConnected:            return "设备未连接"
        case .characteristicNotFound:  return "特征值未找到"
        case .invalidData:             return "数据格式错误"
        case .operationFailed(let m):  return m
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                self.bluetoothState = .on
                let waiters = self._bluetoothReadyWaiters
                self._bluetoothReadyWaiters = []
                for token in waiters {
                    if let c = token.cont { token.cont = nil; c.resume() }
                }
            case .poweredOff:
                self.bluetoothState = .off
                self.isScanning = false
                // 蓝牙关闭时系统会断开所有连接，但不一定触发 didDisconnectPeripheral
                // 必须主动清空连接状态，否则 UI 仍显示已连接，且 services 里的特征值对象已失效
                if let device = self.connectedDevice {
                    self.addLog(.info, data: "蓝牙已关闭，连接断开: \(device.displayName)")
                }
                self.connectedDevice = nil
                self.services = []
                self.peripheralMap = [:]
                let waiters = self._bluetoothReadyWaiters
                self._bluetoothReadyWaiters = []
                for token in waiters {
                    if let c = token.cont { token.cont = nil; c.resume(throwing: BLEError.operationFailed("蓝牙未开启")) }
                }
            case .unsupported:
                self.bluetoothState = .unsupported
                let waiters = self._bluetoothReadyWaiters
                self._bluetoothReadyWaiters = []
                for token in waiters {
                    if let c = token.cont { token.cont = nil; c.resume(throwing: BLEError.operationFailed("设备不支持蓝牙")) }
                }
            case .unauthorized:
                self.bluetoothState = .unauthorized
                let waiters = self._bluetoothReadyWaiters
                self._bluetoothReadyWaiters = []
                for token in waiters {
                    if let c = token.cont { token.cont = nil; c.resume(throwing: BLEError.operationFailed("蓝牙权限未授权")) }
                }
            default:
                self.bluetoothState = .unknown
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                         didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any],
                         rssi RSSI: NSNumber) {
        Task { @MainActor in
            let uuid = peripheral.identifier
            self.peripheralMap[uuid] = peripheral
            let rssi = RSSI.intValue

            if let idx = self.discoveredDevices.firstIndex(where: { $0.id == uuid.uuidString }) {
                self.discoveredDevices[idx].rssi = rssi
            } else {
                let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString) ?? []
                var device = BLEDevice(peripheral: peripheral, rssi: rssi, advertisedServices: services)
                // Also check CBAdvertisementDataLocalNameKey for name
                if let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String, !localName.isEmpty {
                    device.name = localName
                }
                self.discoveredDevices.append(device)
            }
            // Sort by RSSI descending
            self.discoveredDevices.sort { $0.rssi > $1.rssi }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.pendingConnection = nil
            self._connectionCompletion?(.success(()))
            self._connectionCompletion = nil
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                         didFailToConnect peripheral: CBPeripheral,
                         error: Error?) {
        Task { @MainActor in
            self.pendingConnection = nil
            let err = error ?? BLEError.operationFailed("连接失败")
            self._connectionCompletion?(.failure(err))
            self._connectionCompletion = nil
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                         didDisconnectPeripheral peripheral: CBPeripheral,
                         error: Error?) {
        Task { @MainActor in
            if let device = self.connectedDevice, device.id == peripheral.identifier.uuidString {
                let name = device.displayName
                self.connectedDevice = nil
                self.services = []
                self.addLog(.info, data: "设备断开: \(name)")
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let err = error {
                self.addLog(.error, data: "获取服务失败: \(err.localizedDescription)")
                self._servicesCompletion?(.failure(err))
                self._servicesCompletion = nil
                return
            }
            guard let cbServices = peripheral.services else {
                self._servicesCompletion?(.success([]))
                self._servicesCompletion = nil
                return
            }
            self.addLog(.info, data: "发现 \(cbServices.count) 个服务")
            self.services = cbServices.map { BLEService(cbService: $0) }

            self._pendingServiceCount = cbServices.count
            self._completedServiceCount = 0

            if cbServices.isEmpty {
                self._servicesCompletion?(.success([]))
                self._servicesCompletion = nil
                return
            }
            for svc in cbServices {
                peripheral.discoverCharacteristics(nil, for: svc)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                     didDiscoverCharacteristicsFor service: CBService,
                     error: Error?) {
        Task { @MainActor in
            if let err = error {
                self.addLog(.error, data: "获取特征值失败: \(err.localizedDescription)")
            } else if let cbChars = service.characteristics {
                let chars = cbChars.map { BLECharacteristic(cbChar: $0, serviceId: service.uuid.uuidString) }
                if let idx = self.services.firstIndex(where: { $0.id == service.uuid.uuidString }) {
                    self.services[idx].characteristics = chars
                    self.addLog(.info, uuid: service.uuid.uuidString,
                                data: "服务 \(self.services[idx].shortUUID): \(chars.count) 个特征值")
                }
            }
            self._completedServiceCount += 1
            if self._completedServiceCount >= self._pendingServiceCount {
                self._servicesCompletion?(.success(self.services))
                self._servicesCompletion = nil
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                     didUpdateValueFor characteristic: CBCharacteristic,
                     error: Error?) {
        Task { @MainActor in
            if let err = error {
                self.readCallback?(.failure(err))
                self.readCallback = nil
                return
            }
            let data = characteristic.value ?? Data()
            // Read callback (one-shot read)
            if let cb = self.readCallback {
                cb(.success(data))
                self.readCallback = nil
            }
            // ReadOnce via Notify callback (one-shot notify)
            let charId = characteristic.uuid.uuidString
            if let cb = self._readOnceCallbacks.removeValue(forKey: charId) {
                peripheral.setNotifyValue(false, for: characteristic)
                cb(.success(data))
            }
            // Persistent Notify callback
            if let cb = self.notifyCallbacks[charId] {
                cb(data)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                     didWriteValueFor characteristic: CBCharacteristic,
                     error: Error?) {
        Task { @MainActor in
            if let err = error {
                self._writeCompletion?(.failure(err))
            } else {
                self._writeCompletion?(.success(()))
            }
            self._writeCompletion = nil
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                     didUpdateNotificationStateFor characteristic: CBCharacteristic,
                     error: Error?) {
        Task { @MainActor in
            if let err = error {
                self._notifyCompletion?(.failure(err))
            } else {
                self._notifyCompletion?(.success(()))
                let state = characteristic.isNotifying ? "已开启" : "已关闭"
                self.addLog(.info, uuid: characteristic.uuid.uuidString, data: "Notify \(state)")
            }
            self._notifyCompletion = nil
        }
    }
}
