import Foundation
import AVFoundation
import Combine
import Speech

enum TranscriptionLanguage: String, CaseIterable, Identifiable {
    case chineseSimplified = "zh-CN"
    case englishUS = "en-US"
    case korean = "ko-KR"
    case japanese = "ja-JP"

    var id: String { rawValue }

    var localeIdentifier: String { rawValue }

    var displayName: String {
        switch self {
        case .chineseSimplified:
            return "中文"
        case .englishUS:
            return "English"
        case .korean:
            return "韩语"
        case .japanese:
            return "日语"
        }
    }
}

@MainActor
final class VoiceInputController: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isTransitioningState = false
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var transcriptText: String = ""
    @Published var selectedLanguage: TranscriptionLanguage = .chineseSimplified

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var timer: Timer?
    private var currentRecordingURL: URL?
    private var audioFile: AVAudioFile?

    func toggleRecording() async throws -> VoiceCaptureResult? {
        guard !isTransitioningState else { return nil }
        isTransitioningState = true
        defer { isTransitioningState = false }

        if isRecording {
            return try stopRecording()
        }

        do {
            try await startRecording()
            return nil
        } catch {
            stopRecognitionSession(resetTranscript: true)
            throw error
        }
    }

    func cancelRecording() {
        stopRecognitionSession(resetTranscript: true)
    }

    func clearPreparedTranscript() {
        guard !isRecording else { return }
        transcriptText = ""
        elapsedTime = 0
    }

    private func startRecording() async throws {
        guard let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: selectedLanguage.localeIdentifier)) else {
            throw VoiceInputError.recognizerUnavailable
        }

        let hasRecordPermission = await requestMicrophonePermission()
        guard hasRecordPermission else {
            throw VoiceInputError.microphonePermissionDenied
        }

        let hasSpeechPermission = await requestSpeechPermission()
        guard hasSpeechPermission else {
            throw VoiceInputError.speechPermissionDenied
        }

        guard speechRecognizer.isAvailable else {
            throw VoiceInputError.recognizerUnavailable
        }

        transcriptText = ""
        elapsedTime = 0
        currentRecordingURL = nil
        audioFile = nil

        #if os(iOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(iOS 13.0, visionOS 1.0, *) {
            request.requiresOnDeviceRecognition = false
        }

        recognitionRequest = request

        let audioEngine = AVAudioEngine()
        self.audioEngine = audioEngine
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw VoiceInputError.microphoneUnavailable
        }

        let outputURL = makeRecordingURL()
        let audioFile = try AVAudioFile(forWriting: outputURL, settings: recordingSettings(for: format))
        self.audioFile = audioFile
        currentRecordingURL = outputURL
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
            try? audioFile.write(from: buffer)
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let result {
                    self.transcriptText = result.bestTranscription.formattedString
                }

                if error != nil {
                    self.stopRecognitionSession(resetTranscript: false)
                }
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true
        startTimer()
    }

    private func stopRecording() throws -> VoiceCaptureResult {
        guard isRecording else {
            throw VoiceInputError.emptyTranscript
        }

        let finalTranscript = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let recordingURL = currentRecordingURL
        stopRecognitionSession(resetTranscript: false)

        guard !finalTranscript.isEmpty else {
            throw VoiceInputError.emptyTranscript
        }

        guard let recordingURL,
              FileManager.default.fileExists(atPath: recordingURL.path) else {
            throw VoiceInputError.audioFileMissing
        }

        let attachment = LocalAttachment(
            displayName: "recording-\(Self.timestampFormatter.string(from: Date())).m4a",
            fileKind: .audio,
            mimeType: "audio/m4a",
            localURL: recordingURL
        )

        return VoiceCaptureResult(
            transcript: finalTranscript,
            attachment: attachment
        )
    }

    private func stopRecognitionSession(resetTranscript: Bool) {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        audioFile = nil

        timer?.invalidate()
        timer = nil
        isRecording = false
        elapsedTime = 0

        if resetTranscript {
            transcriptText = ""
            if let currentRecordingURL {
                try? FileManager.default.removeItem(at: currentRecordingURL)
            }
        }

        currentRecordingURL = nil

        #if os(iOS) || os(visionOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func requestMicrophonePermission() async -> Bool {
        #if os(iOS) || os(visionOS)
        return await withCheckedContinuation { continuation in
            if #available(iOS 17.0, visionOS 1.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
        #elseif os(macOS)
        return true
        #else
        return false
        #endif
    }

    private func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.elapsedTime += 0.5
            }
        }
    }

    private func makeRecordingURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-recording-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
    }

    private func recordingSettings(for format: AVAudioFormat) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 128_000,
        ]
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

enum VoiceInputError: LocalizedError {
    case microphonePermissionDenied
    case microphoneUnavailable
    case speechPermissionDenied
    case recognizerUnavailable
    case emptyTranscript
    case audioFileMissing

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "还没有获得麦克风权限。请在系统设置里允许访问麦克风后再试。"
        case .microphoneUnavailable:
            return "当前没有可用的麦克风输入，请检查模拟器或真机的录音输入设备。"
        case .speechPermissionDenied:
            return "还没有获得语音识别权限。请在系统设置里允许语音识别后再试。"
        case .recognizerUnavailable:
            return "语音识别当前不可用，请检查网络或稍后重试。"
        case .emptyTranscript:
            return "这次没有识别到可用文字，请重新说一遍。"
        case .audioFileMissing:
            return "录音已经结束，但音频文件没有保存成功，请重试一次。"
        }
    }
}

struct VoiceCaptureResult {
    let transcript: String
    let attachment: LocalAttachment
}
