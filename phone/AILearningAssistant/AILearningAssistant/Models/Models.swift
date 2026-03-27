import Foundation
import UniformTypeIdentifiers
import UIKit

enum AttachmentKind: String, Codable {
    case image
    case document
    case audio

    var displayName: String {
        switch self {
        case .image:
            return "图片"
        case .document:
            return "文档"
        case .audio:
            return "音频"
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
        }
    }
}

enum AttachmentTransferState: Equatable {
    case idle
    case uploading
    case uploaded
    case failed

    var displayText: String {
        switch self {
        case .idle:
            return "待发送"
        case .uploading:
            return "上传中"
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

    init(
        id: UUID = UUID(),
        displayName: String,
        fileKind: AttachmentKind,
        mimeType: String,
        localURL: URL? = nil,
        data: Data? = nil,
        previewImage: UIImage? = nil,
        uploadedPath: String? = nil,
        transferState: AttachmentTransferState = .idle
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
    }

    static func == (lhs: LocalAttachment, rhs: LocalAttachment) -> Bool {
        lhs.id == rhs.id
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

    static func from(filePath: String) -> MessageAttachment {
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
    private static let imageExtensions = Set(["jpg", "jpeg", "png", "heic", "gif", "webp"])
    private static let documentExtensions = Set(["pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "txt", "md"])

    static func kind(forPath path: String) -> AttachmentKind {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if imageExtensions.contains(ext) {
            return .image
        }
        if documentExtensions.contains(ext) {
            return .document
        }
        return .audio
    }

    static func kind(for type: UTType) -> AttachmentKind {
        if type.conforms(to: .image) {
            return .image
        }
        if type.conforms(to: .audio) || type.conforms(to: .mpeg4Movie) {
            return .audio
        }
        return .document
    }

    static func mimeType(for type: UTType, fileExtension: String) -> String {
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
            return "audio/mp4"
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
        ]
    }
}

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
    let mime_type: String
    let file_kind: AttachmentKind
    let file_size: Int
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
