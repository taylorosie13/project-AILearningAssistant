import Foundation
import SwiftUI
import Combine
import PhotosUI

@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isLoading: Bool = false
    
    // 多模态支持：选中的图片
    @Published var selectedImages: [UIImage] = []
    
    // 历史会话支持
    @Published var sessions: [ChatSession] = []
    @Published var selectedSessionId: String? = nil
    
    // 知识卡片
    @Published var knowledgeCards: [KnowledgeCard] = []
    @Published var showingCardEditor: Bool = false
    @Published var editingCardTitle: String = ""
    @Published var editingCardContent: String = ""
    
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
    
    var currentSessionId: String? = nil
    
    init() {
        Task {
            await loadSessions()
            await loadKnowledgeCards()
        }
    }
    
    func loadKnowledgeCards() async {
        do {
            let fetched = try await NetworkManager.shared.fetchKnowledgeCards()
            await MainActor.run {
                self.knowledgeCards = fetched
            }
        } catch {
            print("Error loading cards: \(error)")
        }
    }

    func prepareCardForEditing(content: String) {
        // 优先使用传入的内容（如全量收藏），如果传入为空则尝试使用锁定的局部选区
        let finalContent = content.isEmpty ? lockedSelectedText : content
        guard !finalContent.isEmpty else { return }
        
        // 智能生成初始标题
        let lines = finalContent.components(separatedBy: .newlines)
        let firstLine = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        let cleanTitle = firstLine.trimmingCharacters(in: .whitespacesAndNewlines).prefix(15)
        
        self.editingCardTitle = String(cleanTitle) + (firstLine.count > 15 ? "..." : "")
        self.editingCardContent = finalContent
        
        DispatchQueue.main.async {
            self.showingCardEditor = true
        }
    }

    func confirmSaveCard() {
        let card = KnowledgeCardCreate(
            title: editingCardTitle,
            content: editingCardContent,
            source_session_id: currentSessionId
        )

        Task {
            do {
                _ = try await NetworkManager.shared.createKnowledgeCard(card: card)
                await loadKnowledgeCards()
                await MainActor.run {
                    self.showingCardEditor = false
                }
            } catch {
                print("Error saving card: \(error)")
            }
        }
    }

    func saveAsKnowledgeCard(message: ChatMessage) {
        // 调用预处理，传入空字符串表示尝试使用锁定的局部选区
        prepareCardForEditing(content: message.content)
    }

    func deleteKnowledgeCard(_ card: KnowledgeCard) {
        Task {
            do {
                try await NetworkManager.shared.deleteKnowledgeCard(cardId: card.id)
                await loadKnowledgeCards()
            } catch {
                print("Error deleting card: \(error)")
            }
        }
    }
    
    func loadSessions() async {
        do {
            let fetched = try await NetworkManager.shared.getSessions()
            await MainActor.run {
                self.sessions = fetched
            }
        } catch {
            print("Error loading sessions: \(error)")
        }
    }
    
    func startNewChat() {
        self.messages = []
        self.currentSessionId = nil
        self.selectedSessionId = nil
        self.inputText = ""
        self.selectedImages = []
    }
    
    func selectSession(_ session: ChatSession) {
        self.currentSessionId = session.id
        self.selectedSessionId = session.id
        self.messages = [] 
        isLoading = true
        
        Task {
            do {
                let history = try await NetworkManager.shared.getSessionMessages(sessionId: session.id)
                await MainActor.run {
                    self.messages = history
                    self.isLoading = false
                }
            } catch {
                print("Error selecting session: \(error)")
                await MainActor.run { self.isLoading = false }
            }
        }
    }
    
    func deleteSession(at indexSet: IndexSet) {
        let sessionsToDelete = indexSet.map { sessions[$0] }
        
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            sessions.remove(atOffsets: indexSet)
            for session in sessionsToDelete {
                if session.id == self.currentSessionId {
                    self.messages = []
                    self.currentSessionId = nil
                    self.selectedSessionId = nil
                    self.inputText = ""
                    self.selectedImages = []
                }
            }
        }
        
        Task {
            for session in sessionsToDelete {
                do {
                    try await NetworkManager.shared.deleteSession(sessionId: session.id)
                } catch {
                    print("Error deleting session: \(error)")
                }
            }
        }
    }
    
    func sendMessage() {
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !selectedImages.isEmpty else { return }
        
        let textToSend = inputText
        let imagesToSend = selectedImages
        
        let userMsg = ChatMessage(role: "user", content: textToSend, filePaths: nil)
        messages.append(userMsg)
        
        inputText = ""
        selectedImages = []
        isLoading = true
        
        Task {
            do {
                var uploadedFilePaths: [String] = []
                for (index, image) in imagesToSend.enumerated() {
                    if let data = image.jpegData(compressionQuality: 0.7) {
                        let uploadResp = try await NetworkManager.shared.uploadFile(
                            imageData: data,
                            fileName: "image_\(index).jpg"
                        )
                        uploadedFilePaths.append(uploadResp.file_path)
                    }
                }
                
                if !uploadedFilePaths.isEmpty {
                    if let lastIndex = self.messages.lastIndex(where: { $0.role == "user" }) {
                        self.messages[lastIndex].filePaths = uploadedFilePaths
                    }
                }
                
                let response = try await NetworkManager.shared.sendMessage(
                    prompt: textToSend,
                    sessionId: currentSessionId,
                    filePaths: uploadedFilePaths.isEmpty ? nil : uploadedFilePaths
                )
                
                self.currentSessionId = response.session_id
                let aiMsg = ChatMessage(role: "model", content: response.response, filePaths: nil)
                self.messages.append(aiMsg)
                
            } catch {
                print("Error sending message: \(error)")
                let errorMsg = ChatMessage(role: "model", content: "⚠️ 网络错误: \(error.localizedDescription)", filePaths: nil)
                self.messages.append(errorMsg)
            }
            self.isLoading = false
        }
    }
    
    func removeImage(at index: Int) {
        selectedImages.remove(at: index)
    }
}
