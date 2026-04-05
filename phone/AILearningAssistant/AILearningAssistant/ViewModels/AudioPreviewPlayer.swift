import Foundation
import AVFoundation
import Combine

@MainActor
final class AudioPreviewPlayer: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var preparedAttachmentID: UUID?

    func prepareDuration(for attachment: LocalAttachment) {
        guard attachment.fileKind == .audio else { return }
        guard preparedAttachmentID != attachment.id || duration == 0 else { return }

        preparedAttachmentID = attachment.id

        do {
            duration = try loadDuration(for: attachment)
            currentTime = 0
        } catch {
            duration = 0
            currentTime = 0
        }
    }

    func togglePlayback(for attachment: LocalAttachment) {
        prepareDuration(for: attachment)

        if isPlaying {
            stop()
            return
        }

        do {
            try startPlayback(for: attachment)
        } catch {
            stop()
        }
    }

    func stop() {
        player?.stop()
        player = nil
        timer?.invalidate()
        timer = nil
        isPlaying = false
        currentTime = 0

        #if os(iOS) || os(visionOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func startPlayback(for attachment: LocalAttachment) throws {
        guard attachment.fileKind == .audio else { return }

        #if os(iOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        let audioPlayer: AVAudioPlayer
        if let data = attachment.data {
            audioPlayer = try AVAudioPlayer(data: data)
        } else if let localURL = attachment.localURL {
            let hasAccess = localURL.startAccessingSecurityScopedResource()
            defer {
                if hasAccess {
                    localURL.stopAccessingSecurityScopedResource()
                }
            }
            audioPlayer = try AVAudioPlayer(contentsOf: localURL)
        } else {
            throw AudioPreviewError.fileUnavailable
        }

        audioPlayer.delegate = self
        audioPlayer.prepareToPlay()
        guard audioPlayer.play() else {
            throw AudioPreviewError.unableToPlay
        }

        preparedAttachmentID = attachment.id
        player = audioPlayer
        duration = audioPlayer.duration
        currentTime = audioPlayer.currentTime
        isPlaying = true
        startTimer()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                self.duration = player.duration
            }
        }
    }

    private func loadDuration(for attachment: LocalAttachment) throws -> TimeInterval {
        if let data = attachment.data {
            return try AVAudioPlayer(data: data).duration
        }

        if let localURL = attachment.localURL {
            let hasAccess = localURL.startAccessingSecurityScopedResource()
            defer {
                if hasAccess {
                    localURL.stopAccessingSecurityScopedResource()
                }
            }
            return try AVAudioPlayer(contentsOf: localURL).duration
        }

        throw AudioPreviewError.fileUnavailable
    }
}

extension AudioPreviewPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.stop()
        }
    }
}

enum AudioPreviewError: LocalizedError {
    case fileUnavailable
    case unableToPlay

    var errorDescription: String? {
        switch self {
        case .fileUnavailable:
            return "找不到可预览的音频文件。"
        case .unableToPlay:
            return "音频暂时无法播放，请重新录制或重新选择文件。"
        }
    }
}
