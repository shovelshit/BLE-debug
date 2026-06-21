// CharacteristicView.swift
// Read / Write / Notify operations - mirrors pages/characteristic/characteristic

import SwiftUI

struct CharacteristicView: View {
    let deviceId: String
    let serviceId: String
    let characteristic: BLECharacteristic

    @EnvironmentObject var ble: BLEManager
    @ObservedObject var store = QuickActionsStore.shared

    // Read state
    @State private var readHex: String = ""
    @State private var readASCII: String = ""
    @State private var isReading: Bool = false

    // Write state
    @State private var writeInput: String = ""
    @State private var writeType: WriteInputType = .hex
    @State private var isWriting: Bool = false

    // Notify state
    @State private var notifyEnabled: Bool = false
    @State private var notifyData: [(id: UUID, time: String, hex: String)] = []

    // Preset state
    @State private var showPresets: Bool = false
    @State private var editingPresetId: String? = nil
    @State private var editingName: String = ""
    @State private var editingValue: String = ""

    // Log panel
    @State private var logPanelExpanded: Bool = true
    @State private var logFilter: LogDirection? = nil

    // Alert / Toast
    @State private var alertMessage: String? = nil
    @State private var showSavePresetSheet: Bool = false
    @State private var newPresetName: String = ""
    @State private var quickAddToast: String? = nil    // 添加快捷操作的 toast 提示
    @State private var showQuickNameSheet: Bool = false  // 命名确认弹窗
    @State private var quickActionName: String = ""      // 用户输入的名称

    /// 添加快捷操作的前置条件：写入内容不为空且设备已连接
    private var canAddToQuick: Bool {
        !writeInput.trimmingCharacters(in: .whitespaces).isEmpty && ble.connectedDevice != nil
    }

    var charLogs: [LogEntry] {
        let uuid = characteristic.id
        let all = ble.logs
        let filtered = all.filter { $0.uuid.isEmpty || $0.uuid == uuid }
        if let f = logFilter { return filtered.filter { $0.direction == f } }
        return filtered
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                uuidCard
                if characteristic.canRead    { readSection }
                if characteristic.canWrite || characteristic.canWriteWithoutResponse { writeSection }
                if characteristic.canNotify || characteristic.canIndicate { notifySection }
                logPanel
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .navigationTitle("特征值操作")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { addToQuickToolbar }
        .alert("操作失败", isPresented: .init(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("确定", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
        .sheet(isPresented: $showSavePresetSheet) { savePresetSheet }
        .sheet(isPresented: $showQuickNameSheet) { quickNameSheet }
        .onDisappear {
            if notifyEnabled { disableNotify() }
        }
        .overlay(alignment: .bottom) {
            if let toast = quickAddToast {
                Text(toast)
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Color.orange.opacity(0.92))
                    .clipShape(Capsule())
                    .shadow(radius: 4)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.spring(response: 0.3), value: toast)
            }
        }
        .animation(.spring(response: 0.3), value: quickAddToast)
    }

    // MARK: - UUID Card

    private var uuidCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // ── Char UUID ────────────────────────────────────────────────
            HStack {
                Text("特征值 UUID").font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("复制") { copy(characteristic.id) }
                    .font(.caption).foregroundColor(.blue).buttonStyle(.plain)
            }
            Text(characteristic.id)
                .font(.caption).monospaced()
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            // ── Service UUID ─────────────────────────────────────────────
            HStack {
                Text("所属服务").font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("复制") { copy(serviceId) }
                    .font(.caption).foregroundColor(.blue).buttonStyle(.plain)
            }
            Text(serviceId)
                .font(.caption2).monospaced().foregroundColor(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            Divider()

            HStack {
                // Properties
                FlowLayout(spacing: 6) {
                    ForEach(characteristic.propertyBadges, id: \.self) { badge in
                        Text(badge.rawValue)
                            .font(.caption2)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(propColor(badge).opacity(0.15))
                            .foregroundColor(propColor(badge))
                            .clipShape(Capsule())
                    }
                }
                Spacer()
                if characteristic.canWrite || characteristic.canWriteWithoutResponse {
                    Button(action: addToQuick) {
                        Label("快捷操作", systemImage: "bolt")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.orange)
                    .disabled(!canAddToQuick)
                    .help(canAddToQuick ? "" : writeInput.trimmingCharacters(in: .whitespaces).isEmpty ? "请先填写写入内容" : "请先连接设备")
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func propColor(_ badge: PropertyBadge) -> Color {
        switch badge {
        case .read: return .blue
        case .write, .writeNoResp: return .green
        case .notify, .indicate: return .orange
        }
    }

    // MARK: - Read Section

    private var readSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Read", systemImage: "tray.and.arrow.down")
                    .font(.subheadline).fontWeight(.semibold)
                Spacer()
                Button(action: performRead) {
                    if isReading { ProgressView().scaleEffect(0.8) }
                    else { Text("读取").font(.caption) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isReading)
            }
            if !readHex.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    resultRow(label: "HEX", value: readHex, color: .blue)
                    if !readASCII.isEmpty {
                        resultRow(label: "ASCII", value: readASCII, color: .green)
                    }
                }
            } else {
                Text("点击「读取」获取特征值数据")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func resultRow(label: String, value: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(.caption2).foregroundColor(.secondary).frame(width: 40, alignment: .trailing)
            Text(value).font(.caption).monospaced().foregroundColor(color)
                .textSelection(.enabled)
        }
    }

    // MARK: - Write Section

    private var writeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Write", systemImage: "tray.and.arrow.up")
                    .font(.subheadline).fontWeight(.semibold)
                Spacer()
                // HEX / TEXT switch
                Picker("类型", selection: $writeType) {
                    ForEach(WriteInputType.allCases, id: \.self) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }

            // Input
            ZStack(alignment: .topLeading) {
                if writeInput.isEmpty {
                    Text(writeType == .hex ? "输入十六进制，如: AA BB 01 02" : "输入文本字符串")
                        .font(.caption).foregroundColor(.secondary).padding(8)
                }
                TextEditor(text: $writeInput)
                    .font(.caption).monospaced()
                    .frame(minHeight: 56, maxHeight: 120)
                    .scrollContentBackground(.hidden)
            }
            .padding(4)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.separator), lineWidth: 0.5))

            // Actions row
            HStack {
                Button(action: { showPresets.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: showPresets ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                        Text("预设 \(store.presets.isEmpty ? "" : "(\(store.presets.count))")")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Spacer()

                if !writeInput.isEmpty {
                    Button("＋ 保存") { showSavePresetSheet = true }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }

                Button(action: performWrite) {
                    if isWriting { ProgressView().scaleEffect(0.8) }
                    else { Label("发送", systemImage: "paperplane.fill").font(.caption) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isWriting)
            }

            // Presets
            if showPresets {
                presetPanel
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Presets Panel

    private var presetPanel: some View {
        VStack(spacing: 0) {
            if store.presets.isEmpty {
                Text("暂无预设，输入内容后点「＋ 保存」添加")
                    .font(.caption2).foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(store.presets) { preset in
                    if editingPresetId == preset.id {
                        presetEditRow(preset: preset)
                    } else {
                        presetDisplayRow(preset: preset)
                    }
                    Divider()
                }
            }
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func presetDisplayRow(preset: PresetValue) -> some View {
        HStack {
            Button(action: { applyPreset(preset) }) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name).font(.caption).foregroundColor(.primary)
                    Text(preset.value).font(.caption2).monospaced().foregroundColor(.secondary).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Text(preset.type == .hex ? "HEX" : "TXT")
                .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.blue.opacity(0.1)).foregroundColor(.blue).clipShape(Capsule())
            Button(action: { beginEditPreset(preset) }) {
                Image(systemName: "pencil").font(.caption).foregroundColor(.blue)
            }.buttonStyle(.plain).padding(.horizontal, 4)
            Button(action: { store.deletePreset(id: preset.id) }) {
                Image(systemName: "xmark").font(.caption2).foregroundColor(.red)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            Button("填充到输入框") { applyPreset(preset) }
            Button("编辑") { beginEditPreset(preset) }
            Button("删除", role: .destructive) { store.deletePreset(id: preset.id) }
        }
    }

    private func presetEditRow(preset: PresetValue) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text("名称").font(.caption2).foregroundColor(.secondary).frame(width: 30)
                TextField("预设名称", text: $editingName).font(.caption)
            }
            HStack {
                Text("值").font(.caption2).foregroundColor(.secondary).frame(width: 30)
                TextField("预设值", text: $editingValue).font(.caption).monospaced()
            }
            HStack {
                Button("取消") { editingPresetId = nil }
                    .font(.caption).foregroundColor(.secondary).buttonStyle(.plain)
                Spacer()
                Button("保存") { confirmEditPreset(id: preset.id) }
                    .font(.caption).foregroundColor(.blue).buttonStyle(.plain)
            }
        }
        .padding(10)
    }

    // MARK: - Save Preset Sheet

    private var savePresetSheet: some View {
        NavigationStack {
            Form {
                Section("预设名称") {
                    TextField("输入名称（可留空）", text: $newPresetName)
                }
                Section {
                    Text("值: \(writeInput)").font(.caption).monospaced()
                    Text("类型: \(writeType.rawValue)").font(.caption)
                }
            }
            .navigationTitle("保存预设")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { showSavePresetSheet = false; newPresetName = "" }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { savePreset() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Notify Section

    private var notifySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Notify", systemImage: "bell")
                    .font(.subheadline).fontWeight(.semibold)
                Spacer()
                if notifyEnabled {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                        Text("监听中").font(.caption2).foregroundColor(.green)
                    }
                }
            }

            if !notifyData.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(notifyData, id: \.id) { item in
                            HStack {
                                Text(item.time).font(.caption2).foregroundColor(.secondary).frame(width: 70, alignment: .leading)
                                Text(item.hex).font(.caption).monospaced().foregroundColor(.blue)
                                    .textSelection(.enabled)
                                Spacer()
                            }
                            .padding(.vertical, 4)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 160)
            } else {
                Text(notifyEnabled ? "等待设备推送数据..." : "点击「订阅」开始接收通知")
                    .font(.caption).foregroundColor(.secondary)
            }

            HStack {
                if !notifyData.isEmpty {
                    Button("清空") { notifyData = [] }
                        .font(.caption).foregroundColor(.secondary).buttonStyle(.plain)
                }
                Spacer()
                Button(action: toggleNotify) {
                    Text(notifyEnabled ? "取消订阅" : "订阅").font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .tint(notifyEnabled ? .red : .blue)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Log Panel

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { logPanelExpanded.toggle() }) {
                HStack {
                    Label("通信日志", systemImage: "doc.text").font(.subheadline).fontWeight(.semibold)
                    if !charLogs.isEmpty {
                        Text("\(charLogs.count)")
                            .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.blue.opacity(0.12)).foregroundColor(.blue)
                            .clipShape(Capsule())
                    }
                    Spacer()
                    Image(systemName: logPanelExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(14)

            if logPanelExpanded {
                Divider()
                logFilterBar.padding(.horizontal, 14).padding(.vertical, 8)
                Divider()
                if charLogs.isEmpty {
                    Text("暂无日志，进行读写/订阅后会显示在这里")
                        .font(.caption).foregroundColor(.secondary)
                        .padding(14)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(charLogs) { log in
                                LogRowView(log: log)
                                Divider()
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var logFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(nil, label: "全部")
                filterChip(.send, label: "→ TX")
                filterChip(.recv, label: "← RX")
                filterChip(.info, label: "ℹ INFO")
                filterChip(.error, label: "✕ ERR")
                Spacer()
                Button("清空") { ble.clearLogs() }
                    .font(.caption2).foregroundColor(.red).buttonStyle(.plain)
            }
        }
    }

    private func filterChip(_ filter: LogDirection?, label: String) -> some View {
        let isActive = logFilter == filter
        return Button(action: { logFilter = filter }) {
            Text(label)
                .font(.caption2)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(isActive ? Color.blue.opacity(0.15) : Color.clear)
                .foregroundColor(isActive ? .blue : .secondary)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(isActive ? Color.blue.opacity(0.3) : Color(.separator), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var addToQuickToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if characteristic.canWrite || characteristic.canWriteWithoutResponse {
                Button(action: addToQuick) {
                    Image(systemName: "bolt.badge.plus")
                }
                .disabled(!canAddToQuick)
            }
        }
    }

    // MARK: - BLE Operations

    private func performRead() {
        isReading = true
        ble.addLog(.info, uuid: characteristic.id, data: "Read 请求")
        ble.readCharacteristic(serviceId: serviceId, charId: characteristic.id) { result in
            Task { @MainActor in
                isReading = false
                switch result {
                case .success(let data):
                    readHex = DataHelpers.toHex(data)
                    readASCII = DataHelpers.toASCII(data)
                    ble.addLog(.recv, uuid: characteristic.id, data: readHex)
                case .failure(let err):
                    ble.addLog(.error, uuid: characteristic.id, data: "Read 失败: \(err.localizedDescription)")
                    alertMessage = err.localizedDescription
                }
            }
        }
    }

    private func performWrite() {
        let input = writeInput.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { alertMessage = "请输入数据"; return }

        let data: Data
        do {
            data = writeType == .hex ? try DataHelpers.hexToData(input) : DataHelpers.textToData(input)
        } catch {
            alertMessage = error.localizedDescription; return
        }

        isWriting = true
        let hexStr = DataHelpers.toHex(data)
        let withResponse = characteristic.canWrite

        ble.writeCharacteristic(serviceId: serviceId, charId: characteristic.id,
                                 data: data, withResponse: withResponse) { result in
            Task { @MainActor in
                isWriting = false
                switch result {
                case .success:
                    ble.addLog(.send, uuid: characteristic.id, data: hexStr)
                case .failure(let err):
                    ble.addLog(.error, uuid: characteristic.id, data: "Write 失败: \(err.localizedDescription)")
                    alertMessage = err.localizedDescription
                }
            }
        }
    }

    private func toggleNotify() {
        if notifyEnabled { disableNotify() } else { enableNotify() }
    }

    private func enableNotify() {
        ble.setNotify(serviceId: serviceId, charId: characteristic.id, enabled: true,
                      onData: { [self] data in
            Task { @MainActor in
                let hex = DataHelpers.toHex(data)
                let time = LogEntry.make(direction: .recv, data: "").time
                notifyData.insert((id: UUID(), time: time, hex: hex), at: 0)
                if notifyData.count > 50 { notifyData.removeLast() }
                ble.addLog(.recv, uuid: characteristic.id, data: hex)
            }
        }) { result in
            Task { @MainActor in
                if case .success = result { notifyEnabled = true }
                else if case .failure(let err) = result { alertMessage = "Notify 开启失败: \(err.localizedDescription)" }
            }
        }
    }

    private func disableNotify() {
        ble.setNotify(serviceId: serviceId, charId: characteristic.id, enabled: false) { _ in
            Task { @MainActor in notifyEnabled = false }
        }
    }

    // MARK: - Preset Helpers

    private func applyPreset(_ preset: PresetValue) {
        writeInput = preset.value
        writeType = preset.type == .hex ? .hex : .text
    }

    private func beginEditPreset(_ preset: PresetValue) {
        editingPresetId = preset.id
        editingName = preset.name
        editingValue = preset.value
    }

    private func confirmEditPreset(id: String) {
        guard !editingValue.isEmpty else { return }
        var preset = store.presets.first(where: { $0.id == id })!
        preset.name = editingName.isEmpty ? String(editingValue.prefix(12)) : editingName
        preset.value = editingValue
        store.updatePreset(preset)
        editingPresetId = nil
    }

    private func savePreset() {
        let name = newPresetName.isEmpty ? String(writeInput.prefix(12)) : newPresetName
        let preset = PresetValue(name: name, value: writeInput,
                                 type: writeType == .hex ? .hex : .text)
        store.addPreset(preset)
        showSavePresetSheet = false
        newPresetName = ""
    }

    // MARK: - Quick Action

    /// 点击按钮：校验后弹出命名确认 sheet
    private func addToQuick() {
        let trimmedValue = writeInput.trimmingCharacters(in: .whitespaces)
        guard !trimmedValue.isEmpty else {
            alertMessage = "请先在写入区域填写要发送的数据，再添加到快捷操作"
            return
        }
        guard ble.connectedDevice != nil else {
            alertMessage = "请先连接设备，才能添加快捷操作"
            return
        }
        // 预填默认名称，打开命名弹窗
        quickActionName = "\(characteristic.shortUUID) 快捷"
        showQuickNameSheet = true
    }

    /// 用户确认名称后真正保存
    private func confirmAddToQuick() {
        let trimmedValue = writeInput.trimmingCharacters(in: .whitespaces)
        guard let dev = ble.connectedDevice else { return }
        let finalName = quickActionName.trimmingCharacters(in: .whitespaces)
            .isEmpty ? "\(characteristic.shortUUID) 快捷" : quickActionName.trimmingCharacters(in: .whitespaces)
        var action = QuickAction(
            name: finalName,
            serviceUuid: serviceId,
            charUuid: characteristic.id,
            writeType: writeType == .hex ? .hex : .text,
            value: trimmedValue
        )
        action.deviceMac  = dev.id
        action.deviceName = dev.displayName
        QuickActionsStore.shared.addAction(action)
        ble.addLog(.info, data: "已添加快捷操作: \(finalName)")
        showQuickNameSheet = false
        quickActionName = ""
        quickAddToast = "已添加「\(finalName)」到快捷操作 ⚡️"
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            quickAddToast = nil
        }
    }

    // MARK: - Quick Name Sheet

    private var quickNameSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("操作名称", text: $quickActionName)
                        .autocorrectionDisabled()
                } header: {
                    Text("快捷操作名称")
                } footer: {
                    Text("留空则使用默认名称")
                        .font(.caption2)
                }

                Section("操作详情") {
                    LabeledContent("特征值") {
                        Text(characteristic.id)
                            .font(.caption).monospaced()
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("写入数据") {
                        Text(writeInput)
                            .font(.caption).monospaced()
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    LabeledContent("格式") {
                        Text(writeType == .hex ? "HEX" : "TEXT")
                            .foregroundColor(.secondary)
                    }
                    if let dev = ble.connectedDevice {
                        LabeledContent("设备") {
                            Text(dev.displayName)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("添加快捷操作")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        showQuickNameSheet = false
                        quickActionName = ""
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("添加") { confirmAddToQuick() }
                        .fontWeight(.semibold)
                        .foregroundColor(.orange)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Utilities

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
    }
}

// MARK: - Flow Layout (for property badges)

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, maxH: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0; y += maxH + spacing; maxH = 0
            }
            x += size.width + spacing
            maxH = max(maxH, size.height)
        }
        return CGSize(width: maxWidth, height: y + maxH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, maxH: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX; y += maxH + spacing; maxH = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            maxH = max(maxH, size.height)
        }
    }
}
