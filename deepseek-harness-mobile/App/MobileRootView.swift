import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct MobileRootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var model: MobileAppModel
    @EnvironmentObject private var profiles: ServerProfileStore
    @State private var showingSessions = false
    @State private var liveDrawerOffset: CGFloat?
    @State private var windowSafeArea = EdgeInsets()
    @State private var scrollToBottomRequest = 0
    @State private var conversationNearBottom = true
    @State private var composerDockHeight: CGFloat = 70
    @FocusState private var composerFocused: Bool

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        _showingSessions = State(initialValue: arguments.contains("-show-sidebar") && !arguments.contains("-hide-sidebar"))
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactRoot
            } else {
                tabletRoot
            }
        }
        .sheet(isPresented: $model.showingSettings) {
            ServerSettingsView()
                .environmentObject(model)
                .environmentObject(profiles)
        }
        .sheet(isPresented: $model.showingNewSession) {
            MobileNewSessionSheet()
                .environmentObject(model)
        }
        .alert("连接错误", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onAppear {
            refreshWindowSafeArea()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-hide-sidebar") {
                showingSessions = false
                liveDrawerOffset = nil
            }
            if ProcessInfo.processInfo.arguments.contains("-show-settings") {
                DispatchQueue.main.async { model.showingSettings = true }
            }
            if ProcessInfo.processInfo.arguments.contains("-show-new-session") {
                DispatchQueue.main.async { model.showingNewSession = true }
            }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            refreshWindowSafeArea()
        }
    }

    private var compactRoot: some View {
        GeometryReader { geometry in
            let drawerWidth = min(geometry.size.width * 0.74, 300)
            let offset = drawerOffset(width: drawerWidth)
            let progress = drawerWidth > 0 ? offset / drawerWidth : 0
            ZStack(alignment: .leading) {
                Color(.systemBackground).ignoresSafeArea()
                MobileSessionSidebar(bottomInset: windowSafeArea.bottom) {
                    withAnimation(.snappy(duration: 0.28)) { showingSessions = false }
                }
                .frame(width: drawerWidth)
                .padding(.top, windowSafeArea.top)
                .offset(x: -22 * (1 - progress))
                .opacity(0.48 + (0.52 * progress))
                .blur(radius: 1.5 * (1 - progress))

                compactConversation
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .background(Color(.systemBackground))
                    .overlay {
                        // In dark appearance the system background is nearly
                        // black, so a subtle lightening is needed to preserve
                        // the pushed-page layer used by the WebUI drawer.
                        if colorScheme == .dark {
                            Color.white.opacity(0.075 * progress)
                                .allowsHitTesting(false)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 36 * progress, style: .continuous))
                    .shadow(color: .black.opacity(0.16 * progress), radius: 26, x: -9)
                    .offset(x: offset)
                    .allowsHitTesting(offset <= 1)

                if offset > 1 {
                    Color.black.opacity(0.001)
                        .frame(width: max(0, geometry.size.width - offset), height: geometry.size.height)
                        .contentShape(Rectangle())
                        .offset(x: offset)
                        .onTapGesture {
                            withAnimation(.snappy(duration: 0.28)) { showingSessions = false }
                        }
                    }
                }
            .contentShape(Rectangle())
            .simultaneousGesture(drawerGesture(width: drawerWidth))
            .animation(.snappy(duration: 0.28), value: showingSessions)
        }
        .ignoresSafeArea(.container, edges: .all)
    }

    private var compactConversation: some View {
        NavigationStack {
            Group {
                if model.selectedSessionID == nil {
                    MobileEmptyConversation()
                } else {
                    MobileConversationView(bottomOverlayInset: windowSafeArea.bottom + 86,
                                           dockOverlayHeight: composerDockHeight,
                                           scrollToBottomRequest: scrollToBottomRequest,
                                           isNearBottom: $conversationNearBottom)
                }
            }
            .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 12) {
                        if !model.subagentStack.isEmpty {
                            Button { Task { await model.leaveSubagent() } } label: {
                                Image(systemName: "chevron.left")
                            }
                            .accessibilityLabel("返回父会话")
                        }
                        Button {
                            withAnimation(.snappy(duration: 0.3)) { showingSessions = true }
                        } label: {
                            Image(systemName: "sidebar.left")
                        }
                        .accessibilityLabel("会话列表")
                    }
                }

                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(model.conversationTitle)
                            .font(.headline).lineLimit(1)
                        HStack(spacing: 4) {
                            Circle().fill(model.reconnecting ? Color.orange : model.status.hasPrefix("已连接") ? Color.green : Color.orange)
                                .frame(width: 5, height: 5)
                            Text(profiles.selected.name)
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 230)
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    MobileSubagentMenu()
                    MobileJobsMenu()
                    if model.subagentStack.isEmpty {
                        Button { model.showingNewSession = true } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .accessibilityLabel("新建会话")
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            // Keep the composer visually above the home indicator without using
            // safeAreaInset, which would resize and push the conversation.
            VStack(spacing: 8) {
                if let approval = model.currentApproval {
                    MobileApprovalComposer(request: approval)
                } else {
                    MobileSessionProjectionDock()
                    MobileComposer(focused: $composerFocused,
                                   shouldScrollOnFocus: { conversationNearBottom },
                                   requestScrollToBottom: { scrollToBottomRequest &+= 1 })
                }
            }
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: ComposerDockHeightPreferenceKey.self,
                                               value: proxy.size.height)
                    }
                }
                .padding(.bottom, composerFocused ? 8 : windowSafeArea.bottom + 8)
                .animation(.snappy(duration: 0.22), value: composerFocused)
        }
        .onPreferenceChange(ComposerDockHeightPreferenceKey.self) { height in
            if height > 0 { composerDockHeight = height }
        }
    }

    private func refreshWindowSafeArea() {
        DispatchQueue.main.async {
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
                  let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first else { return }
            let insets = window.safeAreaInsets
            windowSafeArea = EdgeInsets(top: insets.top, leading: insets.left,
                                        bottom: insets.bottom, trailing: insets.right)
        }
    }

    private func drawerOffset(width: CGFloat) -> CGFloat {
        min(width, max(0, liveDrawerOffset ?? (showingSessions ? width : 0)))
    }

    private func drawerGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let origin = showingSessions ? width : 0
                if showingSessions {
                    liveDrawerOffset = min(width, max(0, origin + min(0, value.translation.width)))
                } else if value.translation.width > 0 {
                    liveDrawerOffset = min(width, value.translation.width)
                }
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    liveDrawerOffset = nil
                    return
                }
                let projected = value.predictedEndTranslation.width
                let projectedOffset = min(width, max(0, (showingSessions ? width : 0) + projected))
                let target = projectedOffset > width * 0.5
                if target != showingSessions { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
                withAnimation(.snappy(duration: 0.24)) {
                    showingSessions = target
                    // `nil` resolves to the target edge in the same animation
                    // transaction, so the settle continues from the finger's
                    // actual release position instead of replaying from an edge.
                    liveDrawerOffset = nil
                }
            }
    }

    private var tabletRoot: some View {
        NavigationSplitView {
            MobileSessionList(showSettings: { model.showingSettings = true })
                .navigationTitle("DeepSeek")
        } detail: {
            NavigationStack {
                if model.selectedSessionID == nil {
                    MobileEmptyConversation()
                } else {
                    MobileConversationView(isNearBottom: .constant(true))
                }
            }
        }
    }

    @ViewBuilder private var serverMenu: some View {
        ForEach(profiles.profiles) { profile in
            Button {
                profiles.selectedID = profile.id
                Task { await model.reconnect() }
            } label: {
                Label(profile.name,
                      systemImage: profile.id == profiles.selectedID
                        ? "checkmark"
                        : profile.kind == .localHost ? "network" : "lock.shield")
            }
        }
    }
}

private struct MobileSubagentMenu: View {
    @EnvironmentObject private var model: MobileAppModel

    private var parentID: String? { model.activeConversationID }
    private var entries: [MobileSubagentEntry] { parentID.flatMap { model.subagents[$0] } ?? [] }
    private var healthy: [MobileSubagentEntry] { entries.filter { !$0.isDiagnostic } }
    private var runningCount: Int { healthy.filter { $0.activity == "running" }.count }

    var body: some View {
        if let parentID, !entries.isEmpty {
            Menu {
                ForEach(entries) { entry in
                    if let diagnostic = entry.diagnostic {
                        Section(entry.id) { Text(diagnostic) }
                    } else {
                        Button {
                            Task { await model.openSubagent(entry, parentID: parentID) }
                        } label: {
                            Label(entry.displayName,
                                  systemImage: entry.activity == "running" ? "circle.fill" : "circle")
                        }
                        if entry.mode == "continuable" && entry.activity == "running" {
                            Button("中断 \(entry.displayName)", role: .destructive) {
                                Task { await model.interruptSubagent(entry, parentID: parentID) }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "person.2")
                    Text("\(healthy.count)").font(.caption2.monospacedDigit())
                    if runningCount > 0 { Circle().fill(.green).frame(width: 6, height: 6) }
                }
            }
            .accessibilityLabel("\(healthy.count) 个子代理")
            .task(id: parentID) { await model.loadSubagents(parentID: parentID) }
        }
    }
}

private struct MobileJobsMenu: View {
    @EnvironmentObject private var model: MobileAppModel

    var body: some View {
        if !model.currentJobs.isEmpty {
            Menu {
                ForEach(model.currentJobs) { job in
                    Section(job.label) {
                        Label(job.isLive ? "正在运行" : job.status,
                              systemImage: job.isLive ? "circle.fill" : "checkmark")
                        if let detail = job.detail, !detail.isEmpty { Text(detail) }
                        Text(job.kind)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("\(model.currentJobs.filter { $0.isLive }.count)")
                        .font(.caption2.monospacedDigit())
                }
            }
            .accessibilityLabel("后台任务")
        }
    }
}

private struct MobileSessionSidebar: View {
    @EnvironmentObject private var model: MobileAppModel
    let bottomInset: CGFloat
    let close: () -> Void
    @State private var collapsedWorkspaceIDs = Set<String>()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("DeepSeek")
                    .font(.system(size: 24, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 8)

            List {
                if model.loading && model.sessions.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowBackground(Color.clear)
                } else if groupedSessions.isEmpty {
                    ContentUnavailableView("暂无会话", systemImage: "message")
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(groupedSessions) { group in
                        Section {
                            if !collapsedWorkspaceIDs.contains(group.id) {
                                ForEach(group.sessions) { session in
                                    Button {
                                        Task {
                                            await model.select(session)
                                            close()
                                        }
                                    } label: {
                                        HStack(spacing: 10) {
                                            Circle()
                                                .fill(model.approvals.contains { $0.sessionID == session.id }
                                                      ? Color.orange
                                                      : session.running ? Color.orange : Color.clear)
                                                .overlay(Circle().stroke(Color.secondary.opacity(0.28), lineWidth: 1))
                                                .frame(width: 7, height: 7)
                                            Text(session.title).lineLimit(1)
                                            Spacer(minLength: 0)
                                            if model.approvals.contains(where: { $0.sessionID == session.id }) {
                                                Image(systemName: "checkmark.shield")
                                                    .font(.caption).foregroundStyle(.orange)
                                            }
                                        }
                                        .foregroundStyle(.primary)
                                        .frame(height: 34)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 12))
                                    .listRowBackground(
                                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                                            .fill(session.id == model.selectedSessionID
                                                  ? Color.secondary.opacity(0.11) : Color.clear)
                                    )
                                    .listRowSeparator(.hidden)
                                }
                            }
                        } header: {
                            HStack(spacing: 8) {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.16)) {
                                        if collapsedWorkspaceIDs.contains(group.id) {
                                            collapsedWorkspaceIDs.remove(group.id)
                                        } else {
                                            collapsedWorkspaceIDs.insert(group.id)
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: group.workspaceID == nil ? "tray" : "folder")
                                            .frame(width: 18)
                                        Text(group.title).font(.callout.weight(.semibold)).lineLimit(1)
                                        Image(systemName: "chevron.down")
                                            .font(.caption.weight(.semibold))
                                            .rotationEffect(.degrees(collapsedWorkspaceIDs.contains(group.id) ? -90 : 0))
                                    }
                                    .foregroundStyle(.primary)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Spacer(minLength: 4)
                                if let workspaceID = group.workspaceID {
                                    Button {
                                        Task { await model.createSession(workspaceID: workspaceID); close() }
                                    } label: {
                                        Image(systemName: "plus").frame(width: 28, height: 28)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("在 \(group.title) 中新建会话")
                                }
                            }
                            .textCase(nil)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .listSectionSpacing(6)
            .environment(\.defaultMinListRowHeight, 36)
            .refreshable { await model.refresh() }
            .overlay(alignment: .bottom) {
                HStack(spacing: 12) {
                    Button {
                        close()
                        DispatchQueue.main.async { model.showingNewSession = true }
                    } label: {
                        Label("新建会话", systemImage: "square.and.pencil")
                            .frame(maxWidth: .infinity)
                    }
                    .mobileGlassButton(prominent: true)
                    .controlSize(.large)

                    Button {
                        model.showingSettings = true
                        close()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .mobileGlassButton()
                    .controlSize(.large)
                    .accessibilityLabel("设置")
                }
                .padding(.horizontal, 16).padding(.bottom, bottomInset + 8)
            }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    private var groupedSessions: [SidebarSessionGroup] {
        let visible = Dictionary(uniqueKeysWithValues: model.sessions.map { ($0.id, $0) })
        var accounted = Set<String>()
        var groups: [SidebarSessionGroup] = []
        for workspace in model.workspaces {
            var sessions = workspace.sessionIDs.compactMap { id -> MobileSession? in
                guard let session = visible[id] else { return nil }
                accounted.insert(id)
                return session
            }
            let memberIDs = Set(sessions.map(\.id))
            let pathMatches = model.sessions
                .filter { $0.blank && $0.cwd == workspace.path && !memberIDs.contains($0.id) && !accounted.contains($0.id) }
                .sorted { $0.updatedAt > $1.updatedAt }
            pathMatches.forEach { accounted.insert($0.id) }
            sessions.append(contentsOf: pathMatches)
            groups.append(SidebarSessionGroup(workspaceID: workspace.id,
                                              title: workspace.name, sessions: sessions))
        }
        let ungrouped = model.sessions.filter { !accounted.contains($0.id) }
        if !ungrouped.isEmpty {
            groups.append(SidebarSessionGroup(workspaceID: nil, title: "未分组", sessions: ungrouped))
        }
        return groups
    }
}

private struct SidebarSessionGroup: Identifiable {
    let workspaceID: String?
    let title: String
    let sessions: [MobileSession]
    var id: String { workspaceID ?? "ungrouped" }
}

private struct MobileNewSessionSheet: View {
    @EnvironmentObject private var model: MobileAppModel
    @State private var selectedWorkspaceID: String?
    @State private var addingWorkspace = false
    @State private var workspacePath = ""
    private let ungroupedID = "__ungrouped__"

    var body: some View {
        NavigationStack {
            List {
                Section("工作区") {
                    Button { selectedWorkspaceID = ungroupedID } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "tray").foregroundStyle(.secondary).frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("无工作区").foregroundStyle(.primary)
                                Text("会话显示在“未分组”中").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if selectedWorkspaceID == ungroupedID {
                                Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint)
                            }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    ForEach(model.workspaces) { workspace in
                        Button { selectedWorkspaceID = workspace.id } label: {
                            HStack(spacing: 12) {
                                Image(systemName: workspace.id == model.currentWorkspace?.id ? "folder.fill" : "folder")
                                    .foregroundStyle(.tint).frame(width: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(workspace.name).foregroundStyle(.primary)
                                        if workspace.id == model.currentWorkspace?.id {
                                            Text("当前").font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(workspace.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if selectedWorkspaceID == workspace.id {
                                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if model.workspaces.isEmpty {
                        ContentUnavailableView("尚无工作区", systemImage: "folder",
                                               description: Text("先添加 Mac 上的项目目录。"))
                    }
                }

                Section {
                    if addingWorkspace {
                        TextField("Mac 上的绝对路径", text: $workspacePath)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                        HStack {
                            Button("取消") { addingWorkspace = false; workspacePath = "" }
                            Spacer()
                            Button("添加") { addWorkspace() }
                                .disabled(workspacePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                          || model.workspaceSelectionBusy)
                        }
                    } else {
                        Button { addingWorkspace = true } label: {
                            Label("添加工作区…", systemImage: "plus")
                        }
                    }
                } footer: {
                    Text("移动端连接的是 Mac Host，因此这里填写 Mac 上的目录路径。")
                }
            }
            .navigationTitle("新建会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { model.showingNewSession = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        guard let selectedWorkspaceID else { return }
                        Task {
                            await model.createSession(workspaceID: selectedWorkspaceID == ungroupedID ? nil : selectedWorkspaceID,
                                                      ungrouped: selectedWorkspaceID == ungroupedID)
                        }
                    }
                    .disabled(selectedWorkspaceID == nil || model.workspaceSelectionBusy)
                }
            }
            .overlay { if model.workspaceSelectionBusy { ProgressView().controlSize(.large) } }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            selectDefaultWorkspaceIfNeeded()
        }
        .onChange(of: model.workspaces) { _, _ in
            selectDefaultWorkspaceIfNeeded()
        }
        .onChange(of: model.selectedSessionID) { _, _ in
            selectDefaultWorkspaceIfNeeded()
        }
    }

    private func addWorkspace() {
        let path = workspacePath
        Task {
            if let workspace = await model.createWorkspace(path: path) {
                selectedWorkspaceID = workspace.id
                workspacePath = ""
                addingWorkspace = false
            }
        }
    }

    private func selectDefaultWorkspaceIfNeeded() {
        guard selectedWorkspaceID == nil
                || (selectedWorkspaceID != ungroupedID && !model.workspaces.contains(where: { $0.id == selectedWorkspaceID })) else { return }
        selectedWorkspaceID = model.currentWorkspace?.id ?? model.workspaces.first?.id
    }
}

private struct MobileSessionList: View {
    @EnvironmentObject private var model: MobileAppModel
    @EnvironmentObject private var profiles: ServerProfileStore
    let showSettings: () -> Void
    var select: ((MobileSession) -> Void)?

    init(showSettings: @escaping () -> Void, select: ((MobileSession) -> Void)? = nil) {
        self.showSettings = showSettings
        self.select = select
    }

    var body: some View {
        List {
            Section {
                Menu {
                    ForEach(profiles.profiles) { profile in
                        Button {
                        profiles.selectedID = profile.id
                        Task { await model.reconnect() }
                    } label: {
                        if profile.id == profiles.selectedID {
                            Label(profile.name, systemImage: "checkmark")
                        } else {
                            Text(profile.name)
                        }
                    }
                    }
                    Divider()
                    Button("管理服务器…", action: showSettings)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: profiles.selected.kind == .localHost ? "network" : "lock.shield")
                            .foregroundStyle(.tint).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profiles.selected.name).foregroundStyle(.primary)
                            Text(profiles.selected.kind.title).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                if model.loading && model.sessions.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
                } else if model.sessions.isEmpty {
                    ContentUnavailableView("暂无会话", systemImage: "message")
                } else {
                    ForEach(model.sessions) { session in
                        Button {
                            if let select { select(session) }
                            else { Task { await model.select(session) } }
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Circle()
                                    .fill(session.running ? Color.orange : Color.clear)
                                    .overlay(Circle().stroke(Color.secondary.opacity(session.running ? 0 : 0.28), lineWidth: 1))
                                    .frame(width: 8, height: 8).padding(.top, 6)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                                    HStack(spacing: 5) {
                                        if let cwd = session.cwd {
                                            Text(URL(fileURLWithPath: cwd).lastPathComponent)
                                        }
                                        Text(session.updatedAt, style: .relative)
                                    }
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if session.id == model.selectedSessionID {
                                    Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                HStack {
                    Text("最近会话")
                    Spacer()
                    if model.loading { ProgressView().controlSize(.small) }
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await model.refresh() }
    }
}

private struct MobileEmptyConversation: View {
    @EnvironmentObject private var model: MobileAppModel

    var body: some View {
        VStack(spacing: 18) {
            DeepSeekIcon(kind: .fish, size: 42).foregroundStyle(.tint)
            VStack(spacing: 6) {
                Text("探索未至之境").font(.title2.bold())
                Text("选择现有会话，或从手机开始一次新任务。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Button { model.showingNewSession = true } label: {
                Label("新建会话", systemImage: "square.and.pencil")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

private struct MobileConversationView: View {
    @EnvironmentObject private var model: MobileAppModel
    @AppStorage("compactConversationMode") private var compactConversationMode = true
    var bottomOverlayInset: CGFloat = 10
    var dockOverlayHeight: CGFloat = 0
    var scrollToBottomRequest = 0
    @Binding var isNearBottom: Bool
    @State private var followsLatest = true
    @State private var strictlyAtBottom = true
    @State private var userScrolling = false
    @State private var leftBottomDuringGesture = false
    @State private var manualScrollSettling = false
    @State private var manualScrollSettleGeneration = 0

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(displayRows) { row in
                            switch row {
                            case let .message(message):
                                MobileMessageView(message: message).id(message.id)
                            case let .activities(id, messages, isCurrent):
                                MobileCompactActivityView(messages: messages, isCurrent: isCurrent).id(id)
                            }
                        }
                        GeometryReader { geometry in
                            Color.clear.preference(key: ConversationBottomPreferenceKey.self,
                                value: geometry.frame(in: .named("conversation-scroll")).maxY)
                        }
                        .frame(height: 1)
                        .id("conversation-bottom")
                    }
                    .padding(.horizontal, 16).padding(.top, 18)
                    .padding(.bottom, max(bottomOverlayInset, dockOverlayHeight + 18))
                }
                .coordinateSpace(name: "conversation-scroll")
                .scrollDismissesKeyboard(.interactively)
                .background(Color(.systemBackground))
                .onPreferenceChange(ConversationBottomPreferenceKey.self) { bottomY in
                    let nearBottom = bottomY <= viewport.size.height + 24
                    let atBottom = bottomY <= viewport.size.height + 6
                    isNearBottom = nearBottom
                    strictlyAtBottom = atBottom
                    if userScrolling {
                        if !atBottom { leftBottomDuringGesture = true }
                        if atBottom && leftBottomDuringGesture { followsLatest = true }
                    } else if manualScrollSettling && atBottom {
                        followsLatest = true
                        manualScrollSettling = false
                    }
                }
                .simultaneousGesture(DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        guard abs(value.translation.height) > abs(value.translation.width) else { return }
                        if !userScrolling {
                            userScrolling = true
                            leftBottomDuringGesture = false
                            manualScrollSettling = false
                        }
                        followsLatest = false
                        if !strictlyAtBottom { leftBottomDuringGesture = true }
                    }
                    .onEnded { value in
                        guard userScrolling || abs(value.translation.height) > abs(value.translation.width) else { return }
                        userScrolling = false
                        followsLatest = strictlyAtBottom
                        manualScrollSettling = !strictlyAtBottom
                        manualScrollSettleGeneration &+= 1
                        let generation = manualScrollSettleGeneration
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            guard manualScrollSettleGeneration == generation else { return }
                            // Preference changes during inertial scrolling may
                            // restore follow only while this gesture is settling.
                            if strictlyAtBottom { followsLatest = true }
                            manualScrollSettling = false
                        }
                    })
                .overlay(alignment: .bottom) {
                    if !followsLatest && !model.messages.isEmpty {
                        Button {
                            followsLatest = true
                            scheduleScrollToBottom(proxy)
                        } label: {
                            Image(systemName: "arrow.down")
                        }
                        .mobileGlassButton()
                        .accessibilityLabel("回到底部")
                        .padding(.bottom, max(bottomOverlayInset, dockOverlayHeight) + 8)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.snappy(duration: 0.2), value: followsLatest)
                .onAppear { scheduleScrollToBottom(proxy, animated: false) }
                .onChange(of: streamRevision) { _, _ in
                    if followsLatest { scheduleScrollToBottom(proxy, animated: false) }
                }
                .onChange(of: scrollToBottomRequest) { _, _ in
                    followsLatest = true
                    scheduleScrollToBottom(proxy)
                }
            }
        }
    }

    private var streamRevision: String {
        guard let last = model.messages.last else { return "0" }
        return "\(model.messages.count):\(last.id):\(last.text.count):\(last.running):\(model.sending)"
    }

    private func scheduleScrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            if animated {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("conversation-bottom", anchor: .bottom)
                }
            } else {
                proxy.scrollTo("conversation-bottom", anchor: .bottom)
            }
        }
    }

    private var displayRows: [MobileConversationDisplayRow] {
        guard compactConversationMode else { return model.messages.map(MobileConversationDisplayRow.message) }
        var rows: [MobileConversationDisplayRow] = []
        var activities: [MobileMessage] = []

        func flush(isCurrent: Bool = false) {
            guard let first = activities.first else { return }
            let hasTool = activities.contains { $0.role == .activity }
            let reasoningRunning = activities.contains { $0.role == .reasoning && $0.running }
            if hasTool || reasoningRunning {
                rows.append(.activities(id: "compact-\(first.id)", messages: activities,
                                        isCurrent: isCurrent))
            }
            activities.removeAll(keepingCapacity: true)
        }

        for message in model.messages {
            if message.role == .activity || message.role == .reasoning {
                activities.append(message)
            } else {
                flush()
                rows.append(.message(message))
            }
        }
        flush(isCurrent: model.sending)
        if model.sending,
           !(model.messages.last?.role == .assistant && model.messages.last?.running == true),
           !(rows.last?.isCurrentActivity ?? false) {
            let placeholder = MobileMessage(id: "compact-live-thinking", role: .reasoning,
                text: "", time: nil, running: true)
            rows.append(.activities(id: "compact-live-thinking", messages: [placeholder], isCurrent: true))
        }
        return rows
    }
}

private enum MobileConversationDisplayRow: Identifiable {
    case message(MobileMessage)
    case activities(id: String, messages: [MobileMessage], isCurrent: Bool)

    var id: String {
        switch self {
        case let .message(message): message.id
        case let .activities(id, _, _): id
        }
    }

    var isCurrentActivity: Bool {
        if case let .activities(_, _, isCurrent) = self { return isCurrent }
        return false
    }
}

private struct MobileCompactActivityView: View {
    let messages: [MobileMessage]
    let isCurrent: Bool
    @State private var expanded = false

    private var sourceTools: [MobileMessage] { messages.filter { $0.role == .activity } }
    private var tools: [MobileMessage] { sourceTools.flatMap(disclosureTools(for:)) }
    private var running: Bool { isCurrent || messages.contains { $0.running } }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                guard !tools.isEmpty else { return }
                withAnimation(.easeInOut(duration: 0.14)) { expanded.toggle() }
            } label: {
                HStack(spacing: 0) {
                    DeepSeekIcon(kind: activityIcon, size: 14)
                        .frame(width: 16, height: 16)
                        .padding(.trailing, 6)
                    Text(summary).lineLimit(1)
                    if !tools.isEmpty {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 14, height: 14)
                            .padding(.leading, 7)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(height: 24)
                .contentShape(Rectangle())
                .overlay { if running { MobileSweepHighlight() } }
                .clipped()
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tools) { MobileMessageView(message: $0) }
                }
                .padding(.leading, 22)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1).padding(.leading, 8)
                }
            }
        }
    }

    private var summary: String {
        if let runningCode = sourceTools.last(where: { isCode($0) && $0.running }),
           let title = transientTitle(for: runningCode) {
            return title
        }
        if let active = tools.last(where: { $0.running }) {
            let action = phrase(for: active, running: true)
            if let detail = active.toolSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !detail.isEmpty {
                return "\(action) · \(detail)"
            }
            return action
        }
        if messages.contains(where: { $0.role == .reasoning && $0.running }) || isCurrent {
            if let code = sourceTools.last(where: isCode), let title = transientTitle(for: code) {
                return title
            }
            return "正在思考"
        }
        var seen = Set<String>()
        let completed = tools.map { phrase(for: $0, running: false) }.filter { seen.insert($0).inserted }
        return completed.isEmpty ? "已完成操作" : completed.joined(separator: "、")
    }

    private func phrase(for tool: MobileMessage, running: Bool) -> String {
        let name = (tool.toolName ?? "").lowercased()
        if name == "todo_write" { return running ? "正在更新任务清单" : "更新了任务清单" }
        if name == "ask_user_question" { return running ? "正在等待输入" : "请求了输入" }
        if name == "skill" { return running ? "正在读取技能" : "读取了技能" }
        if name.hasPrefix("cordis_") { return running ? "正在调用插件" : "调用了插件" }
        if name.contains("search") || name == "grep" || name == "glob" { return running ? "正在搜索" : "搜索了内容" }
        if name.contains("read") || name.contains("fetch") { return running ? "正在读取文件" : "读取了文件" }
        if name.contains("bash") || name.contains("shell") || name.contains("terminal") { return running ? "正在运行命令" : "运行了命令" }
        if name.contains("edit") || name.contains("write") || name.contains("patch") { return running ? "正在编辑文件" : "编辑了文件" }
        if name.contains("code") { return running ? "正在执行代码" : "执行了代码" }
        return running ? "正在调用工具" : "调用了工具"
    }

    private func disclosureTools(for tool: MobileMessage) -> [MobileMessage] {
        guard isCode(tool) else { return [tool] }
        return tool.toolChildren.flatMap(disclosureTools(for:))
    }

    private func isCode(_ tool: MobileMessage) -> Bool {
        tool.toolName?.lowercased() == "run_code"
    }

    private func transientTitle(for tool: MobileMessage) -> String? {
        guard let value = tool.toolSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private var activityIcon: DeepSeekIconKind {
        if messages.contains(where: { $0.role == .reasoning && $0.running })
            || sourceTools.contains(where: { isCode($0) && $0.running }) { return .think }
        if let active = tools.last(where: { $0.running }) { return icon(for: active) }
        return tools.last.map(icon(for:)) ?? .think
    }

    private func icon(for tool: MobileMessage) -> DeepSeekIconKind {
        let name = (tool.toolName ?? "").lowercased()
        if name == "todo_write" { return .checklist }
        if name == "ask_user_question" { return .question }
        if name == "skill" { return .skill }
        if name.contains("search") || name == "grep" || name == "glob" { return .search }
        if name.contains("read") || name.contains("fetch") { return .read }
        if name.contains("bash") || name.contains("shell") || name.contains("terminal") || name == "pwsh" { return .terminal }
        if name.contains("edit") || name.contains("write") || name.contains("patch") { return .edit }
        if name.hasPrefix("cordis_") { return .cordis }
        if name.contains("code") { return .code }
        return .sparkle
    }
}

private struct MobileSessionProjectionDock: View {
    @EnvironmentObject private var model: MobileAppModel

    var body: some View {
        VStack(spacing: 8) {
            if let session = model.selectedSession {
                MobileTodoDock(todos: session.todos)
                if let goal = session.goal, goal.phase != "complete" {
                    MobileGoalDock(goal: goal)
                }
            }
            MobileQueueDock(queue: model.currentQueue)
        }
        .padding(hasContent ? 8 : 0)
        .mobileGlassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 12)
    }

    private var hasContent: Bool {
        guard let session = model.selectedSession else { return !model.currentQueue.isEmpty }
        return !session.todos.isEmpty || session.goal.map { $0.phase != "complete" } == true
            || !model.currentQueue.isEmpty
    }
}

private struct MobileApprovalComposer: View {
    @EnvironmentObject private var model: MobileAppModel
    let request: MobileApprovalRequest

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(.orange).frame(width: 8, height: 8)
                Text("等待审核").fontWeight(.medium)
                Spacer()
                Text(request.toolName).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .font(.subheadline).foregroundStyle(.orange)
            .padding(.horizontal, 16).frame(height: 38)
            .background(Color.orange.opacity(0.12))

            Text(request.reason ?? "工具 \(request.toolName) 请求越权执行")
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 13)

            HStack(spacing: 10) {
                Spacer()
                Button("拒绝", role: .destructive) {
                    Task { await model.answerApproval(request, outcome: "rejected") }
                }
                .buttonStyle(.bordered)
                Button("允许一次") {
                    Task { await model.answerApproval(request, outcome: "allowed-once") }
                }
                .buttonStyle(.borderedProminent)
            }
            .disabled(model.interactionBusy)
            .padding(.horizontal, 16).padding(.bottom, 14)
        }
        .mobileGlassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .stroke(Color.orange.opacity(0.42), lineWidth: 1))
        .padding(.horizontal, 12)
    }
}

private struct MobileQueueDock: View {
    @EnvironmentObject private var model: MobileAppModel
    let queue: [MobileQueuedMessage]
    @State private var expanded = false

    var body: some View {
        if !queue.isEmpty {
            VStack(spacing: 0) {
                Button { withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() } } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "tray.full")
                        Text(queue.count == 1 ? "已排队 1 条" : "已排队 \(queue.count) 条").fontWeight(.medium)
                        Spacer()
                        Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? 180 : 0))
                    }.frame(height: 34).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if expanded || queue.count == 1 {
                    ForEach(queue) { item in
                        HStack(spacing: 8) {
                            Text(item.preview).foregroundStyle(.secondary).lineLimit(2)
                            Spacer(minLength: 4)
                            Button { Task { await model.updateQueue(item, action: ["kind": "remove"]) } } label: {
                                Image(systemName: "trash").frame(width: 28, height: 28)
                            }.buttonStyle(.plain)
                            if model.isConversationRunning {
                                Button { Task { await model.updateQueue(item, action: ["kind": "steer"]) } } label: {
                                    Image(systemName: "paperplane").frame(width: 28, height: 28)
                                }.buttonStyle(.plain)
                            }
                        }.frame(minHeight: 36)
                    }
                }
            }
            .font(.system(size: 13)).padding(.horizontal, 12).padding(.vertical, 4)
            .background(Color.secondary.opacity(0.075), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.12)))
        }
    }
}

private struct MobileTodoDock: View {
    let todos: [MobileTodoItem]
    @State private var collapsed = true

    var body: some View {
        if !todos.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { collapsed.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checklist").frame(width: 16)
                        Text("计划").fontWeight(.medium)
                        Text(progress).foregroundStyle(.tertiary).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(collapsed ? 180 : 0))
                    }
                    .frame(height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if !collapsed {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(todos) { item in
                                HStack(spacing: 10) {
                                    todoGlyph(item.status)
                                    Text(item.content).foregroundStyle(.secondary).lineLimit(2)
                                    Spacer(minLength: 0)
                                }
                                .frame(minHeight: 20)
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.secondary.opacity(0.075), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.12)))
        }
    }

    @ViewBuilder private func todoGlyph(_ status: String) -> some View {
        switch status {
        case "completed":
            Image(systemName: "checkmark.circle").foregroundStyle(.green)
        case "in_progress":
            ProgressView().controlSize(.small).tint(.accentColor)
        default:
            Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        }
    }

    private var progress: String {
        let done = todos.filter { $0.status == "completed" }.count
        let active = todos.filter { $0.status == "in_progress" }.count
        let pending = todos.count - done - active
        return [(done > 0 ? "已完成 \(done)" : nil),
                (active > 0 ? "进行中 \(active)" : nil),
                (pending > 0 ? "待处理 \(pending)" : nil)]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

private struct MobileGoalDock: View {
    @EnvironmentObject private var model: MobileAppModel
    let goal: MobileGoalSnapshot
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "scope").foregroundStyle(.tertiary)
            if editing {
                TextField("目标", text: $draft)
                    .textFieldStyle(.plain).onSubmit(save)
                Button(action: save) { Image(systemName: "checkmark") }
                    .disabled(cleanedDraft.isEmpty)
                Button { editing = false } label: { Image(systemName: "xmark") }
            } else {
                Text(phaseLabel).fontWeight(.medium)
                VStack(alignment: .leading, spacing: 1) {
                    Text(goal.objective).foregroundStyle(.secondary).lineLimit(1)
                    if goal.phase == "blocked", let reason = goal.blockedReason {
                        Text(reason).font(.caption2).foregroundStyle(.red).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if goal.phase == "active" {
                    goalButton("pause", label: "暂停") { Task { await model.mutateGoal("goal.pause") } }
                } else if goal.phase == "paused" {
                    goalButton("play", label: "继续") { Task { await model.mutateGoal("goal.resume") } }
                }
                goalButton("pencil", label: "编辑") { draft = goal.objective; editing = true }
                goalButton("trash", label: "清除") { Task { await model.mutateGoal("goal.clear") } }
            }
        }
        .font(.system(size: 13))
        .padding(.leading, 12).padding(.trailing, 6)
        .frame(minHeight: 36)
        .background(Color.secondary.opacity(0.075), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.12)))
        .disabled(model.goalBusy)
    }

    private var cleanedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var phaseLabel: String {
        switch goal.phase { case "paused": return "已暂停"; case "blocked": return "已阻塞"; default: return "目标" }
    }
    private func save() {
        guard !cleanedDraft.isEmpty else { return }
        let value = cleanedDraft
        editing = false
        Task { await model.mutateGoal("goal.edit", objective: value) }
    }
    private func goalButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 28, height: 28).contentShape(Circle()) }
            .buttonStyle(.plain).accessibilityLabel(label)
    }
}

private struct MobileComposer: View {
    @EnvironmentObject private var model: MobileAppModel
    @FocusState.Binding var focused: Bool
    let shouldScrollOnFocus: () -> Bool
    let requestScrollToBottom: () -> Void
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var importingFile = false

    var body: some View {
        VStack(spacing: showsControls ? 6 : 0) {
            if !model.draftAttachments.isEmpty {
                MobileAttachmentRail(attachments: model.draftAttachments)
            }
            HStack(spacing: 12) {
                if !showsControls {
                    plusMenu
                    if planModeActive { planModeButton }
                }
                composerField
                    .frame(minHeight: 38,
                           maxHeight: hasExplicitLineBreak ? 50 : 38,
                           alignment: hasExplicitLineBreak ? .topLeading : .center)
                    .layoutPriority(1)
                if !showsControls {
                    sendButton
                }
            }

            if showsControls {
                HStack(spacing: 12) {
                    HStack(spacing: 18) {
                        plusMenu
                        permissionMenu
                    }
                    if planModeActive { planModeButton }
                    Spacer(minLength: 8)
                    modelMenu
                    sendButton
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, showsControls ? 10 : 8)
        .mobileGlassSurface(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.10), radius: 18, y: 5)
        .padding(.horizontal, 12)
        .animation(.snappy(duration: 0.22), value: showsControls)
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.plainText, .sourceCode, .json, .xml, .commaSeparatedText, .text], allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls): urls.forEach(model.addTextFile)
            case let .failure(error): model.errorMessage = error.localizedDescription
            }
        }
        .onChange(of: selectedPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for item in items {
                    guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                    let type = item.supportedContentTypes.first(where: { $0.conforms(to: .image) })
                    let mediaType = type?.preferredMIMEType ?? "image/jpeg"
                    let ext = type?.preferredFilenameExtension ?? "jpg"
                    model.addImage(data: data, name: "图片-\(UUID().uuidString.prefix(8)).\(ext)", mediaType: mediaType)
                }
                selectedPhotoItems = []
            }
        }
        .onChange(of: focused) { _, isFocused in
            guard isFocused, shouldScrollOnFocus() else { return }
            Task { @MainActor in
                await Task.yield()
                requestScrollToBottom()
            }
        }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-focus-composer") {
                DispatchQueue.main.async { focused = true }
            }
            #endif
        }
    }

    private var composerField: some View {
        TextField("给智能体发送消息", text: $model.draft, axis: .vertical)
            .lineLimit(1...2)
            .textFieldStyle(.plain)
            .focused($focused)
            .font(.body)
    }

    private var plusMenu: some View {
        Menu {
            PhotosPicker(selection: $selectedPhotoItems, maxSelectionCount: 8, matching: .images) {
                Label("添加图片", systemImage: "photo")
            }
            Button { importingFile = true } label: {
                Label("添加文本或代码文件", systemImage: "doc")
            }
            Divider()
            Button { Task { await model.refresh() } } label: {
                Label("刷新会话", systemImage: "arrow.clockwise")
            }
            Divider()
            Button {
                Task { await model.setPlanMode(!planModeActive) }
            } label: {
                Label(planModeActive ? "退出计划模式" : "进入计划模式",
                      systemImage: planModeActive ? "xmark.circle" : "list.bullet.clipboard")
            }
            .disabled(model.selectedSessionID == nil || model.planSelectionBusy)
        } label: {
            DeepSeekIcon(kind: .plus, size: 17).frame(width: 34, height: 34).contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .buttonStyle(.borderless)
        .disabled(model.permissionSelectionBusy)
    }

    private var planModeButton: some View {
        Button { Task { await model.setPlanMode(false) } } label: {
            HStack(spacing: 4) {
                Text("Plan")
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9).frame(height: 28)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .disabled(model.planSelectionBusy)
        .accessibilityLabel("退出计划模式")
    }

    private var permissionMenu: some View {
        Menu {
            permissionButton("read-only", "只读")
            permissionButton("workspace-write", "工作区可写")
            permissionButton("danger-full-access", "完全访问")
        } label: {
            PermissionGlyph(value: model.selectedSession?.permission ?? "workspace-write", size: 18)
                .frame(width: 36, height: 34).contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .buttonStyle(.borderless)
        .disabled(model.permissionSelectionBusy)
        .accessibilityLabel("权限 · \(permissionLabel)")
    }

    private var sendButton: some View {
        Button {
            focused = false
            requestScrollToBottom()
            Task {
                if model.isConversationRunning { await model.stopCurrentConversation() }
                else { await model.send() }
                requestScrollToBottom()
            }
        } label: {
            Group {
                if model.sending { ProgressView() }
                else if model.isConversationRunning {
                    RoundedRectangle(cornerRadius: 2).fill(Color.white).frame(width: 10, height: 10)
                }
                else { DeepSeekIcon(kind: .send, size: 16) }
            }
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .disabled(!model.isConversationRunning && !canSend)
        .accessibilityLabel(model.isConversationRunning ? "中断" : "发送")
    }

    private var modelMenu: some View {
        Menu {
            if model.modelCatalogLoading && model.models.isEmpty {
                Text("正在加载模型…")
            }
            ForEach(providerIDs, id: \.self) { provider in
                Section(model.models.first(where: { $0.provider == provider })?.providerName ?? provider) {
                    ForEach(model.models.filter { $0.provider == provider }) { choice in
                        Button {
                            Task { await model.chooseModel(choice) }
                        } label: {
                            if choice.key == model.currentModel?.key {
                                Label(choice.name, systemImage: "checkmark")
                            } else {
                                Text(choice.name)
                            }
                        }
                    }
                }
            }
            if let currentChoice, !currentChoice.efforts.isEmpty {
                Section("推理强度 · \(effortLabel ?? "默认")") {
                    if currentChoice.defaultEffort == nil {
                        Button("提供方默认") { Task { await model.chooseEffort(nil) } }
                    }
                    ForEach(currentChoice.efforts) { effort in
                        Button {
                            Task { await model.chooseEffort(effort.id) }
                        } label: {
                            if effort.id == effectiveEffort {
                                Label(effort.name, systemImage: "checkmark")
                            } else {
                                Text(effort.name)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(modelLabel).lineLimit(1)
                if let effortLabel { Text(effortLabel).foregroundStyle(.secondary).lineLimit(1) }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .tint(.primary)
        .disabled(model.modelSelectionBusy)
    }

    private func permissionButton(_ value: String, _ title: String) -> some View {
        Button {
            Task { await model.choosePermission(value) }
        } label: {
            HStack {
                PermissionGlyph(value: value, size: 16)
                Text(title)
                Spacer()
                if model.selectedSession?.permission == value { Image(systemName: "checkmark") }
            }
        }
    }

    private var permissionLabel: String {
        switch model.selectedSession?.permission {
        case "read-only": "只读"
        case "danger-full-access": "完全访问"
        default: "工作区可写"
        }
    }

    private var providerIDs: [String] {
        model.models.reduce(into: []) { result, choice in
            if !result.contains(choice.provider) { result.append(choice.provider) }
        }
    }

    private var planModeActive: Bool {
        model.selectedSession?.plan?.targetActive == true
    }

    private var currentChoice: MobileModelChoice? {
        model.models.first { $0.key == model.currentModel?.key }
    }

    private var effectiveEffort: String? {
        model.currentModel?.reasoningEffort ?? currentChoice?.defaultEffort
    }

    private var modelLabel: String {
        currentChoice?.name ?? model.currentModel?.model ?? "选择模型"
    }

    private var effortLabel: String? {
        guard let currentChoice, let effectiveEffort else { return nil }
        return currentChoice.efforts.first { $0.id == effectiveEffort }?.name ?? effectiveEffort
    }

    private var canSend: Bool {
        model.selectedSessionID != nil && (!model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.draftAttachments.isEmpty)
            && !model.sending
            && (model.subagentStack.last.map { $0.entry.mode == "continuable" && model.subagentParentAvailable[$0.parentID] == true } ?? true)
    }

    private var showsControls: Bool {
        focused || hasExplicitLineBreak
    }

    private var hasExplicitLineBreak: Bool {
        model.draft.contains("\n")
    }
}

private struct MobileAttachmentRail: View {
    @EnvironmentObject private var model: MobileAppModel
    let attachments: [MobileDraftAttachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if attachment.kind == .image, let image = UIImage(data: attachment.data) {
                                Image(uiImage: image).resizable().scaledToFill()
                            } else {
                                VStack(spacing: 4) {
                                    Image(systemName: "doc.text").font(.title3)
                                    Text(attachment.name).font(.caption2).lineLimit(1)
                                    Text(attachment.byteCountText).font(.system(size: 9)).foregroundStyle(.tertiary)
                                }.padding(6)
                            }
                        }
                        .frame(width: 68, height: 58)
                        .background(Color.secondary.opacity(0.09))
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        Button { model.removeAttachment(attachment) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white, .black.opacity(0.55))
                        }
                        .buttonStyle(.plain).padding(3)
                    }
                }
            }.padding(.horizontal, 2)
        }.frame(height: 58)
    }
}

private struct ComposerDockHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ConversationBottomPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct MobileMessageView: View {
    let message: MobileMessage
    @State private var expanded = false
    @AppStorage("compactConversationMode") private var compactConversationMode = true

    @ViewBuilder
    var body: some View {
        switch message.role {
        case .activity:
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    guard toolExpandable else { return }
                    withAnimation(.easeInOut(duration: 0.14)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 0) {
                        Group {
                            if expanded { Image(systemName: "chevron.down").font(.system(size: 13, weight: .medium)) }
                            else { toolGlyph }
                        }
                            .frame(width: 16, height: 16)
                            .foregroundStyle(message.isError ? Color.red : Color.secondary.opacity(0.55))
                            .padding(.trailing, 6)
                        Text(toolRowTitle)
                            .foregroundStyle(.secondary)
                        if !rowSummary.isEmpty {
                            Circle().fill(Color.secondary.opacity(0.35)).frame(width: 2, height: 2)
                                .padding(.horizontal, 8)
                            Text(rowSummary)
                                .foregroundStyle(message.isError ? Color.red : Color.secondary.opacity(0.55))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 14))
                    .frame(height: 24)
                    .contentShape(Rectangle())
                    .overlay { if message.running { MobileSweepHighlight() } }
                    .clipped()
                }
                .buttonStyle(.plain)
                if expanded && toolExpandable {
                    toolDetail.padding(.leading, 4).padding(.top, 4)
                }
                if !message.toolChildren.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(message.toolChildren) { child in
                            MobileMessageView(message: child)
                        }
                    }
                    .padding(.leading, 30).padding(.top, 4).padding(.bottom, 2)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Color.primary.opacity(0.14))
                            .frame(width: 1).padding(.leading, 22)
                    }
                }
            }
            .contextMenu {
                if toolExpandable {
                    Button(expanded ? "折叠" : "展开") {
                        withAnimation(.easeInOut(duration: 0.14)) { expanded.toggle() }
                    }
                    Divider()
                }
                Button("复制输入") { UIPasteboard.general.string = message.toolInput ?? message.detail ?? "" }
                    .disabled((message.toolInput ?? message.detail)?.isEmpty != false)
                Button("复制输出") { UIPasteboard.general.string = message.toolOutput ?? "" }
                    .disabled(message.toolOutput?.isEmpty != false)
            }
        case .reasoning:
            if compactConversationMode {
                HStack(spacing: 7) {
                    DeepSeekIcon(kind: .think, size: 14)
                    Text(message.running ? "正在思考" : "已思考")
                }.font(.callout).foregroundStyle(.secondary)
            } else {
                DisclosureGroup(isExpanded: $expanded) {
                    Text(message.text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .padding(.top, 6)
                } label: {
                    HStack(spacing: 7) {
                        DeepSeekIcon(kind: .think, size: 14).frame(width: 16)
                        Text("Think").foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.tertiary)
                        Text(reasoningSummary).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    .font(.callout)
                }
                .tint(.secondary)
            }
        case .command:
            HStack(spacing: 8) {
                DeepSeekIcon(kind: .terminal, size: 14)
                    .foregroundStyle(message.isError ? Color.red : Color.secondary)
                Text(message.text).font(.system(.callout, design: .monospaced))
                    .foregroundStyle(message.isError ? Color.red : Color.secondary)
                Text("·").foregroundStyle(.tertiary)
                Text(message.detail ?? (message.running ? "正在执行" : "已完成"))
                    .foregroundStyle(message.isError ? Color.red : Color.secondary.opacity(0.7))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 24)
            .overlay { if message.running { MobileSweepHighlight() } }
        case .notice:
            Label(message.text, systemImage: "exclamationmark.circle")
                .font(.callout).foregroundStyle(.red)
        case .user:
            HStack {
                Spacer(minLength: 44)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.secondary.opacity(0.13), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                MobileMarkdownView(source: message.text)
                if let time = message.time {
                    Text(time, style: .time).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder private var toolDetail: some View {
        if !message.toolDiffs.isEmpty {
            MobileDiffCard(diffs: message.toolDiffs)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if let input = message.toolInput, !input.isEmpty {
                    MobileToolSection(label: "IN", text: input)
                }
                if message.toolInput?.isEmpty == false && message.toolOutput?.isEmpty == false {
                    Divider().opacity(0.6)
                }
                if let output = message.toolOutput, !output.isEmpty {
                    MobileToolSection(label: "OUT", text: output, error: message.isError)
                } else if message.toolInput == nil, let detail = message.detail, !detail.isEmpty {
                    MobileToolSection(label: "IN", text: detail)
                }
            }
            .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.12)))
        }
    }

    private var toolExpandable: Bool {
        !message.toolDiffs.isEmpty || message.toolInput?.isEmpty == false
            || message.toolOutput?.isEmpty == false || message.detail?.isEmpty == false
    }

    private var rowSummary: String {
        if message.isError, let output = message.toolOutput, !output.isEmpty {
            return output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? output
        }
        let summary = message.toolSummary ?? ""
        guard !message.toolDiffs.isEmpty else { return summary }
        let changes = MobileDiffCard.changeCounts(message.toolDiffs)
        return summary.isEmpty ? "+\(changes.additions) -\(changes.deletions)"
            : "\(summary)  +\(changes.additions) -\(changes.deletions)"
    }

    private var toolRowTitle: String {
        let name = (message.toolName ?? "").lowercased()
        if name == "todo_write" { return "更新任务清单" }
        if name == "ask_user_question" { return "提问" }
        if name == "skill" { return "Skill" }
        if name == "cordis_define" { return "注册 Cordis 插件" }
        if name == "cordis_run" { return "运行 Cordis 插件" }
        if name == "cordis_stop" { return "停止 Cordis 插件" }
        if name == "cordis_undefine" { return "移除 Cordis 插件" }
        switch (name, message.running) {
        case ("edit", true): return "正在编辑"
        case ("edit", false): return "已编辑"
        case ("write", true): return "正在写入"
        case ("write", false): return "已写入"
        default: return message.text.isEmpty ? toolKind : message.text
        }
    }

    private var reasoningSummary: String {
        let visible = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return visible.split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init) ?? visible
    }

    private var toolKind: String {
        let name = (message.toolName ?? "").lowercased()
        if name.contains("search") || name == "grep" || name == "glob" { return "Search" }
        if name.contains("read") || name.contains("fetch") { return "Read" }
        if name.contains("bash") || name.contains("shell") || name.contains("terminal") || name == "pwsh" { return "Bash" }
        if name.contains("edit") || name.contains("write") || name.contains("patch") { return "Edit" }
        if name.contains("code") || name.hasPrefix("cordis_") { return "Code" }
        return "Tool"
    }

    private var toolIcon: String {
        if message.isError { return "xmark.circle" }
        switch toolKind {
        case "Search": return "magnifyingglass"
        case "Read": return "doc.text"
        case "Terminal": return "terminal"
        case "Edit": return "pencil"
        case "Code": return "chevron.left.forwardslash.chevron.right"
        default: return "sparkles"
        }
    }

    @ViewBuilder private var toolGlyph: some View {
        if message.isError {
            Image(systemName: "xmark.circle").font(.system(size: 13, weight: .medium))
        } else {
            let name = (message.toolName ?? "").lowercased()
            if name == "todo_write" { DeepSeekIcon(kind: .checklist, size: 14) }
            else if name == "ask_user_question" { DeepSeekIcon(kind: .question, size: 14) }
            else if name == "skill" { DeepSeekIcon(kind: .skill, size: 14) }
            else if name.contains("search") || name == "grep" || name == "glob" { DeepSeekIcon(kind: .search, size: 14) }
            else if name.contains("read") || name.contains("fetch") { DeepSeekIcon(kind: .read, size: 14) }
            else if name.contains("bash") || name.contains("shell") || name.contains("terminal") || name == "pwsh" { DeepSeekIcon(kind: .terminal, size: 14) }
            else if name.contains("edit") || name.contains("write") || name.contains("patch") { DeepSeekIcon(kind: .edit, size: 14) }
            else if name.hasPrefix("cordis_") { DeepSeekIcon(kind: .cordis, size: 14) }
            else if name.contains("code") { DeepSeekIcon(kind: .code, size: 14) }
            else { DeepSeekIcon(kind: .sparkle, size: 14) }
        }
    }

    private var markdown: AttributedString {
        let source = message.text as NSString
        let pattern = try? NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#,
                                                options: [.dotMatchesLineSeparators])
        let matches = pattern?.matches(in: message.text,
            range: NSRange(location: 0, length: source.length)) ?? []
        guard !matches.isEmpty else {
            return (try? AttributedString(markdown: message.text,
                options: .init(interpretedSyntax: .full))) ?? AttributedString(message.text)
        }
        var output = AttributedString()
        var cursor = 0
        for match in matches where match.range.location >= cursor {
            let prefixRange = NSRange(location: cursor, length: match.range.location - cursor)
            let prefix = source.substring(with: prefixRange)
            output += (try? AttributedString(markdown: prefix,
                options: .init(interpretedSyntax: .full))) ?? AttributedString(prefix)
            var strong = AttributedString(source.substring(with: match.range(at: 1)))
            strong.inlinePresentationIntent = .stronglyEmphasized
            output += strong
            cursor = match.range.location + match.range.length
        }
        let tail = source.substring(from: cursor)
        output += (try? AttributedString(markdown: tail,
            options: .init(interpretedSyntax: .full))) ?? AttributedString(tail)
        return output
    }
}

private struct MobileMarkdownView: View {
    let source: String

    var body: some View {
        let blocks = HarnessMarkdownParser.parse(source)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                MobileMarkdownBlockView(block: block)
                    .padding(.top, index == 0 ? 0 : gap(before: block))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func gap(before block: HarnessMarkdownBlock) -> CGFloat {
        switch block {
        case .heading, .thematicBreak: 22
        default: 12
        }
    }
}

private struct MobileDiffCard: View {
    let diffs: [MobileDiffHunk]
    @State private var expanded = false
    @State private var copied = false

    private let maxLines = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(headRows) { rowView($0) }
                        if hiddenCount > 0 {
                            Button(expanded ? "收起" : "… 其余 \(hiddenCount) 行") {
                                withAnimation(.easeInOut(duration: 0.14)) { expanded.toggle() }
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tertiary)
                            .frame(height: 22)
                        }
                        if !expanded { ForEach(tailRows) { rowView($0) } }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button(copied ? "已复制" : "复制") { copy() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 9).padding(.trailing, 12)
            }
            let counts = Self.changeCounts(diffs)
            Text("└ +\(counts.additions) -\(counts.deletions) · \(counts.files) file\(counts.files == 1 ? "" : "s")")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12).padding(.bottom, 10)
        }
        .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.12)))
    }

    static func changeCounts(_ diffs: [MobileDiffHunk]) -> (additions: Int, deletions: Int, files: Int) {
        let additions = diffs.reduce(0) { $0 + contentLines($1.newText).count }
        let deletions = diffs.reduce(0) { $0 + ($1.oldText.map { contentLines($0).count } ?? 0) }
        return (additions, deletions, Set(diffs.map(\.path)).count)
    }

    private var rows: [Row] {
        var result: [Row] = []
        var previousPath: String?
        var index = 0
        func append(_ kind: Row.Kind, _ text: String) {
            result.append(Row(id: index, kind: kind, text: text)); index += 1
        }
        for diff in diffs {
            append(diff.path == previousPath ? .gap : .path, diff.path == previousPath ? "⋯" : diff.path)
            previousPath = diff.path
            if let old = diff.oldText { Self.contentLines(old).forEach { append(.deleted, $0) } }
            Self.contentLines(diff.newText).forEach { append(.added, $0) }
        }
        return result
    }

    private var hiddenCount: Int { max(0, rows.count - maxLines) }
    private var headRows: [Row] {
        expanded || hiddenCount == 0 ? rows : Array(rows.prefix((maxLines + 1) / 2))
    }
    private var tailRows: [Row] {
        hiddenCount == 0 ? [] : Array(rows.suffix(maxLines - (maxLines + 1) / 2))
    }

    private func rowView(_ row: Row) -> some View {
        HStack(spacing: 0) {
            Text(row.kind == .added ? "+ " : row.kind == .deleted ? "- " : "")
                .frame(width: row.kind == .added || row.kind == .deleted ? 22 : 0, alignment: .center)
            Text(row.text)
                .fontWeight(row.kind == .path ? .semibold : .regular)
                .padding(.trailing, row.kind == .path ? 56 : 14)
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(foreground(for: row.kind))
        .fixedSize(horizontal: true, vertical: false)
        .frame(minHeight: 22)
        .background(background(for: row.kind))
        .textSelection(.enabled)
    }

    private func foreground(for kind: Row.Kind) -> Color {
        switch kind {
        case .added: return .green
        case .deleted: return .red
        case .gap: return .secondary
        case .path: return .primary
        }
    }

    private func background(for kind: Row.Kind) -> Color {
        switch kind {
        case .added: return Color.green.opacity(0.10)
        case .deleted: return Color.red.opacity(0.10)
        default: return .clear
        }
    }

    private func copy() {
        guard !copied else { return }
        UIPasteboard.general.string = rows.map { row in
            row.kind == .added ? "+ \(row.text)" : row.kind == .deleted ? "- \(row.text)" : row.text
        }.joined(separator: "\n")
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { copied = false }
    }

    private static func contentLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let body = text.hasSuffix("\n") ? String(text.dropLast()) : text
        return body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private struct Row: Identifiable {
        enum Kind { case path, gap, deleted, added }
        let id: Int
        let kind: Kind
        let text: String
    }
}

private struct MobileToolSection: View {
    let label: String
    let text: String
    var error = false

    var body: some View {
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 14) {
                Text(label)
                    .foregroundStyle(.tertiary)
                    .frame(width: 26, alignment: .leading)
                Text(text)
                    .foregroundStyle(error ? Color.red : Color.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
        }
        .frame(maxHeight: 240)
        .font(.system(size: 12, design: .monospaced))
    }
}

private struct MobileSweepHighlight: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !reduceMotion {
            TimelineView(.animation) { timeline in
                GeometryReader { proxy in
                    let cycle = timeline.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 2.6) / 2.6
                    let moving = min(1, cycle / 0.9)
                    let eased = 1 - pow(1 - moving, 3)
                    LinearGradient(colors: [.clear, Color(.systemBackground).opacity(0.62), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: 220)
                        .offset(x: -220 + (proxy.size.width + 220) * eased)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

private struct MobileMarkdownBlockView: View {
    let block: HarnessMarkdownBlock

    @ViewBuilder var body: some View {
        switch block {
        case let .paragraph(text):
            inline(text).font(.system(size: 16)).lineSpacing(5)
        case let .heading(level, text):
            inline(text).font(.system(size: headingSize(level), weight: level <= 3 ? .bold : .semibold))
        case let .list(ordered, start, items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Group {
                            if let checked = item.checked {
                                Image(systemName: checked ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 13))
                            } else {
                                Text((item.ordered ?? ordered) ? "\(item.number ?? start + index)." : "•")
                            }
                        }
                        .foregroundStyle(.secondary)
                        .frame(width: 18, alignment: .trailing)
                        inline(item.text).font(.system(size: 16)).lineSpacing(5)
                    }
                    .padding(.leading, CGFloat(item.depth) * 18)
                }
            }
        case let .quote(children):
            HStack(alignment: .top, spacing: 12) {
                Rectangle().fill(Color.secondary.opacity(0.55)).frame(width: 2)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                        MobileMarkdownBlockView(block: child)
                    }
                }
            }
        case .thematicBreak:
            Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1)
        case let .code(language, source):
            MobileMarkdownCodeBlock(language: language, source: source)
        case let .table(header, rows):
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    tableRow(header, header: true)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in tableRow(row, header: false) }
                }
            }
        }
    }

    private func inline(_ source: String) -> Text {
        Text((try? AttributedString(markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source))
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level { case 1: 24; case 2: 22; case 3: 20; default: 16 }
    }

    private func tableRow(_ cells: [String], header: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                inline(cell)
                    .font(.system(size: 14, weight: header ? .semibold : .regular))
                    .frame(minWidth: 96, maxWidth: 260, alignment: .leading)
                    .padding(.vertical, 9)
                    .padding(.leading, index == 0 ? 0 : 14)
                    .padding(.trailing, index == cells.count - 1 ? 0 : 14)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(header ? 0.12 : 0.08)).frame(height: 1)
        }
    }
}

private struct MobileMarkdownCodeBlock: View {
    let language: String?
    let source: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = source
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Color.secondary.opacity(0.08))
            ScrollView(.horizontal, showsIndicators: true) {
                Text(source)
                    .font(.system(size: 13, design: .monospaced)).lineSpacing(4)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(14)
            }
        }
        .background(Color.secondary.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.10)))
    }
}

private extension View {
    @ViewBuilder
    func mobileGlassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                self
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
            } else {
                self
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
            }
        } else if prominent {
            self.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        } else {
            self.buttonStyle(.bordered).buttonBorderShape(.circle)
        }
    }

    @ViewBuilder
    func mobileGlassSurface<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }
}
