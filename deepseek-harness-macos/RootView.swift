import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct DropMarker: Equatable {
    let id: String
    let after: Bool
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var searchText = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var permissionConfirmation: String?
    @State private var permissionAcknowledged = false
    @State private var optimisticPermission: String?
    @State private var imageLightbox: ImageLightboxItem?
    @State private var windowDropActive = false
    @State private var selectedTab = 0
    @State private var navigationIDs: [String] = []
    @State private var navigationIndex = -1
    @State private var historyNavigationTargetID: String?

    var body: some View {
        ZStack {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                VStack(spacing: 0) {
                    HarnessSidebarBrandBar()
                    SidebarView(searchText: $searchText, columnVisibility: $columnVisibility)
                }
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
            } detail: {
                HSplitView {
                    ConversationView(selectedTab: $selectedTab,
                                     permissionConfirmation: $permissionConfirmation,
                                     permissionAcknowledged: $permissionAcknowledged,
                                     optimisticPermission: $optimisticPermission,
                                     openImage: { imageLightbox = $0 })
                        .frame(minWidth: 600)
                    if model.detail != nil {
                        DetailsPanel().frame(minWidth: 260, idealWidth: 310, maxWidth: 420)
                    }
                }
                .navigationTitle(conversationTitle)
            }
            .navigationSplitViewStyle(.balanced)
            if permissionConfirmation != nil {
                PermissionRiskOverlay(acknowledged: $permissionAcknowledged,
                                      disabled: model.current == nil || model.permissionSelectionBusy,
                                      onCancel: closePermissionConfirmation,
                                      onConfirm: confirmPermission)
                    .zIndex(1000)
            }
            if windowDropActive {
                NativeDropOverlay(disabled: !canAcceptImageDrop, description: model.imageDropDescription)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .zIndex(1500)
            }
            if let imageLightbox {
                NativeImageLightbox(item: imageLightbox, close: closeImageLightbox)
                    .transition(.opacity)
                    .zIndex(2000)
            }
        }
        .background(
            MainWindowConfigurator(
                trailingPreset: toolbarPreset,
                backgroundJobs: currentJobs,
                currentSession: model.current,
                allSessions: model.sessions,
                subagentCatalogs: model.subagents,
                subagentCount: currentSubagentCounts.total,
                runningSubagentCount: currentSubagentCounts.running,
                refreshSubagents: model.loadSubagents,
                openSubagent: model.openSubagent,
                interruptSubagent: model.interruptSubagent,
                sessionLogExportBusy: model.sessionLogExportBusy,
                exportSessionLog: model.exportSessionLog
            )
            .frame(width: 0, height: 0)
        )
        .toolbar { windowToolbar }
        .onDrop(of: [.fileURL, .image], isTargeted: $windowDropActive, perform: receiveImageDrop)
        .alert("DeepSeek Harness", isPresented: Binding(get: { model.errorText != nil }, set: { if !$0 { model.errorText = nil } })) {
            Button("好") { model.errorText = nil }
        } message: { Text(model.errorText ?? "") }
        .onAppear {
            recordNavigationVisit(model.current?.id)
            // SwiftUI may restore a stale detail-only split posture even when
            // the window itself is non-restorable. Product startup always
            // exposes the native sidebar; later user toggles remain untouched.
            DispatchQueue.main.async { columnVisibility = .all }
        }
        .onChange(of: model.current?.id) { id in
            recordNavigationVisit(id)
            closePermissionConfirmation()
            optimisticPermission = nil
            closeImageLightbox()
            selectedTab = 0
        }
        .onExitCommand { if permissionConfirmation != nil { closePermissionConfirmation() } }
    }

    @ToolbarContentBuilder
    private var windowToolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            windowToolbarItems.sharedBackgroundVisibility(.hidden)
        } else {
            windowToolbarItems
        }
    }

    @ToolbarContentBuilder
    private var windowToolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(action: { navigateHistory(offset: -1) }) {
                DeepSeekIcon(kind: .chevronLeft, size: 14).frame(width: 24, height: 24)
            }
            .disabled(navigationTarget(offset: -1) == nil)
            .help("后退")
            Button(action: { navigateHistory(offset: 1) }) {
                DeepSeekIcon(kind: .chevronRight, size: 14).frame(width: 24, height: 24)
            }
            .disabled(navigationTarget(offset: 1) == nil)
            .help("前进")
        }
        if !conversationTitle.isEmpty {
            ToolbarItem(placement: .principal) {
                Text(conversationTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .help(conversationTitle)
            }
        }
    }

    private var conversationTitle: String {
        guard let session = model.current, !session.blank || !model.history.isEmpty else { return "" }
        return model.ancestry(for: session).map(\.displayTitle).joined(separator: " / ")
    }

    private var currentSubagentCounts: (total: Int, running: Int) {
        guard let session = model.current else { return (0, 0) }
        return model.subagentCounts(for: session)
    }

    private var currentJobs: [BackgroundJob] {
        guard let id = model.current?.id else { return [] }
        return model.jobs[id] ?? []
    }

    private var toolbarPreset: String? {
        guard let session = model.current, !session.blank || !model.history.isEmpty else { return nil }
        return presetLabel(session.preset)
    }

    private func presetLabel(_ preset: String?) -> String {
        switch preset {
        case "cordis": "PTC 模式"
        case "code": "代码模式"
        case "minimal": "极简模式"
        default: "标准模式"
        }
    }

    private func closePermissionConfirmation() {
        permissionAcknowledged = false
        permissionConfirmation = nil
    }

    private func confirmPermission() {
        guard permissionAcknowledged, let value = permissionConfirmation, model.current != nil else { return }
        optimisticPermission = value
        closePermissionConfirmation()
        model.choosePermission(value) { _ in optimisticPermission = nil }
    }

    private func closeImageLightbox() {
        let restoreFocus = imageLightbox?.restoreFocus
        imageLightbox = nil
        DispatchQueue.main.async { restoreFocus?() }
    }

    /// Session selection follows browser history semantics: a normal visit
    /// appends after the current cursor, while back/forward only moves it.
    private func recordNavigationVisit(_ id: String?) {
        guard let id else { return }
        if historyNavigationTargetID == id {
            historyNavigationTargetID = nil
            return
        }
        historyNavigationTargetID = nil
        if navigationIDs.indices.contains(navigationIndex), navigationIDs[navigationIndex] == id { return }
        if navigationIndex + 1 < navigationIDs.count {
            navigationIDs.removeSubrange((navigationIndex + 1)..<navigationIDs.count)
        }
        navigationIDs.append(id)
        navigationIndex = navigationIDs.count - 1
    }

    private func navigationTarget(offset: Int) -> (index: Int, session: SessionSummary)? {
        guard offset != 0, !navigationIDs.isEmpty else { return nil }
        var candidate = navigationIndex + offset
        while navigationIDs.indices.contains(candidate) {
            let id = navigationIDs[candidate]
            if id != model.current?.id,
               let session = model.sessions.first(where: { $0.id == id }),
               !model.archivedSessionIds.contains(id) {
                return (candidate, session)
            }
            candidate += offset
        }
        return nil
    }

    private func navigateHistory(offset: Int) {
        guard let target = navigationTarget(offset: offset) else { return }
        navigationIndex = target.index
        historyNavigationTargetID = target.session.id
        model.select(target.session)
    }

    private var canAcceptImageDrop: Bool {
        guard model.current != nil, model.canAddImageCount(), !model.interactionBusy else { return false }
        if model.currentSubagentMode == "one-shot" { return false }
        if model.currentSubagentMode == "continuable", model.subagentParentAvailable[model.subagentParentId ?? ""] != true { return false }
        return true
    }

    private func receiveImageDrop(_ providers: [NSItemProvider]) -> Bool {
        guard canAcceptImageDrop else { return true }
        let group = DispatchGroup()
        let lock = NSLock()
        var candidates: [Int: DraftImageCandidate] = [:]
        var textFiles: [Int: URL] = [:]
        var invalid = false
        for (index, provider) in providers.enumerated() {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    defer { group.leave() }
                    guard let url, let data = try? Data(contentsOf: url) else {
                        lock.lock(); invalid = true; lock.unlock(); return
                    }
                    lock.lock()
                    if let mediaType = Self.imageMediaType(url) {
                        candidates[index] = DraftImageCandidate(data: data, name: url.lastPathComponent, mediaType: mediaType)
                    } else if data.count <= 1_024 * 1_024, String(data: data, encoding: .utf8) != nil {
                        textFiles[index] = url
                    } else {
                        invalid = true
                    }
                    lock.unlock()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                group.enter()
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    defer { group.leave() }
                    guard let data, NSImage(data: data) != nil else { lock.lock(); invalid = true; lock.unlock(); return }
                    lock.lock(); candidates[index] = DraftImageCandidate(data: data, name: "image", mediaType: "image/png"); lock.unlock()
                }
            }
        }
        group.notify(queue: .main) {
            lock.lock()
            let failed = invalid
            let ordered = candidates.keys.sorted().compactMap { candidates[$0] }
            let orderedFiles = textFiles.keys.sorted().compactMap { textFiles[$0] }
            lock.unlock()
            if failed { model.errorText = "仅支持图片和不超过 1 MB 的 UTF-8 文本/代码文件" }
            model.addImages(ordered)
            orderedFiles.forEach(model.addTextFile)
        }
        return true
    }

    private static func imageMediaType(_ url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        default: return nil
        }
    }
}

/// The brand starts the native sidebar's content below the unified toolbar.
private struct HarnessSidebarBrandBar: View {
    var body: some View {
        HStack(spacing: 0) {
            DeepSeekBrandWordmark(height: 20)
            Spacer(minLength: 8)
        }
        .padding(.leading, 18).padding(.trailing, 8)
        .frame(height: 44)
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var searchText: String
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @State private var renaming: SessionSummary?
    @State private var renameText = ""
    @State private var searchWorkItem: DispatchWorkItem?
    @State private var searchExpanded = false
    @FocusState private var searchFocused: Bool
    @State private var expandedWorkspaces: Set<String> = []
    @State private var workspaceRenaming: WorkspaceSummary?
    @State private var workspaceRenameText = ""
    @State private var draggingWorkspaceID: String?
    @State private var workspaceDropTarget: DropMarker?
    @State private var draggingSessionID: String?
    @State private var sessionDropTarget: DropMarker?
    @State private var cordisPanelOpen = false
    @State private var viewOptionsOpen = false

    private var filtered: [SessionSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.sessions.filter { session in
            // WebUI keeps durable subagent sessions out of the ordinary
            // workspace tree. They are reached from the owner's titlebar
            // catalog and open as their own conversation.
            guard session.origin != "subagent" else { return false }
            guard !session.blank || session.id == model.current?.id else { return false }
            guard !query.isEmpty else { return true }
            return session.displayTitle.localizedCaseInsensitiveContains(query)
                || (session.cwd?.localizedCaseInsensitiveContains(query) ?? false)
                || model.sessionSearchHits.contains(where: { $0.sessionId == session.id })
        }
    }

    /// WebUI switches to a flat SearchResultItem tree while a query is active:
    /// local title/workspace matches lead by recency, then Host content hits
    /// retain their ranked order, with duplicates merged in place.
    private var searchProjection: (items: [SessionSummary], hasMore: Bool) {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return ([], false) }
        let needle = query.localizedLowercase
        let workspaceNames = Dictionary(uniqueKeysWithValues: model.workspaces.map { ($0.id, $0.name) })
        var accounted: [String: String] = [:]
        for workspace in model.workspaces {
            for id in workspace.sessionIds where accounted[id] == nil { accounted[id] = workspaceNames[workspace.id] }
        }
        let local = model.sessions
            .filter { $0.origin != "subagent" && !$0.blank && !model.archivedSessionIds.contains($0.id) }
            .filter {
                $0.displayTitle.localizedLowercase.contains(needle)
                    || (accounted[$0.id]?.localizedLowercase.contains(needle) ?? false)
                    || ($0.cwd?.localizedLowercase.contains(needle) ?? false)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
        var result: [SessionSummary] = []
        var seen = Set<String>()
        for session in local where seen.insert(session.id).inserted { result.append(session) }
        for hit in model.sessionSearchHits {
            guard let session = model.sessions.first(where: { $0.id == hit.sessionId }), !session.blank,
                  session.origin != "subagent", !model.archivedSessionIds.contains(session.id),
                  seen.insert(session.id).inserted else { continue }
            result.append(session)
        }
        return (Array(result.prefix(20)), model.sessionSearchHasMore || result.count > 20)
    }

    private func workspaceLabel(for session: SessionSummary) -> String {
        if let workspace = model.workspaces.first(where: { $0.sessionIds.contains(session.id) }) { return workspace.name }
        if let cwd = session.cwd { return URL(fileURLWithPath: cwd).lastPathComponent }
        return "未分组"
    }

    private func sessions(in workspace: WorkspaceSummary) -> [SessionSummary] {
        let byId = Dictionary(uniqueKeysWithValues: filtered.map { ($0.id, $0) })
        let accounted = workspace.sessionIds.compactMap { byId[$0] }
        let ids = Set(accounted.map(\.id))
        let rows = accounted + filtered.filter { $0.cwd == workspace.path && !ids.contains($0.id) }.sorted { $0.updatedAt > $1.updatedAt }
        return model.sessionOrderMode == .updated ? rows.sorted { $0.updatedAt > $1.updatedAt } : rows
    }

    private var ungrouped: [SessionSummary] {
        let accounted = Set(model.workspaces.flatMap(\.sessionIds))
        let rows = filtered.filter { !accounted.contains($0.id) }
        return model.sessionOrderMode == .updated ? rows.sorted { $0.updatedAt > $1.updatedAt } : rows
    }
    private var workspaceList: [WorkspaceSummary] { model.workspaces }

    private func sessionRow(_ session: SessionSummary, flat: Bool = false) -> some View {
        SessionRow(
            session: session,
            interaction: model.interactions.first { $0.sessionId == session.id },
            flat: flat,
            onRename: { renaming = session; renameText = session.displayTitle },
            onFork: { model.branch(session: session, at: nil) },
            onArchive: { model.archive(session) }
        )
            .contentShape(Rectangle())
            .onTapGesture { model.select(session) }
            .contextMenu { if !session.blank { sessionContextMenu(for: session) } }
            .padding(.horizontal, 8)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: model.createSession) {
                HStack(spacing: 6) {
                    DeepSeekIcon(kind: .newChat, size: 14)
                    Text("新建会话")
                }
                    .frame(maxWidth: .infinity).frame(height: 36)
            }
            .buttonStyle(.bordered).controlSize(.large).padding(.horizontal, 14).padding(.top, 14)
            .keyboardShortcut("n", modifiers: .command)

            workspaceSectionHeader
                .padding(.leading, 16).padding(.trailing, 8).padding(.top, 2).padding(.bottom, 4)

            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let projection = searchProjection
                if projection.items.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.tertiary)
                        if model.sessionSearchLoading { ProgressView().controlSize(.small) }
                        Text("没有匹配的会话").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(projection.items) { session in
                                SearchResultSessionRow(session: session, workspace: workspaceLabel(for: session), snippet: model.sessionSnippet(session.id))
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.select(session) }
                            }
                        }.padding(.horizontal, 6).padding(.vertical, 4)
                    }.scrollContentBackground(.hidden)
                }
                if projection.hasMore {
                    Text("仅显示前 20 条结果，请缩小搜索范围。").font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.bottom, 4)
                }
            } else if filtered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "message").font(.title2).foregroundStyle(.tertiary)
                    if model.sessionSearchLoading { ProgressView().controlSize(.small) }
                    Text(searchText.isEmpty ? "暂无会话" : "没有匹配的会话").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if model.sessionGroupMode == .workspace {
                        ForEach(workspaceList, id: \.id) { (workspace: WorkspaceSummary) in
                            let rows = sessions(in: workspace)
                            WorkspaceGroupRow(workspace: workspace, expanded: expandedWorkspaces.contains(workspace.id), rows: rows,
                                onToggle: { if expandedWorkspaces.contains(workspace.id) { expandedWorkspaces.remove(workspace.id) } else { expandedWorkspaces.insert(workspace.id) } },
                                onCreate: { model.createSession(workspace: workspace) },
                                onRename: { workspaceRenaming = workspace; workspaceRenameText = workspace.name },
                                onDelete: { model.deleteWorkspace(workspace) },
                                sessionRow: { sessionRow($0) },
                                draggingWorkspaceID: $draggingWorkspaceID,
                                workspaceDropTarget: $workspaceDropTarget,
                                draggingSessionID: $draggingSessionID,
                                sessionDropTarget: $sessionDropTarget,
                                draggable: true,
                                dragging: draggingWorkspaceID == workspace.id,
                                dropTarget: workspaceDropTarget?.id == workspace.id,
                                onDragStart: { draggingWorkspaceID = workspace.id },
                                onDragEnd: { draggingWorkspaceID = nil; workspaceDropTarget = nil },
                                onDragOver: { after in workspaceDropTarget = DropMarker(id: workspace.id, after: after) },
                                onDrop: { after in
                                    if let source = draggingWorkspaceID, source != workspace.id {
                                        // Resolve the DOM-insertBefore anchor from the target row's half.
                                        let list = model.workspaces.filter { $0.id != source }
                                        let targetIndex = list.firstIndex(where: { $0.id == workspace.id }) ?? list.count
                                        let before = after ? list.dropFirst(targetIndex + 1).first?.id : workspace.id
                                        model.reorderWorkspaces(from: source, before: before)
                                    }
                                    draggingWorkspaceID = nil; workspaceDropTarget = nil
                                })
                        }
                        if !ungrouped.isEmpty {
                            WorkspaceGroupRow(workspace: nil, expanded: true, rows: ungrouped, onToggle: {}, onCreate: { model.createSession() }, onRename: {}, onDelete: {}, sessionRow: { sessionRow($0) }, draggingWorkspaceID: $draggingWorkspaceID, workspaceDropTarget: $workspaceDropTarget, draggingSessionID: $draggingSessionID, sessionDropTarget: $sessionDropTarget)
                        }
                        } else {
                            ForEach(filtered.sorted { model.sessionOrderMode == .updated ? $0.updatedAt > $1.updatedAt : false }) { session in
                                sessionRow(session, flat: true)
                                    // WebUI keeps the flat/recency projection read-only; manual
                                    // reordering is only committed inside an accounted workspace.
                                    .dragIf(false) { NSItemProvider(object: session.id as NSString) }
                                    .dropIf(false, of: [.text]) { _ in true }
                            }
                        }
                    }.padding(.horizontal, 6).padding(.vertical, 4)
                }.scrollContentBackground(.hidden)
            }

            if !model.cordisInventory.isEmpty || model.cordisInventoryLoading || model.cordisInventoryError != nil {
                CordisSidebarPanel(open: $cordisPanelOpen)
                    .padding(.horizontal, 8).padding(.top, 8)
            }
            Divider()
            Button(action: openNativeSettings) {
                HStack {
                    Circle().fill(model.connectionText == "已连接" ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(model.connectionText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("设置").font(.system(size: 13)).foregroundStyle(.secondary)
                    DeepSeekIcon(kind: .settings, size: 16)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 46)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("打开设置")
        }
        .sheet(item: $renaming) { session in
            VStack(alignment: .leading, spacing: 18) {
                Text("重命名会话").font(.headline)
                TextField("会话名称", text: $renameText).textFieldStyle(.roundedBorder)
                HStack { Spacer(); Button("取消") { renaming = nil }.keyboardShortcut(.cancelAction)
                    Button("保存") { model.rename(session, to: renameText); renaming = nil }.keyboardShortcut(.defaultAction)
                        .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }.padding(24).frame(width: 390)
        }
        .sheet(item: $workspaceRenaming) { workspace in
            VStack(alignment: .leading, spacing: 16) {
                Text("重命名工作区").font(.headline)
                TextField("工作区名称", text: $workspaceRenameText).textFieldStyle(.roundedBorder)
                HStack { Spacer(); Button("取消") { workspaceRenaming = nil }.keyboardShortcut(.cancelAction); Button("保存") { model.renameWorkspace(workspace, to: workspaceRenameText); workspaceRenaming = nil }.keyboardShortcut(.defaultAction).disabled(workspaceRenameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }.padding(24).frame(width: 390)
        }
        .onExitCommand {
            if searchExpanded { closeSearch() }
        }
    }

    private func openNativeSettings() {
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private var workspaceSectionHeader: some View {
        HStack(spacing: 4) {
            if !searchExpanded {
                Text("工作区")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                Spacer(minLength: 8)
            }
            HStack(spacing: 0) {
                Button {
                    openSearch()
                } label: {
                    DeepSeekIcon(kind: .search, size: searchExpanded ? 11 : 14)
                        .frame(width: 28, height: searchExpanded ? 30 : 28)
                }
                .buttonStyle(.plain)
                .help(searchExpanded ? "" : "搜索")
                if searchExpanded {
                    TextField("搜索会话", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($searchFocused)
                        .onChange(of: searchText, perform: queueSearch)
                    Button(action: closeSearch) {
                        DeepSeekIcon(kind: .close, size: 12).frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("清除搜索")
                }
            }
            .frame(maxWidth: searchExpanded ? .infinity : 28, alignment: .leading)
            .frame(height: searchExpanded ? 30 : 28)
            .overlay {
                if searchExpanded {
                    RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: searchExpanded)
            if !searchExpanded {
                Button {
                    viewOptionsOpen.toggle()
                } label: {
                    DeepSeekIcon(kind: .personalization, size: 16).frame(width: 28, height: 28)
                        .background(viewOptionsOpen ? Color.primary.opacity(0.07) : .clear, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("分组与排序")
                .popover(isPresented: $viewOptionsOpen, arrowEdge: .top) {
                    WorkspaceViewOptionsPopover(presented: $viewOptionsOpen)
                        .environmentObject(model)
                }
                Button { chooseDirectory() } label: {
                    DeepSeekIcon(kind: .projectAdd, size: 16).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain).help("添加工作区")
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .frame(height: 36)
        .animation(.easeInOut(duration: 0.18), value: searchExpanded)
    }

    private func openSearch() {
        guard !searchExpanded else { searchFocused = true; return }
        withAnimation(.easeInOut(duration: 0.18)) { searchExpanded = true }
        DispatchQueue.main.async { searchFocused = true }
    }

    private func closeSearch() {
        searchWorkItem?.cancel()
        searchText = ""
        model.searchSessions("")
        searchFocused = false
        withAnimation(.easeInOut(duration: 0.18)) { searchExpanded = false }
    }

    private func queueSearch(_ value: String) {
        searchWorkItem?.cancel()
        let work = DispatchWorkItem { model.searchSessions(value) }
        searchWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.createWorkspace(path: url.path) }
    }

    @ViewBuilder
    private func sessionContextMenu(for session: SessionSummary) -> some View {
        Button("重命名") { renaming = session; renameText = session.displayTitle }
        Button("分叉会话") { model.branch(session: session, at: nil) }
        Button("归档会话") { model.archive(session) }
    }
}

private struct WorkspaceViewOptionsPopover: View {
    @EnvironmentObject private var model: AppModel
    @Binding var presented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("分组方式")
            optionRow("按工作区", selected: model.sessionGroupMode == .workspace) {
                model.sessionGroupMode = .workspace
            }
            optionRow("单列表", selected: model.sessionGroupMode == .flat) {
                model.sessionGroupMode = .flat
            }

            Divider().padding(.vertical, 5)

            sectionTitle("排序方式")
            optionRow("手动排序", selected: model.sessionOrderMode == .manual) {
                model.sessionOrderMode = .manual
            }
            optionRow("最近更新", selected: model.sessionOrderMode == .updated) {
                model.sessionOrderMode = .updated
            }
        }
        .padding(8)
        .frame(width: 220)
        .nativeGlassPopover(cornerRadius: 16)
        .onExitCommand { presented = false }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .frame(height: 22, alignment: .leading)
    }

    private func optionRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        WorkspaceViewOptionRow(title: title, selected: selected) {
            action()
            presented = false
        }
    }
}

private struct WorkspaceViewOptionRow: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 15))
                    .foregroundStyle(.primary)
                Spacer(minLength: 12)
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .opacity(selected ? 1 : 0)
                    .frame(width: 18)
            }
            .padding(.horizontal, 8)
            .frame(height: 33)
            .background(hovering ? Color.primary.opacity(0.07) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct SearchResultSessionRow: View {
    @EnvironmentObject private var model: AppModel
    let session: SessionSummary
    let workspace: String
    let snippet: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            statusIcon.frame(width: 14).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayTitle).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                Text(workspace).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                if let snippet, !snippet.isEmpty {
                    Text(snippet).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(model.current?.id == session.id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder private var statusIcon: some View {
        if model.interactions.contains(where: { $0.sessionId == session.id }) {
            LifecycleStateDot(state: .warning)
        } else if session.running {
            LifecycleStateDot(state: .ongoing)
        } else if model.runningSubagentCount(for: session) > 0 {
            LifecycleStateDot(state: .ongoing)
        } else {
            Color.clear.frame(width: 10, height: 10)
        }
    }
}

private struct WorkspaceGroupRow<SessionContent: View>: View {
    @EnvironmentObject private var model: AppModel
    let workspace: WorkspaceSummary?
    let expanded: Bool
    let rows: [SessionSummary]
    let onToggle: () -> Void
    let onCreate: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let sessionRow: (SessionSummary) -> SessionContent
    @Binding var draggingWorkspaceID: String?
    @Binding var workspaceDropTarget: DropMarker?
    @Binding var draggingSessionID: String?
    @Binding var sessionDropTarget: DropMarker?
    var draggable = false
    var dragging = false
    var dropTarget = false
    var onDragStart: () -> Void = {}
    var onDragEnd: () -> Void = {}
    var onDragOver: (Bool) -> Void = { _ in }
    var onDrop: (Bool) -> Void = { _ in }
    var title: String { workspace?.name ?? "未分组" }
    @State private var hovering = false
    private var containsCurrent: Bool { rows.contains { $0.id == model.current?.id } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Group {
                    if hovering {
                    DeepSeekIcon(kind: .triangleRight, size: 14)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    } else {
                        DeepSeekIcon(kind: expanded ? .folderOpen : .folderClosed, size: 16)
                            .foregroundStyle(expanded && containsCurrent ? Color.accentColor : .secondary)
                    }
                }.frame(width: 16, height: 20)
                Text(title).font(.system(size: 14)).lineLimit(1)
                Spacer()
                if hovering {
                    if workspace != nil {
                        Menu {
                            Button("重命名") { onRename() }
                            Button("删除工作区", role: .destructive) { onDelete() }
                        } label: {
                            DeepSeekIcon(kind: .ellipsis, size: 16).frame(width: 20, height: 20)
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                    Button(action: onCreate) {
                        DeepSeekIcon(kind: .plus, size: 16).frame(width: 20, height: 20)
                    }.buttonStyle(.plain).help("新建会话")
                }
            }
            .padding(.horizontal, 8).frame(height: 34)
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggle)
                .onHover { hovering = $0 }
                .background(hovering ? Color.primary.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .opacity(dragging ? 0.45 : 1)
                .overlay(alignment: .top) {
                    if workspaceDropTarget?.id == workspace?.id && workspaceDropTarget?.after == false {
                        Rectangle().fill(Color.accentColor).frame(height: 2)
                    }
                }
                .overlay(alignment: .bottom) {
                    if workspaceDropTarget?.id == workspace?.id && workspaceDropTarget?.after == true {
                        Rectangle().fill(Color.accentColor).frame(height: 2)
                    }
                }
                .dragIf(workspace != nil) { onDragStart(); return NSItemProvider(object: workspace!.id as NSString) }
                .dropWorkspaceIf(workspace != nil, targetID: workspace?.id, draggingID: $draggingWorkspaceID, marker: $workspaceDropTarget,
                                 onOver: onDragOver, onDrop: onDrop)
            if expanded {
                ForEach(rows) { session in
                    sessionRow(session)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .top) {
                            if sessionDropTarget?.id == session.id && sessionDropTarget?.after == false {
                                Rectangle().fill(Color.accentColor).frame(height: 2)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if sessionDropTarget?.id == session.id && sessionDropTarget?.after == true {
                                Rectangle().fill(Color.accentColor).frame(height: 2)
                            }
                        }
                        .onDrag { draggingSessionID = session.id; return NSItemProvider(object: session.id as NSString) }
                        .onDrop(of: [.text], delegate: SessionDropDelegate(targetID: session.id, draggingID: $draggingSessionID, dropTarget: $sessionDropTarget, workspace: workspace, model: model))
                }
            }
        }
    }

}

private struct SessionDropDelegate: DropDelegate {
    let targetID: String
    @Binding var draggingID: String?
    @Binding var dropTarget: DropMarker?
    let workspace: WorkspaceSummary?
    let model: AppModel

    func dropEntered(info: DropInfo) { update(info) }
    func dropExited(info: DropInfo) { if dropTarget?.id == targetID { dropTarget = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? { update(info); return DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        defer { draggingID = nil; dropTarget = nil }
        guard let source = draggingID, source != targetID, let workspace else { return false }
        let ids = model.workspaces.first(where: { $0.id == workspace.id })?.sessionIds ?? workspace.sessionIds
        let targetIndex = ids.firstIndex(of: targetID) ?? ids.count
        let after = dropTarget?.after == true
        let before = after ? ids.dropFirst(targetIndex + 1).first(where: { $0 != source }) : targetID
        model.reorderSessions(in: workspace, sourceID: source, before: before)
        return true
    }
    private func update(_ info: DropInfo) {
        dropTarget = DropMarker(id: targetID, after: info.location.y > 17.5)
    }
}

private extension View {
    @ViewBuilder
    func dragIf(_ condition: Bool, _ provider: @escaping () -> NSItemProvider) -> some View {
        if condition { self.onDrag(provider) } else { self }
    }

    @ViewBuilder
    func dropIf(_ condition: Bool, of types: [UTType], perform action: @escaping ([NSItemProvider]) -> Bool) -> some View {
        if condition { self.onDrop(of: types, isTargeted: nil, perform: action) } else { self }
    }

    @ViewBuilder
    func dropWorkspaceIf(_ condition: Bool, targetID: String?, draggingID: Binding<String?>, marker: Binding<DropMarker?>,
                         onOver: @escaping (Bool) -> Void, onDrop: @escaping (Bool) -> Void) -> some View {
        if condition, let targetID {
            self.onDrop(of: [.text], delegate: WorkspaceDropDelegate(targetID: targetID, draggingID: draggingID, marker: marker, onOver: onOver, onDrop: onDrop))
        } else { self }
    }
}

private struct WorkspaceDropDelegate: DropDelegate {
    let targetID: String
    @Binding var draggingID: String?
    @Binding var marker: DropMarker?
    let onOver: (Bool) -> Void
    let onDrop: (Bool) -> Void

    func dropEntered(info: DropInfo) { update(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? { update(info); return DropProposal(operation: .move) }
    func dropExited(info: DropInfo) { if marker?.id == targetID { marker = nil } }
    func performDrop(info: DropInfo) -> Bool {
        let after = info.location.y > 15
        onDrop(after)
        draggingID = nil
        marker = nil
        return true
    }
    private func update(_ info: DropInfo) {
        let after = info.location.y > 15
        marker = DropMarker(id: targetID, after: after)
        onOver(after)
    }
}

private struct SessionRow: View {
    @EnvironmentObject private var model: AppModel
    let session: SessionSummary
    let interaction: PendingInteraction?
    let flat: Bool
    let onRename: () -> Void
    let onFork: () -> Void
    let onArchive: () -> Void
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 0) {
            if !flat || hasVisibleStatus {
                Group {
                    if interaction != nil { LifecycleStateDot(state: .warning) }
                    else if session.running || model.runningSubagentCount(for: session) > 0 { LifecycleStateDot(state: .ongoing) }
                    else { Color.clear.frame(width: 10, height: 10) }
                }.frame(width: 16, height: 20)
            }
            Text(session.displayTitle)
                .lineLimit(1)
                .font(.system(size: 14))
                .padding(.leading, (!flat || hasVisibleStatus) ? 4 : 0)
                .padding(.trailing, 6)
            Spacer(minLength: 4)
            if !session.blank {
                if hovering {
                    Menu {
                        Button("重命名", action: onRename)
                        Button("分叉会话", action: onFork)
                        Button("归档会话", action: onArchive)
                    } label: {
                        DeepSeekIcon(kind: .ellipsis, size: 16).frame(width: 24, height: 24)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                } else {
                    Text(relativeSessionTime(session.updatedAt)).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(model.current?.id == session.id || hovering ? Color.primary.opacity(0.055) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
        .help(sessionHelp)
    }
    private var hasVisibleStatus: Bool {
        interaction != nil || session.running || model.runningSubagentCount(for: session) > 0
    }
    private var sessionHelp: String {
        var lines = [session.displayTitle]
        if !session.blank { lines.append("更新于 \(relativeSessionTime(session.updatedAt))前") }
        if interaction != nil { lines.append("正在等待你的操作") }
        else if session.running { lines.append("正在运行") }
        else if model.runningSubagentCount(for: session) > 0 { lines.append("子智能体正在运行") }
        return lines.joined(separator: "\n")
    }
    private func relativeSessionTime(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(seconds / 60)分" }
        if seconds < 86400 { return "\(seconds / 3600)时" }
        if seconds < 2_592_000 { return "\(seconds / 86400)天" }
        return "\(seconds / 2_592_000)月"
    }
}

private struct ConversationView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selectedTab: Int
    @Binding var permissionConfirmation: String?
    @Binding var permissionAcknowledged: Bool
    @Binding var optimisticPermission: String?
    let openImage: (ImageLightboxItem) -> Void
    @State private var draft = ""
    @State private var followsLatest = true
    @State private var initializedScrollSessionID: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let session = model.current, !session.blank {
                ConversationViewTabs(selectedTab: $selectedTab)
            }
            if model.current == nil {
                EmptyState(title: "还没有会话", subtitle: "从左侧新建一个会话开始", symbol: "message.badge")
            } else if selectedTab == 1 {
                TrajectoryView()
            } else if model.history.isEmpty {
                ZStack {
                    EllipticalGradient(colors: [Color.blue.opacity(0.075), .clear], center: .center)
                        .scaleEffect(x: 1.35, y: 0.6).blur(radius: 24).allowsHitTesting(false)
                    VStack(spacing: 12) {
                        HeroView()
                        HeroWorkspaceSeat()
                        composerBody.padding(.horizontal, 24)
                    }
                    .frame(maxWidth: 828)
                    .padding(.horizontal, 24).padding(.bottom, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ZStack(alignment: .bottom) {
                        ScrollView {
                            LazyVStack(spacing: 16) {
                                ForEach(conversationRows) { row in
                                    switch row {
                                    case let .message(item):
                                        MessageRow(item: item, openImage: openImage).id(row.id)
                                    case let .activities(group):
                                        CompactActivityRow(group: group).id(row.id)
                                    }
                                }
                                ForEach(currentSteering) { item in PendingSteeringView(item: item).id("steering-\(item.id)") }
                                Color.clear.frame(height: 1).id("conversation-bottom")
                            }
                            .background(
                                NativeConversationScrollObserver(
                                    onPositionChange: { atBottom in followsLatest = atBottom },
                                    onContentResize: {
                                        if followsLatest { scrollToLatest(proxy) }
                                    }
                                )
                                .frame(width: 0, height: 0)
                            )
                            .frame(maxWidth: 748).padding(.horizontal, 32).padding(.top, 16).padding(.bottom, 24).frame(maxWidth: .infinity)
                        }
                        if !followsLatest {
                            HStack {
                                Spacer(minLength: 0)
                                Button {
                                    followsLatest = true
                                    scrollToLatest(proxy, animated: true)
                                } label: {
                                    DeepSeekIcon(kind: .chevronDown, size: 14)
                                        .frame(width: 34, height: 34)
                                        .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .background(Color(nsColor: .controlBackgroundColor), in: Circle())
                                .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1))
                                .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
                                .help("回到最新内容")
                                .accessibilityLabel("回到最新内容")
                            }
                            .frame(maxWidth: 748)
                            .padding(.horizontal, 32).padding(.bottom, 16)
                            .transition(.opacity)
                        }
                    }
                    .onAppear { initializeScroll(proxy) }
                    .onChange(of: model.current?.id) { _ in initializeScroll(proxy) }
                    .onChange(of: model.history.count) { _ in
                        let appendedOwnMessage = model.history.last.map(isUserMessage) ?? false
                        if appendedOwnMessage {
                            followsLatest = true
                            scrollToLatest(proxy)
                        } else if followsLatest {
                            scrollToLatest(proxy)
                        }
                    }
                    .onChange(of: model.history.last?.kind) { _ in
                        if followsLatest { scrollToLatest(proxy) }
                    }
                    .onChange(of: currentSteering.count) { _ in
                        followsLatest = true
                        scrollToLatest(proxy)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 8) {
                    TodoDockView(todos: model.projections.todos)
                    if let goal = model.projections.goal { GoalDockView(goal: goal) }
                    QueueDockView(queue: currentQueue)
                }.frame(maxWidth: 748).padding(.horizontal, 32)
                composerBody.padding(.horizontal, 24)
                SessionStatsLine().padding(.horizontal, 40).padding(.top, 4).padding(.bottom, 6)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { if model.isLoading { ProgressView().controlSize(.small).padding(.top, 9) } }
    }

    private var sessionQueue: [QueuedMessage] { model.queues[model.current?.id ?? ""] ?? [] }
    private var currentQueue: [QueuedMessage] { sessionQueue.filter { $0.placement == "queued" } }
    private var currentSteering: [QueuedMessage] { sessionQueue.filter { $0.placement == "steering" } }
    private var conversationRows: [ConversationDisplayRow] {
        if model.compactConversationDisplay { return conciseConversationRows(model.history) }
        return model.history.map(ConversationDisplayRow.message)
    }

    private func initializeScroll(_ proxy: ScrollViewProxy) {
        let sessionID = model.current?.id
        guard initializedScrollSessionID != sessionID else { return }
        initializedScrollSessionID = sessionID
        followsLatest = true
        scrollToLatest(proxy)
    }

    /// NSScrollView frame notifications can arrive inside SwiftUI's layout
    /// transaction. ScrollViewProxy traps if touched during that update, so
    /// every caller crosses one main-run-loop boundary before scrolling.
    private func scrollToLatest(_ proxy: ScrollViewProxy, animated: Bool = false) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("conversation-bottom", anchor: .bottom)
                }
            } else {
                proxy.scrollTo("conversation-bottom", anchor: .bottom)
            }
        }
    }

    private func isUserMessage(_ item: ConversationItem) -> Bool {
        if case .user = item.kind { return true }
        return false
    }

    @ViewBuilder private var composerBody: some View {
        if let interaction = model.interactions.first(where: { $0.sessionId == model.current?.id }) {
            InteractionComposer(interaction: interaction)
        } else if model.currentSubagentMode == "one-shot" || (model.currentSubagentMode == "continuable" && model.subagentParentAvailable[model.subagentParentId ?? ""] != true) {
            SubagentReadOnlyComposer(oneShot: model.currentSubagentMode == "one-shot")
        } else {
            ComposerViewSwiftUI(draft: $draft, focused: _focused,
                                permissionConfirmation: $permissionConfirmation,
                                permissionAcknowledged: $permissionAcknowledged,
                                optimisticPermission: $optimisticPermission,
                                openImage: openImage)
        }
    }
}

/// WebUI view ledger tabs stay immediately below the native titlebar. The
/// title/mode/export row itself lives in NSToolbar and is not duplicated here.
private struct ConversationViewTabs: View {
    @Binding var selectedTab: Int

    var body: some View {
        HStack(spacing: 36) {
            tab("对话", tag: 0)
            tab("轨迹", tag: 1)
            Spacer(minLength: 0)
        }
        .padding(.leading, 28).padding(.trailing, 28)
        .frame(height: 35, alignment: .bottom)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: Theme.separator)).frame(height: 1)
        }
    }

    private func tab(_ title: String, tag: Int) -> some View {
        Button { selectedTab = tag } label: {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selectedTab == tag ? Color(nsColor: Theme.business) : Color.secondary)
                .padding(.bottom, 11)
                .overlay(alignment: .bottom) {
                    if selectedTab == tag {
                        Capsule().fill(Color(nsColor: Theme.business)).frame(height: 2).offset(y: -1)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

private struct SubagentReadOnlyComposer: View {
    let oneShot: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(oneShot ? "一次性子智能体记录" : "此子智能体暂时只读").font(.headline)
            Text(oneShot ? "一次性任务不支持后续消息，可在这里查看完整执行记录。" : "父会话当前不在线，重新打开父会话后即可继续发送消息。")
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: 780, alignment: .leading).padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct HeroView: View {
    var body: some View {
        HStack(spacing: 10) {
            DeepSeekIcon(kind: .fish, size: 34)
            Text("探索未至之境").font(.system(size: 26, weight: .medium))
            Text("预览版").font(.system(size: 11, design: .monospaced).weight(.medium)).foregroundStyle(Color.accentColor)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
        }
        .frame(height: 34)
    }
}

/// Visible only in the blank/new-session Hero. It echoes the Workspace that
/// New Session already selected and lets the user connect another Workspace's
/// reusable blank session before the first message is sent.
private struct HeroWorkspaceSeat: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(model.workspaces) { workspace in
                    Button { model.createSession(workspace: workspace) } label: {
                        if workspace.id == model.currentWorkspace?.id {
                            Label(workspace.name, systemImage: "checkmark")
                        } else {
                            Text(workspace.name)
                        }
                    }
                }
                if !model.workspaces.isEmpty { Divider() }
                Button(action: addWorkspace) {
                    Label("添加工作区…", systemImage: "plus")
                }
            } label: {
                HStack(spacing: 4) {
                    DeepSeekIcon(kind: model.currentWorkspace == nil ? .folderClosed : .folderOpen, size: 16)
                    Text(model.currentWorkspace?.name ?? "选择工作区").lineLimit(1)
                    DeepSeekIcon(kind: .chevronDown, size: 12).foregroundStyle(.tertiary)
                }
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 8).frame(height: 28)
                .contentShape(Capsule())
            }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(model.isLoading)
            .help("选择或添加工作区")

            if !model.agentPresets.isEmpty {
                Menu {
                    ForEach(model.agentPresets.filter { $0.broken == nil }) { preset in
                        Button { model.selectPreset(preset) } label: {
                            if model.current?.preset == preset.id { Label(preset.displayName, systemImage: "checkmark") }
                            else { Text(preset.displayName) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 14))
                        Text(model.agentPresets.first(where: { $0.id == model.current?.preset })?.displayName ?? "标准模式")
                        DeepSeekIcon(kind: .chevronDown, size: 12).foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 8).frame(height: 28)
                    .contentShape(Capsule())
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 20)
    }

    private func addWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "添加工作区"
        if panel.runModal() == .OK, let url = panel.url {
            model.createWorkspace(path: url.path)
        }
    }
}

/// Exact grouped WebUI stats strip under the docked composer. Durable Host
/// projections are preferred; the trajectory fold is only a compatibility
/// fallback for older assemblies that do not publish `sessionStats`.
private struct SessionStatsLine: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if !line.isEmpty {
            Text(line)
                .font(.system(size: 12)).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: 748, minHeight: 20, alignment: .center)
                .help(line)
        }
    }

    private var line: String { groups.joined(separator: " | ") }

    private var groups: [String] {
        let stats = model.projections.sessionStats ?? fallbackStats
        var result: [String] = []
        if stats.steps > 0 {
            result.append("\(stats.turns) 轮 · \(stats.steps) 步")
            var durations: [String] = []
            if stats.llmMs > 0 { durations.append("LLM \(formatDuration(stats.llmMs))") }
            if stats.toolMs > 0 { durations.append("工具调用 \(formatDuration(stats.toolMs))") }
            if !durations.isEmpty { result.append(durations.joined(separator: " · ")) }
            var speeds: [String] = []
            if stats.ttftSteps > 0 { speeds.append("首 token 平均 \(formatDuration(stats.ttftMs / Double(stats.ttftSteps)))") }
            if stats.decodeMs > 0 {
                let tps = Double(stats.decodeTokens) / (stats.decodeMs / 1_000)
                speeds.append("\(formatTPS(tps)) tok/s")
            }
            if !speeds.isEmpty { result.append(speeds.joined(separator: " · ")) }
        }
        if let usage = model.projections.tokenUsage ?? model.current?.tokenUsage {
            let input = usage.uncachedInput + usage.cacheRead + usage.cacheWrite
            if input > 0 || usage.output > 0 {
                if input > 0 { result.append("缓存命中 \(Int((Double(usage.cacheRead) / Double(input) * 100).rounded()))%") }
                result.append("输入 \(formatTokens(input)) tok · 输出 \(formatTokens(usage.output)) tok")
            }
        }
        return result
    }

    private var fallbackStats: SessionStats {
        let cells = model.trajectory.flatMap(\.groups).flatMap(\.cells)
        let assistants = cells.filter { $0.kind == .assistant }
        let turns = Set(model.trajectory.filter { turn in
            turn.groups.flatMap(\.cells).contains { $0.kind == .assistant }
        }.map(\.turn)).count
        let llm = assistants.compactMap(\.duration).reduce(0, +) * 1_000
        let tools = cells.filter { $0.kind == .tool }.compactMap(\.duration).reduce(0, +) * 1_000
        return SessionStats(turns: turns, steps: assistants.count, llmMs: llm, toolMs: tools,
                            ttftMs: 0, ttftSteps: 0, decodeMs: 0, decodeTokens: 0)
    }

    private func formatDuration(_ milliseconds: Double) -> String {
        let seconds = milliseconds / 1_000
        if seconds < 60 { return "\((seconds * 10).rounded() / 10)s" }
        let whole = Int(seconds.rounded())
        return "\(whole / 60)m\(whole % 60)s"
    }

    private func formatTPS(_ value: Double) -> String {
        value >= 10 ? "\(Int(value.rounded()))" : "\((value * 10).rounded() / 10)"
    }

    private func formatTokens(_ value: Int) -> String {
        func scaled(_ value: Double) -> String {
            value >= 100 ? "\(Int(value.rounded()))" : "\((value * 10).rounded() / 10)"
        }
        if value < 1_000 { return "\(value)" }
        if value < 1_000_000 { return "\(scaled(Double(value) / 1_000))K" }
        return "\(scaled(Double(value) / 1_000_000))M"
    }
}

private struct EmptyState: View {
    let title: String; let subtitle: String; let symbol: String
    var body: some View {
        VStack(spacing: 10) { Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.tertiary); Text(title).font(.headline); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MessageRow: View {
    @EnvironmentObject private var model: AppModel
    let item: ConversationItem
    let openImage: (ImageLightboxItem) -> Void

    var body: some View {
        switch item.kind {
        case let .user(text, images):
            UserMessageContent(text: text, images: images, item: item, openImage: openImage)
        case let .images(refs, alignEnd):
            MessageImageGalleryNative(refs: refs, alignEnd: alignEnd, openImage: openImage)
        case let .assistant(text, streaming):
            HStack(alignment: .top) { NativeMarkdownView(source: text, streaming: streaming); Spacer(minLength: 20) }
                .contextMenu { Button("复制") { model.copy(text) } }
        case let .assistantActions(text, messageId):
            AssistantActionsContent(text: text, messageId: messageId, item: item)
        case let .reasoning(text, running): ReasoningRow(text: text, running: running)
        case let .tool(tool): ToolCallRow(tool: tool)
        case let .commandInput(text): GoalCommandInputRow(text: text)
        case let .command(name, summary, body, running, error):
            CommandEventRow(name: name, summary: summary, detail: body, running: running, error: error)
        case let .editedFiles(card): EditedFilesSummaryCardView(card: card).padding(.top, 8)
        case let .producedFiles(paths): ProducedFilesRow(paths: paths)
        case let .notice(text): Label(text, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red)
        }
    }

}

/// Codex-style concise activity disclosure. The header describes completed
/// and current actions; its disclosure body intentionally contains tool calls
/// only. Private reasoning text is neither summarized from raw text nor shown.
private struct CompactActivityRow: View {
    let group: CompactActivityGroup
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if group.disclosureTools.isEmpty {
                statusLine
            } else {
                Button { withAnimation(.easeInOut(duration: 0.14)) { expanded.toggle() } } label: {
                    statusLine.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? "已展开" : "已折叠")
            }

            if expanded, !group.disclosureTools.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(group.disclosureTools) { tool in ToolCallRow(tool: tool) }
                }
                .padding(.leading, 22)
                .padding(.top, 5)
                .padding(.bottom, 2)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 1).padding(.leading, 7)
                }
            }
        }
        .contextMenu {
            if !group.disclosureTools.isEmpty {
                Button(expanded ? "折叠工具调用" : "展开工具调用") {
                    withAnimation(.easeInOut(duration: 0.14)) { expanded.toggle() }
                }
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: 0) {
            DeepSeekIcon(kind: activityIcon, size: 14)
                .frame(width: 16, height: 16)
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .padding(.trailing, 6)
            Text(group.summary)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .lineLimit(1)
            if !group.disclosureTools.isEmpty {
                DeepSeekIcon(kind: .chevronRight, size: 12)
                    .frame(width: 14, height: 14)
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .padding(.leading, 7)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            Spacer(minLength: 0)
        }
        .frame(height: 24)
        .overlay { if group.running { SweepHighlight() } }
        .clipped()
    }

    private var activityIcon: DeepSeekIconKind {
        if group.reasoningRunning || group.tools.contains(where: { $0.variant == .code && $0.state == .running }) { return .think }
        if let active = group.disclosureTools.last(where: { $0.state == .running }) { return icon(for: active) }
        if group.reasoningRunning { return .think }
        return group.disclosureTools.last.map { icon(for: $0) } ?? .think
    }

    private func icon(for tool: ToolCall) -> DeepSeekIconKind {
        if tool.name == "todo_write" { return .checklist }
        if tool.name == "ask_user_question" { return .question }
        if tool.name == "skill" { return .skill }
        if tool.name.hasPrefix("cordis_") { return .code }
        switch tool.variant {
        case .search: return .search
        case .read: return .read
        case .bash: return .terminal
        case .write, .edit: return .edit
        case .code: return .code
        case .others: return .sparkle
        }
    }
}

/// WebUI `GoalCommandInputView`: `/goal` command input is a right-aligned
/// command-code bubble and deliberately owns no ordinary message actions.
private struct GoalCommandInputRow: View {
    let text: String
    var body: some View {
        HStack {
            Spacer(minLength: 80)
            Text(text)
                .font(.system(size: 14, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color(nsColor: Theme.bubble), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .frame(maxWidth: 525, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct UserMessageContent: View {
    @EnvironmentObject private var model: AppModel
    let text: String
    let images: [ImageAttachmentRef]
    let item: ConversationItem
    let openImage: (ImageLightboxItem) -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            VStack(alignment: .trailing, spacing: 8) {
                if !images.isEmpty {
                    MessageImageGalleryNative(refs: images, alignEnd: true, openImage: openImage)
                }
                if !text.isEmpty {
                    Text(text).font(.system(size: 16)).lineSpacing(3).textSelection(.enabled)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
            }
            .frame(maxWidth: 525, alignment: .trailing)
            MessageActionRow(text: text, time: item.time, clockAtStart: true,
                             messageId: nil, branchSeq: nil, timeVisible: hovering)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onHover { hovering = $0 }
        .contextMenu { Button("复制") { model.copy(text) } }
    }
}

private struct AssistantActionsContent: View {
    @EnvironmentObject private var model: AppModel
    let text: String
    let messageId: String?
    let item: ConversationItem
    @State private var noteOpen = false
    @State private var noteDraft = ""
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            MessageActionRow(text: text, time: item.time, clockAtStart: false,
                             messageId: messageId, branchSeq: item.seq, timeVisible: hovering,
                             metrics: item.metrics,
                             noteOpen: $noteOpen, noteDraft: $noteDraft)
                .padding(.leading, -6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("复制") { model.copy(text) }
            Button("从此消息分支") { model.branch(at: item.seq) }
                .disabled(!model.branchAvailable(at: item.seq))
            if let messageId {
                let feedback = model.feedback[messageId]
                Divider()
                Button(feedback?.rating == "positive" ? "取消标记" : "好的回答") {
                    model.rateMessage(messageId: messageId, rating: "positive")
                }
                Button(feedback?.rating == "negative" ? "取消标记" : "有问题的回答") {
                    model.rateMessage(messageId: messageId, rating: "negative")
                }
                if let feedback {
                    Button(feedback.note == nil ? "添加反馈说明…" : "编辑反馈说明…") {
                        noteDraft = feedback.note ?? ""; noteOpen = true
                    }
                }
            }
        }
    }

}

/// Native counterpart of WebUI `MessageIconActions` plus the injected
/// `MessageFeedbackActions`. The action order, hit targets and clock spacing
/// intentionally follow those components rather than macOS toolbar defaults.
private struct MessageActionRow: View {
    @EnvironmentObject private var model: AppModel
    let text: String
    let time: Date?
    let clockAtStart: Bool
    let messageId: String?
    let branchSeq: Int?
    let timeVisible: Bool
    let metrics: MessageMetrics?
    private let noteOpen: Binding<Bool>?
    private let noteDraft: Binding<String>?
    @State private var copied = false
    @State private var notePending = false

    init(text: String, time: Date?, clockAtStart: Bool, messageId: String?, branchSeq: Int?,
         timeVisible: Bool, metrics: MessageMetrics? = nil,
         noteOpen: Binding<Bool>? = nil, noteDraft: Binding<String>? = nil) {
        self.text = text
        self.time = time
        self.clockAtStart = clockAtStart
        self.messageId = messageId
        self.branchSeq = branchSeq
        self.timeVisible = timeVisible
        self.metrics = metrics
        self.noteOpen = noteOpen
        self.noteDraft = noteDraft
    }

    var body: some View {
        Group {
            if clockAtStart {
                actionContents.fixedSize(horizontal: true, vertical: false)
            } else {
                actionContents.frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(minHeight: 28)
    }

    private var actionContents: some View {
        HStack(alignment: .top, spacing: 10) {
            if clockAtStart { clock.padding(.trailing, 12) }
            DSMessageActionButton(kind: copied ? .check : .copy,
                                  help: copied ? "已复制" : "复制") { copy() }
            if let messageId {
                feedbackActions(messageId)
            }
            if let branchSeq {
                let available = model.branchAvailable(at: branchSeq)
                DSMessageActionButton(kind: .branch,
                                      help: available ? "从此消息分支" : "仅可从最新的已完成回答分支",
                                      available: available) {
                    if available { model.branch(at: branchSeq) }
                }
            }
            if !clockAtStart { Spacer(minLength: 12) }
            if !clockAtStart { clock.padding(.leading, 12) }
        }
    }

    @ViewBuilder
    private var clock: some View {
        if let time {
            Text(metricText(time))
                .font(.system(size: 14))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .lineLimit(1)
                .frame(height: 28)
                .opacity(timeVisible ? 1 : 0)
                .animation(.easeOut(duration: 0.08), value: timeVisible)
        }
    }

    private func metricText(_ time: Date) -> String {
        var facts = [messageClock(time)]
        if let value = metrics?.runMs { facts.append("用时 \(runDuration(value))") }
        if let value = metrics?.ttftMs { facts.append("首 token \(latency(value))秒") }
        if let value = metrics?.tokensPerSecond { facts.append("\(throughput(value)) tok/s") }
        return facts.joined(separator: " · ")
    }

    private func runDuration(_ milliseconds: Double) -> String {
        let total = max(0, Int(floor(milliseconds / 1_000)))
        return total >= 60 ? "\(total / 60)分\(String(format: "%02d", total % 60))秒" : "\(total)秒"
    }

    private func latency(_ milliseconds: Double) -> String {
        let seconds = max(0, milliseconds) / 1_000
        if seconds >= 10 { return "\(Int(seconds.rounded()))" }
        let rounded = (seconds * 10).rounded() / 10
        return rounded.rounded() == rounded ? "\(Int(rounded))" : String(format: "%.1f", rounded)
    }

    private func throughput(_ value: Double) -> String {
        let clamped = max(0, value)
        return clamped >= 10 ? "\(Int(clamped.rounded()))" : String(format: "%.1f", (clamped * 10).rounded() / 10)
    }

    @ViewBuilder
    private func feedbackActions(_ messageId: String) -> some View {
        let feedback = model.feedback[messageId]
        DSMessageActionButton(kind: .like, help: feedback?.rating == "positive" ? "取消标记" : "好的回答",
                              active: feedback?.rating == "positive", available: !notePending) {
            model.rateMessage(messageId: messageId, rating: "positive")
            noteOpen?.wrappedValue = false
        }
        DSMessageActionButton(kind: .dislike, help: feedback?.rating == "negative" ? "取消标记" : "有问题的回答",
                              active: feedback?.rating == "negative", available: !notePending) {
            model.rateMessage(messageId: messageId, rating: "negative")
            noteOpen?.wrappedValue = false
        }
        if let feedback, let noteOpen, let noteDraft {
            if noteOpen.wrappedValue {
                HStack(alignment: .top, spacing: 6) {
                    TextField("这条回答哪里好，或哪里有问题？（可选）", text: noteDraft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .lineLimit(2...4)
                        .frame(width: 260)
                    Button("保存") { saveNote(messageId) }
                        .buttonStyle(MessageNoteButtonStyle(primary: true))
                        .disabled(notePending)
                    Button("取消") { noteOpen.wrappedValue = false }
                        .buttonStyle(MessageNoteButtonStyle(primary: false))
                }
            } else {
                Button {
                    noteDraft.wrappedValue = feedback.note ?? ""
                    noteOpen.wrappedValue = true
                } label: {
                    Text(feedback.note ?? "补充说明")
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: 220)
                }
                .buttonStyle(MessageNoteOpenButtonStyle())
                .help(feedback.note == nil ? "补充说明" : "编辑反馈说明")
            }
        }
    }

    private func copy() {
        guard !copied else { return }
        model.copy(text)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { copied = false }
    }

    private func saveNote(_ messageId: String) {
        guard let noteDraft, let noteOpen else { return }
        notePending = true
        model.saveFeedbackNote(messageId: messageId, note: noteDraft.wrappedValue) { success in
            notePending = false
            if success { noteOpen.wrappedValue = false }
        }
    }
}

private struct CommandEventRow: View {
    let name: String
    let summary: String
    let detail: String?
    let running: Bool
    let error: Bool
    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if detail != nil { withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() } }
            } label: {
                HStack(spacing: 8) {
                    Group {
                        if error { LifecycleStateDot(state: .error) }
                        else if running { LifecycleStateDot(state: .ongoing) }
                        else if hovering && detail != nil {
                            DeepSeekIcon(kind: .chevronDown, size: 14)
                                .rotationEffect(.degrees(expanded ? 180 : 0))
                        } else { DeepSeekIcon(kind: .terminal, size: 14) }
                    }.frame(width: 14, height: 20)
                    Text("/\(name)").font(.system(size: 14, design: .monospaced)).foregroundStyle(error ? Color.red : Color.secondary)
                    Text("·").foregroundStyle(.quaternary)
                    Text(summary.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 14)).foregroundStyle(error ? Color.red : Color(nsColor: .tertiaryLabelColor))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).onHover { hovering = $0 }
            if expanded, let detail {
                ScrollView(.horizontal) {
                    Text(detail).font(.system(size: 12.5, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
                .padding(.leading, 22)
            }
        }
        .contextMenu {
            Button("复制结果") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(detail ?? summary, forType: .string) }
        }
    }
}

private struct DSMessageActionButton: View {
    let kind: DeepSeekIconKind
    let help: String
    var active = false
    var available = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button { if available { action() } } label: {
            DeepSeekIcon(kind: kind, size: 16)
                .frame(width: 28, height: 28)
                .foregroundStyle(active ? Color.primary : Color(nsColor: .tertiaryLabelColor))
                .background(hovering && available ? Color.primary.opacity(0.07) : Color.clear,
                            in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(available ? 1 : 0.4)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct MessageNoteOpenButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(Color(nsColor: configuration.isPressed ? .secondaryLabelColor : .tertiaryLabelColor))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(configuration.isPressed ? Color.primary.opacity(0.07) : Color.clear,
                        in: Capsule())
    }
}

private struct MessageNoteButtonStyle: ButtonStyle {
    let primary: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .foregroundStyle(primary ? Color.white : Color(nsColor: .tertiaryLabelColor))
            .background(primary ? Color.accentColor.opacity(configuration.isPressed ? 0.78 : 1)
                                : Color.primary.opacity(configuration.isPressed ? 0.07 : 0),
                        in: Capsule())
    }
}

private struct MessageImageGalleryNative: View {
    let refs: [ImageAttachmentRef]
    let alignEnd: Bool
    let openImage: (ImageLightboxItem) -> Void

    var body: some View {
        HStack(spacing: 10) {
            if alignEnd { Spacer(minLength: 80) }
            WrappingImageLayout(spacing: 10, alignment: alignEnd ? .trailing : .leading) {
                ForEach(refs) { ref in
                    MessageImageNative(ref: ref, tile: refs.count > 1, openImage: openImage)
                }
            }
            .frame(maxWidth: alignEnd ? 525 : .infinity, alignment: alignEnd ? .trailing : .leading)
            if !alignEnd { Spacer(minLength: 20) }
        }
    }
}

/// Native equivalent of WebUI `.gallery { display:flex; flex-wrap:wrap; gap:10px }`.
private struct WrappingImageLayout: Layout {
    let spacing: CGFloat
    let alignment: HorizontalAlignment

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let available = proposal.width ?? .greatestFiniteMagnitude
        let rows = rows(for: subviews, availableWidth: available)
        let contentWidth = rows.map(\.width).max() ?? 0
        let width = proposal.width.map { min($0, contentWidth) } ?? contentWidth
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(for: subviews, availableWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = alignment == .trailing ? bounds.maxX - row.width : bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(for subviews: Subviews, availableWidth: CGFloat) -> [Row] {
        guard !subviews.isEmpty else { return [] }
        var result: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let proposedWidth = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, proposedWidth > availableWidth {
                result.append(row)
                row = Row(indices: [index], width: size.width, height: size.height)
            } else {
                row.indices.append(index)
                row.width = proposedWidth
                row.height = max(row.height, size.height)
            }
        }
        if !row.indices.isEmpty { result.append(row) }
        return result
    }
}

struct ImageLightboxItem: Identifiable {
    let id = UUID()
    let image: NSImage
    let label: String
    let restoreFocus: () -> Void
}

private struct MessageImageNative: View {
    @EnvironmentObject private var model: AppModel
    let ref: ImageAttachmentRef
    let tile: Bool
    let openImage: (ImageLightboxItem) -> Void
    @State private var data: Data?
    @State private var attempted = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: activate) {
            Group {
                if let data, let image = NSImage(data: data) {
                    thumbnail(image)
                } else if attempted {
                    Text("加载失败\n点击重试")
                        .font(.system(size: 12)).multilineTextAlignment(.center).foregroundStyle(.tertiary)
                        .frame(width: tile ? 64 : 140, height: tile ? 64 : 72)
                        .background(Color.red.opacity(0.07))
                } else {
                    ProgressView().controlSize(.small)
                        .frame(width: tile ? 64 : 96, height: tile ? 64 : 96)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.primary.opacity(0.10)))
        }
        .buttonStyle(.plain)
        .focused($focused)
        .help("预览原图")
        .accessibilityLabel("打开图片：\(ref.name ?? "图片")")
        .task { if data == nil { model.loadImage(ref) { data = $0; attempted = true } } }
    }

    private func activate() {
        guard let data, let image = NSImage(data: data) else {
            attempted = false
            model.loadImage(ref) { self.data = $0; attempted = true }
            return
        }
        openImage(ImageLightboxItem(image: image, label: ref.name ?? "图片", restoreFocus: { focused = true }))
    }

    @ViewBuilder private func thumbnail(_ image: NSImage) -> some View {
        if tile {
            Image(nsImage: image).resizable().scaledToFill().frame(width: 64, height: 64).clipped()
        } else {
            let fit = MessageImageFit.single(width: ref.width, height: ref.height)
            Image(nsImage: image).resizable().scaledToFill()
                .frame(width: fit.width, height: fit.height, alignment: alignment(for: fit.crop)).clipped()
        }
    }

    private func alignment(for crop: MessageImageFit.Crop) -> Alignment {
        switch crop { case .center: return .center; case .top: return .top; case .leading: return .leading }
    }
}

private struct NativeImageLightbox: View {
    @Environment(\.colorScheme) private var colorScheme
    let item: ImageLightboxItem
    let close: () -> Void
    @FocusState private var closeFocused: Bool

    var body: some View {
        ZStack {
            NativeLightboxMask().ignoresSafeArea().contentShape(Rectangle()).onTapGesture(perform: close)
            Image(nsImage: item.image)
                .resizable().scaledToFit()
                .frame(maxWidth: 1600, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .background(inputColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 16, y: 12)
                .shadow(color: .black.opacity(0.04), radius: 4)
                .padding(40)
                .accessibilityLabel(item.label)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: close) { DeepSeekIcon(kind: .close, size: 16) }
                .buttonStyle(.plain).frame(width: 36, height: 36)
                .background(inputColor, in: Circle())
                .overlay(Circle().stroke(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.10)))
                .focused($closeFocused).accessibilityLabel("关闭图片预览")
                .padding(20)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("图片预览")
        .onAppear { DispatchQueue.main.async { closeFocused = true } }
        .onExitCommand(perform: close)
    }

    private var inputColor: Color {
        colorScheme == .dark
            ? Color(red: 44 / 255, green: 44 / 255, blue: 46 / 255)
            : .white
    }
}

private struct NativeLightboxMask: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(dark ? 0.50 : 0.24).cgColor
    }
}

private struct NativeDropOverlay: View {
    let disabled: Bool
    let description: String?

    var body: some View {
        ZStack {
            NativeDropMask().ignoresSafeArea()
            VStack(spacing: 0) {
                Group {
                    if disabled { UploadDisabledIllustration() }
                    else { UploadIllustration() }
                }
                .frame(width: 115, height: 84)
                Text(disabled ? "当前无法添加图片" : "图片拖动到此处即可添加")
                    .font(.system(size: 20)).padding(.top, 16)
                if !disabled, let description {
                    Text(description).font(.system(size: 14)).foregroundStyle(.tertiary).padding(.top, 16)
                }
            }
            .padding(.horizontal, 40).offset(y: -16)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(disabled ? "当前无法添加图片" : (["图片拖动到此处即可添加", description].compactMap { $0 }.joined(separator: "，")))
    }
}

/// Exact disabled-state paths and colors from WebUI `DropOverlay.tsx`.
private struct UploadDisabledIllustration: View {
    var body: some View {
        Canvas { context, _ in
            let grey = Color(red: 151 / 255, green: 157 / 255, blue: 166 / 255)
            let orange = Color(red: 245 / 255, green: 158 / 255, blue: 11 / 255)
            context.fill(DeepSeekIcon.svgPath(Self.leftCard), with: .color(grey))
            context.fill(DeepSeekIcon.svgPath(Self.star), with: .color(.white))
            context.fill(DeepSeekIcon.svgPath(Self.rightCard), with: .color(grey))
            for line in Self.noteLines {
                context.stroke(DeepSeekIcon.svgPath(line), with: .color(.white), lineWidth: 3)
            }
            context.fill(DeepSeekIcon.svgPath(Self.centerCard), with: .color(orange))
            context.stroke(DeepSeekIcon.svgPath(Self.badge), with: .color(.white), lineWidth: 3.5)
            context.stroke(DeepSeekIcon.svgPath(Self.slash), with: .color(.white),
                           style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
        }
        .accessibilityHidden(true)
    }

    private static let leftCard = "M29.6829 4.63701L11.0677 12.4368C4.95519 14.998 2.07624 22.0294 4.6374 28.1419L12.2285 46.259C14.7896 52.3715 21.8211 55.2505 27.9336 52.6893L46.5488 44.8895C52.6613 42.3283 55.5403 35.2969 52.9791 29.1844L45.388 11.0673C42.8269 4.9548 35.7954 2.07585 29.6829 4.63701Z"
    private static let star = "M30.4915 28.1375L40.8863 33.4569L37.223 34.9529L29.53 31.0165L26.7917 39.2128L23.1283 40.7088L26.8285 29.6344L16.8965 24.5522L20.5599 23.0562L27.79 26.7555L30.3637 19.0526L34.0271 17.5566L30.4915 28.1375Z"
    private static let rightCard = "M107.496 19.2285L81.0381 10.9357C76.8221 9.61423 72.333 11.9607 71.0116 16.1768L60.6844 49.1246C59.363 53.3406 61.7095 57.8297 65.9255 59.1511L92.383 67.4439C96.599 68.7654 101.088 66.4189 102.41 62.2029L112.737 29.255C114.058 25.039 111.712 20.55 107.496 19.2285Z"
    private static let noteLines = [
        "M77.5088 26.3047L101.057 33.7967",
        "M72.2646 42.7871L86.3938 47.2823",
        "M74.8867 34.5469L98.4353 42.0388",
    ]
    private static let centerCard = "M66.5798 30.1418L41.481 30.2006C33.5281 30.2193 27.0962 36.6815 27.1148 44.6343L27.172 69.0742C27.1907 77.0271 33.6529 83.459 41.6057 83.4404L66.7045 83.3816C74.6574 83.363 81.0894 76.9008 81.0707 68.9479L81.0135 44.5081C80.9949 36.5552 74.5327 30.1232 66.5798 30.1418Z"
    private static let badge = "M54 70.7969C61.732 70.7969 68 64.5289 68 56.7969C68 49.0649 61.732 42.7969 54 42.7969C46.268 42.7969 40 49.0649 40 56.7969C40 64.5289 46.268 70.7969 54 70.7969Z"
    private static let slash = "M44 46.7969L64 66.7969"
}

private struct NativeDropMask: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .withinWindow
        view.state = .active
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        view.layer?.backgroundColor = dark
            ? NSColor(srgbRed: 39 / 255, green: 39 / 255, blue: 48 / 255, alpha: 0.70).cgColor
            : NSColor.white.withAlphaComponent(0.70).cgColor
    }
}

/// Exact accepted-state illustration geometry from WebUI `DropOverlay.tsx`.
private struct UploadIllustration: View {
    var body: some View {
        Canvas { context, _ in
            let cyan = Color(red: 156 / 255, green: 229 / 255, blue: 237 / 255)
            let blue = Color(red: 103 / 255, green: 158 / 255, blue: 254 / 255)
            let deepBlue = Color(red: 57 / 255, green: 100 / 255, blue: 254 / 255)
            context.fill(rotatedRoundRect(origin: .zero, size: CGSize(width: 44.1832, height: 43.6431), radius: 12,
                                          angle: -22.7338, pivot: CGPoint(x: 0, y: 17.0742)), with: .color(cyan))
            context.fill(rotatedRoundRect(origin: CGPoint(x: 73.4043, y: 8.54297), size: CGSize(width: 43.7267, height: 50.5284),
                                          radius: 8, angle: 17.403, pivot: CGPoint(x: 73.4043, y: 8.54297)), with: .color(blue))
            context.fill(DeepSeekIcon.svgPath(Self.star), with: .color(.white))
            for line in Self.noteLines { context.stroke(DeepSeekIcon.svgPath(line), with: .color(.white), lineWidth: 3) }
            context.fill(rotatedRoundRect(origin: CGPoint(x: 31.583, y: 38.6641), size: CGSize(width: 44.9157, height: 44.3666),
                                          radius: 12, angle: -0.134233, pivot: CGPoint(x: 31.583, y: 38.6641)), with: .color(deepBlue))
            context.stroke(DeepSeekIcon.svgPath(Self.mountain), with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            context.fill(Path(ellipseIn: CGRect(x: 56.22776, y: 47.85906, width: 8.77588, height: 8.77588)), with: .color(.white))
        }
        .accessibilityHidden(true)
    }

    private func rotatedRoundRect(origin: CGPoint, size: CGSize, radius: CGFloat, angle: CGFloat, pivot: CGPoint) -> Path {
        let base = Path(roundedRect: CGRect(origin: origin, size: size), cornerRadius: radius)
        var transform = CGAffineTransform(translationX: pivot.x, y: pivot.y)
        transform = transform.rotated(by: angle * .pi / 180)
        transform = transform.translatedBy(x: -pivot.x, y: -pivot.y)
        return base.applying(transform)
    }

    private static let star = "M30.4917 28.1369L40.8865 33.4564L37.2232 34.9524L29.5302 31.0159L26.7919 39.2122L23.1285 40.7082L26.8287 29.6338L16.8967 24.5516L20.5601 23.0556L27.7902 26.7549L30.3639 19.052L34.0273 17.556L30.4917 28.1369Z"
    private static let noteLines = [
        "M77.5088 26.3047L101.057 33.7966",
        "M72.2646 42.7871L86.3938 47.2823",
        "M74.8867 34.5469L98.4353 42.0388",
    ]
    private static let mountain = "M38.9521 73.0337C39.6129 71.7086 41.7113 66.0937 43.5113 61.1663C44.1607 59.3885 46.7484 59.3923 47.4591 61.1465C48.9728 64.8828 50.7969 68.6922 51.9988 69.1925C54.2946 70.1482 57.9854 59.3573 68.0064 70.1801"
}

private struct AttachmentRailNative: View {
    @EnvironmentObject private var model: AppModel
    let images: [DraftImage]
    let files: [DraftTextFile]
    let openImage: (ImageLightboxItem) -> Void
    @FocusState private var focusedImageID: UUID?
    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                ForEach(images) { image in
                    ZStack(alignment: .topTrailing) {
                            Button {
                                guard let nsImage = NSImage(data: image.data) else { return }
                                openImage(ImageLightboxItem(image: nsImage, label: image.name,
                                    restoreFocus: { focusedImageID = image.id }))
                            } label: {
                                if let nsImage = NSImage(data: image.data) {
                                    Image(nsImage: nsImage).resizable().scaledToFill().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 16))
                                }
                            }.buttonStyle(.plain).focused($focusedImageID, equals: image.id).help("预览原图")
                            Button { model.removeImage(image) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.55)) }
                                .buttonStyle(.plain).padding(4)
                        }.id(image.id).frame(width: 64, height: 64).background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                }
                ForEach(files) { file in
                    ZStack(alignment: .topTrailing) {
                        VStack(spacing: 4) {
                            Image(systemName: "doc.text").font(.system(size: 20)).foregroundStyle(.secondary)
                            Text(file.name).font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
                            Text(file.byteCountText).font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                        .padding(6).frame(width: 76, height: 64)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                        Button { model.removeFile(file) } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.55))
                        }.buttonStyle(.plain).padding(4)
                    }.id(file.id)
                }
                }.padding(.horizontal, 2)
            }.frame(height: 64)
            .overlay(alignment: .leading) {
                if images.count > 4 { Button { if let first = images.first { withAnimation { reader.scrollTo(first.id, anchor: .leading) } } } label: { Image(systemName: "chevron.left.circle.fill") }.buttonStyle(.plain).padding(.leading, 2) }
            }
            .overlay(alignment: .trailing) {
                if images.count > 4 { Button { if let last = images.last { withAnimation { reader.scrollTo(last.id, anchor: .trailing) } } } label: { Image(systemName: "chevron.right.circle.fill") }.buttonStyle(.plain).padding(.trailing, 2) }
            }
        }
    }
}

private struct ReasoningRow: View {
    let text: String
    let running: Bool
    @State private var expanded = false
    @State private var hovering = false

    private var summary: String {
        if running {
            let visible = text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            return visible.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? visible
        }
        return text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.14)) { expanded.toggle() } } label: {
                HStack(spacing: 0) {
                    Group { if expanded || hovering { DeepSeekIcon(kind: .chevronDown, size: 14) } else { DeepSeekIcon(kind: .think, size: 14) } }
                        .frame(width: 16, height: 16).foregroundStyle(.tertiary).padding(.trailing, 6)
                    Text("Think").foregroundStyle(.secondary)
                    if !expanded {
                        Circle().fill(Color(nsColor: .quaternaryLabelColor)).frame(width: 2, height: 2).padding(.horizontal, 8)
                        Text(summary).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.font(.system(size: 14)).frame(height: 24).contentShape(Rectangle())
                    .overlay { if running { SweepHighlight() } }.clipped()
            }.buttonStyle(.plain)
            if expanded {
                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
                    .lineSpacing(7)
                    .textSelection(.enabled)
                    .padding(.leading, 22)
                    .padding(.vertical, 4)
            }
        }
        .onHover { hovering = $0 }
        .contextMenu { Button("复制思考内容") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }; Button(expanded ? "折叠" : "展开") { expanded.toggle() } }
    }
}

private struct ToolCallRow: View {
    @EnvironmentObject private var model: AppModel
    let tool: ToolCall
    @State private var expanded = false
    @State private var hovering = false
    @State private var bodyHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if tool.cordis != nil {
                CordisToolRow(tool: tool, expanded: $expanded)
            } else {
                ToolStatusLine(
                    tool: tool,
                    expanded: tool.expandable && expanded,
                    hovering: tool.expandable && hovering,
                    onToggle: tool.expandable ? toggleExpanded : nil
                )
                .onHover { hovering = $0 }
                if expanded && tool.expandable { ToolExpandedBody(tool: tool, revealInspect: hovering || bodyHovering).padding(.leading, 4).padding(.top, 4).onHover { bodyHovering = $0 } }
            }
            if !tool.subCalls.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tool.subCalls) { child in ToolCallRow(tool: child) }
                }.padding(.leading, 8).overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 1) }
                    .padding(.leading, 22).padding(.top, 4).padding(.bottom, 2)
            }
        }
        .contextMenu {
            if tool.expandable { Button(expanded ? "折叠" : "展开") { toggleExpanded() }; Divider() }
            Button("复制输入") { model.copy(tool.rawInput ?? tool.arguments) }
            Button("复制输出") { model.copy(tool.output ?? "") }.disabled(tool.output == nil)
            Button("Inspect") { model.showTool(tool) }
        }
    }

    private func toggleExpanded() {
        withAnimation(.easeInOut(duration: 0.14)) { expanded.toggle() }
    }
}

private struct ToolStatusLine: View {
    @EnvironmentObject private var model: AppModel
    let tool: ToolCall
    let expanded: Bool
    let hovering: Bool
    let onToggle: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            if showsFileLink {
                toggleArea { leadingAndTitle(includeSeparator: true) }
                fileLink
                if let suffix = tool.errorSummary == nil ? tool.summarySuffix : nil {
                    Text(suffix).foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                        .padding(.leading, 6).fixedSize()
                }
                Spacer(minLength: 0)
                    .contentShape(Rectangle())
                    .onTapGesture { onToggle?() }
                    .accessibilityHidden(true)
            } else {
                toggleArea {
                    HStack(spacing: 0) {
                        leadingAndTitle(includeSeparator: !rowSummary.isEmpty)
                        if !rowSummary.isEmpty {
                            Text(rowSummary)
                                .foregroundStyle(tool.errorSummary == nil ? Color(nsColor: .tertiaryLabelColor) : Color(nsColor: Theme.stateError))
                                .lineLimit(1)
                        }
                        if let suffix = tool.errorSummary == nil ? tool.summarySuffix : nil {
                            Text(suffix).foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                                .padding(.leading, 4).fixedSize()
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .font(.system(size: 14)).frame(height: 24)
        .overlay { if tool.state == .running { SweepHighlight() } }.clipped()
    }

    @ViewBuilder
    private func toggleArea<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if let onToggle {
            Button(action: onToggle) { content().contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? "已展开" : "已折叠")
        } else {
            content()
        }
    }

    private func leadingAndTitle(includeSeparator: Bool) -> some View {
        HStack(spacing: 0) {
            Group {
                if expanded || hovering { DeepSeekIcon(kind: .chevronDown, size: 14) }
                else if tool.state == .error { LifecycleStateDot(state: .error) }
                else if tool.state == .stopped { LifecycleStateDot(state: .warning) }
                else { DeepSeekIcon(kind: icon, size: 14) }
            }.frame(width: 16, height: 16).foregroundStyle(tool.state == .error ? Color(nsColor: Theme.stateError) : Color(nsColor: .tertiaryLabelColor)).padding(.trailing, 6)
            Text(rowTitle).foregroundStyle(Color(nsColor: .secondaryLabelColor))
            if includeSeparator {
                Circle().fill(Color(nsColor: .quaternaryLabelColor)).frame(width: 2, height: 2).padding(.horizontal, 8)
            }
        }
    }

    private var fileLink: some View {
        Button { if let path = tool.filePath { model.openToolPath(path) } } label: {
            Text(rowSummary)
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .lineLimit(1)
                .underline(color: Color(nsColor: .quaternaryLabelColor))
        }
        .buttonStyle(.plain)
        .help(tool.filePath.map { "打开 \($0)" } ?? "")
    }

    private var rowSummary: String {
        if let failure = tool.errorSummary { return failure }
        guard let path = tool.filePath, path == tool.summary, let cwd = model.current?.cwd else { return tool.summary }
        let root = URL(fileURLWithPath: cwd).standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let absolute = path.hasPrefix("/")
            ? URL(fileURLWithPath: path).standardized.path
            : URL(fileURLWithPath: cwd).appendingPathComponent(path).standardized.path
        let rootPrefix = "/" + root + "/"
        return absolute.hasPrefix(rootPrefix) ? String(absolute.dropFirst(rootPrefix.count)) : tool.summary
    }
    private var rowTitle: String {
        switch (tool.variant, tool.state) {
        case (.edit, .running): return "正在编辑"
        case (.edit, .ok): return "已编辑"
        case (.write, .running): return "正在写入"
        case (.write, .ok): return "已写入"
        default: return tool.displayTitle
        }
    }
    private var showsFileLink: Bool { tool.filePath != nil && tool.errorSummary == nil && !rowSummary.isEmpty }

    private var icon: DeepSeekIconKind {
        if tool.name == "todo_write" { return .checklist }
        if tool.name == "ask_user_question" { return .question }
        if tool.name == "skill" { return .skill }
        if tool.name.hasPrefix("cordis_") { return .code }
        switch tool.variant { case .search: return .search; case .read: return .read; case .bash: return .terminal
        case .write, .edit: return .edit; case .code: return .code; case .others: return .sparkle }
    }
}

private struct SweepHighlight: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if !reduceMotion {
            TimelineView(.animation) { timeline in
                GeometryReader { proxy in
                    let cycle = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.6) / 2.6
                    let moving = min(1, cycle / 0.9)
                    let eased = 1 - pow(1 - moving, 3)
                    LinearGradient(colors: [.clear, Color(nsColor: .windowBackgroundColor).opacity(0.60), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 300).offset(x: -300 + (proxy.size.width + 300) * eased)
                }
            }.allowsHitTesting(false)
        }
    }
}

private struct ToolExpandedBody: View {
    @EnvironmentObject private var model: AppModel
    let tool: ToolCall
    let revealInspect: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if tool.name == "skill", let output = tool.output {
                    SkillInstructionsCard(output: output, error: tool.state == .error)
                } else if let presentation = tool.presentation {
                    // Host card primitives already own their 12px surface;
                    // wrapping again produces the double-card seen in the old native build.
                    ToolPresentationView(presentation: presentation)
                } else {
                    GenericToolBody(tool: tool)
                }
            }
            .contextMenu { Button("复制输入") { model.copy(tool.rawInput ?? tool.arguments) }; Button("复制输出") { model.copy(tool.output ?? "") }.disabled(tool.output == nil) }
            HStack {
                Button { model.showTool(tool) } label: {
                    HStack(spacing: 4) { DeepSeekIcon(kind: .inspect, size: 12); Text("Inspect") }
                        .font(.system(size: 11)).foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
                        .overlay(Capsule().stroke(Color.primary.opacity(0.10)))
                }
                    .buttonStyle(.plain)
                    .opacity(revealInspect ? 1 : 0)
                    .animation(.easeOut(duration: 0.10), value: revealInspect)
                Spacer()
            }.frame(height: 22).padding(.top, 4).padding(.leading, 4).padding(.bottom, 2)
        }
    }
}

private struct SkillInstructionsCard: View {
    let output: String
    let error: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("说明")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.44)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
            Divider().opacity(0.55)
            ScrollView(.vertical) {
                Text(output)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(error ? Color.red : Color(nsColor: .secondaryLabelColor))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxHeight: 260)
        .toolBodySurface()
        .padding(.leading, 4)
        .padding(.vertical, 4)
    }
}

private struct GenericToolBody: View {
    @EnvironmentObject private var model: AppModel
    let tool: ToolCall

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if tool.variant == .code, let code = tool.inputText {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text("typescript").foregroundStyle(.secondary)
                        Spacer()
                        Button("复制") { model.copy(code) }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14).frame(height: 36)
                    ScrollView([.horizontal, .vertical]) {
                        Text(NativeSyntaxHighlighter.attributed(code, language: "typescript"))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }.frame(maxHeight: 260)
                }
                .toolBodySurface()
                if let output = tool.output {
                    ToolIOCard(input: nil, output: output, error: tool.state == .error)
                }
            }
            if tool.variant != .code {
                let input = tool.filePath == nil ? tool.inputText : nil
                if input != nil || tool.output != nil {
                    ToolIOCard(input: input, output: tool.output, error: tool.state == .error)
                }
            }
        }
        .font(.system(size: 13, design: .monospaced))
    }
}

private struct ToolIOCard: View {
    let input: String?
    let output: String?
    let error: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let input { LabeledToolSection(label: "IN", text: input) }
            if input != nil && output != nil { Divider().opacity(0.6) }
            if let output { LabeledToolSection(label: "OUT", text: output, error: error) }
        }.toolBodySurface()
    }
}

private extension View {
    func toolBodySurface() -> some View {
        background(Color(nsColor: .textBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.14)))
    }
}

private struct LabeledToolSection: View {
    let label: String
    let text: String
    var error = false
    var body: some View {
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 14) {
                Text(label).foregroundStyle(.tertiary).frame(width: 26, alignment: .leading)
                Text(text).foregroundStyle(error ? Color.red : Color.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 16).padding(.vertical, 12)
        }.frame(maxHeight: 150)
    }
}

/// AppKit-backed multiline composer: it grows with its content up to the
/// WebUI-sized cap, then keeps the caret and earlier lines reachable through
/// the native overlay scroller. Return submits; Shift-Return inserts a line.
private final class ComposerNativeTextView: NSTextView {
    var placeholder = "给智能体发送消息"

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), !placeholder.isEmpty else { return }
        let padding = textContainer?.lineFragmentPadding ?? 5
        let origin = NSPoint(x: textContainerInset.width + padding, y: textContainerInset.height)
        placeholder.draw(at: origin, withAttributes: [
            .font: font ?? NSFont.systemFont(ofSize: 16),
            .foregroundColor: NSColor.placeholderTextColor,
        ])
    }
}

private struct ComposerTextInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let focused: FocusState<Bool>.Binding
    let onSubmit: () -> Void

    private let minimumHeight: CGFloat = 44
    private let maximumHeight: CGFloat = 176

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .automatic

        let textView = ComposerNativeTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 16)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: minimumHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        scrollView.documentView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.textView = textView
        DispatchQueue.main.async { context.coordinator.resize() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        // Never replace NSTextView's storage while an input method owns marked
        // text. Doing so commits only part of the pinyin buffer and leaves the
        // candidate window drawing over a stale SwiftUI placeholder.
        if !textView.hasMarkedText(), !context.coordinator.hasPendingNativeChange,
           textView.string != text {
            let selection = textView.selectedRange()
            context.coordinator.applyingExternalText = true
            textView.string = text
            context.coordinator.applyingExternalText = false
            textView.setSelectedRange(NSRange(location: min(selection.location, textView.string.utf16.count), length: 0))
            textView.needsDisplay = true
            DispatchQueue.main.async { context.coordinator.resize() }
        }
        if focused.wrappedValue, scrollView.window?.firstResponder !== textView {
            DispatchQueue.main.async { scrollView.window?.makeFirstResponder(textView) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextInput
        weak var scrollView: NSScrollView?
        weak var textView: NSTextView?
        var applyingExternalText = false
        private var pendingNativeText: String?
        private var nativeSyncScheduled = false

        var hasPendingNativeChange: Bool { pendingNativeText != nil }

        init(parent: ComposerTextInput) { self.parent = parent }

        func textDidBeginEditing(_ notification: Notification) {
            parent.focused.wrappedValue = true
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.focused.wrappedValue = false
            flushNativeText()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView, !applyingExternalText else { return }
            pendingNativeText = textView.string
            textView.needsDisplay = true
            resize()
            guard !nativeSyncScheduled else { return }
            nativeSyncScheduled = true
            // Cross the AppKit edit callback boundary before publishing into
            // SwiftUI. The pending marker prevents updateNSView from treating
            // the temporarily stale binding as an external replacement.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.nativeSyncScheduled = false
                self.flushNativeText()
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            // Return belongs to the active Chinese/Japanese/Korean input
            // method first; intercepting it here truncates the marked text and
            // submits the incomplete draft.
            guard !textView.hasMarkedText() else { return false }
            if NSEvent.modifierFlags.contains(.shift) {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.onSubmit()
            }
            return true
        }

        private func flushNativeText() {
            guard let value = pendingNativeText else { return }
            pendingNativeText = nil
            if parent.text != value { parent.text = value }
        }

        func resize() {
            guard let textView, let scrollView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            let width = max(1, scrollView.contentSize.width)
            if abs(textView.frame.width - width) > 0.5 {
                textView.frame.size.width = width
                textContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            }
            layoutManager.ensureLayout(for: textContainer)
            let required = ceil(layoutManager.usedRect(for: textContainer).height + textView.textContainerInset.height * 2)
            let next = min(parent.maximumHeight, max(parent.minimumHeight, required))
            scrollView.hasVerticalScroller = required > parent.maximumHeight
            if abs(parent.height - next) > 0.5 {
                DispatchQueue.main.async { [weak self] in self?.parent.height = next }
            }
            if required > parent.maximumHeight {
                textView.scrollRangeToVisible(textView.selectedRange())
            }
        }
    }
}

private struct ComposerViewSwiftUI: View {
    @EnvironmentObject private var model: AppModel
    @Binding var draft: String
    @FocusState var focused: Bool
    @Binding var permissionConfirmation: String?
    @Binding var permissionAcknowledged: Bool
    @Binding var optimisticPermission: String?
    let openImage: (ImageLightboxItem) -> Void
    @State private var commandMenuOpen = false
    @State private var modelMenuOpen = false
    @State private var permissionMenuOpen = false
    @State private var editorHeight: CGFloat = 44

    var body: some View {
        VStack(spacing: 12) {
            if !model.draftImages.isEmpty || !model.draftFiles.isEmpty {
                AttachmentRailNative(images: model.draftImages, files: model.draftFiles, openImage: openImage)
                    .padding(.horizontal, 12).padding(.top, 4)
            }
            ComposerTextInput(text: $draft, height: $editorHeight, focused: $focused, onSubmit: submit)
                .frame(height: editorHeight)
                .padding(.leading, 12).padding(.trailing, 10).padding(.top, 2)
                .contextMenu { Button("清空草稿") { draft = "" }.disabled(draft.isEmpty) }
            HStack(spacing: 12) {
                HStack(spacing: 16) {
                    Button { commandMenuOpen.toggle() } label: {
                        DeepSeekIcon(kind: .plus, size: 14)
                            .frame(width: 28, height: 28)
                            .background(Color(nsColor: Theme.selector), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain).help("命令")
                        .popover(isPresented: $commandMenuOpen, arrowEdge: .bottom) {
                            SlashCommandMenu(draft: $draft, presented: $commandMenuOpen)
                                .environmentObject(model)
                        }
                    if model.projections.permissions != nil { permissionTrigger }
                    if model.projections.plan?.targetActive == true { planModeChip }
                }
                Spacer()
                HStack(spacing: 12) {
                    modelTrigger
                    if let session = model.current, session.contextPressure != nil { ContextMeter(session: session) }
                    Button(action: model.current?.running == true ? model.stop : submit) {
                        Group {
                            if model.current?.running == true {
                                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color.white).frame(width: 10, height: 10)
                            } else {
                                DeepSeekIcon(kind: .send, size: 16).foregroundStyle(.white)
                            }
                        }
                        .frame(width: 34, height: 34)
                        .background(Color(nsColor: Theme.business), in: Circle())
                        .contentShape(Circle())
                    }
                    .buttonStyle(ComposerPrimaryButtonStyle(active: model.current?.running == true || canSubmit))
                    .disabled(model.current?.running != true && !canSubmit)
                    .offset(y: -2)
                    .help(model.current?.running == true ? "停止" : "发送")
                }
            }.padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 6)
        }
        .padding(.top, 10)
        .frame(maxWidth: 780).background(Color(nsColor: Theme.input), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.primary.opacity(0.09))).shadow(color: .black.opacity(0.06), radius: 8, y: 3)
        .onChange(of: model.current?.id) { _ in
            permissionMenuOpen = false
            optimisticPermission = nil
            permissionAcknowledged = false
            permissionConfirmation = nil
        }
        .onChange(of: model.projections.permissions) { value in
            if value == nil { permissionMenuOpen = false; optimisticPermission = nil }
        }
        .onChange(of: model.permissionSelectionBusy) { busy in
            if !busy { optimisticPermission = nil }
        }
    }

    private var permissionTrigger: some View {
        let value = optimisticPermission ?? model.projections.permissions?.currentValue ?? ""
        let current = model.projections.permissions?.options.first { $0.value == value }
        return Button { permissionMenuOpen.toggle() } label: {
            HStack(spacing: 4) {
                if PermissionGlyphKind(rawValue: value) != nil { PermissionGlyph(value: value, size: 14) }
                Text(current?.displayName ?? permissionDisplayName(value)).lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(permissionMenuOpen ? 180 : 0))
            }
            .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            .padding(.leading, 8).padding(.trailing, 4).frame(height: 28)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(model.current == nil || model.permissionSelectionBusy || permissionConfirmation != nil)
        .help(current?.description ?? "访问模式：\(current?.displayName ?? permissionDisplayName(value))")
        .popover(isPresented: $permissionMenuOpen, arrowEdge: .bottom) {
            if let permissions = model.projections.permissions {
                PermissionSelectionPopover(value: permissions, presented: $permissionMenuOpen) { choice in
                    choosePermission(choice)
                }
            }
        }
    }

    private var planModeChip: some View {
        Button(action: model.exitPlanMode) {
            HStack(spacing: 4) {
                Text("Plan")
                DeepSeekIcon(kind: .closeFill, size: 12)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color(nsColor: Theme.warnLabel))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .frame(minHeight: 24)
            .background(Color(nsColor: Theme.warnTertiary), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(model.current == nil || model.interactionBusy || model.planSelectionBusy)
        .opacity(model.planSelectionBusy ? 0.6 : 1)
        .help("退出 Plan 模式")
    }

    private var modelTrigger: some View {
        Button { modelMenuOpen.toggle() } label: {
            HStack(spacing: 4) {
                Text(currentChoice?.name ?? model.currentModel?.model ?? "选择模型")
                    .lineLimit(1).truncationMode(.tail)
                if let effortLabel { Text(effortLabel).foregroundStyle(.tertiary).fixedSize() }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(modelMenuOpen ? 180 : 0))
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.leading, 8).padding(.trailing, 4).frame(height: 28)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(model.current == nil || model.subagentParentId != nil)
        .help(modelTriggerLabel)
        .popover(isPresented: $modelMenuOpen, arrowEdge: .bottom) {
            ModelSelectionPopover(presented: $modelMenuOpen).environmentObject(model)
        }
    }

    private var currentChoice: ModelChoice? { model.models.first { $0.key == model.currentModel?.key } }
    private var currentEfforts: [ReasoningEffort] { currentChoice?.efforts ?? [] }
    private var effectiveEffort: String? { model.currentModel?.reasoningEffort ?? currentChoice?.defaultEffort }
    private var effortLabel: String? { guard let effectiveEffort else { return nil }; return currentEfforts.first { $0.id == effectiveEffort }?.name ?? effectiveEffort }
    private var modelTriggerLabel: String {
        let name = currentChoice?.name ?? model.currentModel?.model ?? "选择模型"
        return effortLabel.map { "\(name) · \($0)" } ?? name
    }

    private var canSubmit: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.draftImages.isEmpty || !model.draftFiles.isEmpty
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !model.draftImages.isEmpty || !model.draftFiles.isEmpty else { return }
        draft = ""
        let running = model.current?.running == true
        let modifiers = NSEvent.modifierFlags
        let alternate = modifiers.contains(.command) || modifiers.contains(.control)
        let preferred = model.busyEnterMode
        let busyMode = alternate ? (preferred == "queue" ? "steer" : "queue") : preferred
        model.send(text, mode: running ? busyMode : "queue")
    }
    private func choosePermission(_ choice: PermissionOption) {
        permissionMenuOpen = false
        guard choice.value != model.projections.permissions?.currentValue else { return }
        if choice.value == "danger-full-access" {
            permissionAcknowledged = false
            permissionConfirmation = choice.value
            return
        }
        optimisticPermission = choice.value
        model.choosePermission(choice.value) { _ in optimisticPermission = nil }
    }

    private func permissionDisplayName(_ value: String) -> String {
        if value == "danger-full-access" { return "Full access" }
        guard value.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil else { return value }
        return value.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

/// The WebUI applies exactly one 0.4 alpha to the disabled primary circle.
/// A custom style prevents AppKit's disabled button treatment from dimming the
/// already-dimmed label a second time.
private struct ComposerPrimaryButtonStyle: ButtonStyle {
    let active: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(active ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && active ? 0.96 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private struct PermissionSelectionPopover: View {
    let value: PermissionSelectValue
    @Binding var presented: Bool
    let onChoose: (PermissionOption) -> Void
    @FocusState private var focusedRow: String?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(value.options.filter { $0.value != "custom" }) { option in
                Button { onChoose(option) } label: {
                    HStack(spacing: 8) {
                        if PermissionGlyphKind(rawValue: option.value) != nil {
                            PermissionGlyph(value: option.value, size: 16).foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(option.displayName).font(.system(size: 14, weight: .medium)).lineLimit(1)
                            if let description = option.description, !description.isEmpty {
                                Text(description).font(.system(size: 12)).foregroundStyle(.tertiary).lineLimit(1)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "checkmark").opacity(option.value == value.currentValue ? 1 : 0).frame(width: 18)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6).frame(minHeight: 38)
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain).focused($focusedRow, equals: option.value)
                .modifier(ModelMenuRowFeedback(focused: focusedRow == option.value))
                .help(option.description ?? option.displayName)
            }
        }
        .padding(4).frame(width: 240).nativeGlassPopover(cornerRadius: 22)
        .onAppear { DispatchQueue.main.async { focusedRow = rowIDs.first } }
        .onMoveCommand(perform: moveFocus)
        .onExitCommand { presented = false }
    }

    private var rowIDs: [String] { value.options.filter { $0.value != "custom" }.map(\.value) }
    private func moveFocus(_ direction: MoveCommandDirection) {
        guard direction == .up || direction == .down, !rowIDs.isEmpty else { return }
        let current = focusedRow.flatMap { rowIDs.firstIndex(of: $0) } ?? 0
        let delta = direction == .down ? 1 : -1
        focusedRow = rowIDs[(current + delta + rowIDs.count) % rowIDs.count]
    }
}

private struct PermissionRiskOverlay: View {
    @Binding var acknowledged: Bool
    let disabled: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @FocusState private var acknowledgementFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.24).ignoresSafeArea().background(.ultraThinMaterial).onTapGesture(perform: onCancel)
            VStack(spacing: 20) {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text("确认启用 Full access？").font(.system(size: 16, weight: .medium))
                        Spacer()
                        Button(action: onCancel) { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28) }
                            .buttonStyle(.plain).help("关闭")
                    }.padding(.leading, 24).padding(.top, 22).padding(.trailing, 14).padding(.bottom, 12)
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle").font(.system(size: 18)).foregroundStyle(.red).padding(.top, 2)
                            Text("启用 Full access 后，agent 将减少确认步骤，并且可以直接执行更多操作，包括敏感操作、文件修改或外部命令。仅建议在你信任当前任务时使用。")
                                .font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(4)
                        }
                        Toggle("我已了解风险，并愿意继续", isOn: $acknowledged)
                            .toggleStyle(.checkbox).font(.system(size: 14)).disabled(disabled)
                            .focused($acknowledgementFocused)
                    }.padding(.horizontal, 24)
                }
                HStack(spacing: 8) {
                    Spacer()
                    Button("取消", action: onCancel).frame(minWidth: 72)
                    Button("启用 Full access", action: onConfirm).buttonStyle(.borderedProminent)
                        .frame(minWidth: 136).disabled(disabled || !acknowledged)
                }.padding(.horizontal, 24)
            }
            .padding(.bottom, 24).frame(width: 440)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.24), radius: 28, y: 12)
            .onAppear { acknowledged = false; DispatchQueue.main.async { acknowledgementFocused = true } }
        }
        .transition(.opacity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("确认启用 Full access？")
    }
}

private struct ModelSelectionPopover: View {
    enum Section { case model, effort }

    @EnvironmentObject private var model: AppModel
    @Binding var presented: Bool
    @State private var expandedSection: Section?
    @FocusState private var focusedRow: String?

    var body: some View {
        rootPane
        .padding(4)
        .frame(width: 240)
        .nativeGlassPopover(cornerRadius: 22)
        .onAppear {
            expandedSection = nil
            model.refreshModels()
            focusFirst()
        }
        .onChange(of: expandedSection) { _ in focusFirst() }
        .onMoveCommand(perform: moveFocus)
        .onExitCommand {
            if expandedSection == nil { presented = false }
            else { expandedSection = nil }
        }
    }

    private var rootPane: some View {
        VStack(spacing: 0) {
            rootCell(id: "root:model", label: "Model", value: modelLabel,
                     expanded: expandedSection == .model) {
                toggle(.model)
            }
            if expandedSection == .model {
                modelPane
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if currentChoice?.efforts.isEmpty == false {
                rootCell(id: "root:effort", label: "Effort", value: effortLabel ?? "Provider default",
                         expanded: expandedSection == .effort) {
                    toggle(.effort)
                }
                if expandedSection == .effort {
                    effortPane
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .animation(.easeInOut(duration: 0.16), value: expandedSection)
    }

    private var modelPane: some View {
        VStack(spacing: 0) {
            if model.modelCatalogLoading && model.models.isEmpty {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在加载模型…") }
                    .font(.system(size: 13)).foregroundStyle(.secondary).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = model.modelCatalogError {
                HStack(alignment: .top, spacing: 8) {
                    Text(error).lineLimit(3); Spacer(minLength: 0)
                    Button("重试") { model.refreshModels() }.buttonStyle(.plain).fontWeight(.semibold)
                }
                .font(.system(size: 12)).foregroundStyle(.red).padding(8)
                .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            }
            ForEach(model.modelCatalogFailures) { failure in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(failure.name)：\(failure.message)").lineLimit(4)
                    Spacer(minLength: 0)
                    Button("重试") { model.refreshModels() }.buttonStyle(.plain).fontWeight(.semibold)
                }
                .font(.system(size: 12)).foregroundStyle(.orange).padding(8)
                .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(providerIDs, id: \.self) { provider in
                        Text(model.models.first(where: { $0.provider == provider })?.providerName ?? provider)
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 8).padding(.top, 5).padding(.bottom, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(model.models.filter { $0.provider == provider }) { choice in
                            optionRow(id: "model:\(choice.key)", title: choice.name,
                                      description: choice.description, selected: choice.key == model.currentModel?.key) {
                                choose(choice)
                            }
                        }
                    }
                    if !model.modelCatalogLoading && model.models.isEmpty && model.modelCatalogError == nil {
                        Text("暂无可用模型").font(.system(size: 13)).foregroundStyle(.tertiary).padding(10)
                    }
                }
            }.frame(maxHeight: 248)
        }
    }

    private var effortPane: some View {
        VStack(spacing: 0) {
            if let choice = currentChoice {
                if choice.defaultEffort == nil {
                    optionRow(id: "effort:provider-default", title: "Provider default", description: nil,
                              selected: model.currentModel?.reasoningEffort == nil) { chooseEffort(nil) }
                }
                ForEach(choice.efforts) { effort in
                    optionRow(id: "effort:\(effort.id)", title: effort.name, description: effort.description,
                              selected: effectiveEffort == effort.id) { chooseEffort(effort.id) }
                }
            } else {
                Text("当前模型没有推理强度选项").font(.system(size: 13)).foregroundStyle(.tertiary).padding(10)
            }
        }
    }

    private func rootCell(id: String, label: String, value: String, expanded: Bool,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(label).frame(maxWidth: .infinity, alignment: .leading)
                Text(value).foregroundStyle(.tertiary).lineLimit(1)
                DeepSeekIcon(kind: .chevronRight, size: 12)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }.padding(.horizontal, 10).frame(height: 40).contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).focused($focusedRow, equals: id)
        .modifier(ModelMenuRowFeedback(focused: focusedRow == id))
    }

    private func optionRow(id: String, title: String, description: String?, selected: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    if let description { Text(description).font(.system(size: 12)).foregroundStyle(.tertiary).lineLimit(1) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "checkmark").opacity(selected ? 1 : 0).frame(width: 18)
            }.padding(.horizontal, 8).padding(.vertical, 6).frame(minHeight: 38).contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).disabled(model.modelSelectionBusy).focused($focusedRow, equals: id)
        .modifier(ModelMenuRowFeedback(focused: focusedRow == id))
    }

    private var providerIDs: [String] {
        model.models.reduce(into: []) { result, choice in if !result.contains(choice.provider) { result.append(choice.provider) } }
    }
    private var currentChoice: ModelChoice? { model.models.first { $0.key == model.currentModel?.key } }
    private var effectiveEffort: String? { model.currentModel?.reasoningEffort ?? currentChoice?.defaultEffort }
    private var modelLabel: String { currentChoice?.name ?? model.currentModel?.model ?? "选择模型" }
    private var effortLabel: String? {
        guard let choice = currentChoice else { return nil }
        guard let effectiveEffort else { return "Provider default" }
        return choice.efforts.first { $0.id == effectiveEffort }?.name ?? effectiveEffort
    }

    private var rowIDs: [String] {
        var rows = ["root:model"]
        if expandedSection == .model { rows.append(contentsOf: model.models.map { "model:\($0.key)" }) }
        if currentChoice?.efforts.isEmpty == false { rows.append("root:effort") }
        if expandedSection == .effort, let choice = currentChoice {
            rows.append(contentsOf: (choice.defaultEffort == nil ? ["effort:provider-default"] : [])
                + choice.efforts.map { "effort:\($0.id)" })
        }
        return rows
    }

    private func toggle(_ section: Section) {
        expandedSection = expandedSection == section ? nil : section
    }

    private func focusFirst() {
        DispatchQueue.main.async { focusedRow = rowIDs.first }
    }
    private func moveFocus(_ direction: MoveCommandDirection) {
        guard direction == .up || direction == .down, !rowIDs.isEmpty else { return }
        let current = focusedRow.flatMap { rowIDs.firstIndex(of: $0) } ?? 0
        let delta = direction == .down ? 1 : -1
        focusedRow = rowIDs[(current + delta + rowIDs.count) % rowIDs.count]
    }
    private func choose(_ choice: ModelChoice) {
        if choice.key == model.currentModel?.key { presented = false; return }
        model.chooseModel(choice) { if $0 { presented = false } }
    }
    private func chooseEffort(_ effort: String?) {
        if model.currentModel?.reasoningEffort == effort || (model.currentModel?.reasoningEffort == nil && effectiveEffort == effort) {
            presented = false; return
        }
        model.chooseEffort(effort) { if $0 { presented = false } }
    }
}

private struct ModelMenuRowFeedback: ViewModifier {
    let focused: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(hovering || focused ? Color.primary.opacity(0.07) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(focused ? Color.accentColor.opacity(0.72) : Color.clear,
                            lineWidth: focused ? 3 : 0)
            }
            .onHover { hovering = $0 }
    }
}

private struct SlashCommandMenu: View {
    @EnvironmentObject private var model: AppModel
    @Binding var draft: String
    @Binding var presented: Bool
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: chooseImages) { Label("图片", systemImage: "photo") }
                Button(action: chooseFiles) { Label("文件", systemImage: "doc.text") }
                Spacer(minLength: 0)
            }
            .buttonStyle(.borderless).padding(.horizontal, 10).frame(height: 38)
            Divider()
            TextField("搜索命令", text: $query).textFieldStyle(.plain).padding(.horizontal, 12).frame(height: 38)
            Divider()
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filtered) { command in
                        Button { choose(command) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Text("/\(command.name)").font(.system(size: 13, design: .monospaced).weight(.medium)).foregroundStyle(.primary).frame(width: 92, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(command.description).foregroundStyle(.secondary).lineLimit(2)
                                    if let hint = command.inputHint { Text(hint).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1) }
                                }
                                Spacer(minLength: 0)
                            }.padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if filtered.isEmpty { Text("没有匹配的命令").font(.caption).foregroundStyle(.tertiary).padding(18) }
                }.padding(6)
            }.frame(maxHeight: 310)
        }.frame(width: 390).background(.regularMaterial)
    }

    private var filtered: [CommandDescriptor] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return model.commands }
        return model.commands.filter { $0.name.lowercased().contains(needle) || $0.description.lowercased().contains(needle) }
    }
    private func choose(_ command: CommandDescriptor) {
        draft = "/\(command.name)\(command.inputHint == nil ? "" : " ")"
        presented = false
    }

    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "添加图片"
        if panel.runModal() == .OK { panel.urls.forEach(model.addImage) }
        presented = false
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .sourceCode, .json, .xml, .commaSeparatedText, .text]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "添加文件"
        if panel.runModal() == .OK { panel.urls.forEach(model.addTextFile) }
        presented = false
    }
}

private struct ContextMeter: View {
    let session: SessionSummary
    @State private var presented = false
    private var pressure: ContextPressure { session.contextPressure! }
    private let systemColor = Color(red: 0.48, green: 0.53, blue: 0.62)
    private let toolsColor = Color(red: 167 / 255, green: 139 / 255, blue: 250 / 255)
    private let messagesColor = Color(red: 0.22, green: 0.48, blue: 0.94)

    var body: some View {
        Button { presented.toggle() } label: {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                Circle().trim(from: 0, to: pressure.fraction).stroke(Color.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
            }
            .frame(width: 14, height: 14)
            .frame(width: 28, height: 28)
            .contentShape(Circle())
        }
        .buttonStyle(ContextMeterTriggerStyle())
        .help("上下文已用 \(percent)%")
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            panel
        }
    }

    private var percent: Int { Int((pressure.fraction * 100).rounded()) }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("上下文已用").foregroundStyle(.tertiary)
                Text("\(percent)%").fontWeight(.medium).foregroundStyle(.primary)
                Spacer(minLength: 6)
                Text("~\(tokens(pressure.usedTokens)) / \(tokens(pressure.contextWindow))")
                    .fontWeight(.medium).foregroundStyle(.primary).monospacedDigit()
            }
            .font(.system(size: 12)).frame(height: 20)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    HStack(spacing: 1) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(segment.color)
                                .frame(width: max(segment.fraction > 0 ? 2 : 0,
                                                  proxy.size.width * pressure.fraction * segment.fraction))
                        }
                    }
                }
            }
            .frame(height: 4).padding(.top, 10).padding(.bottom, 12)
            if let breakdown = session.contextBreakdown {
                legend("系统提示词", value: breakdown.system, color: systemColor)
                legend("工具", value: breakdown.tools, color: toolsColor)
                legend("对话消息", value: breakdown.messages, color: messagesColor)
            }
        }
        .padding(12)
        .frame(width: 264)
        .nativeGlassPopover(cornerRadius: 12)
    }

    private var segments: [(fraction: CGFloat, color: Color)] {
        guard let value = session.contextBreakdown else { return [(1, Color.secondary)] }
        let total = max(1, value.system + value.tools + value.messages)
        return [(CGFloat(value.system) / CGFloat(total), systemColor),
                (CGFloat(value.tools) / CGFloat(total), toolsColor),
                (CGFloat(value.messages) / CGFloat(total), messagesColor)]
    }

    private func legend(_ title: String, value: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text("~\(tokens(value))").foregroundStyle(.primary).monospacedDigit()
        }.font(.system(size: 12)).frame(height: 24)
    }

    private func tokens(_ value: Int) -> String {
        let number: Double
        let suffix: String
        if value >= 1_000_000 { number = Double(value) / 1_000_000; suffix = "M" }
        else if value >= 1_000 { number = Double(value) / 1_000; suffix = "K" }
        else { return "\(value)" }
        let rounded = (number * 10).rounded() / 10
        return (rounded.rounded() == rounded ? "\(Int(rounded))" : String(format: "%.1f", rounded)) + suffix
    }
}

private struct ContextMeterTriggerStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.primary.opacity(0.1) : Color.clear, in: Circle())
    }
}

private struct DetailsPanel: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.detail?.tool.name ?? "详情").font(.system(size: 14, weight: .medium)).lineLimit(1)
                Spacer()
                if model.detail != nil {
                    Button { model.detail = nil } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28) }
                        .buttonStyle(.plain).help("关闭详情")
                }
            }.padding(.leading, 12).padding(.trailing, 12).padding(.top, 14).padding(.bottom, 12)
            Divider()
            if let detail = model.detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let input = detail.tool.detailInputText {
                            ToolDetailSection(label: "Input") { ToolDetailCode(text: input, error: false) }
                        }
                        ToolDetailSection(label: "Output") {
                            if let presentation = detail.tool.presentation {
                                VStack(alignment: .leading, spacing: 6) {
                                    if case let .terminal(card) = presentation,
                                       let description = card.description, !description.isEmpty {
                                        Text(description).font(.system(size: 13)).foregroundStyle(.secondary)
                                    }
                                    ToolPresentationView(presentation: presentation, detailMode: true)
                                    if case .web = presentation, let output = detail.tool.output, !output.isEmpty {
                                        ToolDetailCode(text: output, error: detail.tool.state == .error)
                                    }
                                }
                            } else if detail.tool.state == .running {
                                Text("正在运行").font(.system(size: 13)).foregroundStyle(.tertiary).padding(.vertical, 8)
                            } else {
                                ToolDetailCode(text: detail.tool.output ?? "", error: detail.tool.state == .error)
                            }
                        }
                    }.padding(.horizontal, 16).padding(.vertical, 12)
                }
            } else {
                Text("点击消息流中的工具行查看详情").font(.system(size: 13)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(.horizontal, 16).padding(.vertical, 20)
            }
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ToolDetailSection<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            content
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ToolDetailCode: View {
    let text: String
    let error: Bool
    var body: some View {
        Text(text).font(.system(size: 13, design: .monospaced))
            .foregroundStyle(error ? Color.red : Color.primary).lineSpacing(5).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    private enum Tab: Hashable { case general, models, plugins, presets }
    @State private var selection: Tab = .general

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettingsView()
                .environmentObject(model)
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(Tab.general)
            ModelProviderSettingsView()
                .environmentObject(model)
                .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 32)
                .tabItem { Label("模型", systemImage: "cpu") }
                .tag(Tab.models)
            PluginInventorySettingsView()
                .environmentObject(model)
                .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 32)
                .tabItem { Label("插件", systemImage: "puzzlepiece.extension") }
                .tag(Tab.plugins)
            AgentPresetSettingsView()
                .environmentObject(model)
                .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 32)
                .tabItem { Label("Agent 预设", systemImage: "person.2") }
                .tag(Tab.presets)
        }
        .tabViewStyle(.automatic)
        .frame(minWidth: 820, idealWidth: 980, minHeight: 600, idealHeight: 720)
        .transaction { $0.animation = nil }
        .task {
            model.loadHostSettings()
            model.loadAgentPresets()
        }
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("serverURL") private var serverURL = "http://localhost:3080"
    @State private var agentPreset = "standard"
    @State private var permission = "workspace-write"
    @State private var language = "zh"
    @State private var busyEnter = "queue"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsSection("新建会话") {
                settingsLine("Agent 预设", subtitle: "对此后新建的会话生效。运行中的会话保持它开始时的预设。") {
                    Picker("", selection: valueBinding($agentPreset, namespace: "agent-presets", key: "default")) {
                        ForEach(model.agentPresets.filter { $0.broken == nil }) { preset in
                            Text(preset.displayName).tag(preset.id)
                        }
                    }.labelsHidden().pickerStyle(.menu).frame(width: 210)
                }
                settingsLine("权限", subtitle: "选择新会话的默认权限模式") {
                    Picker("", selection: valueBinding($permission, namespace: "permission", key: "defaultPreset")) {
                        Text("Read Only").tag("read-only")
                        Text("Workspace Write").tag("workspace-write")
                        Text("Full Access").tag("danger-full-access")
                    }.labelsHidden().pickerStyle(.menu).frame(width: 210)
                }
                settingsLine("语言") {
                    Picker("", selection: valueBinding($language, namespace: "locale", key: "preference")) {
                        Text("中文").tag("zh")
                        Text("English").tag("en")
                    }.labelsHidden().pickerStyle(.menu).frame(width: 150)
                }
                }

                settingsSection("外观") {
                    settingsLine("颜色模式", subtitle: "选择浅色、深色，或跟随 macOS 系统外观。") {
                        Picker("", selection: appearanceBinding) {
                            Text("浅色").tag(1)
                            Text("深色").tag(2)
                            Text("跟随系统").tag(0)
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 330)
                    }
                }

                settingsSection("对话") {
                settingsLine("简洁显示模式", subtitle: "隐藏详细思考；折叠时显示当前动作，展开后只显示实际工具调用。") {
                    Toggle("", isOn: $model.compactConversationDisplay).labelsHidden().toggleStyle(.switch)
                }
                settingsLine("繁忙时 Enter 键行为", subtitle: "仅在智能体运行时生效；Cmd/Ctrl+Enter 使用另一行为") {
                    Picker("", selection: valueBinding($busyEnter, namespace: "ui-conversation", key: "busyEnter")) {
                        Text("排队发送").tag("queue")
                        Text("直接引导").tag("steer")
                    }.labelsHidden().pickerStyle(.menu).frame(width: 160)
                }
                }

                settingsSection("连接") {
                settingsLine("客户端服务器", subtitle: "原生客户端连接的 DeepSeek Harness 地址") {
                    HStack(spacing: 8) {
                        TextField("http://localhost:3080", text: $serverURL).textFieldStyle(.roundedBorder).frame(width: 230)
                        Button("重新连接") {
                            if let url = URL(string: serverURL) { HarnessAPI.shared.baseURL = url; model.reconnect() }
                        }
                    }
                }
                if model.hostSettings?.hasDocument == true {
                    settingsLine("配置文件", subtitle: "直接打开 Host 当前使用的配置文件。") {
                        Button(action: model.openSettingsDocument) {
                            HStack(spacing: 7) {
                                if model.settingsDocumentOpening { ProgressView().controlSize(.small) }
                                Text("打开配置文件")
                            }
                        }.disabled(model.settingsDocumentOpening)
                    }
                }
                if let error = model.hostSettingsError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                }
            }
            .padding(.horizontal, 36).padding(.top, 28).padding(.bottom, 40)
            .frame(maxWidth: 860, alignment: .topLeading)
        }
        .onAppear(perform: syncFromHost)
        .onReceive(model.$hostSettings) { _ in syncFromHost() }
    }

    private var settingsWritable: Bool { model.hostSettings?.writable == true }

    private func valueBinding(_ local: Binding<String>, namespace: String, key: String) -> Binding<String> {
        Binding(get: { local.wrappedValue }, set: { value in
            local.wrappedValue = value
            model.setHostSetting(namespace: namespace, path: [key], value: value)
        })
    }

    private func syncFromHost() {
        guard let settings = model.hostSettings else { return }
        agentPreset = settings.namespace("agent-presets")?.value("default") as? String
            ?? model.agentPresets.first(where: \.isDefault)?.id ?? "standard"
        permission = settings.namespace("permission")?.value("defaultPreset") as? String ?? "workspace-write"
        language = settings.namespace("locale")?.value("preference") as? String ?? "zh"
        busyEnter = settings.namespace("ui-conversation")?.value("busyEnter") as? String ?? "queue"
    }

    private var appearanceBinding: Binding<Int> {
        Binding(get: { model.appearance }, set: { tag in
            model.appearance = tag
            let preference = tag == 1 ? "light" : tag == 2 ? "dark" : "system"
            model.setHostSetting(namespace: "ui-theme", path: ["preference"], value: preference)
        })
    }

    private func settingsSection<Content: View>(_ title: String,
                                                @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 18, weight: .semibold))
            VStack(alignment: .leading, spacing: 8, content: content)
            Divider().padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsLine<Control: View>(_ title: String, subtitle: String? = nil,
                                             @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 15, weight: .medium))
                if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 20)
            control().disabled(!settingsWritable && title != "简洁显示模式" && title != "客户端服务器")
        }
        .padding(.vertical, 8)
    }
}

private struct ModelProviderSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var showingInactive = false
    @State private var editing: ModelProviderSettings?
    @State private var apiKey = ""
    @State private var saving = false
    @State private var removalTarget: ModelProviderSettings?

    private var filtered: [ModelProviderSettings] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        return model.modelProviders.filter { provider in
            (showingInactive || provider.active || provider.configured)
                && (needle.isEmpty || provider.id.localizedLowercase.contains(needle) || provider.displayName.localizedLowercase.contains(needle))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("模型").font(.title2.bold())
                Spacer()
                Button { model.loadModelProviders() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("刷新提供方")
            }
            Text("配置模型提供方和 API 密钥。密钥只写入 Host 凭证存储，不会从服务端读取回来。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("搜索提供方", text: $query).textFieldStyle(.roundedBorder)
                Toggle("显示可添加提供方", isOn: $showingInactive).toggleStyle(.switch).controlSize(.small)
            }
            if model.modelProvidersLoading && model.modelProviders.isEmpty {
                VStack(spacing: 10) { ProgressView(); Text("正在读取模型提供方…").font(.caption).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.modelProvidersError, model.modelProviders.isEmpty {
                VStack(spacing: 10) { Text("加载模型提供方失败").font(.headline); Text(error).font(.caption).foregroundStyle(.secondary); Button("重试") { model.loadModelProviders() } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(filtered) { provider in
                            HStack(spacing: 12) {
                                DeepSeekIcon(kind: provider.id == "deepseek-official" ? .fish : .sparkle, size: 22)
                                    .foregroundStyle(provider.usable ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 7) {
                                        Text(provider.displayName).font(.headline)
                                        if provider.id != provider.displayName { Text(provider.id).font(.caption2.monospaced()).foregroundStyle(.tertiary) }
                                    }
                                    HStack(spacing: 8) {
                                        Text(provider.active ? "适配器已启用" : "未启用").foregroundStyle(provider.active ? Color.green : Color.secondary)
                                        if let ref = provider.apiKeyRef {
                                            Text(provider.credential?.configured == true ? "密钥已配置" : "缺少密钥")
                                                .foregroundStyle(provider.credential?.configured == true ? Color.green : Color.orange)
                                            Text(ref).foregroundStyle(.tertiary)
                                        } else if provider.configured {
                                            Text("使用提供方原生认证").foregroundStyle(.secondary)
                                        } else {
                                            Text("添加时将使用 \(provider.credentialRef)").foregroundStyle(.tertiary)
                                        }
                                        if provider.modelCount > 0 { Text("\(provider.modelCount) 个模型").foregroundStyle(.secondary) }
                                    }.font(.caption)
                                }
                                Spacer()
                                if provider.usable { Text("可用").font(.caption).foregroundStyle(.green) }
                                else if provider.configured { Text("已配置").font(.caption).foregroundStyle(.orange) }
                                else { Text("可添加").font(.caption).foregroundStyle(.secondary) }
                                Button(provider.configured ? (provider.credential?.configured == true ? "更新密钥" : "设置密钥") : "添加提供方") {
                                    apiKey = ""; editing = provider
                                }.disabled(provider.credential?.writable == false || !model.modelProvidersWritable)
                                if provider.removable {
                                    Menu {
                                        Button("移除提供方", role: .destructive) { removalTarget = provider }
                                    } label: { Image(systemName: "ellipsis") }
                                    .menuStyle(.borderlessButton).fixedSize()
                                }
                            }
                            .padding(13)
                            .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.08)))
                        }
                    }.padding(.vertical, 2)
                }
            }
        }
        .task { if model.modelProviders.isEmpty { model.loadModelProviders() } }
        .sheet(item: $editing) { provider in
            VStack(alignment: .leading, spacing: 14) {
                HStack { DeepSeekIcon(kind: provider.id == "deepseek-official" ? .fish : .sparkle, size: 24); Text(provider.displayName).font(.title3.bold()) }
                Text("凭证引用：\(provider.credentialRef)").font(.caption.monospaced()).foregroundStyle(.secondary)
                SecureField(provider.credential?.configured == true ? "输入新密钥以替换现有值" : "API 密钥", text: $apiKey).textFieldStyle(.roundedBorder)
                Text("出于安全原因，Host 只返回是否已配置；现有密钥内容永远不会显示。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("取消") { editing = nil }.keyboardShortcut(.cancelAction).disabled(saving)
                    Button("保存") {
                        saving = true
                        model.saveProviderCredential(provider, value: apiKey) { success in
                            saving = false; if success { editing = nil; apiKey = "" }
                        }
                    }.keyboardShortcut(.defaultAction).disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                }
            }.padding(22).frame(width: 480)
        }
        .alert("移除提供方", isPresented: Binding(get: { removalTarget != nil }, set: { if !$0 { removalTarget = nil } })) {
            Button("取消", role: .cancel) { removalTarget = nil }
            Button("移除", role: .destructive) {
                if let target = removalTarget { model.removeProvider(target) }
                removalTarget = nil
            }
        } message: {
            Text("将移除 \(removalTarget?.displayName ?? "该提供方") 的用户配置；由本页管理的凭证也会一并清除。")
        }
    }
}

private struct PluginInventorySettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab = "可配置"
    @State private var query = ""
    @State private var expanded: String?
    @State private var timeoutMs = ""
    @State private var maxOutputBytes = ""
    @State private var maxParallelToolCalls = ""
    @State private var searchBaseURL = ""
    @State private var searchMaxUses = ""
    @State private var searchAPIKey = ""
    @State private var savingNamespace: String?

    private var filtered: [PluginInventoryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !needle.isEmpty else { return model.pluginInventory }
        return model.pluginInventory.filter {
            $0.moduleName.localizedLowercase.contains(needle) || $0.entryId.localizedLowercase.contains(needle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("插件").font(.title2.bold())
                Spacer()
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("刷新插件列表")
            }
            Text("配置 WebUI 提供的插件能力，或查看 Host Loader 的安装清单。")
                .font(.caption).foregroundStyle(.secondary)
            Picker("", selection: $tab) {
                Text("可配置").tag("可配置")
                Text("已安装").tag("已安装")
            }.pickerStyle(.segmented).frame(width: 220)
            if tab == "可配置" { configurableContent }
            else { inventoryContent }
        }
        .task { refresh() }
        .onReceive(model.$pluginSettings) { snapshot in seed(snapshot) }
        .onChange(of: query) { _ in if let expanded, !filtered.contains(where: { $0.id == expanded }) { self.expanded = nil } }
    }

    @ViewBuilder private var configurableContent: some View {
        if model.pluginSettingsLoading && model.pluginSettings == nil {
            VStack(spacing: 10) { ProgressView(); Text("正在读取插件设置…").font(.caption).foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.pluginSettingsError, model.pluginSettings == nil {
            VStack(spacing: 10) { Text("加载插件设置失败").font(.headline); Text(error).font(.caption).foregroundStyle(.secondary); Button("重试") { model.loadPluginSettings() } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 10) {
                    pluginCard(title: "Bash", subtitle: "命令执行超时与每个输出流的内存上限", symbol: "terminal") {
                        pluginField("超时（毫秒）", text: $timeoutMs, overridden: overridden("shell", "timeoutMs"))
                        pluginField("最大输出字节数", text: $maxOutputBytes, overridden: overridden("shell", "maxOutputBytes"))
                    } save: {
                        save("shell", fields: ["timeoutMs": timeoutMs, "maxOutputBytes": maxOutputBytes])
                    }
                    pluginCard(title: "Agent Loop", subtitle: "单个步骤内可并行执行的安全工具调用上限", symbol: "arrow.triangle.branch") {
                        pluginField("最大并行工具调用", text: $maxParallelToolCalls, overridden: overridden("agent-loop", "maxParallelToolCalls"))
                    } save: {
                        save("agent-loop", fields: ["maxParallelToolCalls": maxParallelToolCalls])
                    }
                    pluginCard(title: "Web Search", subtitle: "DeepSeek 搜索服务地址、调用次数与写入式密钥", symbol: "globe") {
                        pluginField("Base URL（留空继承默认）", text: $searchBaseURL, overridden: overridden("web-search-deepseek", "baseURL"))
                        pluginField("每次请求最大搜索次数", text: $searchMaxUses, overridden: overridden("web-search-deepseek", "maxUses"))
                        SecureField(model.pluginSettings?.webSearchCredential?.configured == true ? "输入新 API Key 以替换" : "API Key", text: $searchAPIKey)
                            .textFieldStyle(.roundedBorder)
                        Text(model.pluginSettings?.webSearchCredential?.configured == true ? "密钥已配置" : "密钥尚未配置")
                            .font(.caption).foregroundStyle(model.pluginSettings?.webSearchCredential?.configured == true ? Color.green : Color.orange)
                    } save: {
                        save("web-search-deepseek", fields: ["baseURL": searchBaseURL, "maxUses": searchMaxUses], apiKey: searchAPIKey)
                    }
                }.padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder private var inventoryContent: some View {
        TextField("搜索插件", text: $query).textFieldStyle(.roundedBorder)
        HStack {
            Text("插件列表").font(.headline)
            Text("\(filtered.count)").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
            if model.pluginInventoryLoading && model.pluginInventory.isEmpty {
                VStack(spacing: 10) { ProgressView(); Text("正在读取插件…").font(.caption).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.pluginInventoryError, model.pluginInventory.isEmpty {
                VStack(spacing: 10) {
                    Text("暂时无法读取插件。").font(.headline)
                    Text(error).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("重试") { model.loadPluginInventory() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                EmptyState(title: model.pluginInventory.isEmpty ? "暂无插件" : "没有匹配的插件", subtitle: "", symbol: "puzzlepiece.extension")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filtered) { entry in
                            VStack(spacing: 0) {
                                Button { expanded = expanded == entry.id ? nil : entry.id } label: {
                                    HStack(spacing: 10) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(entry.shortName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                            Text(entry.moduleName).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                                        }
                                        Spacer()
                                        if entry.enabled { Circle().fill(phaseColor(entry.fiberPhase)).frame(width: 8, height: 8).help(phaseLabel(entry.fiberPhase)) }
                                        Text(entry.enabled ? "已启用" : "已停用")
                                            .font(.caption).foregroundStyle(entry.enabled ? Color.green : Color.secondary)
                                            .padding(.horizontal, 7).padding(.vertical, 3)
                                            .background((entry.enabled ? Color.green : Color.secondary).opacity(0.1), in: Capsule())
                                        Image(systemName: expanded == entry.id ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.secondary)
                                    }.padding(.horizontal, 13).frame(minHeight: 48).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                if expanded == entry.id {
                                    Divider().opacity(0.5)
                                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                                        GridRow { Text("Loader 条目").foregroundStyle(.secondary); Text(entry.entryId).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
                                        GridRow { Text("配置状态").foregroundStyle(.secondary); Text(entry.enabled ? "已启用" : "已停用") }
                                        if entry.enabled { GridRow { Text("Cordis 状态").foregroundStyle(.secondary); Text(phaseLabel(entry.fiberPhase)) } }
                                    }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(13)
                                }
                            }
                            .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.08)))
                        }
                    }.padding(.vertical, 2)
                }
            }
    }

    private func pluginCard<Fields: View>(title: String, subtitle: String, symbol: String,
                                          @ViewBuilder fields: () -> Fields, save: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 22).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            fields()
            HStack {
                Text(model.pluginSettings?.writable == true ? "更改将实时应用" : "设置为只读")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if savingNamespace == namespaceForCard(title) { ProgressView().controlSize(.small) }
                Button("保存", action: save)
                    .disabled(model.pluginSettings?.writable != true || savingNamespace != nil)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.08)))
    }

    private func pluginField(_ label: String, text: Binding<String>, overridden: Bool) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 13)).frame(width: 190, alignment: .leading)
            TextField("", text: text).textFieldStyle(.roundedBorder)
            if overridden { Text("已覆盖").font(.caption2).foregroundStyle(Color.accentColor) }
        }
    }

    private func namespaceForCard(_ title: String) -> String {
        switch title { case "Bash": return "shell"; case "Agent Loop": return "agent-loop"; default: return "web-search-deepseek" }
    }

    private func overridden(_ ns: String, _ field: String) -> Bool {
        model.pluginSettings?.namespace(ns)?.isOverridden(field) == true
    }

    private func refresh() {
        model.loadPluginSettings()
        model.loadPluginInventory()
    }

    private func save(_ ns: String, fields: [String: String], apiKey: String? = nil) {
        savingNamespace = ns
        model.savePluginSettings(namespace: ns, fields: fields, apiKey: apiKey) { success in
            savingNamespace = nil
            if success { searchAPIKey = "" }
        }
    }

    private func seed(_ snapshot: PluginSettingsSnapshot?) {
        guard let snapshot else { return }
        func text(_ ns: String, _ key: String) -> String {
            guard let value = snapshot.namespace(ns)?.value(key) else { return "" }
            return String(describing: value)
        }
        timeoutMs = text("shell", "timeoutMs")
        maxOutputBytes = text("shell", "maxOutputBytes")
        maxParallelToolCalls = text("agent-loop", "maxParallelToolCalls")
        searchBaseURL = text("web-search-deepseek", "baseURL")
        searchMaxUses = text("web-search-deepseek", "maxUses")
    }

    private func phaseLabel(_ phase: String?) -> String {
        switch phase { case "pending": return "等待依赖"; case "loading": return "加载中"; case "active": return "已挂载"; case "failed": return "挂载失败"; case "unloading": return "卸载中"; default: return "未挂载" }
    }
    private func phaseColor(_ phase: String?) -> Color {
        switch phase { case "active": return .green; case "failed": return .red; case "pending", "loading", "unloading": return .orange; default: return .secondary }
    }
}

private struct AgentPresetSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selected: AgentPresetEntry?
    @State private var copyName = ""
    @State private var showingCopy = false
    @State private var draft = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("Agent 预设").font(.system(size: 24, weight: .bold))
                Spacer()
                Button { model.loadAgentPresets() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 15))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain).help("刷新预设")
            }
            Text("预设决定新会话使用的工具和插件组合。系统预设只读，用户预设可打开、复制或删除。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .padding(.top, 14).padding(.bottom, 22)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.agentPresets.enumerated()), id: \.element.id) { index, preset in
                        HStack(spacing: 14) {
                            Image(systemName: preset.trust == "system" ? "shippingbox" : "person.crop.circle")
                                .font(.system(size: 18)).foregroundStyle(preset.trust == "system" ? .blue : .orange)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(preset.displayName).font(.system(size: 16, weight: .semibold))
                                Text(preset.description ?? preset.id)
                                    .font(.system(size: 13)).foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 16)
                            if preset.isDefault {
                                Text("默认").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Menu {
                                Button("查看内容") { selected = preset; model.readPreset(preset) }
                                Button("打开目录") { model.openPreset(preset) }
                                Button("复制为新预设") { selected = preset; showingCopy = true }
                                    .disabled(!model.agentPresetAuthorable)
                                if preset.trust == "user" {
                                    Divider()
                                    Button("删除", role: .destructive) { model.removePreset(preset) }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "ellipsis.circle").font(.system(size: 16))
                                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                                }
                                .frame(width: 48, height: 30)
                                .contentShape(Rectangle())
                            }
                            .menuStyle(.borderlessButton).fixedSize()
                        }
                        .padding(.horizontal, 20).padding(.vertical, 14)
                        if index < model.agentPresets.count - 1 {
                            Divider().padding(.leading, 68).padding(.trailing, 20)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07)))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }.sheet(item: $selected) { preset in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(preset.displayName).font(.headline)
                    Spacer()
                    Text(preset.trust == "system" ? "系统预设 · 只读" : "用户预设 · 本地编辑")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if preset.trust == "user" {
                    Text("WebUI 通过打开预设目录写入文件；这里提供原生编辑草稿，点击“打开目录”后保存到实际文件即可。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Group {
                    if preset.trust == "system" {
                        ScrollView([.horizontal, .vertical]) {
                            Text(model.agentPresetContent ?? "正在读取…")
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(10)
                        }
                    } else {
                        TextEditor(text: $draft)
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
                HStack {
                    Button("打开目录") { model.openPreset(preset) }
                    if preset.trust == "user" {
                        Button("复制草稿") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(draft.isEmpty ? (model.agentPresetContent ?? "") : draft, forType: .string) }
                    }
                    Spacer()
                    Button("关闭") { selected = nil }.keyboardShortcut(.cancelAction)
                }
            }
            .padding(22).frame(width: 720, height: 560)
            .onAppear { draft = model.agentPresetContent ?? "" }
        }.alert("复制 Agent 预设", isPresented: $showingCopy) { TextField("新预设 ID", text: $copyName); Button("取消", role: .cancel) {}; Button("复制") { if let selected, !copyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { model.copyPreset(selected, to: copyName.trimmingCharacters(in: .whitespacesAndNewlines)); copyName = "" } } } message: { Text("复制会保留原有组合内容，之后可在 Finder 中编辑。") }
    }
}
