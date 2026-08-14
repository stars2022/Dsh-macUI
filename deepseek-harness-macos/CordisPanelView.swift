import SwiftUI

struct CordisSidebarPanel: View {
    @EnvironmentObject private var model: AppModel
    @Binding var open: Bool
    @State private var selectedPackages: [String: String] = [:]

    private var approvals: Int {
        model.cordisInventory.filter { $0.latestRun?.status == "awaiting-approval" }.count
    }
    private var running: Int {
        model.cordisInventory.filter { visibleStatus($0, selectedPackage: selectedPackage($0)) == "运行中" }.count
    }
    private var mine: [CordisInventoryRow] { grouped(current: true) }
    private var others: [CordisInventoryRow] { grouped(current: false) }

    var body: some View {
        Button { open.toggle(); if open { model.loadCordisInventory() } } label: {
            HStack(spacing: 8) {
                DeepSeekIcon(kind: .cordis, size: 14)
                Text("Cordis Plugin").lineLimit(1)
                Spacer(minLength: 0)
                Text("\(running) running").font(.system(size: 12)).foregroundStyle(.tertiary)
                if approvals > 0 {
                    Text("\(approvals)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).frame(minHeight: 16).background(Color.orange, in: Capsule())
                }
            }.font(.system(size: 14)).frame(maxWidth: .infinity).frame(height: 49).padding(.horizontal, 8)
                .background(open || approvals > 0 ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) { panelBody.frame(width: 420, height: 480) }
        .onChange(of: approvals) { value in if value > 0 { open = true } }
    }

    private var panelBody: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Cordis 插件").font(.system(size: 13, weight: .medium))
                Spacer()
                Button { model.loadCordisInventory() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).disabled(model.cordisInventoryLoading).help("刷新")
            }.frame(minHeight: 44).padding(.horizontal, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let error = model.cordisInventoryError {
                        Text("读取插件清单失败：\(error)").font(.system(size: 12)).foregroundStyle(.red).padding(.vertical, 8)
                    } else if model.cordisInventoryLoading && model.cordisInventory.isEmpty {
                        Text("读取中…").font(.system(size: 12)).foregroundStyle(.tertiary).padding(.vertical, 8)
                    } else if model.cordisInventory.isEmpty {
                        Text("还没有定义任何插件").font(.system(size: 12)).foregroundStyle(.tertiary).padding(.vertical, 8)
                    }
                    if !mine.isEmpty { group("当前会话", rows: mine) }
                    if !others.isEmpty { group("其他会话", rows: others) }
                }.padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func grouped(current: Bool) -> [CordisInventoryRow] {
        model.cordisInventory.filter { ($0.agentId == model.current?.id) == current }.sorted {
            let left = $0.latestRun?.status == "awaiting-approval"
            let right = $1.latestRun?.status == "awaiting-approval"
            return left != right ? left : $0.pluginId.localizedStandardCompare($1.pluginId) == .orderedAscending
        }
    }

    private func group(_ title: String, rows: [CordisInventoryRow]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                .textCase(.uppercase).tracking(0.44).padding(.top, 8)
            ForEach(rows) { rowCard($0) }
        }
    }

    private func rowCard(_ row: CordisInventoryRow) -> some View {
        let selectedId = selectedPackage(row)
        let package = row.packages.first(where: { $0.packageId == selectedId })
        let status = visibleStatus(row, selectedPackage: selectedId)
        let busy = model.cordisActionBusy.contains(row.pluginId)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(row.pluginId).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                Text(package?.name ?? row.pluginId).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                Text(status).font(.system(size: 11)).foregroundStyle(panelStatusColor(status))
                    .padding(.horizontal, 6).frame(height: 20)
                    .background(panelStatusColor(status).opacity(0.10), in: Capsule())
            }
            if row.packages.count > 1 {
                HStack(spacing: 8) {
                    Text("版本").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Picker("版本", selection: packageBinding(row)) {
                        ForEach(row.packages) { item in Text("\(item.name) · \(item.packageId)").tag(item.packageId) }
                    }.labelsHidden().controlSize(.small).disabled(busy)
                }
            }
            HStack(spacing: 8) {
                Text(package?.purpose ?? "").font(.system(size: 12)).foregroundStyle(.tertiary).lineLimit(1)
                Spacer(minLength: 0)
                if row.latestRun?.status == "awaiting-approval" {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help("原生端不能执行插件的 React Client half；请在 WebUI 的 Cordis 面板审批")
                } else if row.activePackageId != nil {
                    actionButton(icon: .stop, help: "停止", disabled: busy) { model.stopCordis(row) }
                }
                actionButton(icon: .trash, help: "移除", disabled: busy) { model.removeCordis(row) }
            }
            if let next = row.nextPackageId, next != row.currentPackageId {
                HStack(spacing: 8) {
                    if let current = row.currentPackageId { Text("当前：\(current)") }
                    Text("待切换：\(next)")
                }.font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            if let failure = row.latestRun?.errorMessage, row.latestRun?.status == "failed" {
                Text(failure).font(.system(size: 12)).foregroundStyle(.red)
            }
            if let error = model.cordisActionErrors[row.pluginId] {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
            }
            if busy { ProgressView().controlSize(.mini) }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.42), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(row.latestRun?.status == "awaiting-approval" ? Color(nsColor: Theme.business) : Color.primary.opacity(0.12)))
    }

    private func actionButton(icon: DeepSeekIconKind, help: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { DeepSeekIcon(kind: icon, size: 14).frame(width: 28, height: 28) }
            .buttonStyle(.plain).background(Color.primary.opacity(0.06), in: Circle()).disabled(disabled).help(help)
    }

    private func selectedPackage(_ row: CordisInventoryRow) -> String? {
        if let selected = selectedPackages[row.pluginId], row.packages.contains(where: { $0.packageId == selected }) { return selected }
        return row.nextPackageId ?? row.currentPackageId ?? row.packages.last?.packageId
    }

    private func packageBinding(_ row: CordisInventoryRow) -> Binding<String> {
        Binding(get: { selectedPackage(row) ?? "" }, set: { selectedPackages[row.pluginId] = $0 })
    }

    private func visibleStatus(_ row: CordisInventoryRow, selectedPackage: String?) -> String {
        if row.latestRun?.status == "awaiting-approval" { return "待审批" }
        if row.latestRun?.status == "failed", row.latestRun?.packageId == selectedPackage { return "运行失败" }
        guard let active = row.activePackageId else { return "待激活" }
        let package = row.packages.first(where: { $0.packageId == active })
        return package?.hasClientHalf == true ? "Client 待激活" : "运行中"
    }

    private func panelStatusColor(_ status: String) -> Color {
        switch status { case "运行中": return .green; case "待审批", "Client 待激活": return .orange; case "运行失败": return .red
        default: return Color(nsColor: .tertiaryLabelColor) }
    }
}
