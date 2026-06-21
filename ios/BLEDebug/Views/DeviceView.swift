// DeviceView.swift
// Device services & characteristics list - mirrors pages/device/device

import SwiftUI

struct DeviceView: View {
    let device: BLEDevice
    @EnvironmentObject var ble: BLEManager

    @State private var isLoading: Bool = false
    @State private var showDisconnectAlert: Bool = false
    @State private var navigateToChar: CharNavTarget? = nil
    @State private var showLogs: Bool = false

    var isConnected: Bool { ble.connectedDevice?.id == device.id }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                deviceCard
                servicesSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(device.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarItems }
        .alert("断开连接", isPresented: $showDisconnectAlert) {
            Button("取消", role: .cancel) {}
            Button("断开", role: .destructive) { ble.disconnect() }
        } message: {
            Text("确认断开与 \(device.displayName) 的连接？")
        }
        .sheet(isPresented: $showLogs) {
            NavigationStack {
                LogView()
                    .navigationTitle("通信日志")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("关闭") { showLogs = false }
                        }
                    }
            }
        }
        .navigationDestination(item: $navigateToChar) { target in
            CharacteristicView(
                deviceId: target.deviceId,
                serviceId: target.serviceId,
                characteristic: target.characteristic
            )
        }
        .onAppear { loadServicesIfNeeded() }
    }

    // MARK: - Device Card

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.blue.opacity(0.1))
                        .frame(width: 56, height: 56)
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.title2)
                        .foregroundColor(.blue)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.displayName)
                        .font(.headline)
                    Text(device.id)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .monospaced()
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isConnected ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(isConnected ? "已连接" : "已断开")
                            .font(.caption)
                            .foregroundColor(isConnected ? .green : .red)
                    }
                }
            }

            Divider()

            HStack(spacing: 12) {
                Button(action: refreshServices) {
                    Label("刷新服务", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if isConnected {
                    Button(role: .destructive, action: { showDisconnectAlert = true }) {
                        Label("断开连接", systemImage: "xmark.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Spacer()

                Button(action: { showLogs = true }) {
                    Label("日志", systemImage: "doc.text")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Services Section

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("服务列表")
                    .font(.subheadline).fontWeight(.semibold)
                Text("(\(ble.services.count))")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在发现服务...")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(14)
            } else if ble.services.isEmpty {
                Text("暂无服务，请点击「刷新服务」")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(14)
            } else {
                ForEach(ble.services.indices, id: \.self) { idx in
                    if idx > 0 { Divider().padding(.leading, 14) }
                    ServiceRow(
                        service: ble.services[idx],
                        onToggle: { toggleService(idx) },
                        onCharTap: { char in
                            navigateToChar = CharNavTarget(
                                deviceId: device.id,
                                serviceId: ble.services[idx].id,
                                characteristic: char
                            )
                        }
                    )
                }
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if isLoading {
                ProgressView().scaleEffect(0.8)
            } else {
                Button(action: refreshServices) {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
    }

    // MARK: - Actions

    private func loadServicesIfNeeded() {
        if !ble.services.isEmpty { return }
        discoverServices()
    }

    private func discoverServices() {
        isLoading = true
        ble.discoverServices { result in
            Task { @MainActor in
                isLoading = false
                if case .failure(let err) = result {
                    print("服务发现失败: \(err.localizedDescription)")
                }
            }
        }
    }

    private func refreshServices() {
        ble.services = []
        discoverServices()
    }

    private func toggleService(_ idx: Int) {
        ble.services[idx].isExpanded.toggle()
    }
}

// MARK: - Service Row

struct ServiceRow: View {
    let service: BLEService
    let onToggle: () -> Void
    let onCharTap: (BLECharacteristic) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Service header - 不用 Button 包裹，避免与 textSelection 冲突
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(service.id)
                        .font(.caption)
                        .monospaced()
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        if service.isPrimary {
                            Text("Primary")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.blue.opacity(0.12))
                                .foregroundColor(.blue)
                                .clipShape(Capsule())
                        }
                        Text("\(service.characteristics.count) 个特征值")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: service.isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
                    .onTapGesture { onToggle() }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
            .onTapGesture { onToggle() }

            // Characteristics
            if service.isExpanded {
                Divider()
                ForEach(service.characteristics) { char in
                    Button(action: { onCharTap(char) }) {
                        CharacteristicRow(characteristic: char)
                    }
                    .buttonStyle(.plain)
                }
                if service.characteristics.isEmpty {
                    Text("无特征值")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 6)
                        .padding(.leading, 14)
                }
            }
        }
    }
}

// MARK: - Characteristic Row

struct CharacteristicRow: View {
    let characteristic: BLECharacteristic

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(characteristic.id)
                    .font(.caption)
                    .monospaced()
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                HStack(spacing: 4) {
                    ForEach(characteristic.propertyBadges, id: \.self) { badge in
                        Text(badge.rawValue)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(badgeColor(badge).opacity(0.15))
                            .foregroundColor(badgeColor(badge))
                            .clipShape(Capsule())
                    }
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.top, 2)
        }
        .padding(.vertical, 8)
        .padding(.leading, 16)
        .contentShape(Rectangle())
    }

    private func badgeColor(_ badge: PropertyBadge) -> Color {
        switch badge {
        case .read:       return .blue
        case .write, .writeNoResp: return .green
        case .notify, .indicate:   return .orange
        }
    }
}

// MARK: - Navigation Target

struct CharNavTarget: Hashable {
    let deviceId: String
    let serviceId: String
    let characteristic: BLECharacteristic

    static func == (lhs: CharNavTarget, rhs: CharNavTarget) -> Bool {
        lhs.characteristic.id == rhs.characteristic.id
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(characteristic.id)
    }
}

#Preview {
    NavigationStack {
        Text("Preview unavailable without CBPeripheral")
    }
}
