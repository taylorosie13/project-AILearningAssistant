import Foundation
import Combine

nonisolated struct SavedVoiceCapture: Identifiable, Codable, Equatable {
    let id: UUID
    var transcript: String
    let languageCode: String
    let languageDisplayName: String
    let createdAt: Date
    let audioFileName: String

    var audioURL: URL {
        VoiceCaptureStore.audioDirectory.appendingPathComponent(audioFileName)
    }
}

@MainActor
final class VoiceCaptureStore: ObservableObject {
    @Published private(set) var captures: [SavedVoiceCapture] = []
    @Published private(set) var hasLoaded = false

    nonisolated private static let metadataURL = audioDirectory.appendingPathComponent("voice-captures.json")
    nonisolated static let audioDirectory: URL = {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = baseURL.appendingPathComponent("VoiceCaptures", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private var loadTask: Task<Void, Never>?

    init() {}

    func ensureLoaded() {
        guard !hasLoaded, loadTask == nil else { return }
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.load()
            self.loadTask = nil
        }
    }

    func saveCapture(transcript: String, language: TranscriptionLanguage, attachment: LocalAttachment) throws {
        guard let sourceURL = attachment.localURL else {
            throw VoiceCaptureStoreError.missingAudioFile
        }

        let fileName = "\(UUID().uuidString).m4a"
        let destinationURL = Self.audioDirectory.appendingPathComponent(fileName)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

        let capture = SavedVoiceCapture(
            id: UUID(),
            transcript: transcript,
            languageCode: language.localeIdentifier,
            languageDisplayName: language.displayName,
            createdAt: Date(),
            audioFileName: fileName
        )

        captures.insert(capture, at: 0)
        try persist()
    }

    func deleteCapture(_ capture: SavedVoiceCapture) {
        captures.removeAll { $0.id == capture.id }
        try? FileManager.default.removeItem(at: capture.audioURL)
        try? persist()
    }

    func updateCapture(_ capture: SavedVoiceCapture, transcript: String) throws {
        guard let index = captures.firstIndex(where: { $0.id == capture.id }) else { return }
        captures[index].transcript = transcript
        try persist()
    }

    private func load() async {
        let loadedCaptures = await Self.loadCapturesFromDisk()
        captures = loadedCaptures
        hasLoaded = true
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(captures)
        try data.write(to: Self.metadataURL, options: .atomic)
    }

    nonisolated private static func loadCapturesFromDisk() async -> [SavedVoiceCapture] {
        await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: metadataURL) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let decoded = try? decoder.decode([SavedVoiceCapture].self, from: data) else { return [] }
            return decoded.filter { FileManager.default.fileExists(atPath: $0.audioURL.path) }
        }.value
    }
}

enum VoiceCaptureStoreError: LocalizedError {
    case missingAudioFile

    var errorDescription: String? {
        switch self {
        case .missingAudioFile:
            return "找不到要保存的音频文件。"
        }
    }
}
