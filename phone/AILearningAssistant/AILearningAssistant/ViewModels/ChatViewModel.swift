import Foundation
import SwiftUI
import Combine
import PhotosUI
import UniformTypeIdentifiers

@MainActor
class ChatViewModel: ObservableObject {
    struct AlertState: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    enum ProcessingStage {
        case idle
        case uploadingFile(String)
        case preparingDocuments(Int)
        case requestingModel

        var statusText: String? {
            switch self {
            case .idle:
                return nil
            case .uploadingFile(let fileName):
                return "正在上传 \(fileName)..."
            case .preparingDocuments(let count):
                return count == 1 ? "正在转换文档" : "正在转换 \(count) 个文档"
            case .requestingModel:
                return "魔法施展中..."
            }
        }
    }

    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published private(set) var isLoading: Bool = false
    @Published var activeAlert: AlertState?
    @Published private(set) var processingStage: ProcessingStage = .idle
    
    // 多模态支持：选中的附件
    @Published var selectedAttachments: [LocalAttachment] = []
    
    // 历史会话支持
    @Published var sessions: [ChatSession] = []
    @Published var selectedSessionId: String? = nil
    
    // 知识卡片
    @Published var knowledgeCards: [KnowledgeCard] = []
    @Published var showingCardEditor: Bool = false
    @Published var editingCardTitle: String = ""
    @Published var editingCardContent: String = ""
    @Published var editingCardCategory: String = ""
    @Published var editingCardTagsText: String = ""
    @Published var editingCardID: Int?
    
    // 追踪用户在 WebView 中选中的文本
    @Published var lastSelectedText: String = "" {
        didSet {
            // 只有当新选中的文本非空时才真正锁定记录，防止失去焦点时被清空
            if !lastSelectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.lockedSelectedText = lastSelectedText
            }
        }
    }
    // 核心锁定区：存储最后一次有效的选区内容
    private var lockedSelectedText: String = ""
    private var isSendingMessage = false {
        didSet { syncLoadingState() }
    }
    private var isLoadingSession = false {
        didSet { syncLoadingState() }
    }
    private var activeSessionLoadID = UUID()
    private var activeSendID = UUID()
    private var sessionLoadTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var hasLoadedInitialData = false
    
    var currentSessionId: String? = nil
    
    init() {}

    func loadInitialDataIfNeeded() {
        guard !hasLoadedInitialData else { return }
        hasLoadedInitialData = true

        Task {
            async let sessionsTask: Void = loadSessions()
            async let knowledgeCardsTask: Void = loadKnowledgeCards()
            _ = await (sessionsTask, knowledgeCardsTask)
        }
    }

    private func presentError(_ error: Error, fallback: String) {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedMessage = message.isEmpty ? fallback : message
        let errorID = makeErrorID()
        activeAlert = AlertState(
            title: alertTitle(for: fallback, message: resolvedMessage),
            message: "\(resolvedMessage)\n错误ID：\(errorID)"
        )
        print("[\(errorID)] \(fallback): \(error)")
    }

    func dismissAlert() {
        activeAlert = nil
    }

    private func alertTitle(for fallback: String, message: String) -> String {
        let lowered = message.lowercased()

        if message.contains("文件太大")
            || message.contains("空的")
            || message.contains("类型")
            || message.contains("文件名") {
            return "这个文件有点问题"
        }

        if lowered.contains("网络")
            || message.contains("没有联网")
            || message.contains("连不上服务")
            || message.contains("超时")
            || message.contains("断开") {
            return "网络出了点问题"
        }

        if message.contains("服务有点异常")
            || message.contains("服务有点忙")
            || message.contains("服务器处理")
            || message.contains("服务器开小差") {
            return "服务器开小差了"
        }

        if fallback.contains("发送") {
            return "消息发送失败"
        }
        if fallback.contains("上传") {
            return "文件上传失败"
        }
        if fallback.contains("加载") {
            return "加载失败"
        }
        if fallback.contains("删除") {
            return "删除失败"
        }
        if fallback.contains("保存") {
            return "保存未成功"
        }
        return "出了点小状况"
    }

    private func makeErrorID() -> String {
        String(UUID().uuidString.prefix(8)).uppercased()
    }
    
    func loadKnowledgeCards() async {
        do {
            let fetched = try await NetworkManager.shared.fetchKnowledgeCards()
            self.knowledgeCards = fetched
        } catch {
            presentError(error, fallback: "加载知识卡片失败")
        }
    }

    func prepareCardForEditing(content: String) {
        // 优先使用传入的内容（如全量收藏），如果传入为空则尝试使用锁定的局部选区
        let finalContent = content.isEmpty ? lockedSelectedText : content
        guard !finalContent.isEmpty else { return }
        editingCardID = nil
        
        // 智能生成初始标题
        let lines = finalContent.components(separatedBy: .newlines)
        let firstLine = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        let cleanTitle = firstLine.trimmingCharacters(in: .whitespacesAndNewlines).prefix(15)
        
        self.editingCardTitle = String(cleanTitle) + (firstLine.count > 15 ? "..." : "")
        self.editingCardContent = finalContent
        self.editingCardCategory = ""
        self.editingCardTagsText = ""
        
        self.showingCardEditor = true
    }

    func prepareExistingCardForEditing(_ card: KnowledgeCard) {
        editingCardID = card.id
        editingCardTitle = card.title
        editingCardContent = card.content
        editingCardCategory = card.category ?? ""
        editingCardTagsText = card.tags.joined(separator: ", ")
        showingCardEditor = true
    }

    func confirmSaveCard() {
        let trimmedTitle = editingCardTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContent = editingCardContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCategory = editingCardCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTags = parseTags(from: editingCardTagsText)
        guard !trimmedTitle.isEmpty, !trimmedContent.isEmpty else { return }

        Task {
            do {
                if let editingCardID {
                    let card = KnowledgeCardUpdate(
                        title: trimmedTitle,
                        content: trimmedContent,
                        category: trimmedCategory.isEmpty ? nil : trimmedCategory,
                        tags: normalizedTags
                    )
                    _ = try await NetworkManager.shared.updateKnowledgeCard(cardId: editingCardID, card: card)
                } else {
                    let card = KnowledgeCardCreate(
                        title: trimmedTitle,
                        content: trimmedContent,
                        category: trimmedCategory.isEmpty ? nil : trimmedCategory,
                        tags: normalizedTags,
                        source_session_id: currentSessionId
                    )
                    _ = try await NetworkManager.shared.createKnowledgeCard(card: card)
                }
                await loadKnowledgeCards()
                resetCardEditor()
                self.showingCardEditor = false
            } catch {
                presentError(error, fallback: "保存知识卡片失败")
            }
        }
    }

    func saveAsKnowledgeCard(message: ChatMessage) {
        // 调用预处理，传入空字符串表示尝试使用锁定的局部选区
        prepareCardForEditing(content: message.content)
    }

    func cancelCardEditing() {
        resetCardEditor()
        showingCardEditor = false
    }

    private func resetCardEditor() {
        editingCardID = nil
        editingCardTitle = ""
        editingCardContent = ""
        editingCardCategory = ""
        editingCardTagsText = ""
    }

    private func parseTags(from rawValue: String) -> [String] {
        rawValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func deleteKnowledgeCard(_ card: KnowledgeCard) {
        Task {
            do {
                try await NetworkManager.shared.deleteKnowledgeCard(cardId: card.id)
                await loadKnowledgeCards()
            } catch {
                presentError(error, fallback: "删除知识卡片失败")
            }
        }
    }
    
    func loadSessions() async {
        do {
            let fetched = try await NetworkManager.shared.getSessions()
            self.sessions = fetched
        } catch {
            presentError(error, fallback: "加载历史会话失败")
        }
    }
    
    func startNewChat() {
        activeAlert = nil
        activeSessionLoadID = UUID()
        activeSendID = UUID()
        sessionLoadTask?.cancel()
        sendTask?.cancel()
        self.messages = []
        self.currentSessionId = nil
        self.selectedSessionId = nil
        self.inputText = ""
        self.selectedAttachments = []
        self.isLoadingSession = false
        self.isSendingMessage = false
    }
    
    func selectSession(_ session: ChatSession) {
        activeAlert = nil
        let loadID = UUID()
        activeSessionLoadID = loadID
        activeSendID = UUID()
        sessionLoadTask?.cancel()
        sendTask?.cancel()
        self.currentSessionId = session.id
        self.selectedSessionId = session.id
        self.messages = [] 
        isLoadingSession = true
        isSendingMessage = false
        
        sessionLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let history = try await NetworkManager.shared.getSessionMessages(sessionId: session.id)

                guard !Task.isCancelled else { return }
                guard loadID == self.activeSessionLoadID, self.selectedSessionId == session.id else { return }

                self.messages = history
                self.isLoadingSession = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                guard loadID == self.activeSessionLoadID else { return }

                self.presentError(error, fallback: "加载会话记录失败")
                self.isLoadingSession = false
            }
        }
    }

    private func syncLoadingState() {
        isLoading = isSendingMessage || isLoadingSession
        if !isLoading {
            processingStage = .idle
        }
    }

    private func updateAttachmentState(id: UUID, state: AttachmentTransferState, uploadedPath: String? = nil) {
        guard let index = selectedAttachments.firstIndex(where: { $0.id == id }) else { return }
        var updatedAttachments = selectedAttachments
        updatedAttachments[index].transferState = state
        if let uploadedPath {
            updatedAttachments[index].uploadedPath = uploadedPath
        }
        selectedAttachments = updatedAttachments
    }

    private func resetAttachmentStatesToIdle() {
        var updatedAttachments = selectedAttachments
        for index in updatedAttachments.indices {
            updatedAttachments[index].transferState = .idle
            updatedAttachments[index].uploadedPath = nil
        }
        selectedAttachments = updatedAttachments
    }

    func sendMessage() {
        guard !isSendingMessage else { return }
        activeAlert = nil

        let trimmedInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty || !selectedAttachments.isEmpty else { return }

        let textToSend = trimmedInput
        let attachmentsToSend = selectedAttachments
        let localMessageID = UUID()
        let sendID = UUID()
        activeSendID = sendID
        
        let userMsg = ChatMessage(id: localMessageID, role: "user", content: textToSend, filePaths: nil)
        messages.append(userMsg)
        
        inputText = ""
        isSendingMessage = true
        
        sendTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isSendingMessage = false
                self.processingStage = .idle
            }

            do {
                var uploadedFilePaths: [String] = []
                for attachment in attachmentsToSend {
                    self.processingStage = .uploadingFile(attachment.displayName)
                    self.updateAttachmentState(id: attachment.id, state: .uploading)
                    let uploadResp = try await uploadAttachment(attachment)
                    uploadedFilePaths.append(uploadResp.file_path)
                    self.updateAttachmentState(id: attachment.id, state: .uploaded, uploadedPath: uploadResp.file_path)
                }

                guard !Task.isCancelled, sendID == self.activeSendID else { return }
                
                if !uploadedFilePaths.isEmpty,
                   let messageIndex = self.messages.firstIndex(where: { $0.id == localMessageID }) {
                    self.messages[messageIndex].filePaths = uploadedFilePaths
                }

                let officeDocumentCount = attachmentsToSend.filter(\.requiresServerDocumentPreparation).count
                self.processingStage = officeDocumentCount > 0
                    ? .preparingDocuments(officeDocumentCount)
                    : .requestingModel

                let response = try await NetworkManager.shared.sendMessage(
                    prompt: textToSend,
                    sessionId: self.currentSessionId,
                    filePaths: uploadedFilePaths.isEmpty ? nil : uploadedFilePaths
                )

                guard !Task.isCancelled, sendID == self.activeSendID else { return }
                
                self.processingStage = .requestingModel
                self.currentSessionId = response.session_id
                let aiMsg = ChatMessage(role: "model", content: response.response, filePaths: nil)
                self.messages.append(aiMsg)
                self.selectedAttachments = []
                
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, sendID == self.activeSendID else { return }
                if self.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.inputText = textToSend
                }
                self.messages.removeAll(where: { $0.id == localMessageID })
                for attachment in attachmentsToSend {
                    self.updateAttachmentState(id: attachment.id, state: .failed)
                }
                self.presentError(error, fallback: "发送消息失败")
            }
        }
    }

    func deleteSession(at indexSet: IndexSet) {
        let sessionsToDelete = indexSet.map { sessions[$0] }
        
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            sessions.remove(atOffsets: indexSet)
            for session in sessionsToDelete {
                if session.id == self.currentSessionId {
                    activeSessionLoadID = UUID()
                    activeSendID = UUID()
                    sessionLoadTask?.cancel()
                    sendTask?.cancel()
                    self.messages = []
                    self.currentSessionId = nil
                    self.selectedSessionId = nil
                    self.inputText = ""
                    self.selectedAttachments = []
                    self.isLoadingSession = false
                    self.isSendingMessage = false
                }
            }
        }
        
        Task {
            for session in sessionsToDelete {
                do {
                    try await NetworkManager.shared.deleteSession(sessionId: session.id)
                } catch {
                    presentError(error, fallback: "删除会话失败")
                }
            }
        }
    }
    
    func addPickedImage(_ image: UIImage) {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else { return }

        selectedAttachments.append(
            LocalAttachment(
                displayName: "image_\(selectedAttachments.count + 1).jpg",
                fileKind: .image,
                mimeType: "image/jpeg",
                data: imageData,
                previewImage: image
            )
        )
    }

    func addPickedFile(from url: URL) {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
            ?? .data

        guard type != .data else {
            activeAlert = AlertState(title: "添加文件失败", message: "无法识别这个文件的类型，请换一个文件后再试。")
            return
        }

        selectedAttachments.append(
            LocalAttachment(
                displayName: url.lastPathComponent,
                fileKind: AttachmentTypeResolver.kind(for: type),
                mimeType: AttachmentTypeResolver.mimeType(for: type, fileExtension: url.pathExtension),
                localURL: url
            )
        )
    }

    func addAttachment(_ attachment: LocalAttachment) {
        selectedAttachments.append(attachment)
    }

    func removeAttachment(at index: Int) {
        selectedAttachments.remove(at: index)
    }

    func retryAttachments() {
        resetAttachmentStatesToIdle()
        sendMessage()
    }

    private func uploadAttachment(_ attachment: LocalAttachment) async throws -> UploadResponse {
        do {
            if let data = attachment.data {
                return try await NetworkManager.shared.uploadFile(
                    data: data,
                    fileName: attachment.displayName,
                    mimeType: attachment.mimeType
                )
            }

            guard let localURL = attachment.localURL else {
                throw NetworkError.serverError(statusCode: -1, message: "找不到待上传的本地文件。")
            }

            let fileData = try await loadFileData(from: localURL)
            return try await NetworkManager.shared.uploadFile(
                data: fileData,
                fileName: attachment.displayName,
                mimeType: attachment.mimeType
            )
        } catch {
            throw contextualizedUploadError(error, fileName: attachment.displayName)
        }
    }

    nonisolated private func loadFileData(from localURL: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let hasAccess = localURL.startAccessingSecurityScopedResource()
            defer {
                if hasAccess {
                    localURL.stopAccessingSecurityScopedResource()
                }
            }

            return try Data(contentsOf: localURL)
        }.value
    }

    private func contextualizedUploadError(_ error: Error, fileName: String) -> Error {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeFileName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !safeFileName.isEmpty else { return error }
        guard !message.contains(safeFileName) else { return error }

        if let networkError = error as? NetworkError {
            switch networkError {
            case .serverError(let statusCode, let message):
                return NetworkError.serverError(statusCode: statusCode, message: "《\(safeFileName)》上传失败：\(message)")
            case .transportError(let message):
                return NetworkError.transportError(message: "《\(safeFileName)》上传失败：\(message)")
            default:
                return NetworkError.serverError(statusCode: -1, message: "《\(safeFileName)》上传失败：\(message)")
            }
        }

        return NetworkError.serverError(statusCode: -1, message: "《\(safeFileName)》上传失败：\(message)")
    }
}
