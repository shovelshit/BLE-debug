// ScanView.swift
// BLE device scanner - mirrors pages/index/index

import SwiftUI
import CoreBluetooth

struct ScanView: View {
    @EnvironmentObject var ble: BLEManager

    @State private var searchKeyword: String = ""
    @State private var filterEmpty: Bool = true
    @State private var navigateToDevice: BLEDevice? = nil
    @State private var showConnectingSheet: Bool = false
    @State private var connectingDevice: BLEDevice? = nil
    @State private var connectError: String? = nil

    // MARK: Filtered devices
    var filteredDevices: [BLEDevice] {
        var result = ble.discoveredDevices
        if filterEmpty {
            result = result.filter { !$0.name.isEmpty }
        }
        if !searchKeyword.isEmpty {
            let kw = searchKeyword.lowercased()
            result = result.filter {
                $0.name.lowercased().contains(kw) ||
                $0.id.lowercased().contains(kw)
            }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Status bar
                statusBar

                // Scan controls
                scanControls

                // Search bar
                if !ble.discoveredDevices.isEmpty {
                    searchBar
                }

                // Device list
                deviceList
            }
            .navigationTitle("BLE 调试助手")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $navigateToDevice) { device in
                DeviceView(device: device)
            }
        }
    }

    // MARK: - Status Bar
    private var statusBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Circle()
                    .fill(bluetoothDotColor)
                    .frame(width: 8, height: 8)
                Text("蓝牙 \(ble.bluetoothState.label)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if ble.connectedDevice != nil {
                HStack(spacing: 6) {
                    Circle().fill(Color.blue).frame(width: 8, height: 8)
                    Text("已连接设备")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    private var bluetoothDotColor: Color {
        switch ble.bluetoothState {
        case .on:           return .green
        case .unsupported:  return .gray
        default:            return .red
        }
    }

    // MARK: - Scan Controls
    private var scanControls: some View {
        VStack(spacing: 6) {
            // Centered scan button
            HStack {
                Spacer()
                Button(action: toggleScan) {
                    HStack(spacing: 6) {
                        if ble.isScanning {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.75)
                        }
                        Text(ble.isScanning ? "停止扫描" : "开始扫描")
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(ble.isScanning ? .red : .blue)
                .disabled(!ble.bluetoothState.isOn && !ble.isScanning)
                Spacer()
            }
            .padding(.horizontal, 16)

            HStack {
                Text("发现 ")
                    .font(.caption)
                    .foregroundColor(.secondary)
                +
                Text("\(ble.discoveredDevices.count)")
                    .font(.caption)
                    .bold()
                    .foregroundColor(.blue)
                +
                Text(" 个设备")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if filteredDevices.count != ble.discoveredDevices.count {
                    Text(" (显示 \(filteredDevices.count) 个)")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                if ble.isScanning {
                    Text(" · 扫描中...")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                Spacer()

                // Filter toggle
                Button(action: { filterEmpty.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: filterEmpty ? "eye.slash" : "eye")
                            .font(.caption)
                        Text(filterEmpty ? "已过滤" : "过滤空")
                            .font(.caption)
                    }
                    .foregroundColor(filterEmpty ? .blue : .secondary)
                }
                .buttonStyle(.plain)

                if !ble.discoveredDevices.isEmpty && !ble.isScanning {
                    Button("清空") {
                        ble.discoveredDevices = []
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    // MARK: - Search Bar
    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("搜索设备名称或 UUID", text: $searchKeyword)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !searchKeyword.isEmpty {
                Button(action: { searchKeyword = "" }) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - Device List
    @ViewBuilder
    private var deviceList: some View {
        if ble.bluetoothState == .unsupported {
            emptyState(icon: "laptopcomputer", title: "当前平台不支持蓝牙", subtitle: "请在 iOS 或 iPadOS 设备上使用")
        } else if filteredDevices.isEmpty && !ble.discoveredDevices.isEmpty && !ble.isScanning {
            emptyState(icon: "magnifyingglass", title: searchKeyword.isEmpty ? "所有设备均无名称" : "未找到「\(searchKeyword)」相关设备",
                       subtitle: "共发现 \(ble.discoveredDevices.count) 个设备，\(searchKeyword.isEmpty ? "关闭过滤可查看全部" : "清空搜索可查看全部")")
        } else if ble.discoveredDevices.isEmpty && ble.isScanning {
            emptyState(icon: "antenna.radiowaves.left.and.right", title: "扫描中，请稍候...", subtitle: nil)
        } else if ble.discoveredDevices.isEmpty {
            emptyState(icon: "dot.radiowaves.left.and.right", title: "点击「开始扫描」搜索附近蓝牙设备", subtitle: "请确保蓝牙已开启并授权")
        } else {
            List(filteredDevices) { device in
                DeviceRow(device: device, isConnected: ble.connectedDevice?.id == device.id)
                    .contentShape(Rectangle())
                    .onTapGesture { selectDevice(device) }
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
            .listStyle(.plain)
        }
    }

    private func emptyState(icon: String, title: String, subtitle: String?) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text(title)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions
    private func toggleScan() {
        if ble.isScanning {
            ble.stopScan()
        } else {
            ble.startScan()
        }
    }

    private func selectDevice(_ device: BLEDevice) {
        if ble.isScanning { ble.stopScan() }

        // Already connected to this device
        if ble.connectedDevice?.id == device.id {
            navigateToDevice = device
            return
        }

        // Connect
        connectingDevice = device
        showConnectingSheet = true
        connectError = nil

        Task { @MainActor in
            // Disconnect existing if needed
            if ble.connectedDevice != nil { ble.disconnect() }

            let result = await withCheckedContinuation { continuation in
                ble.connect(to: device) { result in
                    continuation.resume(returning: result)
                }
            }
            showConnectingSheet = false
            switch result {
            case .success:
                navigateToDevice = device
            case .failure(let err):
                connectError = err.localizedDescription
            }
        }
    }
}

// MARK: - Device Row

struct DeviceRow: View {
    let device: BLEDevice
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 12) {
            // BLE Icon
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isConnected ? Color.blue.opacity(0.12) : Color(.secondarySystemBackground))
                    .frame(width: 44, height: 44)
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.title3)
                    .foregroundColor(isConnected ? .blue : .secondary)
            }

            // Info
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(device.displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer()
                    Text(isConnected ? "已连接" : "点击连接")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isConnected ? Color.green.opacity(0.15) : Color.blue.opacity(0.12))
                        .foregroundColor(isConnected ? .green : .blue)
                        .clipShape(Capsule())
                }
                Text(device.id)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .monospaced()
                rssiView
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
        .background(isConnected ? Color.blue.opacity(0.04) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var rssiView: some View {
        HStack(spacing: 3) {
            rssiBar(minRSSI: -90)
            rssiBar(minRSSI: -80)
            rssiBar(minRSSI: -70)
            rssiBar(minRSSI: -60)
            Text(device.rssiLabel)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func rssiBar(minRSSI: Int) -> some View {
        let active = device.rssi >= minRSSI
        return RoundedRectangle(cornerRadius: 1.5)
            .fill(active ? rssiColor : Color(.systemGray4))
            .frame(width: 4, height: CGFloat(8 + (minRSSI + 90) / 7))
    }

    private var rssiColor: Color {
        switch device.rssiStrength {
        case .strong:   return .green
        case .medium:   return .yellow
        case .weak:     return .orange
        case .veryWeak: return .red
        }
    }
}

#Preview {
    ScanView().environmentObject(BLEManager())
}
