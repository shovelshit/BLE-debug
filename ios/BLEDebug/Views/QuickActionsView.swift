// QuickActionsView.swift
// One-tap BLE write actions - mirrors pages/quick/quick

import SwiftUI
import CoreBluetooth

struct QuickActionsView: View {
    @EnvironmentObject var ble: BLEManager
    @ObservedObject var store = QuickActionsStore.shared

    // sheet(item:) 包装，确保每次打开都重建 Sheet（避免 @State 复用导致数据不刷新）
    struct EditorItem: Identifiable {
        let id = UUID()          // 每次都是新 id → sheet 强制重建
        let action: QuickAction? // nil = 新建，non-nil = 编辑
    }
    @State private var editorItem: EditorItem? = nil
    @State private var execState: [String: ExecState] = [:]
    @State private var execHint: [String: String] = [:]
    @State private var execResult: ExecResult? = nil

    struct ExecResult: Identifiable {
        let id = UUID()
        let actionName: String
        let success: Bool
        let sentHex: String      // 成功时发送的数据
        let message: String      // 失败原因 or 成功提示
        let charUuid: String
        var receivedHex: String = ""   // 等待 Notify 收到的响应数据
        var receivedAscii: String = "" // 同上的 ASCII 表示
        var waitedForNotify: Bool = false
    }

    enum ExecState { case idle, running, ok, err }

    var body: some View {
        NavigationStack {
            Group {
                if store.actions.isEmpty {
                    emptyState
                } else {
                    actionList
                }
            }
            .navigationTitle("快捷操作")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { editorItem = EditorItem(action: nil) }) {
                        Image(systemName: "plus")
                    }
                }
            }
            // 编辑 sheet 挂在内容 Group 上
            .sheet(item: $editorItem) { item in
                ActionEditorSheet(
                    action: item.action,
                    onSave: saveAction,
                    onCancel: { editorItem = nil }
                )
                .environmentObject(ble)
            }
        }
        // 执行结果 sheet 挂在 NavigationStack 外层，避免与编辑 sheet 冲突
        .sheet(item: $execResult) { result in
            ExecResultSheet(result: result)
        }
    }

    // MARK: - Empty State
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "bolt.circle")
                .font(.system(size: 56))
                .foregroundColor(.secondary)
            Text("暂无快捷操作")
                .font(.headline).foregroundColor(.secondary)
            Text("点击右上角「+」添加一键 BLE 写入操作")
                .font(.caption).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button(action: { editorItem = EditorItem(action: nil) }) {
                Label("添加快捷操作", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
    }

    // MARK: - Action List
    private var actionList: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(store.actions) { action in
                    ActionCard(
                        action: action,
                        execState: execState[action.id] ?? .idle,
                        hint: execHint[action.id] ?? "",
                        onExecute: { executeAction(action) },
                        onEdit: { editorItem = EditorItem(action: action) },
                        onDelete: { store.deleteAction(id: action.id) }
                    )
                }
            }
            .padding(16)
        }
    }

    // MARK: - Save
    private func saveAction(_ action: QuickAction) {
        if editorItem?.action != nil {
            store.updateAction(action)
        } else {
            store.addAction(action)
        }
        editorItem = nil
    }

    // MARK: - Execute

    private func executeAction(_ action: QuickAction) {
        setExecState(action.id, .running, "准备中...")

        let connected = ble.connectedDevice
        let targetMac = action.deviceMac.isEmpty ? nil : action.deviceMac

        // ── Case 1: already connected to target (or no target specified) ──
        if let connected, targetMac == nil || targetMac == connected.id {
            // Services may already be discovered
            if !ble.services.isEmpty {
                doWrite(action, deviceId: connected.id)
            } else {
                setExecState(action.id, .running, "发现服务...")
                Task { @MainActor in
                    _ = await withCheckedContinuation { cont in
                        ble.discoverServices { cont.resume(returning: $0) }
                    }
                    doWrite(action, deviceId: connected.id)
                }
            }
            return
        }

        // ── Case 2: no device UUID configured, but a device IS connected ──
        if targetMac == nil, let connected {
            if !ble.services.isEmpty {
                doWrite(action, deviceId: connected.id)
            } else {
                setExecState(action.id, .running, "发现服务...")
                Task { @MainActor in
                    _ = await withCheckedContinuation { cont in
                        ble.discoverServices { cont.resume(returning: $0) }
                    }
                    doWrite(action, deviceId: connected.id)
                }
            }
            return
        }

        // ── Case 3: no device UUID, nothing connected ──────────────────────
        guard let targetMac else {
            execFail(action.id, "未连接设备，请先在「扫描」页连接设备，或在编辑中填写设备 UUID",
                     actionName: action.name, charUuid: action.charUuid)
            return
        }

        // ── Case 4: scan & connect by UUID ────────────────────────────────
        Task { @MainActor in
            if let connected, targetMac != connected.id {
                ble.disconnect()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            setExecState(action.id, .running, "扫描中...")
            let peripheral = await scanForPeripheral(uuid: targetMac, timeout: 8)
            guard let peripheral else {
                execFail(action.id, "扫描超时，未找到设备",
                         actionName: action.name, charUuid: action.charUuid)
                return
            }

            setExecState(action.id, .running, "连接中...")
            let devInfo = BLEDevice(peripheral: peripheral, rssi: -80)
            let connectResult = await withCheckedContinuation { cont in
                ble.connect(to: devInfo) { cont.resume(returning: $0) }
            }
            guard case .success = connectResult else {
                execFail(action.id, "连接失败",
                         actionName: action.name, charUuid: action.charUuid)
                return
            }

            setExecState(action.id, .running, "发现服务...")
            _ = await withCheckedContinuation { cont in
                ble.discoverServices { cont.resume(returning: $0) }
            }

            doWrite(action, deviceId: targetMac)
        }
    }

    private func doWrite(_ action: QuickAction, deviceId: String) {
        setExecState(action.id, .running, "发送中...")
        let data: Data
        do {
            data = action.writeType == .hex
                ? try DataHelpers.hexToData(action.value)
                : DataHelpers.textToData(action.value)
        } catch {
            execFail(action.id, "数据格式错误: \(action.value)")
            return
        }

        let hexStr = DataHelpers.toHex(data)
        let serviceId: String
        let withResponse: Bool

        if !action.serviceUuid.isEmpty {
            serviceId    = action.serviceUuid
            withResponse = ble.services.first(where: { $0.id == serviceId })?
                .characteristics.first(where: { $0.id == action.charUuid })?.canWrite ?? true
        } else {
            // Auto-find service that contains charUuid
            if let svc = ble.services.first(where: { s in
                s.characteristics.contains(where: { $0.id == action.charUuid })
            }) {
                serviceId    = svc.id
                withResponse = svc.characteristics.first(where: { $0.id == action.charUuid })?.canWrite ?? true
            } else {
                execFail(action.id, "未找到特征值 \(action.charUuid.prefix(8))…，请补填服务 UUID",
                         actionName: action.name, charUuid: action.charUuid)
                return
            }
        }

        ble.writeCharacteristic(serviceId: serviceId, charId: action.charUuid,
                                 data: data, withResponse: withResponse) { result in
            Task { @MainActor in
                switch result {
                case .success:
                    ble.addLog(.send, uuid: action.charUuid, data: "[快捷] \(action.name): \(hexStr)")

                    // ── 写入成功后，若需要等待 Notify 响应 ──────────────
                    guard action.waitForNotify else {
                        execOk(action.id, actionName: action.name, sentHex: hexStr,
                               charUuid: action.charUuid)
                        return
                    }

                    let notifyChar = action.notifyCharUuid.trimmingCharacters(in: .whitespaces)
                                        .isEmpty ? action.charUuid : action.notifyCharUuid
                    setExecState(action.id, .running, "等待响应...")

                    // 找到 notify char 所属的 service
                    let notifySvcId: String
                    if !action.serviceUuid.isEmpty && notifyChar == action.charUuid {
                        notifySvcId = action.serviceUuid
                    } else if let svc = ble.services.first(where: { s in
                        s.characteristics.contains(where: { $0.id == notifyChar })
                    }) {
                        notifySvcId = svc.id
                    } else {
                        // 找不到 notify char 的 service，降级直接成功
                        execOk(action.id, actionName: action.name, sentHex: hexStr,
                               charUuid: action.charUuid)
                        return
                    }

                    let notifyResult = await withCheckedContinuation { cont in
                        ble.readOnceNotify(serviceId: notifySvcId, charId: notifyChar,
                                           timeout: 5.0) { cont.resume(returning: $0) }
                    }

                    switch notifyResult {
                    case .success(let respData):
                        let respHex = DataHelpers.toHex(respData)
                        let respAscii = DataHelpers.toASCII(respData)
                        ble.addLog(.recv, uuid: notifyChar, data: "[快捷响应] \(action.name): \(respHex)")
                        execOk(action.id, actionName: action.name, sentHex: hexStr,
                               charUuid: action.charUuid,
                               receivedHex: respHex, receivedAscii: respAscii)
                    case .failure(let err):
                        // 等待超时，仍算写入成功，附带超时说明
                        ble.addLog(.info, uuid: notifyChar, data: "[快捷] 等待响应: \(err.localizedDescription)")
                        execOk(action.id, actionName: action.name, sentHex: hexStr,
                               charUuid: action.charUuid,
                               receivedHex: "", receivedAscii: "",
                               notifyNote: err.localizedDescription)
                    }

                case .failure(let err):
                    ble.addLog(.error, uuid: action.charUuid, data: "[快捷] \(action.name) 失败: \(err.localizedDescription)")
                    execFail(action.id, err.localizedDescription,
                             actionName: action.name, charUuid: action.charUuid)
                }
            }
        }
    }

    // Scan for a specific peripheral UUID
    private func scanForPeripheral(uuid: String, timeout: Double) async -> CBPeripheral? {
        return await withCheckedContinuation { cont in
            var found = false
            ble.startScan()
            Task {
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    if let dev = ble.discoveredDevices.first(where: { $0.id == uuid }) {
                        if !found {
                            found = true
                            ble.stopScan()
                            cont.resume(returning: dev.peripheral)
                        }
                        return
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                if !found {
                    ble.stopScan()
                    cont.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Exec State Helpers

    private func setExecState(_ id: String, _ state: ExecState, _ hint: String = "") {
        execState[id] = state
        execHint[id]  = hint
    }

    private func execOk(_ id: String,
                        actionName: String,
                        sentHex: String,
                        charUuid: String,
                        receivedHex: String = "",
                        receivedAscii: String = "",
                        notifyNote: String = "") {
        setExecState(id, .ok, "执行成功 ✓")
        let msg = notifyNote.isEmpty ? "写入成功" : "写入成功（\(notifyNote)）"
        var result = ExecResult(
            actionName: actionName,
            success: true,
            sentHex: sentHex,
            message: msg,
            charUuid: charUuid
        )
        result.receivedHex     = receivedHex
        result.receivedAscii   = receivedAscii
        result.waitedForNotify = !receivedHex.isEmpty || !notifyNote.isEmpty
        execResult = result
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            setExecState(id, .idle)
        }
    }

    private func execFail(_ id: String, _ msg: String, actionName: String = "", charUuid: String = "") {
        setExecState(id, .err, msg)
        execResult = ExecResult(
            actionName: actionName,
            success: false,
            sentHex: "",
            message: msg,
            charUuid: charUuid
        )
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            setExecState(id, .idle)
        }
    }
}

// MARK: - Action Card

struct ActionCard: View {
    let action: QuickAction
    let execState: QuickActionsView.ExecState
    let hint: String
    let onExecute: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var cardColor: (bg: Color, border: Color, text: Color) {
        switch action.color {
        case .blue:   return (.blue.opacity(0.08),   .blue.opacity(0.4),   .blue)
        case .green:  return (.green.opacity(0.08),  .green.opacity(0.4),  .green)
        case .orange: return (.orange.opacity(0.08), .orange.opacity(0.4), .orange)
        case .red:    return (.red.opacity(0.08),    .red.opacity(0.4),    .red)
        case .purple: return (.purple.opacity(0.08), .purple.opacity(0.4), .purple)
        case .teal:   return (Color.teal.opacity(0.08), Color.teal.opacity(0.4), .teal)
        }
    }

    var execColor: Color {
        switch execState {
        case .idle:    return cardColor.border
        case .running: return .orange
        case .ok:      return .green
        case .err:     return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── 卡片内容区（可点击进入编辑）────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                // ── Header row ──────────────────────────────────────────
                HStack(alignment: .top) {
                    // 状态图标
                    Image(systemName: execIcon)
                        .font(.callout)
                        .foregroundColor(execColor)
                    Spacer()
                    // 编辑 / 删除菜单（独立触控区，不会误触执行）
                    Menu {
                        Button(action: onEdit) { Label("编辑", systemImage: "pencil") }
                        Divider()
                        Button(role: .destructive, action: onDelete) { Label("删除", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .frame(width: 32, height: 32)   // 扩大点击区域
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                // ── Name ────────────────────────────────────────────────
                Text(action.name)
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(.primary)
                    .lineLimit(2)

                // ── Device ──────────────────────────────────────────────
                if !action.deviceName.isEmpty || !action.deviceMac.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.caption2).foregroundColor(.secondary)
                        Text(action.deviceName.isEmpty ? String(action.deviceMac.prefix(18)) : action.deviceName)
                            .font(.caption2).foregroundColor(.secondary).lineLimit(1)
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.caption2).foregroundColor(.orange)
                        Text("未绑定设备")
                            .font(.caption2).foregroundColor(.orange)
                    }
                }

                Divider().padding(.vertical, 2)

                // ── Char UUID ───────────────────────────────────────────
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .top, spacing: 4) {
                        Text("Char")
                            .font(.system(size: 9)).foregroundColor(.secondary)
                            .frame(width: 26, alignment: .leading)
                            .padding(.top, 1)
                        Text(action.charUuid)
                            .font(.system(size: 10)).monospaced().foregroundColor(.primary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !action.serviceUuid.isEmpty {
                        HStack(alignment: .top, spacing: 4) {
                            Text("Svc")
                                .font(.system(size: 9)).foregroundColor(.secondary)
                                .frame(width: 26, alignment: .leading)
                                .padding(.top, 1)
                            Text(action.serviceUuid)
                                .font(.system(size: 10)).monospaced().foregroundColor(.secondary)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                // ── Value ───────────────────────────────────────────────
                HStack(spacing: 4) {
                    Text(action.writeType == .hex ? "HEX" : "TXT")
                        .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(cardColor.text.opacity(0.12)).foregroundColor(cardColor.text)
                        .clipShape(Capsule())
                    Text(action.value)
                        .font(.caption2).monospaced().foregroundColor(.secondary)
                        .lineLimit(1)
                }

                // ── Status hint ─────────────────────────────────────────
                if !hint.isEmpty {
                    Text(hint)
                        .font(.caption2)
                        .foregroundColor(execState == .err ? .red : .orange)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
                .padding(.horizontal, 12)

            // ── 执行按钮（独立区域，宽大好点）────────────────────────
            Button(action: onExecute) {
                HStack(spacing: 6) {
                    if execState == .running {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Image(systemName: execIcon)
                            .font(.caption).fontWeight(.semibold)
                    }
                    Text(execButtonLabel)
                        .font(.caption).fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundColor(execButtonColor)
            }
            .buttonStyle(.plain)
            .disabled(execState == .running)
        }
        .background(cardColor.bg)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(execColor.opacity(0.5), lineWidth: 1.5))
    }

    private var execButtonLabel: String {
        switch execState {
        case .idle:    return "执行"
        case .running: return "执行中…"
        case .ok:      return "执行成功"
        case .err:     return "执行失败"
        }
    }

    private var execButtonColor: Color {
        switch execState {
        case .idle:    return cardColor.text
        case .running: return .orange
        case .ok:      return .green
        case .err:     return .red
        }
    }

    var execIcon: String {
        switch execState {
        case .idle:    return "bolt.fill"
        case .running: return "arrow.triangle.2.circlepath"
        case .ok:      return "checkmark.circle.fill"
        case .err:     return "xmark.circle.fill"
        }
    }
}

// MARK: - Action Editor Sheet

struct ActionEditorSheet: View {
    let action: QuickAction?
    let onSave: (QuickAction) -> Void
    let onCancel: () -> Void

    @EnvironmentObject var ble: BLEManager

    @State private var name: String
    @State private var deviceName: String
    @State private var deviceMac: String
    @State private var serviceUuid: String
    @State private var charUuid: String
    @State private var writeType: QuickAction.WriteType
    @State private var value: String
    @State private var color: QuickAction.ActionColor
    @State private var waitForNotify: Bool
    @State private var notifyCharUuid: String

    // Picker for selecting from discovered services
    @State private var showCharPicker: Bool = false

    init(action: QuickAction?, onSave: @escaping (QuickAction) -> Void, onCancel: @escaping () -> Void) {
        self.action   = action
        self.onSave   = onSave
        self.onCancel = onCancel
        // 直接在 init 里初始化 @State，避免 onAppear 时机问题
        _name           = State(initialValue: action?.name           ?? "")
        _deviceName     = State(initialValue: action?.deviceName     ?? "")
        _deviceMac      = State(initialValue: action?.deviceMac      ?? "")
        _serviceUuid    = State(initialValue: action?.serviceUuid    ?? "")
        _charUuid       = State(initialValue: action?.charUuid       ?? "")
        _writeType      = State(initialValue: action?.writeType      ?? .hex)
        _value          = State(initialValue: action?.value          ?? "")
        _color          = State(initialValue: action?.color          ?? .blue)
        _waitForNotify  = State(initialValue: action?.waitForNotify  ?? false)
        _notifyCharUuid = State(initialValue: action?.notifyCharUuid ?? "")
    }

    /// Flat list of (serviceId, char) from currently connected device
    var availableChars: [(svcId: String, char: BLECharacteristic)] {
        ble.services.flatMap { svc in
            svc.characteristics
                .filter { $0.canWrite || $0.canWriteWithoutResponse }
                .map { (svcId: svc.id, char: $0) }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // ── 基本信息 ───────────────────────────────────────────
                Section("基本信息") {
                    TextField("操作名称 *", text: $name)
                }

                // ── 设备信息 ───────────────────────────────────────────
                Section {
                    TextField("设备名称（可选）", text: $deviceName)
                    HStack {
                        TextField("设备 UUID *", text: $deviceMac)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.caption).foregroundColor(.primary)
                        if ble.connectedDevice != nil {
                            Button("填入当前") {
                                deviceMac   = ble.connectedDevice?.id ?? ""
                                deviceName  = ble.connectedDevice?.displayName ?? ""
                            }
                            .font(.caption)
                            .buttonStyle(.borderless)
                            .foregroundColor(.blue)
                        }
                    }
                    if deviceMac.trimmingCharacters(in: .whitespaces).isEmpty {
                        Label("必填：设备 UUID，点击「填入当前」可自动填充", systemImage: "exclamationmark.circle")
                            .font(.caption2).foregroundColor(.red.opacity(0.8))
                    }
                } header: {
                    Text("设备信息")
                }

                // ── 特征值信息 ─────────────────────────────────────────
                Section {
                    // If a device is connected with services, offer picker
                    if !availableChars.isEmpty {
                        Button {
                            showCharPicker = true
                        } label: {
                            HStack {
                                Image(systemName: "list.bullet")
                                    .foregroundColor(.blue)
                                Text(charUuid.isEmpty ? "从已连接设备选择特征值…" : "重新选择特征值")
                                    .foregroundColor(.blue)
                                Spacer()
                                if !charUuid.isEmpty {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    // Service UUID field
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text("服务 UUID *").font(.caption2)
                                .foregroundColor(serviceUuid.trimmingCharacters(in: .whitespaces).isEmpty ? .red.opacity(0.8) : .secondary)
                            if serviceUuid.trimmingCharacters(in: .whitespaces).isEmpty {
                                Text("必填").font(.caption2).foregroundColor(.red.opacity(0.8))
                            }
                        }
                        TextField("请输入服务 UUID", text: $serviceUuid)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.caption).monospaced()
                    }

                    // Char UUID field
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text("特征值 UUID *").font(.caption2)
                                .foregroundColor(charUuid.trimmingCharacters(in: .whitespaces).isEmpty ? .red.opacity(0.8) : .secondary)
                            if charUuid.trimmingCharacters(in: .whitespaces).isEmpty {
                                Text("必填").font(.caption2).foregroundColor(.red.opacity(0.8))
                            }
                        }
                        TextField("请输入特征值 UUID", text: $charUuid)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.caption).monospaced()
                    }
                } header: {
                    Text("特征值信息")
                }

                // ── 写入数据 ───────────────────────────────────────────
                Section("写入数据") {
                    Picker("格式", selection: $writeType) {
                        Text("HEX").tag(QuickAction.WriteType.hex)
                        Text("TEXT").tag(QuickAction.WriteType.text)
                    }
                    .pickerStyle(.segmented)
                    TextField(writeType == .hex ? "如: AA BB 01 02" : "文本内容", text: $value)
                        .font(.caption).monospaced()
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                }

                // ── 等待响应 ───────────────────────────────────────────
                Section {
                    Toggle("写入后等待 Notify 响应", isOn: $waitForNotify)
                    if waitForNotify {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("响应特征值 UUID（留空则用写入特征值）")
                                .font(.caption2).foregroundColor(.secondary)
                            TextField("与写入特征值相同", text: $notifyCharUuid)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .font(.caption).monospaced()
                        }
                        Label("开启后，写入成功会等待最多 5 秒，并在结果弹窗展示收到的数据", systemImage: "info.circle")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                } header: {
                    Text("响应设置")
                }

                // ── 颜色标签 ───────────────────────────────────────────
                Section("颜色标签") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 8) {
                        ForEach(QuickAction.ActionColor.allCases, id: \.self) { c in
                            Button(action: { color = c }) {
                                ZStack {
                                    Circle()
                                        .fill(colorSwatch(c))
                                        .frame(width: 32, height: 32)
                                    if color == c {
                                        Image(systemName: "checkmark").font(.caption2).foregroundColor(.white)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle(action == nil ? "新建快捷操作" : "编辑快捷操作")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty ||
                                  deviceMac.trimmingCharacters(in: .whitespaces).isEmpty ||
                                  serviceUuid.trimmingCharacters(in: .whitespaces).isEmpty ||
                                  charUuid.trimmingCharacters(in: .whitespaces).isEmpty ||
                                  value.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .sheet(isPresented: $showCharPicker) {
                CharPickerSheet(availableChars: availableChars) { svcId, char in
                    serviceUuid = svcId
                    charUuid    = char.id
                    if name.isEmpty {
                        name = char.shortUUID + " 写入"
                    }
                    showCharPicker = false
                }
            }
        }
    }

    private func save() {
        var a = action ?? QuickAction(name: "", charUuid: "", value: "")
        a.name           = name.trimmingCharacters(in: .whitespaces)
        a.deviceName     = deviceName
        a.deviceMac      = deviceMac.trimmingCharacters(in: .whitespaces)
        a.serviceUuid    = serviceUuid.trimmingCharacters(in: .whitespaces)
        a.charUuid       = charUuid.trimmingCharacters(in: .whitespaces)
        a.writeType      = writeType
        a.value          = value.trimmingCharacters(in: .whitespaces)
        a.color          = color
        a.waitForNotify  = waitForNotify
        a.notifyCharUuid = notifyCharUuid.trimmingCharacters(in: .whitespaces)
        onSave(a)
    }

    private func colorSwatch(_ c: QuickAction.ActionColor) -> Color {
        switch c {
        case .blue:   return .blue
        case .green:  return .green
        case .orange: return .orange
        case .red:    return .red
        case .purple: return .purple
        case .teal:   return .teal
        }
    }
}

// MARK: - Characteristic Picker Sheet

struct CharPickerSheet: View {
    let availableChars: [(svcId: String, char: BLECharacteristic)]
    let onSelect: (String, BLECharacteristic) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(groupedByService.keys.sorted()), id: \.self) { svcId in
                    Section {
                        ForEach(groupedByService[svcId]!, id: \.id) { char in
                            Button {
                                onSelect(svcId, char)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(char.id)
                                        .font(.caption).monospaced()
                                        .foregroundColor(.primary)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                    HStack(spacing: 4) {
                                        ForEach(char.propertyBadges, id: \.self) { badge in
                                            Text(badge.rawValue)
                                                .font(.caption2)
                                                .padding(.horizontal, 5).padding(.vertical, 1)
                                                .background(badgeColor(badge).opacity(0.15))
                                                .foregroundColor(badgeColor(badge))
                                                .clipShape(Capsule())
                                        }
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("服务: " + svcId)
                            .font(.caption2).monospaced()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("选择特征值")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var groupedByService: [String: [BLECharacteristic]] {
        Dictionary(grouping: availableChars, by: \.svcId)
            .mapValues { $0.map(\.char) }
    }

    private func badgeColor(_ badge: PropertyBadge) -> Color {
        switch badge {
        case .read:                return .blue
        case .write, .writeNoResp: return .green
        case .notify, .indicate:   return .orange
        }
    }
}

// MARK: - Exec Result Sheet

struct ExecResultSheet: View {
    let result: QuickActionsView.ExecResult
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // ── 状态图标 ────────────────────────────────────────
                    ZStack {
                        Circle()
                            .fill(result.success ? Color.green.opacity(0.12) : Color.red.opacity(0.12))
                            .frame(width: 80, height: 80)
                        Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 44))
                            .foregroundColor(result.success ? .green : .red)
                    }
                    .padding(.top, 8)

                    Text(result.success ? "执行成功" : "执行失败")
                        .font(.title2).fontWeight(.bold)
                        .foregroundColor(result.success ? .green : .red)

                    // ── 详情卡片 ────────────────────────────────────────
                    VStack(spacing: 0) {
                        // 操作名称
                        if !result.actionName.isEmpty {
                            ResultRow(label: "操作", value: result.actionName, monospaced: false)
                            Divider().padding(.leading, 16)
                        }

                        // 特征值
                        if !result.charUuid.isEmpty {
                            ResultRow(label: "特征值", value: result.charUuid, monospaced: true)
                            Divider().padding(.leading, 16)
                        }

                        if result.success {
                            // 发送数据 HEX
                            ResultRow(label: "发送数据 (HEX)",
                                      value: result.sentHex.isEmpty ? "—" : result.sentHex,
                                      monospaced: true)
                            // 响应数据（如果等待过 Notify）
                            if result.waitedForNotify {
                                Divider().padding(.leading, 16)
                                if result.receivedHex.isEmpty {
                                    ResultRow(label: "响应数据", value: "（无数据 / 超时）",
                                              monospaced: false, valueColor: .secondary)
                                } else {
                                    ResultRow(label: "响应数据 (HEX)", value: result.receivedHex,
                                              monospaced: true, valueColor: .teal)
                                    if !result.receivedAscii.isEmpty {
                                        Divider().padding(.leading, 16)
                                        ResultRow(label: "响应数据 (ASCII)", value: result.receivedAscii,
                                                  monospaced: true, valueColor: .teal)
                                    }
                                }
                            }
                            Divider().padding(.leading, 16)
                            ResultRow(label: "结果", value: result.message,
                                      monospaced: false, valueColor: .green)
                        } else {
                            // 失败原因
                            ResultRow(label: "失败原因", value: result.message,
                                      monospaced: false, valueColor: .red)
                        }
                    }
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 16)

                    // ── 关闭按钮 ────────────────────────────────────────
                    Button(action: { dismiss() }) {
                        Text("关闭")
                            .font(.subheadline).fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(result.success ? Color.green : Color.red)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("执行结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Result Row

private struct ResultRow: View {
    let label: String
    let value: String
    var monospaced: Bool = false
    var valueColor: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2).foregroundColor(.secondary)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .foregroundColor(valueColor)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
