import SwiftUI
import UIKit

struct NoteDraft: Identifiable, Hashable {
    let id = UUID()
    let note: Note?
    var title: String
    var contentMarkdown: String
    var summary: String
    var category: String
    var tagsText: String

    init(note: Note? = nil) {
        self.note = note
        self.title = note?.title ?? ""
        self.contentMarkdown = note?.content_markdown ?? ""
        self.summary = note?.summary ?? ""
        self.category = note?.category ?? ""
        self.tagsText = note?.tags.joined(separator: ", ") ?? ""
    }
}

private struct NoteDraftSnapshot: Equatable {
    let title: String
    let contentMarkdown: String
    let summary: String
    let category: String
    let tagsText: String

    var hasAnyContent: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !contentMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !tagsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct PersistedNoteDraft: Codable {
    let title: String
    let contentMarkdown: String
    let summary: String
    let category: String
    let tagsText: String
    let savedAt: Date
}

struct NoteDraftStatus: Hashable {
    let draftKey: String
    let noteID: Int?
    let title: String
    let savedAt: Date
    let preview: String
    let sourceLabel: String
}

private enum NoteEditorMode: String, CaseIterable, Identifiable {
    case edit = "编辑"
    case preview = "预览"

    var id: String { rawValue }
}

private enum MarkdownCommandKind: Equatable {
    case prefixLine(String)
    case wrap(prefix: String, suffix: String, placeholder: String)
    case insert(String)
}

private struct MarkdownEditorCommand: Identifiable, Equatable {
    let id = UUID()
    let kind: MarkdownCommandKind
}

private struct MarkdownShortcut: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    let command: MarkdownCommandKind
}

private let markdownShortcuts: [MarkdownShortcut] = [
    .init(title: "大标题", systemImage: "textformat.size.larger", command: .prefixLine("# ")),
    .init(title: "小标题", systemImage: "textformat.size", command: .prefixLine("## ")),
    .init(title: "加粗", systemImage: "bold", command: .wrap(prefix: "**", suffix: "**", placeholder: "重点内容")),
    .init(title: "列表", systemImage: "list.bullet", command: .prefixLine("- ")),
    .init(title: "引用", systemImage: "text.quote", command: .prefixLine("> ")),
    .init(title: "代码", systemImage: "chevron.left.forwardslash.chevron.right", command: .wrap(prefix: "```text\n", suffix: "\n```", placeholder: "在这里写代码或示例")),
    .init(title: "公式", systemImage: "function", command: .wrap(prefix: "$$\n", suffix: "\n$$", placeholder: "公式写这里")),
    .init(title: "分隔线", systemImage: "minus", command: .insert("\n---\n")),
]

struct NoteEditView: View {
    let draft: NoteDraft
    let noteViewModel: NoteViewModel
    let onFinish: (Note) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var markdownPreviewViewModel = ChatViewModel()
    @State private var initialSnapshot: NoteDraftSnapshot
    @State private var title: String
    @State private var contentMarkdown: String
    @State private var summary: String
    @State private var category: String
    @State private var tagsText: String
    @State private var isSaving = false
    @State private var editorMode: NoteEditorMode = .edit
    @State private var editorCommand: MarkdownEditorCommand?
    @State private var autosaveTask: Task<Void, Never>?
    @State private var showDiscardChangesDialog = false
    @State private var lastAutosavedAt: Date?
    @State private var restoredFromAutosave = false

    init(draft: NoteDraft, noteViewModel: NoteViewModel, onFinish: @escaping (Note) -> Void) {
        let restoredDraft = Self.restoredDraft(from: draft)
        self.draft = draft
        self.noteViewModel = noteViewModel
        self.onFinish = onFinish
        _initialSnapshot = State(initialValue: Self.snapshot(from: draft))
        _title = State(initialValue: restoredDraft.title)
        _contentMarkdown = State(initialValue: restoredDraft.contentMarkdown)
        _summary = State(initialValue: restoredDraft.summary)
        _category = State(initialValue: restoredDraft.category)
        _tagsText = State(initialValue: restoredDraft.tagsText)
        if let persisted = Self.loadPersistedDraft(for: draft) {
            _lastAutosavedAt = State(initialValue: persisted.savedAt)
            _restoredFromAutosave = State(initialValue: true)
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            AppTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    metadataCard
                    summaryCard
                    contentCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, editorMode == .edit ? 104 : 24)
            }
            
            if editorMode == .edit {
                editorToolbar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
        .navigationTitle(draft.note == nil ? "新建笔记" : "编辑笔记")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("取消") { handleDismissAttempt() }
                    .foregroundColor(AppTheme.accent)
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Button(isSaving ? "保存中..." : "保存") {
                    saveNote()
                }
                .foregroundColor(AppTheme.accent)
                .disabled(isSaving || !canSave)
            }
        }
        .alert("还有内容没保存", isPresented: $showDiscardChangesDialog) {
            Button("继续编辑", role: .cancel) {}
            Button("存入草稿箱") {
                persistDraft(currentSnapshot)
                noteViewModel.activeAlert = .init(
                    title: "已存入草稿箱",
                    message: "内容已保存到草稿箱，可以再来编辑哦"
                )
                dismiss()
            }
            Button("放弃修改", role: .destructive) {
                autosaveTask?.cancel()
                clearPersistedDraft()
                dismiss()
            }
        } message: {
            Text("确认返回吗？未保存的内容将会丢失")
        }
        .onChange(of: title) { _, _ in scheduleAutosave() }
        .onChange(of: contentMarkdown) { _, _ in scheduleAutosave() }
        .onChange(of: summary) { _, _ in scheduleAutosave() }
        .onChange(of: category) { _, _ in scheduleAutosave() }
        .onChange(of: tagsText) { _, _ in scheduleAutosave() }
        .onDisappear {
            autosaveTask?.cancel()
        }
    }

    private var metadataCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("笔记信息")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(AppTheme.accent)

            TextField("输入笔记标题", text: $title)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            HStack(spacing: 12) {
                TextField("分类", text: $category)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                TextField("标签，用逗号分隔", text: $tagsText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }

            Picker("编辑模式", selection: $editorMode) {
                ForEach(NoteEditorMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if restoredFromAutosave || lastAutosavedAt != nil {
                Text(autosaveStatusText)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .padding(18)
        .background(Color(red: 0.96, green: 0.97, blue: 0.94))
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("摘要")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(AppTheme.accent)

            TextEditor(text: $summary)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 110)
                .padding(10)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .padding(18)
        .background(Color.white.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    private var contentCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("正文")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.accent)

                Spacer()

                if editorMode == .edit {
                    Text("点击工具栏可以快捷插入格式模板哦~")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                } else {
                    Text("当前为预览模式")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }

            if editorMode == .edit {
                MarkdownTextEditor(text: $contentMarkdown, command: $editorCommand)
                    .frame(minHeight: 420)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if contentMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("正文还没写内容，先开始整理吧。")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    } else {
                        MarkdownView(
                            content: contentMarkdown,
                            viewModel: markdownPreviewViewModel
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
        .padding(18)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .shadow(color: AppTheme.shadow, radius: 4, x: 0, y: 2)
    }

    private var editorToolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(markdownShortcuts) { shortcut in
                        Button(action: { editorCommand = normalizedCommand(for: shortcut.command) }) {
                            Label(shortcut.title, systemImage: shortcut.systemImage)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(AppTheme.accent)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(AppTheme.userBubble)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.98))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 4)
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !contentMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var currentSnapshot: NoteDraftSnapshot {
        NoteDraftSnapshot(
            title: title,
            contentMarkdown: contentMarkdown,
            summary: summary,
            category: category,
            tagsText: tagsText
        )
    }

    private var hasUnsavedChanges: Bool {
        currentSnapshot != initialSnapshot
    }

    private var autosaveStatusText: String {
        if restoredFromAutosave, let lastAutosavedAt {
            return "已恢复草稿·\(lastAutosavedAt.formatted(date: .omitted, time: .shortened))自动保存"
        }
        if let lastAutosavedAt {
            return "草稿已自动保存·\(lastAutosavedAt.formatted(date: .omitted, time: .shortened))"
        }
        return "草稿未保存"
    }

    private func normalizedCommand(for command: MarkdownCommandKind) -> MarkdownEditorCommand {
        let current = contentMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else {
            return MarkdownEditorCommand(kind: command)
        }
        switch command {
        case .insert(let snippet):
            if snippet.hasPrefix("\n") {
                return MarkdownEditorCommand(kind: .insert(snippet))
            }
            return MarkdownEditorCommand(kind: .insert("\n\(snippet)"))
        default:
            return MarkdownEditorCommand(kind: command)
        }
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        let snapshot = currentSnapshot
        autosaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            persistDraft(snapshot)
        }
    }

    private func persistDraft(_ snapshot: NoteDraftSnapshot) {
        let defaults = UserDefaults.standard
        let key = Self.autosaveKey(for: draft)

        guard snapshot.hasAnyContent else {
            defaults.removeObject(forKey: key)
            lastAutosavedAt = nil
            restoredFromAutosave = false
            return
        }

        let persisted = PersistedNoteDraft(
            title: snapshot.title,
            contentMarkdown: snapshot.contentMarkdown,
            summary: snapshot.summary,
            category: snapshot.category,
            tagsText: snapshot.tagsText,
            savedAt: Date()
        )

        guard let data = try? JSONEncoder().encode(persisted) else { return }
        defaults.set(data, forKey: key)
        lastAutosavedAt = persisted.savedAt
        restoredFromAutosave = false
    }

    private func clearPersistedDraft() {
        UserDefaults.standard.removeObject(forKey: Self.autosaveKey(for: draft))
        lastAutosavedAt = nil
        restoredFromAutosave = false
    }

    private func handleDismissAttempt() {
        if hasUnsavedChanges {
            showDiscardChangesDialog = true
        } else {
            dismiss()
        }
    }

    private func saveNote() {
        guard !isSaving else { return }
        isSaving = true

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContent = contentMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        Task {
            let savedNote: Note?
            if let note = draft.note {
                savedNote = await noteViewModel.updateNote(
                    noteId: note.id,
                    title: trimmedTitle,
                    contentMarkdown: trimmedContent,
                    summary: trimmedSummary.isEmpty ? nil : trimmedSummary,
                    category: trimmedCategory.isEmpty ? nil : trimmedCategory,
                    tags: normalizedTags
                )
            } else {
                savedNote = await noteViewModel.createNote(
                    title: trimmedTitle,
                    contentMarkdown: trimmedContent,
                    summary: trimmedSummary.isEmpty ? nil : trimmedSummary,
                    category: trimmedCategory.isEmpty ? nil : trimmedCategory,
                    tags: normalizedTags
                )
            }

            isSaving = false
            guard let savedNote else { return }
            clearPersistedDraft()
            initialSnapshot = currentSnapshot
            onFinish(savedNote)
            dismiss()
        }
    }

    private static func snapshot(from draft: NoteDraft) -> NoteDraftSnapshot {
        NoteDraftSnapshot(
            title: draft.title,
            contentMarkdown: draft.contentMarkdown,
            summary: draft.summary,
            category: draft.category,
            tagsText: draft.tagsText
        )
    }

    private static func autosaveKey(for draft: NoteDraft) -> String {
        if let note = draft.note {
            return "note-editor-draft-\(note.id)"
        }
        return "note-editor-draft-new"
    }

    private static func loadPersistedDraft(for draft: NoteDraft) -> PersistedNoteDraft? {
        let defaults = UserDefaults.standard
        let key = autosaveKey(for: draft)
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PersistedNoteDraft.self, from: data)
    }

    private static func restoredDraft(from draft: NoteDraft) -> NoteDraft {
        guard let persisted = loadPersistedDraft(for: draft) else { return draft }
        var restored = draft
        restored.title = persisted.title
        restored.contentMarkdown = persisted.contentMarkdown
        restored.summary = persisted.summary
        restored.category = persisted.category
        restored.tagsText = persisted.tagsText
        return restored
    }

    static func draftStatuses(notes: [Note]) -> [NoteDraftStatus] {
        let defaults = UserDefaults.standard
        let notesByID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })

        return defaults.dictionaryRepresentation().compactMap { key, value in
            guard key.hasPrefix("note-editor-draft-"),
                  let data = value as? Data,
                  let persisted = try? JSONDecoder().decode(PersistedNoteDraft.self, from: data) else {
                return nil
            }
            return makeDraftStatus(forKey: key, persisted: persisted, notesByID: notesByID)
        }
        .sorted { $0.savedAt > $1.savedAt }
    }

    static func makeDraft(from status: NoteDraftStatus, notes: [Note]) -> NoteDraft? {
        if let noteID = status.noteID {
            guard let note = notes.first(where: { $0.id == noteID }) else { return nil }
            return NoteDraft(note: note)
        }
        return NoteDraft()
    }

    static func clearDraft(withKey key: String) {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func makeDraftStatus(
        forKey key: String,
        persisted: PersistedNoteDraft,
        notesByID: [Int: Note]
    ) -> NoteDraftStatus? {
        let noteID: Int?
        let sourceLabel: String

        if key == "note-editor-draft-new" {
            noteID = nil
            sourceLabel = "新建笔记草稿"
        } else {
            let suffix = key.replacingOccurrences(of: "note-editor-draft-", with: "")
            guard let parsedID = Int(suffix) else { return nil }
            guard notesByID[parsedID] != nil else { return nil }
            noteID = parsedID
            sourceLabel = "笔记修改草稿"
        }

        let trimmedTitle = persisted.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = noteID.flatMap { notesByID[$0]?.title } ?? "未命名草稿"
        let displayTitle = trimmedTitle.isEmpty ? fallbackTitle : trimmedTitle
        let previewSource = [
            persisted.summary,
            persisted.contentMarkdown,
            persisted.category
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty }) ?? "暂时没有内容哦"
        let preview = String(previewSource.prefix(60))

        return NoteDraftStatus(
            draftKey: key,
            noteID: noteID,
            title: displayTitle,
            savedAt: persisted.savedAt,
            preview: preview,
            sourceLabel: sourceLabel
        )
    }
}

private struct MarkdownTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var command: MarkdownEditorCommand?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, command: $command)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        textView.backgroundColor = .white
        textView.textColor = UIColor.label
        textView.layer.cornerRadius = 16
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        textView.alwaysBounceVertical = true
        textView.autocapitalizationType = .sentences
        textView.autocorrectionType = .yes
        textView.spellCheckingType = .yes
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.smartInsertDeleteType = .no
        textView.text = text
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if let command {
            context.coordinator.apply(command, to: uiView)
            return
        }

        if uiView.text != text, !context.coordinator.isApplyingProgrammaticChange {
            let selectedRange = uiView.selectedRange
            uiView.text = text
            let safeLocation = min(selectedRange.location, (text as NSString).length)
            uiView.selectedRange = NSRange(location: safeLocation, length: 0)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let text: Binding<String>
        private let command: Binding<MarkdownEditorCommand?>
        var isApplyingProgrammaticChange = false
        private var lastAppliedCommandID: UUID?

        init(text: Binding<String>, command: Binding<MarkdownEditorCommand?>) {
            self.text = text
            self.command = command
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingProgrammaticChange else { return }
            text.wrappedValue = textView.text
        }

        func apply(_ command: MarkdownEditorCommand, to textView: UITextView) {
            guard lastAppliedCommandID != command.id else { return }
            lastAppliedCommandID = command.id

            let selectedRange = textView.selectedRange
            guard let currentText = textView.text,
                  let range = Range(selectedRange, in: currentText) else {
                applyFallback(command.kind, to: textView)
                return
            }

            let selectedText = String(currentText[range])
            let replacement: String
            let nextSelection: NSRange

            switch command.kind {
            case .insert(let snippet):
                replacement = snippet
                nextSelection = NSRange(
                    location: selectedRange.location + (replacement as NSString).length,
                    length: 0
                )
            case .wrap(let prefix, let suffix, let placeholder):
                let body = selectedText.isEmpty ? placeholder : selectedText
                replacement = "\(prefix)\(body)\(suffix)"
                if selectedText.isEmpty {
                    nextSelection = NSRange(
                        location: selectedRange.location + (prefix as NSString).length,
                        length: (body as NSString).length
                    )
                } else {
                    nextSelection = NSRange(
                        location: selectedRange.location + (prefix as NSString).length,
                        length: (body as NSString).length
                    )
                }
            case .prefixLine(let prefix):
                let body = selectedText.isEmpty ? "内容" : selectedText
                let lines = body.components(separatedBy: .newlines)
                replacement = lines.map { line in
                    line.isEmpty ? prefix.trimmingCharacters(in: .whitespaces) : "\(prefix)\(line)"
                }.joined(separator: "\n")
                nextSelection = NSRange(
                    location: selectedRange.location,
                    length: (replacement as NSString).length
                )
            }

            let updatedText = currentText.replacingCharacters(in: range, with: replacement)
            isApplyingProgrammaticChange = true
            textView.text = updatedText
            textView.selectedRange = nextSelection
            if !textView.isFirstResponder {
                textView.becomeFirstResponder()
            }

            finishProgrammaticChange(with: updatedText)
        }

        private func applyFallback(_ command: MarkdownCommandKind, to textView: UITextView) {
            let originalLength = (textView.text as NSString?)?.length ?? 0
            isApplyingProgrammaticChange = true
            switch command {
            case .insert(let snippet):
                textView.text += snippet
                textView.selectedRange = NSRange(location: originalLength + (snippet as NSString).length, length: 0)
            case .wrap(let prefix, let suffix, let placeholder):
                textView.text += "\(prefix)\(placeholder)\(suffix)"
                textView.selectedRange = NSRange(
                    location: originalLength + (prefix as NSString).length,
                    length: (placeholder as NSString).length
                )
            case .prefixLine(let prefix):
                textView.text += "\(prefix)内容"
                textView.selectedRange = NSRange(
                    location: originalLength,
                    length: ((prefix + "内容") as NSString).length
                )
            }
            if !textView.isFirstResponder {
                textView.becomeFirstResponder()
            }
            finishProgrammaticChange(with: textView.text)
        }

        private func clearPendingCommand() {
            DispatchQueue.main.async {
                self.command.wrappedValue = nil
            }
        }

        private func finishProgrammaticChange(with updatedText: String) {
            DispatchQueue.main.async {
                self.text.wrappedValue = updatedText
                self.isApplyingProgrammaticChange = false
                self.clearPendingCommand()
            }
        }
    }
}
