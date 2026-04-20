import Foundation
import Combine

@MainActor
final class NoteViewModel: ObservableObject {
    @Published private(set) var notes: [Note] = []
    @Published private(set) var isLoading = false
    @Published var activeAlert: ChatViewModel.AlertState?
    @Published var presentedNote: Note?

    private var hasLoadedInitialData = false

    func loadInitialDataIfNeeded() {
        guard !hasLoadedInitialData else { return }
        hasLoadedInitialData = true
        Task { await loadNotes(showError: false) }
    }

    func loadNotes(showError: Bool = true) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            notes = try await NetworkManager.shared.fetchNotes()
            activeAlert = nil
        } catch {
            guard showError else { return }
            presentError(error, fallback: "加载笔记失败")
        }
    }

    func fetchLatestNote(noteId: String) async -> Note? {
        do {
            let note = try await NetworkManager.shared.fetchNote(noteId: noteId)
            upsert(note)
            activeAlert = nil
            return note
        } catch {
            presentError(error, fallback: "加载笔记详情失败")
            return nil
        }
    }

    func createNote(
        title: String,
        contentMarkdown: String,
        summary: String?,
        category: String?,
        tags: [String]
    ) async -> Note? {
        let payload = NoteCreate(
            title: title,
            content_markdown: contentMarkdown,
            summary: summary,
            category: category,
            tags: tags,
            source_type: "manual",
            source_ref_id: nil,
            source_title: nil
        )

        do {
            let response = try await NetworkManager.shared.createNote(payload)
            let note = try await NetworkManager.shared.fetchNote(noteId: response.note_id)
            upsert(note)
            activeAlert = nil
            presentedNote = nil
            return note
        } catch {
            presentError(error, fallback: "保存笔记失败")
            return nil
        }
    }

    func updateNote(
        noteId: String,
        title: String,
        contentMarkdown: String,
        summary: String?,
        category: String?,
        tags: [String]
    ) async -> Note? {
        let payload = NoteUpdate(
            title: title,
            content_markdown: contentMarkdown,
            summary: summary,
            category: category,
            tags: tags
        )

        do {
            let response = try await NetworkManager.shared.updateNote(noteId: noteId, note: payload)
            let note = try await NetworkManager.shared.fetchNote(noteId: response.note_id)
            upsert(note)
            activeAlert = nil
            presentedNote = nil
            return note
        } catch {
            presentError(error, fallback: "更新笔记失败")
            return nil
        }
    }

    func deleteNote(_ note: Note) async {
        do {
            try await NetworkManager.shared.deleteNote(noteId: note.id)
            notes.removeAll { $0.id == note.id }
            activeAlert = nil
        } catch {
            presentError(error, fallback: "删除笔记失败")
        }
    }

    func generateNoteFromCurrentSession(sessionId: String, sessionTitle: String?) async -> Note? {
        let request = NoteGenerateRequest(
            source_type: "session",
            session_id: sessionId,
            source_text: nil,
            file_paths: nil,
            category: nil,
            tags: [],
            source_ref_id: sessionId,
            source_title: sessionTitle,
            title_hint: sessionTitle
        )
        return await generateNote(request, fallback: "整理会话笔记失败")
    }

    func generateNote(from message: ChatMessage) async -> Note? {
        let sourceType = inferSourceType(from: message)
        let titleHint = makeTitleHint(from: message.content, fallback: "聊天笔记")
        let request = NoteGenerateRequest(
            source_type: sourceType,
            session_id: nil,
            source_text: message.content,
            file_paths: message.filePaths,
            category: nil,
            tags: [],
            source_ref_id: nil,
            source_title: titleHint,
            title_hint: titleHint
        )
        return await generateNote(request, fallback: "整理消息笔记失败")
    }

    func generateNote(from capture: SavedVoiceCapture) async -> Note? {
        let title = makeTitleHint(from: capture.transcript, fallback: "语音整理")
        let request = NoteGenerateRequest(
            source_type: "audio",
            session_id: nil,
            source_text: capture.transcript,
            file_paths: nil,
            category: nil,
            tags: [],
            source_ref_id: capture.id.uuidString,
            source_title: title,
            title_hint: title
        )
        return await generateNote(request, fallback: "整理语音笔记失败")
    }

    func expandCardToNote(card: KnowledgeCard) async -> Note? {
        do {
            let response = try await NetworkManager.shared.expandCardToNote(cardId: card.id)
            upsert(response.note)
            activeAlert = nil
            presentedNote = response.note
            return response.note
        } catch {
            presentError(error, fallback: "扩展卡片笔记失败")
            return nil
        }
    }

    func extractCard(from note: Note) async {
        do {
            let response = try await NetworkManager.shared.extractKnowledgeCard(fromNoteId: note.id)
            activeAlert = .init(title: "卡片已生成", message: "\(response.message)")
        } catch {
            presentError(error, fallback: "提炼知识卡片失败")
        }
    }

    func dismissAlert() {
        activeAlert = nil
    }

    private func generateNote(_ request: NoteGenerateRequest, fallback: String) async -> Note? {
        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await NetworkManager.shared.generateNote(request)
            upsert(response.note)
            activeAlert = nil
            presentedNote = response.note
            return response.note
        } catch {
            presentError(error, fallback: fallback)
            return nil
        }
    }

    private func inferSourceType(from message: ChatMessage) -> String {
        guard let filePaths = message.filePaths, !filePaths.isEmpty else {
            return "message"
        }
        let attachments = filePaths.map(MessageAttachment.from(filePath:))
        if attachments.allSatisfy({ $0.fileKind == .audio }) {
            return "audio"
        }
        return "document"
    }

    private func makeTitleHint(from text: String, fallback: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return String(trimmed.prefix(20))
    }

    private func upsert(_ note: Note) {
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index] = note
        } else {
            notes.insert(note, at: 0)
        }
        notes.sort { lhs, rhs in
            if lhs.updated_at == rhs.updated_at {
                return lhs.id > rhs.id
            }
            return lhs.updated_at > rhs.updated_at
        }
    }

    private func presentError(_ error: Error, fallback: String) {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        activeAlert = .init(
            title: fallback,
            message: message.isEmpty ? "刚刚操作没成功，请稍后再试。" : message
        )
    }
}
