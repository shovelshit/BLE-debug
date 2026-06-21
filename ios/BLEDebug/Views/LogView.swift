// LogView.swift
// Full communication log - mirrors pages/log/log

import SwiftUI

struct LogView: View {
    @EnvironmentObject var ble: BLEManager

    @State private var filter: LogDirection? = nil
    @State private var showClearAlert: Bool = false
    @State private var searchText: String = ""

    var filteredLogs: [LogEntry] {
        var logs = ble.logs
        if let f = filter { logs = logs.filter { $0.direction == f } }
        if !searchText.isEmpty {
            let kw = searchText.lowercased()
            logs = logs.filter {
                $0.data.lowercased().contains(kw) ||
                $0.uuid.lowercased().contains(kw) ||
                $0.time.contains(kw)
            }
        }
        return logs
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if filteredLogs.isEmpty {
                emptyState
            } else {
                logList
            }
        }
        .toolbar { toolbarItems }
        .alert("清空日志", isPresented: $showClearAlert) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { ble.clearLogs() }
        } message: {
            Text("确认清空所有通信日志？")
        }
    }

    // MARK: - Filter Bar
    private var filterBar: some View {
        VStack(spacing: 8) {
            // Search
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("搜索日志内容或 UUID", text: $searchText)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)

            // Direction filters
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterChip(nil, label: "全部", count: ble.logs.count)
                    filterChip(.send,  label: "→ TX",   count: ble.logs.filter { $0.direction == .send }.count)
                    filterChip(.recv,  label: "← RX",   count: ble.logs.filter { $0.direction == .recv }.count)
                    filterChip(.info,  label: "ℹ INFO",  count: ble.logs.filter { $0.direction == .info }.count)
                    filterChip(.error, label: "✕ ERR",   count: ble.logs.filter { $0.direction == .error }.count)
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
    }

    private func filterChip(_ f: LogDirection?, label: String, count: Int) -> some View {
        let isActive = filter == f
        return Button(action: { filter = f }) {
            HStack(spacing: 4) {
                Text(label).font(.caption2)
                Text("\(count)")
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(isActive ? Color.white.opacity(0.3) : Color(.systemGray5))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(isActive ? filterActiveColor(f) : Color(.secondarySystemBackground))
            .foregroundColor(isActive ? .white : .secondary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func filterActiveColor(_ f: LogDirection?) -> Color {
        switch f {
        case .send:  return .blue
        case .recv:  return .green
        case .info:  return Color(hue: 0.58, saturation: 0.6, brightness: 0.6)
        case .error: return .red
        case nil:    return Color(.systemGray)
        }
    }

    // MARK: - Log List
    private var logList: some View {
        List(filteredLogs) { log in
            LogRowView(log: log)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .swipeActions(edge: .leading) {
                    Button {
                        UIPasteboard.general.string = log.copyText
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                    .tint(.blue)
                }
                .contextMenu {
                    Button(action: { UIPasteboard.general.string = log.copyText }) {
                        Label("复制此条", systemImage: "doc.on.doc")
                    }
                    Button(action: { UIPasteboard.general.string = filteredLogs.map(\.copyText).joined(separator: "\n") }) {
                        Label("复制全部 (\(filteredLogs.count) 条)", systemImage: "doc.on.clipboard")
                    }
                }
        }
        .listStyle(.plain)
    }

    // MARK: - Empty State
    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text(ble.logs.isEmpty ? "暂无日志" : "无匹配日志")
                .font(.subheadline).foregroundColor(.secondary)
            if !ble.logs.isEmpty {
                Text("尝试更改过滤条件")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Toolbar
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button(action: exportLogs) {
                Image(systemName: "square.and.arrow.up")
            }
            .disabled(filteredLogs.isEmpty)

            Button(action: { showClearAlert = true }) {
                Image(systemName: "trash")
            }
            .disabled(ble.logs.isEmpty)
        }
    }

    private func exportLogs() {
        let text = filteredLogs.map(\.copyText).joined(separator: "\n")
        UIPasteboard.general.string = text
    }
}

// MARK: - Log Row View (shared)

struct LogRowView: View {
    let log: LogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(log.time)
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
                directionBadge
                Spacer()
            }
            if !log.uuid.isEmpty {
                Text(log.uuid)
                    .font(.caption2).monospaced()
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Text(log.data)
                .font(.caption).monospaced()
                .foregroundColor(.primary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }

    private var directionBadge: some View {
        Text(log.direction.label)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(badgeColor.opacity(0.15))
            .foregroundColor(badgeColor)
            .clipShape(Capsule())
    }

    private var badgeColor: Color {
        switch log.direction {
        case .send:  return .blue
        case .recv:  return .green
        case .info:  return .secondary
        case .error: return .red
        }
    }
}

#Preview {
    LogView().environmentObject(BLEManager())
}
