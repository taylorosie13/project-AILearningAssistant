import Foundation
import UniformTypeIdentifiers
import UIKit

nonisolated enum AttachmentKind: String, Codable {
    case image
    case document
    case audio
    case video

    var displayName: String {
        switch self {
        case .image:
            return "图片"
        case .document:
            return "文档"
        case .audio:
            return "音频"
        case .video:
            return "视频"
        }
    }

    var systemImageName: String {
        switch self {
        case .image:
            return "photo"
        case .document:
            return "doc.text"
        case .audio:
            return "waveform"
        case .video:
            return "video"
        }
    }
}

enum AttachmentTransferState: Equatable {
    case idle
    case uploading
    case processing
    case uploaded
    case failed

    var displayText: String {
        switch self {
        case .idle:
            return "待发送"
        case .uploading:
            return "上传中"
        case .processing:
            return "处理中"
        case .uploaded:
            return "已就绪"
        case .failed:
            return "失败"
        }
    }

    var systemImageName: String {
        switch self {
        case .idle:
            return "clock"
        case .uploading:
            return "arrow.up.circle"
        case .processing:
            return "sparkles"
        case .uploaded:
            return "checkmark.circle"
        case .failed:
            return "exclamationmark.circle"
        }
    }
}

struct LocalAttachment: Identifiable, Equatable {
    let id: UUID
    let displayName: String
    let fileKind: AttachmentKind
    let mimeType: String
    let localURL: URL?
    let data: Data?
    let previewImage: UIImage?
    var uploadedPath: String?
    var transferState: AttachmentTransferState
    var uploadProgress: Double
    var requiresUserQuestion: Bool

    init(
        id: UUID = UUID(),
        displayName: String,
        fileKind: AttachmentKind,
        mimeType: String,
        localURL: URL? = nil,
        data: Data? = nil,
        previewImage: UIImage? = nil,
        uploadedPath: String? = nil,
        transferState: AttachmentTransferState = .idle,
        uploadProgress: Double = 0,
        requiresUserQuestion: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.fileKind = fileKind
        self.mimeType = mimeType
        self.localURL = localURL
        self.data = data
        self.previewImage = previewImage
        self.uploadedPath = uploadedPath
        self.transferState = transferState
        self.uploadProgress = uploadProgress
        self.requiresUserQuestion = requiresUserQuestion
    }

    static func == (lhs: LocalAttachment, rhs: LocalAttachment) -> Bool {
        lhs.id == rhs.id
    }

    var renderIdentity: String {
        "\(id.uuidString)-\(transferState.displayText)-\(Int(uploadProgress * 100))-\(uploadedPath ?? "")-\(requiresUserQuestion)"
    }

    var requiresServerDocumentPreparation: Bool {
        guard fileKind == .document else { return false }
        let officeExtensions = Set(["doc", "docx", "ppt", "pptx", "xls", "xlsx"])
        let fileExtension = (localURL?.pathExtension.isEmpty == false ? localURL?.pathExtension : nil)
            ?? URL(fileURLWithPath: displayName).pathExtension
        return officeExtensions.contains(fileExtension.lowercased())
    }
}

struct MessageAttachment: Identifiable, Hashable {
    var id: String { filePath }
    let filePath: String
    let fileKind: AttachmentKind
    let displayName: String

    var fileExtension: String {
        URL(fileURLWithPath: filePath).pathExtension.uppercased()
    }

    nonisolated static func from(filePath: String) -> MessageAttachment {
        let fileName = URL(fileURLWithPath: filePath).lastPathComponent
        let displayName: String
        if let separatorRange = fileName.range(of: "__") {
            displayName = String(fileName[separatorRange.upperBound...])
        } else {
            displayName = fileName
        }

        let fileKind = AttachmentTypeResolver.kind(forPath: filePath)
        return MessageAttachment(filePath: filePath, fileKind: fileKind, displayName: displayName)
    }
}

enum AttachmentTypeResolver {
    nonisolated private static let imageExtensions = Set(["jpg", "jpeg", "png", "heic", "gif", "webp"])
    nonisolated private static let documentExtensions = Set(["pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "txt", "md"])
    nonisolated private static let videoExtensions = Set(["mp4", "mov", "m4v"])

    nonisolated static func kind(forPath path: String) -> AttachmentKind {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if imageExtensions.contains(ext) {
            return .image
        }
        if documentExtensions.contains(ext) {
            return .document
        }
        if videoExtensions.contains(ext) {
            return .video
        }
        return .audio
    }

    nonisolated static func kind(for type: UTType) -> AttachmentKind {
        if type.conforms(to: .image) {
            return .image
        }
        if type.conforms(to: .movie) || type.conforms(to: .video) {
            return .video
        }
        if type.conforms(to: .audio) || type.conforms(to: .mpeg4Movie) {
            return .audio
        }
        return .document
    }

    nonisolated static func mimeType(for type: UTType, fileExtension: String) -> String {
        if let mimeType = type.preferredMIMEType {
            return mimeType
        }
        switch fileExtension.lowercased() {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "heic":
            return "image/heic"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "pdf":
            return "application/pdf"
        case "doc":
            return "application/msword"
        case "docx":
            return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "ppt":
            return "application/vnd.ms-powerpoint"
        case "pptx":
            return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "xls":
            return "application/vnd.ms-excel"
        case "xlsx":
            return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "txt":
            return "text/plain"
        case "md":
            return "text/markdown"
        case "m4a":
            return "audio/m4a"
        case "mp3":
            return "audio/mpeg"
        case "wav":
            return "audio/wav"
        case "aac":
            return "audio/aac"
        case "mp4":
            return "video/mp4"
        case "mov":
            return "video/quicktime"
        case "m4v":
            return "video/x-m4v"
        default:
            return "application/octet-stream"
        }
    }
}

extension UTType {
    static var supportedChatAttachments: [UTType] {
        [
            .image,
            .pdf,
            .plainText,
            .text,
            .audio,
            .movie,
            UTType(filenameExtension: "doc") ?? .data,
            UTType(filenameExtension: "docx") ?? .data,
            UTType(filenameExtension: "ppt") ?? .data,
            UTType(filenameExtension: "pptx") ?? .data,
            UTType(filenameExtension: "xls") ?? .data,
            UTType(filenameExtension: "xlsx") ?? .data,
            UTType(filenameExtension: "md") ?? .data,
            UTType(filenameExtension: "m4a") ?? .audio,
            UTType(filenameExtension: "mp3") ?? .audio,
            UTType(filenameExtension: "wav") ?? .audio,
            UTType(filenameExtension: "aac") ?? .audio,
            UTType(filenameExtension: "mp4") ?? .movie,
            UTType(filenameExtension: "mov") ?? .movie,
            UTType(filenameExtension: "m4v") ?? .movie,
        ]
    }
}

enum LearningMode: String, Codable, CaseIterable, Identifiable {
    case normal
    case feynman

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal:
            return "普通问答"
        case .feynman:
            return "费曼学习法"
        }
    }

    var subtitle: String {
        switch self {
        case .normal:
            return "直接提问，直接回答"
        case .feynman:
            return "先让你讲清楚，再追问补漏洞"
        }
    }

    var systemImageName: String {
        switch self {
        case .normal:
            return "bubble.left.and.bubble.right"
        case .feynman:
            return "person.crop.rectangle.stack"
        }
    }
}

nonisolated struct StreamingTextSegment: Identifiable, Hashable {
    let id = UUID()
    let text: String
    let createdAt: Date
}

nonisolated struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let role: String
    var content: String
    var filePaths: [String]?
    var isStreaming: Bool
    var streamingSegments: [StreamingTextSegment]

    init(id: UUID = UUID(), role: String, content: String, filePaths: [String]? = nil, isStreaming: Bool = false, streamingSegments: [StreamingTextSegment] = []) {
        self.id = id
        self.role = role
        self.content = content
        self.filePaths = filePaths
        self.isStreaming = isStreaming
        self.streamingSegments = streamingSegments
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
        self.isStreaming = false
        self.streamingSegments = []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(filePaths, forKey: .filePaths)
    }
}

nonisolated struct ChatStreamEvent: Decodable {
    let session_id: String?
    let text: String?
    let response: String?
    let detail: String?
}

nonisolated struct ChatSession: Identifiable, Codable {
    let id: String
    let created_at: String
    let preview: String?
    
    enum CodingKeys: String, CodingKey {
        case id = "session_id"
        case created_at, preview
    }
}

nonisolated struct UploadResponse: Codable {
    let message: String
    let file_path: String
    let original_filename: String
    let mime_type: String
    let file_kind: AttachmentKind
    let file_size: Int
    let prepared_for_model: Bool
    let model_warning: String?
}

// MARK: - 知识卡片相关模型
nonisolated struct KnowledgeCard: Identifiable, Codable {
    let id: String
    let title: String
    let content: String
    let category: String?
    let tags: [String]
    let source_session_id: String?
    let created_at: String
    
    enum CodingKeys: String, CodingKey {
        case title, content, category, tags, created_at
        case id = "card_id"
        case source_session_id = "source_session_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        content = try container.decode(String.self, forKey: .content)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        source_session_id = try container.decodeIfPresent(String.self, forKey: .source_session_id)
        created_at = try container.decode(String.self, forKey: .created_at)
    }
}

nonisolated struct KnowledgeCardCreate: Codable {
    let title: String
    let content: String
    let category: String?
    let tags: [String]
    let source_session_id: String?
}

nonisolated struct KnowledgeCardUpdate: Codable {
    let title: String
    let content: String
    let category: String?
    let tags: [String]
}

// MARK: - 笔记相关模型
nonisolated struct Note: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let content_markdown: String
    let summary: String?
    let category: String?
    let tags: [String]
    let source_type: String
    let source_ref_id: String?
    let source_title: String?
    let created_at: String
    let updated_at: String

    var sourceDisplayName: String {
        switch source_type {
        case "session":
            return "会话整理"
        case "message":
            return "消息整理"
        case "document":
            return "文档整理"
        case "audio":
            return "语音整理"
        case "card":
            return "卡片扩展"
        default:
            return "手动创建"
        }
    }

    var sourceDescription: String {
        let title = source_title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, !title.isEmpty {
            return "\(sourceDisplayName) · \(title)"
        }
        if let ref = source_ref_id, !ref.isEmpty {
            return "\(sourceDisplayName) · \(ref)"
        }
        return sourceDisplayName
    }

    var detailContentMarkdown: String {
        var lines = content_markdown.components(separatedBy: .newlines)

        func trimLeadingBlankLines() {
            while let first = lines.first, first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.removeFirst()
            }
        }

        trimLeadingBlankLines()

        // 详情页顶部已经展示了标题，这里把 Markdown 开头重复的一级标题去掉。
        if let first = lines.first, first.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("# ") {
            lines.removeFirst()
        }

        trimLeadingBlankLines()

        // 摘要卡片已经单独展示过，就不在正文里再显示一次。
        if let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let first = lines.first,
           first.trimmingCharacters(in: .whitespacesAndNewlines) == "## 摘要" {
            lines.removeFirst()
            while let first = lines.first {
                let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("## ") {
                    break
                }
                lines.removeFirst()
            }
        }

        trimLeadingBlankLines()

        // “正文”这个小标题已经由外层卡片承担了。
        if let first = lines.first, first.trimmingCharacters(in: .whitespacesAndNewlines) == "## 正文" {
            lines.removeFirst()
        }

        let cleaned = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? content_markdown : cleaned
    }
}

nonisolated struct NoteCreate: Codable {
    let title: String
    let content_markdown: String
    let summary: String?
    let category: String?
    let tags: [String]
    let source_type: String
    let source_ref_id: String?
    let source_title: String?
}

nonisolated struct NoteUpdate: Codable {
    let title: String
    let content_markdown: String
    let summary: String?
    let category: String?
    let tags: [String]
}

nonisolated struct NoteGenerateRequest: Codable {
    let source_type: String
    let session_id: String?
    let source_text: String?
    let file_paths: [String]?
    let category: String?
    let tags: [String]
    let source_ref_id: String?
    let source_title: String?
    let title_hint: String?
}

nonisolated struct NoteMutationResponse: Codable {
    let message: String
    let note_id: String
}

nonisolated struct NoteGenerationResponse: Codable {
    let message: String
    let note_id: String
    let note: Note
}

nonisolated struct CardExtractionResponse: Codable {
    let message: String
    let card_id: String
}
