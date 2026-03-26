import Foundation

struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let role: String
    let content: String
    var filePaths: [String]?

    init(id: UUID = UUID(), role: String, content: String, filePaths: [String]? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.filePaths = filePaths
    }
    
    enum CodingKeys: String, CodingKey {
        case role, content
        case filePaths = "file_paths"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.role = try container.decode(String.self, forKey: .role)
        self.content = try container.decode(String.self, forKey: .content)
        self.filePaths = try container.decodeIfPresent([String].self, forKey: .filePaths)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(filePaths, forKey: .filePaths)
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
    let category: String?
    let tags: [String]
    let source_session_id: String?
    let created_at: String
    
    enum CodingKeys: String, CodingKey {
        case id, title, content, category, tags, created_at
        case source_session_id = "source_session_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        content = try container.decode(String.self, forKey: .content)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        source_session_id = try container.decodeIfPresent(String.self, forKey: .source_session_id)
        created_at = try container.decode(String.self, forKey: .created_at)
    }
}

struct KnowledgeCardCreate: Codable {
    let title: String
    let content: String
    let category: String?
    let tags: [String]
    let source_session_id: String?
}

struct KnowledgeCardUpdate: Codable {
    let title: String
    let content: String
    let category: String?
    let tags: [String]
}
