import SwiftUI

struct NotesView: View {
    @ObservedObject var noteViewModel: NoteViewModel
    @ObservedObject var chatViewModel: ChatViewModel

    @Environment(\.scenePhase) private var scenePhase
    @State private var searchText = ""
    @State private var collapsedCategories: Set<String> = []
    @State private var editingDraft: NoteDraft?
    @State private var bannerTask: Task<Void, Never>?
    @State private var draftStatuses: [NoteDraftStatus] = []
    @State private var draftToClear: NoteDraftStatus?

    private let uncategorizedTitle = "未分类"

    private var filteredNotes: [Note] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return noteViewModel.notes }

        return noteViewModel.notes.filter { note in
            note.title.localizedCaseInsensitiveContains(keyword) ||
            note.content_markdown.localizedCaseInsensitiveContains(keyword) ||
            (note.summary?.localizedCaseInsensitiveContains(keyword) ?? false) ||
            (note.category?.localizedCaseInsensitiveContains(keyword) ?? false) ||
            note.tags.contains(where: { $0.localizedCaseInsensitiveContains(keyword) }) ||
            (note.source_title?.localizedCaseInsensitiveContains(keyword) ?? false)
        }
    }

    private var groupedNotes: [(category: String, notes: [Note])] {
        let grouped = Dictionary(grouping: filteredNotes) { note in
            let trimmed = note.category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? uncategorizedTitle : trimmed
        }

        return grouped
            .map { category, notes in
                (
                    category: category,
                    notes: notes.sorted { lhs, rhs in
                        if lhs.updated_at == rhs.updated_at {
                            return lhs.id > rhs.id
                        }
                        return lhs.updated_at > rhs.updated_at
                    }
                )
            }
            .sorted { lhs, rhs in
                if lhs.category == uncategorizedTitle { return false }
                if rhs.category == uncategorizedTitle { return true }
                return lhs.category.localizedStandardCompare(rhs.category) == .orderedAscending
            }
    }

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                searchBar

                if noteViewModel.isLoading && noteViewModel.notes.isEmpty && draftStatuses.isEmpty {
                    Spacer()
                    ProgressView("正在加载笔记...")
                    Spacer()
                } else if noteViewModel.notes.isEmpty && draftStatuses.isEmpty {
                    emptyState(
                        systemImage: "book.closed",
                        title: "还没有笔记",
                        subtitle: "可以手动新建，也可以从聊天、语音和卡片里整理生成。"
                    )
                } else if filteredNotes.isEmpty && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    emptyState(
                        systemImage: "magnifyingglass",
                        title: "没有找到匹配的笔记",
                        subtitle: "标题、正文、分类、标签和来源标题都会参与搜索。"
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 22) {
                            if !draftStatuses.isEmpty && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                DraftInboxSection(
                                    statuses: draftStatuses,
                                    onContinue: { status in
                                        guard let draft = NoteEditView.makeDraft(from: status, notes: noteViewModel.notes) else {
                                            NoteEditView.clearDraft(withKey: status.draftKey)
                                            refreshDraftStatuses()
                                            noteViewModel.activeAlert = .init(
                                                title: "草稿已失效",
                                                message: "这条草稿对应的原笔记已经不存在了，我已经帮你清掉。"
                                            )
                                            return
                                        }
                                        editingDraft = draft
                                    },
                                    onClear: { status in
                                        draftToClear = status
                                    }
                                )
                            }

                            ForEach(groupedNotes, id: \.category) { group in
                                VStack(alignment: .leading, spacing: 14) {
                                    Button {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                            toggleCategory(group.category)
                                        }
                                    } label: {
                                        HStack {
                                            HStack(spacing: 8) {
                                                Image(systemName: group.category == uncategorizedTitle ? "tray.full.fill" : "folder.fill")
                                                    .foregroundColor(AppTheme.accent)
                                                Text(group.category)
                                                    .font(.system(size: 18, weight: .bold, design: .rounded))
                                                    .foregroundColor(AppTheme.accent)
                                            }
                                            Spacer()
                                            Text("\(group.notes.count) 篇")
                                                .font(.caption)
                                                .foregroundColor(.gray)
                                            Image(systemName: collapsedCategories.contains(group.category) ? "chevron.down" : "chevron.up")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundColor(.gray)
                                        }
                                    }
                                    .buttonStyle(.plain)

                                    if !collapsedCategories.contains(group.category) {
                                        ForEach(group.notes) { note in
                                            NavigationLink(destination: NoteDetailView(note: note, noteViewModel: noteViewModel, chatViewModel: chatViewModel)) {
                                                NoteRow(note: note)
                                            }
                                            .buttonStyle(.plain)
                                            .contextMenu {
                                                Button {
                                                    editingDraft = NoteDraft(note: note)
                                                } label: {
                                                    Label("编辑笔记", systemImage: "square.and.pencil")
                                                }

                                                Button(role: .destructive) {
                                                    Task { await noteViewModel.deleteNote(note) }
                                                } label: {
                                                    Label("删除笔记", systemImage: "trash")
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(16)
                    }
                }
            }

            if let alert = noteViewModel.activeAlert {
                VStack {
                    BannerView(
                        title: alert.title,
                        message: alert.message,
                        onClose: {
                            bannerTask?.cancel()
                            withAnimation { noteViewModel.dismissAlert() }
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(2)
            }
        }
        .navigationTitle("笔记库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Text("\(filteredNotes.count) 篇")
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 12) {
                    Button {
                        Task { await noteViewModel.loadNotes() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(AppTheme.accent)
                    }

                    Button {
                        editingDraft = NoteDraft()
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .foregroundColor(AppTheme.accent)
                    }
                }
            }
        }
        .task {
            noteViewModel.loadInitialDataIfNeeded()
            refreshDraftStatuses()
            if noteViewModel.notes.isEmpty {
                await noteViewModel.loadNotes()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            refreshDraftStatuses()
        }
        .onChange(of: noteViewModel.notes) { _, _ in
            refreshDraftStatuses()
        }
        .onChange(of: editingDraft?.id) { _, newValue in
            if newValue == nil {
                refreshDraftStatuses()
            }
        }
        .onChange(of: noteViewModel.activeAlert?.id) { _, newValue in
            bannerTask?.cancel()
            guard newValue != nil else { return }
            bannerTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { return }
                withAnimation { noteViewModel.dismissAlert() }
            }
        }
        .navigationDestination(item: $editingDraft) { draft in
            NoteEditView(draft: draft, noteViewModel: noteViewModel) { _ in
                refreshDraftStatuses()
            }
        }
        .alert("清空草稿", isPresented: Binding(
            get: { draftToClear != nil },
            set: { if !$0 { draftToClear = nil } }
        )) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                guard let draftToClear else { return }
                NoteEditView.clearDraft(withKey: draftToClear.draftKey)
                self.draftToClear = nil
                refreshDraftStatuses()
            }
        } message: {
            Text("清空后，这份草稿就找不回来了。")
        }
        .navigationDestination(item: $noteViewModel.presentedNote) { note in
            NoteDetailView(note: note, noteViewModel: noteViewModel, chatViewModel: chatViewModel)
        }
    }

    private func refreshDraftStatuses() {
        draftStatuses = NoteEditView.draftStatuses(notes: noteViewModel.notes)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.gray)

            TextField("搜索标题、正文、分类、标签", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray.opacity(0.8))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.white)
        .cornerRadius(16)
        .shadow(color: AppTheme.shadow, radius: 4, x: 0, y: 2)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func toggleCategory(_ category: String) {
        if collapsedCategories.contains(category) {
            collapsedCategories.remove(category)
        } else {
            collapsedCategories.insert(category)
        }
    }

    @ViewBuilder
    private func emptyState(systemImage: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: systemImage)
                .font(.system(size: 46))
                .foregroundColor(AppTheme.accent.opacity(0.35))
            Text(title)
                .font(.headline)
                .foregroundColor(.gray)
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.gray.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Spacer()
        }
    }
}

private struct DraftInboxSection: View {
    let statuses: [NoteDraftStatus]
    let onContinue: (NoteDraftStatus) -> Void
    let onClear: (NoteDraftStatus) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("草稿箱")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.accent)
                Spacer()
                Text("\(statuses.count) 条")
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            Text("这里会暂存你还没正式保存的内容，新建笔记和修改笔记都会放进来。")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            ForEach(statuses, id: \.draftKey) { status in
                DraftInboxCard(
                    status: status,
                    onContinue: { onContinue(status) },
                    onClear: { onClear(status) }
                )
            }
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [Color.white, Color.orange.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: AppTheme.shadow, radius: 4, x: 0, y: 2)
    }
}

private struct DraftInboxCard: View {
    let status: NoteDraftStatus
    let onContinue: () -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(status.sourceLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.orange.opacity(0.95))
                Spacer()
                Text(status.savedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundColor(.gray)
            }

            Text(status.title)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundColor(.primary)
                .lineLimit(2)

            Text(status.preview)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .lineLimit(3)

            HStack(spacing: 10) {
                Button(action: onContinue) {
                    Label("继续编辑", systemImage: "square.and.pencil")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(AppTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                Button(action: onClear) {
                    Label("清空草稿", systemImage: "trash")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color.orange.opacity(0.95))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Color.white.opacity(0.92))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
                        )
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

private struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(note.title)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.accent)
                    .lineLimit(2)
                Spacer()
                Text(String(note.updated_at.prefix(10)))
                    .font(.caption2)
                    .foregroundColor(.gray)
            }

            HStack(spacing: 8) {
                InfoChip(
                    text: note.sourceDisplayName,
                    icon: "sparkles",
                    background: Color.blue.opacity(0.1),
                    foreground: Color.blue.opacity(0.85)
                )

                ForEach(note.tags.prefix(3), id: \.self) { tag in
                    InfoChip(
                        text: tag,
                        icon: "number",
                        background: Color.orange.opacity(0.12),
                        foreground: Color.orange.opacity(0.85)
                    )
                }
            }

            Text(note.summary?.isEmpty == false ? note.summary! : note.content_markdown)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .lineLimit(4)
        }
        .padding(16)
        .background(Color.white)
        .cornerRadius(18)
        .shadow(color: AppTheme.shadow, radius: 4, x: 0, y: 2)
    }
}
