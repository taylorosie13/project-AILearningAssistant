import Foundation

struct ChatMessage: Identifiable, Codable {
    let id = UUID()
    let role: String
    let content: String
    var filePaths: [String]?
    
    enum CodingKeys: String, CodingKey {
        case role, content
        case filePaths = "file_paths"
    }
}

struct ChatResponse: Codable {
    let session_id: String
    let response: String
}

struct ChatSession: Identifiable, Codable {
    let id: String
    let created_at: String
    let preview: String?
    
    enum CodingKeys: String, CodingKey {
        case id = "session_id"
        case created_at, preview
    }
}

struct UploadResponse: Codable {
    let message: String
    let file_path: String
    let original_filename: String
}

// MARK: - 知识卡片相关模型
struct KnowledgeCard: Identifiable, Codable {
    let id: Int
    let title: String
    let content: String
    let source_session_id: String?
    let created_at: String
    
    enum CodingKeys: String, CodingKey {
        case id, title, content, created_at
        case source_session_id = "source_session_id"
    }
}

struct KnowledgeCardCreate: Codable {
    let title: String
    let content: String
    let source_session_id: String?
}
