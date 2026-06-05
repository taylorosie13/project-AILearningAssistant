import SwiftUI

struct VoiceWorkspaceView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case workspace = "语音工作台"
        case saved = "已保存内容"

        var id: String { rawValue }
    }

    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var noteViewModel: NoteViewModel
    @ObservedObject var store: VoiceCaptureStore
    let showsDismissButton: Bool
    let onReturnToChat: (() -> Void)?
    @StateObject private var voiceInputController = VoiceInputController()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var mode: Mode = .workspace
    @State private var draftTranscript: String = ""
    @State private var draftAttachment: LocalAttachment?
    @State private var editingCapture: SavedVoiceCapture?
    @State private var editingSavedTranscript: String = ""
    @State private var localAlert: ChatViewModel.AlertState?
    @State private var bannerTask: Task<Void, Never>?
    @State private var generatingNoteCaptureIDs: Set<UUID> = []

    init(
        viewModel: ChatViewModel,
        noteViewModel: NoteViewModel,
        store: VoiceCaptureStore,
        showsDismissButton: Bool = false,
        onReturnToChat: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.noteViewModel = noteViewModel
        self.store = store
        self.showsDismissButton = showsDismissButton
        self.onReturnToChat = onReturnToChat
    }

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            VStack(spacing: 16) {
                Picker("模式", selection: $mode) {
                    ForEach(Mode.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 12)

                if mode == .workspace {
                    workspaceContent
                } else {
                    savedContent
                }
            }

            if let alert = localAlert {
                VStack {
                    BannerView(
                        title: alert.title,
                        message: alert.message,
                        onClose: {
                            bannerTask?.cancel()
                            withAnimation {
                                localAlert = nil
                            }
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(2)
            }
        }
        .navigationTitle("语音转写")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDismissButton {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                        .foregroundColor(AppTheme.accent)
                }
            }
        }
        .task {
            store.ensureLoaded()
        }
        .onDisappear {
            bannerTask?.cancel()
            voiceInputController.cancelRecording()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .inactive, .background:
                if voiceInputController.isRecording {
                    voiceInputController.cancelRecording()
                    localAlert = .init(title: "录音已停止", message: "App 退到后台后，录音会先暂停。回到前台后可以重新开始录音。")
                }
            case .active:
                break
            @unknown default:
                voiceInputController.cancelRecording()
            }
        }
        .onChange(of: localAlert?.id) { _, newValue in
            bannerTask?.cancel()
            guard newValue != nil else { return }
            bannerTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { return }
                withAnimation {
                    localAlert = nil
                }
            }
        }
        .onChange(of: noteViewModel.activeAlert?.id) { _, newValue in
            guard newValue != nil, let alert = noteViewModel.activeAlert else { return }
            localAlert = alert
            noteViewModel.dismissAlert()
        }
        .sheet(item: $editingCapture) { capture in
            NavigationStack {
                SavedCaptureEditorSheet(
                    capture: capture,
                    transcript: $editingSavedTranscript,
                    onCancel: { editingCapture = nil },
                    onSave: { saveEditedCapture(capture) }
                )
            }
        }
        .navigationDestination(item: $noteViewModel.presentedNote) { note in
            NoteDetailView(
                note: note,
                noteViewModel: noteViewModel,
                chatViewModel: viewModel,
                onAskAI: { selectedNote in
                    viewModel.startNewChat(with: selectedNote)
                    returnToChat()
                }
            )
        }
    }

    private var workspaceContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                languageSelector
                recordingPanel
                if hasDraft {
                    draftPanel
                }
                contextPanel
            }
            .padding(16)
        }
    }

    private var savedContent: some View {
        Group {
            if store.captures.isEmpty {
                VStack(spacing: 18) {
                    Spacer()
                    Image(systemName: "waveform.badge.mic")
                        .font(.system(size: 42))
                        .foregroundColor(AppTheme.accent.opacity(0.35))
                    Text("还没有已保存的语音内容")
                        .font(.headline)
                        .foregroundColor(.gray)
                    Text("在语音工作台录音并点“保存内容”后，就会出现在这里。")
                        .font(.subheadline)
                        .foregroundColor(.gray.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                    Spacer()
                }
            } else {
                List {
                    ForEach(store.captures) { capture in
                        SavedVoiceCaptureRow(
                            capture: capture,
                            isGeneratingNote: generatingNoteCaptureIDs.contains(capture.id),
                            onEdit: { beginEditing(capture) },
                            onAskAI: { sendSavedCaptureToAI(capture) },
                            onGenerateNote: {
                                generateNote(from: capture)
                            }
                        )
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    .onDelete(perform: deleteSavedCaptures)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var languageSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("转写语言")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(AppTheme.accent)

            Menu {
                ForEach(TranscriptionLanguage.allCases) { language in
                    Button(language.displayName) {
                        selectLanguage(language)
                    }
                }
            } label: {
                HStack {
                    Label(voiceInputController.selectedLanguage.displayName, systemImage: "globe")
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.primary)
                .padding(14)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(voiceInputController.isRecording || voiceInputController.isTransitioningState)
        }
    }

    private var recordingPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("实时转写", systemImage: "waveform.badge.mic")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(voiceInputController.isRecording ? .red : AppTheme.accent)
                Spacer()
                Text(voiceInputController.statusText ?? "未开始")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }

            Text(currentTranscriptText)
                .font(.system(size: 15))
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            Button(action: toggleRecording) {
                HStack {
                    Spacer()
                    Image(systemName: voiceInputController.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                    Text(voiceInputController.isRecording ? "停止录音" : "开始录音")
                    Spacer()
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .padding(.vertical, 14)
                .background(voiceInputController.isRecording ? Color.red : AppTheme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .disabled(voiceInputController.isTransitioningState)
        }
        .padding(18)
        .background(Color(red: 0.94, green: 0.96, blue: 0.92))
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    private var draftPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("待处理内容", systemImage: "tray.full.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(AppTheme.accent)

            if let draftAttachment {
                SelectedAttachmentCard(attachment: draftAttachment)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            TextEditor(text: $draftTranscript)
                .font(.system(size: 15))
                .foregroundColor(.primary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 140)
                .padding(10)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            HStack(spacing: 10) {
                Button(action: saveCapture) {
                    Text("保存内容")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AppTheme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(AppTheme.userBubble)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                Button(action: sendToAI) {
                    Text("交给 AI 并提问")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(AppTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }

            Button("丢弃这次内容", role: .destructive) {
                clearPreparedContent(clearLiveTranscript: true)
            }
            .font(.system(size: 13, weight: .medium))
        }
        .padding(18)
        .background(Color(red: 0.96, green: 0.97, blue: 0.94))
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    private var contextPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("当前聊天上下文")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(AppTheme.accent)

            Text("如果你选择“交给 AI 并提问”，会把本次转写文字和录音附件一起加入当前聊天。聊天里已选的其他附件也会一并保留。")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            Text("加入聊天后不会立刻发送，你可以回到聊天页继续补充问题，再手动点发送。")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            if !viewModel.selectedAttachments.isEmpty {
                Text("当前聊天还挂着 \(viewModel.selectedAttachments.count) 个附件。")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private var hasDraft: Bool {
        !draftTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draftAttachment != nil
    }

    private var currentTranscriptText: String {
        let liveText = voiceInputController.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        return liveText.isEmpty ? "开始说话后，这里会实时显示转写文字。" : liveText
    }

    private func toggleRecording() {
        Task {
            do {
                if let result = try await voiceInputController.toggleRecording() {
                    draftTranscript = result.transcript
                    draftAttachment = result.attachment
                }
            } catch {
                localAlert = .init(title: "语音转写失败", message: error.localizedDescription)
            }
        }
    }

    private func saveCapture() {
        guard let draftAttachment else { return }
        do {
            try store.saveCapture(
                transcript: draftTranscript,
                language: voiceInputController.selectedLanguage,
                attachment: draftAttachment
            )
            clearPreparedContent(clearLiveTranscript: true)
            mode = .saved
        } catch {
            localAlert = .init(title: "保存失败", message: error.localizedDescription)
        }
    }

    private func sendToAI() {
        guard let draftAttachment else { return }
        viewModel.addAttachment(draftAttachment)

        let trimmedTranscript = draftTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if existing.isEmpty {
            viewModel.inputText = trimmedTranscript
        } else {
            viewModel.inputText = "\(viewModel.inputText)\n\(trimmedTranscript)"
        }

        clearPreparedContent(clearLiveTranscript: true)
        returnToChat()
    }

    private func sendSavedCaptureToAI(_ capture: SavedVoiceCapture) {
        viewModel.addAttachment(
            LocalAttachment(
                displayName: "voice-\(capture.createdAt.formatted(date: .numeric, time: .omitted)).m4a",
                fileKind: .audio,
                mimeType: "audio/m4a",
                localURL: capture.audioURL
            )
        )

        let existing = viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if existing.isEmpty {
            viewModel.inputText = capture.transcript
        } else {
            viewModel.inputText = "\(viewModel.inputText)\n\(capture.transcript)"
        }

        returnToChat()
    }

    private func clearPreparedContent(clearLiveTranscript: Bool = false) {
        draftTranscript = ""
        draftAttachment = nil
        if clearLiveTranscript {
            voiceInputController.clearPreparedTranscript()
        }
    }

    private func selectLanguage(_ language: TranscriptionLanguage) {
        guard voiceInputController.selectedLanguage != language else { return }
        voiceInputController.selectedLanguage = language
        clearPreparedContent(clearLiveTranscript: true)
    }

    private func deleteSavedCaptures(at offsets: IndexSet) {
        for index in offsets {
            store.deleteCapture(store.captures[index])
        }
    }

    private func beginEditing(_ capture: SavedVoiceCapture) {
        editingSavedTranscript = capture.transcript
        editingCapture = capture
    }

    private func saveEditedCapture(_ capture: SavedVoiceCapture) {
        let trimmedTranscript = editingSavedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            localAlert = .init(title: "保存失败", message: "已保存内容不能为空。")
            return
        }

        do {
            try store.updateCapture(capture, transcript: trimmedTranscript)
            editingCapture = nil
        } catch {
            localAlert = .init(title: "保存失败", message: error.localizedDescription)
        }
    }

    private func generateNote(from capture: SavedVoiceCapture) {
        guard !generatingNoteCaptureIDs.contains(capture.id) else { return }
        generatingNoteCaptureIDs.insert(capture.id)

        Task {
            _ = await noteViewModel.generateNote(from: capture)
            generatingNoteCaptureIDs.remove(capture.id)
        }
    }

    private func returnToChat() {
        if let onReturnToChat {
            onReturnToChat()
        } else {
            dismiss()
        }
    }
}

struct SavedVoiceCaptureRow: View {
    let capture: SavedVoiceCapture
    let isGeneratingNote: Bool
    let onEdit: () -> Void
    let onAskAI: () -> Void
    let onGenerateNote: () -> Void
    @StateObject private var player = AudioPreviewPlayer()
    @State private var isConfirmingNoteGeneration = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(capture.languageDisplayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppTheme.accent)
                    Text(capture.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: onEdit) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(AppTheme.accent)
                        .frame(width: 32, height: 32)
                        .background(AppTheme.userBubble)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("修改已保存内容")
            }

            Text(capture.transcript)
                .font(.system(size: 14))
                .foregroundColor(.primary)

            AudioAttachmentPreviewCard(
                attachment: LocalAttachment(
                    displayName: "saved-\(capture.createdAt.formatted(date: .numeric, time: .omitted)).m4a",
                    fileKind: .audio,
                    mimeType: "audio/m4a",
                    localURL: capture.audioURL
                ),
                player: player
            )

            HStack(spacing: 10) {
                Button(action: onAskAI) {
                    Label("问 AI", systemImage: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(AppTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)

                Button(action: { isConfirmingNoteGeneration = true }) {
                    Label(isGeneratingNote ? "整理中" : "整理成笔记", systemImage: "book.closed")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppTheme.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(AppTheme.userBubble)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(isGeneratingNote)
            }
        }
        .padding(.vertical, 8)
        .alert("整理成笔记？", isPresented: $isConfirmingNoteGeneration) {
            Button("取消", role: .cancel) {}
            Button("开始整理") {
                onGenerateNote()
            }
            .disabled(isGeneratingNote)
        } message: {
            Text("会根据这段语音转写生成一篇新笔记。")
        }
        .onDisappear {
            Task { @MainActor in
                player.stop()
            }
        }
    }
}

struct SavedCaptureEditorSheet: View {
    let capture: SavedVoiceCapture
    @Binding var transcript: String
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(capture.languageDisplayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppTheme.accent)
                Text(capture.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            TextEditor(text: $transcript)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 220)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            Spacer()
        }
        .padding(16)
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle("修改已保存内容")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("取消", action: onCancel)
                    .foregroundColor(AppTheme.accent)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("保存", action: onSave)
                    .foregroundColor(AppTheme.accent)
            }
        }
    }
}

extension VoiceInputController {
    var statusText: String? {
        guard isRecording else { return nil }
        let totalSeconds = Int(elapsedTime.rounded(.down))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "正在实时转写 \(String(format: "%02d:%02d", minutes, seconds))"
    }
}
