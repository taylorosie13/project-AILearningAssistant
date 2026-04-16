import SwiftUI

struct NoteDetailView: View {
    let note: Note
    @ObservedObject var noteViewModel: NoteViewModel
    @ObservedObject var chatViewModel: ChatViewModel

    @State private var currentNote: Note
    @State private var editingDraft: NoteDraft?
    @State private var showingSourceInfo = false

    init(note: Note, noteViewModel: NoteViewModel, chatViewModel: ChatViewModel) {
        self.note = note
        self.noteViewModel = noteViewModel
        self.chatViewModel = chatViewModel
        _currentNote = State(initialValue: note)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerCard

                if let summary = currentNote.summary, !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("摘要")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundColor(AppTheme.accent)
                        Text(summary)
                            .font(.system(size: 15))
                            .foregroundColor(.primary)
                    }
                    .padding(18)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .shadow(color: AppTheme.shadow, radius: 4, x: 0, y: 2)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("正文")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(AppTheme.accent)
                    MarkdownView(content: currentNote.content_markdown, viewModel: chatViewModel)
                }
                .padding(18)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .shadow(color: AppTheme.shadow, radius: 4, x: 0, y: 2)

                HStack(spacing: 12) {
                    Button(action: { editingDraft = NoteDraft(note: currentNote) }) {
                        Label("编辑笔记", systemImage: "square.and.pencil")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(AppTheme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(AppTheme.userBubble)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }

                    Button(action: extractKnowledgeCard) {
                        Label("提炼卡片", systemImage: "archivebox")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(AppTheme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .padding(16)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle("笔记详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingSourceInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundColor(AppTheme.accent)
                }
            }
        }
        .task {
            if let latest = await noteViewModel.fetchLatestNote(noteId: note.id) {
                currentNote = latest
            }
        }
        .navigationDestination(item: $editingDraft) { draft in
            NoteEditView(draft: draft, noteViewModel: noteViewModel) { updatedNote in
                currentNote = updatedNote
            }
        }
        .alert("来源信息", isPresented: $showingSourceInfo) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(currentNote.sourceDescription)
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(currentNote.title)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundColor(AppTheme.accent)

            HStack(spacing: 8) {
                InfoChip(
                    text: currentNote.category?.isEmpty == false ? currentNote.category! : "未分类",
                    icon: "folder.fill",
                    background: AppTheme.userBubble.opacity(0.9),
                    foreground: AppTheme.accent
                )

                ForEach(currentNote.tags, id: \.self) { tag in
                    InfoChip(
                        text: tag,
                        icon: "number",
                        background: Color.orange.opacity(0.12),
                        foreground: Color.orange.opacity(0.85)
                    )
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("来源：\(currentNote.sourceDescription)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                Text("更新：\(String(currentNote.updated_at.prefix(16)))")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .padding(18)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: AppTheme.shadow, radius: 4, x: 0, y: 2)
    }

    private func extractKnowledgeCard() {
        Task {
            await noteViewModel.extractCard(from: currentNote)
            await chatViewModel.loadKnowledgeCards()
        }
    }
}
