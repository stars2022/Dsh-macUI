import SwiftUI

struct ServerSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: MobileAppModel
    @EnvironmentObject private var profiles: ServerProfileStore
    @State private var showingAdd = false
    @State private var pairingProfile: ServerProfile?
    @State private var editingProfile: ServerProfile?
    @AppStorage("compactConversationMode") private var compactConversationMode = true

    var body: some View {
        NavigationStack {
            List {
                Section("显示") {
                    Toggle("简洁显示模式", isOn: $compactConversationMode)
                    Text("开启时隐藏详细思考，只保留已完成/正在进行的动作；展开后仅显示工具输入与输出。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("服务器地址") {
                    ForEach(profiles.profiles) { profile in
                        HStack(spacing: 12) {
                            Button {
                                profiles.selectedID = profile.id
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: profile.kind == .localHost ? "network" : "lock.shield")
                                    VStack(alignment: .leading) {
                                        Text(profile.name)
                                        Text(profile.baseURL.absoluteString)
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if profile.id == profiles.selectedID {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if profile.kind == .encryptedRelay {
                                Button("配对") { pairingProfile = profile }.buttonStyle(.bordered)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if profiles.profiles.count > 1 {
                                Button("删除", role: .destructive) {
                                    profiles.remove(profile)
                                }
                            }
                            Button {
                                editingProfile = profile
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                    Button { showingAdd = true } label: { Label("添加服务器", systemImage: "plus") }
                }
                Section {
                    Text("本地 Host 适合局域网；远程地址必须使用 HTTPS，并通过配对获得端到端加密密钥。中继服务看不到提示词、回复或工作区内容。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("连接")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss(); Task { await model.reconnect() } } } }
            .sheet(isPresented: $showingAdd) { AddServerView() }
            .sheet(item: $editingProfile) { EditServerView(profile: $0) }
            .sheet(item: $pairingProfile) { PairDeviceView(profile: $0) }
        }
    }
}

private struct EditServerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var profiles: ServerProfileStore
    let profile: ServerProfile
    @State private var name: String
    @State private var address: String
    @State private var kind: ServerKind

    init(profile: ServerProfile) {
        self.profile = profile
        _name = State(initialValue: profile.name)
        _address = State(initialValue: profile.baseURL.absoluteString)
        _kind = State(initialValue: profile.kind)
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("类型", selection: $kind) {
                    ForEach(ServerKind.allCases) { Text($0.title).tag($0) }
                }
                TextField("名称", text: $name)
                TextField(kind == .localHost ? "http://192.168.1.10:3080" : "https://relay.example.com",
                          text: $address)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Text("修改只会在点按“保存”后写入配置。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("编辑服务器")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let url = validURL else { return }
                        profiles.update(ServerProfile(id: profile.id,
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? kind.title : name.trimmingCharacters(in: .whitespacesAndNewlines),
                            kind: kind, baseURL: url))
                        dismiss()
                    }
                    .disabled(validURL == nil)
                }
            }
        }
    }

    private var validURL: URL? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.host != nil,
              kind != .encryptedRelay || url.scheme == "https" else { return nil }
        return url
    }
}

private struct AddServerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var profiles: ServerProfileStore
    @State private var name = ""
    @State private var address = ""
    @State private var kind = ServerKind.localHost

    var body: some View {
        NavigationStack {
            Form {
                Picker("类型", selection: $kind) { ForEach(ServerKind.allCases) { Text($0.title).tag($0) } }
                TextField("名称", text: $name)
                TextField(kind == .localHost ? "http://192.168.1.10:3080" : "https://relay.example.com", text: $address)
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                Text(kind.subtitle).font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("添加服务器")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        guard let url = URL(string: address), url.host != nil else { return }
                        profiles.add(name: name.isEmpty ? kind.title : name, kind: kind, url: url)
                        dismiss()
                    }.disabled(URL(string: address)?.host == nil || (kind == .encryptedRelay && URL(string: address)?.scheme != "https"))
                }
            }
        }
    }
}

private struct PairDeviceView: View {
    @Environment(\.dismiss) private var dismiss
    let profile: ServerProfile
    @StateObject private var coordinator = PairingCoordinator()
    @State private var code = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Mac 上显示的一次性配对码") {
                    TextField("ABCD-EFGH", text: $code).textInputAutocapitalization(.characters).font(.system(.title3, design: .monospaced))
                    if !coordinator.status.isEmpty { Text(coordinator.status).foregroundStyle(.secondary) }
                }
                Section { Text("库密钥由 Mac 使用这台 iPhone 的 P-256 公钥封装；中继服务器只能转交密文，不能解密。") .font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("配对设备")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("开始配对") {
                        Task {
                            do { _ = try await coordinator.pair(profile: profile, code: code); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }
                    }.disabled(code.count < 8 || coordinator.busy)
                }
            }
            .alert("配对失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
        }
    }
}
