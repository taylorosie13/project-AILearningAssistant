import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct PickedMediaFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            return Self(url: try copyPickedMediaFile(from: received.file))
        }
        FileRepresentation(importedContentType: .mpeg4Movie) { received in
            return Self(url: try copyPickedMediaFile(from: received.file))
        }
        FileRepresentation(importedContentType: .quickTimeMovie) { received in
            return Self(url: try copyPickedMediaFile(from: received.file))
        }
    }

    private static func copyPickedMediaFile(from sourceURL: URL) throws -> URL {
        let pathExtension = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("picked-media-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }
}

// MARK: - 主题配色
struct AppTheme {
    static let background = Color(red: 0.97, green: 0.97, blue: 0.95)
    static let userBubble = Color(red: 0.88, green: 0.92, blue: 0.88)
    static let aiBubble = Color.white
    static let accent = Color(red: 0.25, green: 0.35, blue: 0.25)
    static let shadow = Color.black.opacity(0.05)
    static let sidebarBackground = Color(red: 0.94, green: 0.94, blue: 0.92)
}

struct ChatView: View {
    @AppStorage(LaunchPermissionViewModel.localNetworkApprovalKey) private var startupLocalNetworkApproved = false
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var voiceCaptureStore = VoiceCaptureStore()
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var showFileImporter = false
    @State private var showVoiceWorkspace = false
    @State private var cameraImage: UIImage? = nil
    @State private var showSidebar = false
    @State private var bannerTask: Task<Void, Never>?
    
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let screenWidth = geometry.size.width
                
                ZStack {
                    AppTheme.background.ignoresSafeArea()
                    
                    VStack(spacing: 0) {
                        ScrollView {
                            ScrollViewReader { proxy in
                                LazyVStack(spacing: 24) {
                                    if viewModel.messages.isEmpty {
                                        EmptyStateView()
                                    } else {
                                        ForEach(viewModel.messages) { message in
                                            MessageBubble(message: message, viewModel: viewModel)
                                                .transition(.asymmetric(
                                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                                    removal: .opacity
                                                ))
                                        }
                                    }
                                    
                                    if viewModel.isLoading {
                                        HStack {
                                            LoadingIndicator(statusText: viewModel.processingStage.statusText)
                                                .padding(.leading, 20)
                                            Spacer()
                                        }
                                    }
                                }
                                .padding(.vertical, 20)
                                .onChange(of: viewModel.messages.count) { oldValue, newValue in
                                    withAnimation { scrollToBottom(proxy: proxy) }
                                }
                            }
                        }
                        
                        InputArea(
                            viewModel: viewModel,
                            selectedItems: $selectedItems,
                            showCamera: $showCamera,
                            showFileImporter: $showFileImporter,
                            showVoiceWorkspace: $showVoiceWorkspace
                        )
                        .opacity(showSidebar ? 0.3 : 1.0)
                    }

                    if let alert = viewModel.activeAlert {
                        VStack {
                            BannerView(
                                title: alert.title,
                                message: alert.message,
                                onClose: {
                                    bannerTask?.cancel()
                                    withAnimation {
                                        viewModel.dismissAlert()
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
                    
                    if showSidebar {
                        Color.black.opacity(0.2)
                            .ignoresSafeArea()
                            .onTapGesture {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showSidebar = false }
                            }
                    }
                    
                    // 侧边栏：使用 geometry 获取的动态宽度
                    SidebarView(
                        showSidebar: $showSidebar,
                        viewModel: viewModel,
                        voiceCaptureStore: voiceCaptureStore,
                        screenWidth: screenWidth
                    )
                        .offset(x: showSidebar ? 0 : -screenWidth * 0.8)
                }
                .navigationTitle(showSidebar ? "" : (viewModel.currentSessionId == nil ? "新会话" : "正在学习"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if !showSidebar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button(action: {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showSidebar.toggle() }
                                if showSidebar { Task { await viewModel.loadSessions() } }
                            }) {
                                Image(systemName: "line.3.horizontal")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(AppTheme.accent)
                            }
                        }
                        
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button(action: {
                                withAnimation { viewModel.startNewChat() }
                            }) {
                                Image(systemName: "square.and.pencil")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(AppTheme.accent)
                            }
                        }
                    }
                }
                .fullScreenCover(isPresented: $showCamera) {
                    ImagePicker(image: $cameraImage, sourceType: .camera)
                }
                .fileImporter(
                    isPresented: $showFileImporter,
                    allowedContentTypes: UTType.supportedChatAttachments,
                    allowsMultipleSelection: true
                ) { result in
                    switch result {
                    case .success(let urls):
                        for url in urls {
                            viewModel.addPickedFile(from: url)
                        }
                    case .failure(let error):
                        viewModel.activeAlert = .init(title: "选择文件失败", message: error.localizedDescription)
                    }
                }
                .sheet(isPresented: $viewModel.showingCardEditor) {
                    CardEditSheet(viewModel: viewModel)
                }
                .sheet(isPresented: $showVoiceWorkspace) {
                    NavigationStack {
                        VoiceWorkspaceView(
                            viewModel: viewModel,
                            store: voiceCaptureStore,
                            showsDismissButton: true
                        )
                    }
                }
                .onChange(of: viewModel.activeAlert?.id) { _, newValue in
                    bannerTask?.cancel()
                    guard newValue != nil else { return }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {}
                    bannerTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        guard !Task.isCancelled else { return }
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            viewModel.dismissAlert()
                        }
                    }
                }
                .onChange(of: cameraImage) { oldImage, newImage in
                    if let image = newImage {
                        viewModel.addPickedImage(image)
                        cameraImage = nil
                    }
                }
                .task {
                    guard startupLocalNetworkApproved else { return }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    viewModel.loadInitialDataIfNeeded()
                }
            }
            .preferredColorScheme(.light)
        }
    }
    
    private func scrollToBottom(proxy: ScrollViewProxy) {
        if let last = viewModel.messages.last {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
}

struct BannerView: View {
    let title: String
    let message: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18))
                .foregroundColor(Color(red: 0.78, green: 0.43, blue: 0.08))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(AppTheme.accent)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundColor(.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(6)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.98))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 4)
    }
}

// MARK: - 知识卡片编辑弹窗
struct CardEditSheet: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section("卡片标题") {
                    TextField("输入卡片标题...", text: $viewModel.editingCardTitle)
                }
                Section("分类") {
                    TextField("例如：数学 / 物理 / 英语", text: $viewModel.editingCardCategory)
                }
                Section("标签") {
                    TextField("用逗号分隔多个标签", text: $viewModel.editingCardTagsText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("卡片内容") {
                    TextEditor(text: $viewModel.editingCardContent)
                        .frame(minHeight: 200)
                }
            }
            .navigationTitle("存为知识卡片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        viewModel.cancelCardEditing()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        viewModel.confirmSaveCard()
                    }
                    .disabled(
                        viewModel.editingCardTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        viewModel.editingCardContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
            .onDisappear {
                if !viewModel.showingCardEditor {
                    viewModel.cancelCardEditing()
                }
            }
        }
    }
}

// MARK: - 侧边栏视图
struct SidebarView: View {
    @Binding var showSidebar: Bool
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var voiceCaptureStore: VoiceCaptureStore
    let screenWidth: CGFloat
    
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // 顶部 Header
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "graduationcap.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(AppTheme.accent)
                        Spacer()
                        Button(action: { withAnimation { showSidebar = false } }) {
                            Image(systemName: "xmark")
                                .foregroundColor(.gray)
                        }
                    }
                    Text("学习档案")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundColor(AppTheme.accent)
                    Text("记录每一个知识点")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                .padding(.top, 60)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                
                // 滚动内容区
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        // 知识卡片盒入口
                        NavigationLink(destination: KnowledgeCardView(viewModel: viewModel)) {
                            HStack {
                                Image(systemName: "archivebox.fill")
                                    .foregroundColor(AppTheme.accent)
                                Text("知识卡片盒")
                                    .font(.system(size: 16, weight: .semibold))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            .padding()
                            .background(Color.white.opacity(0.4))
                            .cornerRadius(12)
                        }
                        .padding(.horizontal, 15)
                        .padding(.bottom, 10)
                        .buttonStyle(PlainButtonStyle())

                        NavigationLink(
                            destination: VoiceWorkspaceView(
                                viewModel: viewModel,
                                store: voiceCaptureStore
                            )
                        ) {
                            HStack {
                                Image(systemName: "waveform.badge.mic")
                                    .foregroundColor(AppTheme.accent)
                                Text("语音转写")
                                    .font(.system(size: 16, weight: .semibold))
                                Spacer()
                                Text("\(voiceCaptureStore.captures.count)")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            .padding()
                            .background(Color.white.opacity(0.4))
                            .cornerRadius(12)
                        }
                        .padding(.horizontal, 15)
                        .padding(.bottom, 10)
                        .buttonStyle(PlainButtonStyle())
                        
                        Text("历史会话")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 4)
                        
                        // 会话列表
                        if viewModel.sessions.isEmpty {
                            Text("暂无历史记录")
                                .font(.caption2)
                                .foregroundColor(.gray.opacity(0.6))
                                .padding(.horizontal, 20)
                                .padding(.top, 10)
                        } else {
                            ForEach(viewModel.sessions) { session in
                                // 使用 VStack + onTapGesture 替代 Button 解决 ContextMenu 动画冲突
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(session.preview ?? "新会话")
                                        .font(.system(size: 15, weight: .medium))
                                        .lineLimit(1)
                                        .foregroundColor(viewModel.currentSessionId == session.id ? AppTheme.accent : Color(white: 0.2))
                                    HStack {
                                        Image(systemName: "clock")
                                            .font(.system(size: 10))
                                        Text(String(session.created_at.prefix(10)))
                                            .font(.system(size: 10))
                                    }
                                    .foregroundColor(.gray)
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                // 使用实色背景 (不透明) 解决 ContextMenu 预览时的白色块问题
                                .background(
                                    viewModel.currentSessionId == session.id ? 
                                    AppTheme.userBubble : // 选中时使用淡绿色
                                    Color(red: 0.98, green: 0.98, blue: 0.97) // 未选中时使用极淡的实色灰色
                                )
                                .cornerRadius(12)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(viewModel.currentSessionId == session.id ? AppTheme.accent.opacity(0.3) : Color.clear, lineWidth: 1)
                                )
                                .padding(.horizontal, 15)
                                .contentShape(Rectangle()) // 确保整行可点击
                                .onTapGesture {
                                    viewModel.selectSession(session)
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                        showSidebar = false
                                    }
                                }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        if let index = viewModel.sessions.firstIndex(where: { $0.id == session.id }) {
                                            viewModel.deleteSession(at: IndexSet(integer: index))
                                        }
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
                
                Spacer()
                
                HStack {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundColor(AppTheme.accent)
                    Text("Taylor 的助手")
                        .font(.footnote)
                    Spacer()
                    Text("Beta v0.2")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                .padding()
                .background(Color.white.opacity(0.5))
            }
            .frame(width: screenWidth * 0.8)
            .background(AppTheme.sidebarBackground)
            .shadow(color: Color.black.opacity(0.15), radius: 20, x: 5, y: 0)
            
            Spacer()
        }
        .task(id: showSidebar) {
            guard showSidebar else { return }
            voiceCaptureStore.ensureLoaded()
        }
    }
}

// MARK: - 消息气泡
struct MessageBubble: View {
    let message: ChatMessage
    @ObservedObject var viewModel: ChatViewModel
    var isUser: Bool { message.role == "user" }
    
    var body: some View {
        Group {
            if isUser {
                HStack {
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        if let filePaths = message.filePaths, !filePaths.isEmpty {
                            MessageAttachmentList(filePaths: filePaths)
                        }
                        if !message.content.isEmpty {
                            Text(message.content)
                                .font(.system(size: 16, weight: .regular, design: .rounded))
                                .textSelection(.enabled) // 开启文本选择
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(AppTheme.userBubble)
                                .foregroundColor(Color(white: 0.15))
                                .clipShape(BubbleShape(isUser: true))
                                .shadow(color: AppTheme.shadow, radius: 2, x: 0, y: 1)
                                .contextMenu {
                                    Button(action: { UIPasteboard.general.string = message.content }) {
                                        Label("复制文本", systemImage: "doc.on.doc")
                                    }
                                    Button(action: { viewModel.saveAsKnowledgeCard(message: message) }) {
                                        Label("收藏为知识卡片", systemImage: "archivebox")
                                    }
                                }
                        }
                    }
                    .frame(maxWidth: 280, alignment: .trailing)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14))
                            .foregroundColor(AppTheme.accent)
                        Text("AI 解析")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(AppTheme.accent)
                        Spacer()
                    }
                    .padding(.bottom, 4)
                    
                    if let filePaths = message.filePaths, !filePaths.isEmpty {
                        MessageAttachmentList(filePaths: filePaths)
                    }
                    
                    if !message.content.isEmpty {
                        MarkdownView(content: message.content, viewModel: viewModel)
                            .padding(.top, 4)
                        
                        // 新增：AI 解析底部的功能操作栏
                        HStack(spacing: 16) {
                            Button(action: { UIPasteboard.general.string = message.content }) {
                                Label("复制全文", systemImage: "doc.on.doc")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(AppTheme.accent.opacity(0.7))
                            }
                            
                            Button(action: { viewModel.saveAsKnowledgeCard(message: message) }) {
                                Label("全量收藏", systemImage: "archivebox")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(AppTheme.accent.opacity(0.7))
                            }
                            Spacer()
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 2)
                    }
                    
                    Divider()
                        .padding(.top, 6)
                        .opacity(0.3)
                }
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                // 彻底移除此处的 .contextMenu 以防止缩放异常
            }
        }
        .padding(.horizontal, 16)
    }
}

struct MessageAttachmentList: View {
    let filePaths: [String]

    private var attachments: [MessageAttachment] {
        filePaths.map(MessageAttachment.from(filePath:))
    }

    var body: some View {
        VStack(spacing: 10) {
            ForEach(attachments) { attachment in
                if attachment.fileKind == .image {
                    let imageUrl = "\(NetworkManager.shared.baseURL)/\(attachment.filePath)"
                    AsyncImage(url: URL(string: imageUrl)) { phase in
                        if let image = phase.image {
                            image.resizable()
                                .scaledToFit()
                                .cornerRadius(12)
                                .shadow(color: AppTheme.shadow, radius: 5, x: 0, y: 2)
                        } else {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.gray.opacity(0.1))
                                .frame(height: 150)
                                .overlay(ProgressView())
                        }
                    }
                } else {
                    AttachmentCard(
                        title: attachment.displayName,
                        subtitle: "\(attachment.fileKind.displayName) · \(attachment.fileExtension)",
                        systemImageName: attachment.fileKind.systemImageName
                    )
                }
            }
        }
    }
}

// MARK: - 底部输入区域
struct InputArea: View {
    @ObservedObject var viewModel: ChatViewModel
    @Binding var selectedItems: [PhotosPickerItem]
    @Binding var showCamera: Bool
    @Binding var showFileImporter: Bool
    @Binding var showVoiceWorkspace: Bool
    
    var body: some View {
        let topStatusText = viewModel.isLoading ? viewModel.processingStage.statusText : nil

        VStack(spacing: 0) {
            Divider().opacity(0.5)
            if let topStatusText {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text(topStatusText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppTheme.accent)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, viewModel.shouldShowSelectedAttachmentTray ? 0 : 4)
            }
            if viewModel.shouldShowSelectedAttachmentTray {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(viewModel.selectedAttachments.enumerated()), id: \.element.renderIdentity) { index, attachment in
                            ZStack(alignment: .topTrailing) {
                                SelectedAttachmentCard(attachment: attachment)
                                Button(action: { viewModel.removeAttachment(at: index) }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, AppTheme.accent)
                                }
                                .offset(x: 6, y: -6)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 15)
                    .padding(.bottom, 5)
                }
                if viewModel.hasFailedAttachments && !viewModel.isLoading {
                    HStack {
                        Button(action: { withAnimation { viewModel.retryAttachments() } }) {
                            Label("重试附件上传", systemImage: "arrow.clockwise")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(AppTheme.accent)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                }
            }
            HStack(alignment: .bottom, spacing: 12) {
                Button(action: { showCamera = true }) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 20))
                        .foregroundColor(AppTheme.accent)
                        .padding(.bottom, 10)
                }
                Button(action: { showVoiceWorkspace = true }) {
                    Image(systemName: "waveform.badge.mic")
                        .font(.system(size: 20))
                        .foregroundColor(AppTheme.accent)
                        .padding(.bottom, 10)
                }
                .disabled(viewModel.isLoading)
                Button(action: { showFileImporter = true }) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 20))
                        .foregroundColor(AppTheme.accent)
                        .padding(.bottom, 10)
                }
                PhotosPicker(selection: $selectedItems, matching: .any(of: [.images, .videos])) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 20))
                        .foregroundColor(AppTheme.accent)
                        .padding(.bottom, 10)
                }
                .onChange(of: selectedItems) { oldValue, newValue in
                    Task {
                        for item in newValue {
                            let supportedTypes = item.supportedContentTypes
                            if supportedTypes.contains(where: { $0.conforms(to: .image) }) {
                                if let data = try? await item.loadTransferable(type: Data.self),
                                   let image = UIImage(data: data) {
                                    viewModel.addPickedImage(image)
                                }
                                continue
                            }

                            if supportedTypes.contains(where: { $0.conforms(to: .movie) || $0.conforms(to: .video) }) {
                                if let pickedFile = try? await item.loadTransferable(type: PickedMediaFile.self) {
                                    viewModel.addPickedFile(from: pickedFile.url)
                                }
                            }
                        }
                        selectedItems = []
                    }
                }
                TextField("问点什么...", text: $viewModel.inputText, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.gray.opacity(0.06))
                    .cornerRadius(18)
                    .font(.system(size: 16))
                Button(action: { withAnimation { viewModel.sendMessage() } }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .resizable()
                        .frame(width: 32, height: 32)
                        .foregroundColor(viewModel.canSendCurrentMessage ? AppTheme.accent : Color.gray.opacity(0.3))
                        .padding(.bottom, 4)
                }
                .disabled(!viewModel.canSendCurrentMessage)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.white)
        }
    }
}

struct SelectedAttachmentCard: View {
    let attachment: LocalAttachment
    @StateObject private var audioPreviewPlayer = AudioPreviewPlayer()

    var body: some View {
        Group {
            if attachment.fileKind == .image, let previewImage = attachment.previewImage {
                ZStack(alignment: .bottomLeading) {
                    Image(uiImage: previewImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 60, height: 60)
                        .cornerRadius(10)
                        .clipped()
                    AttachmentStatusBadge(state: attachment.transferState, progress: attachment.uploadProgress)
                        .padding(4)
                }
            } else if attachment.fileKind == .audio {
                AudioAttachmentPreviewCard(
                    attachment: attachment,
                    player: audioPreviewPlayer
                )
                .frame(width: 220)
            } else {
                AttachmentCard(
                    title: attachment.displayName,
                    subtitle: attachment.fileKind.displayName,
                    systemImageName: attachment.fileKind.systemImageName,
                    compact: true,
                    transferState: attachment.transferState,
                    uploadProgress: attachment.uploadProgress
                )
                .frame(width: 170)
            }
        }
        .id(attachment.renderIdentity)
        .onDisappear {
            Task { @MainActor in
                audioPreviewPlayer.stop()
            }
        }
    }
}

struct AudioAttachmentPreviewCard: View {
    let attachment: LocalAttachment
    @ObservedObject var player: AudioPreviewPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button(action: { player.togglePlayback(for: attachment) }) {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(AppTheme.accent)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    Text(attachment.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(2)

                    Text("音频附件")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 0)
            }

            GeometryReader { proxy in
                let progress = playbackProgress
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.gray.opacity(0.15))
                        .frame(height: 6)
                    Capsule()
                        .fill(AppTheme.accent)
                        .frame(width: max(10, proxy.size.width * progress), height: 6)
                }
            }
            .frame(height: 6)

            HStack {
                Text(formattedTime(player.currentTime))
                Spacer()
                if let transferState = transferStateText {
                    Text(transferState)
                        .foregroundColor(transferStateColor)
                } else {
                    Text(formattedTime(player.duration))
                }
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: AppTheme.shadow, radius: 4, x: 0, y: 2)
        .onAppear {
            Task { @MainActor in
                player.prepareDuration(for: attachment)
            }
        }
    }

    private var playbackProgress: CGFloat {
        guard player.duration > 0 else { return 0 }
        return min(max(player.currentTime / player.duration, 0), 1)
    }

    private var transferStateText: String? {
        switch attachment.transferState {
        case .idle:
            return nil
        case .uploading:
            return "上传中 \(Int((attachment.uploadProgress * 100).rounded()))%"
        case .processing:
            return attachment.transferState.displayText
        default:
            return attachment.transferState.displayText
        }
    }

    private var transferStateColor: Color {
        switch attachment.transferState {
        case .uploading:
            return AppTheme.accent
        case .processing:
            return Color.orange
        case .uploaded:
            return .green
        case .failed:
            return .red
        case .idle:
            return .secondary
        }
    }

    private func formattedTime(_ time: TimeInterval) -> String {
        let totalSeconds = Int(time.rounded(.down))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct AttachmentCard: View {
    let title: String
    let subtitle: String
    let systemImageName: String
    var compact: Bool = false
    var transferState: AttachmentTransferState? = nil
    var uploadProgress: Double = 0

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImageName)
                .font(.system(size: compact ? 18 : 20, weight: .semibold))
                .foregroundColor(AppTheme.accent)
                .frame(width: compact ? 30 : 38, height: compact ? 30 : 38)
                .background(AppTheme.userBubble.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: compact ? 12 : 14, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(2)

                Text(subtitle)
                    .font(.system(size: compact ? 11 : 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if let transferState {
                    HStack(spacing: 4) {
                        Image(systemName: transferState.systemImageName)
                            .font(.system(size: 10, weight: .semibold))
                        Text(statusText(for: transferState))
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(statusColor(for: transferState))
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, compact ? 10 : 12)
        .padding(.vertical, compact ? 10 : 12)
        .background(Color.white.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: AppTheme.shadow, radius: 4, x: 0, y: 2)
    }

    private func statusColor(for state: AttachmentTransferState) -> Color {
        switch state {
        case .idle:
            return .secondary
        case .uploading:
            return AppTheme.accent
        case .processing:
            return Color.orange
        case .uploaded:
            return .green
        case .failed:
            return .red
        }
    }

    private func statusText(for state: AttachmentTransferState) -> String {
        if state == .uploading {
            return "上传中 \(Int((uploadProgress * 100).rounded()))%"
        }
        return state.displayText
    }
}

struct AttachmentStatusBadge: View {
    let state: AttachmentTransferState
    var progress: Double = 0

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: state.systemImageName)
                .font(.system(size: 9, weight: .bold))
            Text(statusText)
                .font(.system(size: 9, weight: .bold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(badgeBackground)
        .foregroundColor(.white)
        .clipShape(Capsule())
    }

    private var badgeBackground: Color {
        switch state {
        case .idle:
            return .gray.opacity(0.8)
        case .uploading:
            return AppTheme.accent
        case .processing:
            return Color.orange
        case .uploaded:
            return .green
        case .failed:
            return .red
        }
    }

    private var statusText: String {
        if state == .uploading {
            return "\(Int((progress * 100).rounded()))%"
        }
        return state.displayText
    }
}

// MARK: - 辅助组件
struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 25) {
            Spacer(minLength: 80)
            ZStack {
                Circle().fill(AppTheme.accent.opacity(0.05)).frame(width: 120, height: 120)
                Image(systemName: "graduationcap.fill").font(.system(size: 50)).foregroundColor(AppTheme.accent.opacity(0.4))
            }
            VStack(spacing: 8) {
                Text("您的私人学伴").font(.system(.title3, design: .rounded).bold()).foregroundColor(AppTheme.accent)
                Text("蒽蒽快来学习吧诡秘").font(.subheadline).foregroundColor(.gray)
            }
            Spacer()
        }
    }
}

struct BubbleShape: Shape {
    var isUser: Bool
    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: [.topLeft, .topRight, isUser ? .bottomLeft : .bottomRight], cornerRadii: CGSize(width: 18, height: 18))
        return Path(path.cgPath)
    }
}

struct LoadingIndicator: View {
    let statusText: String?
    @State private var isAnimating = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle().fill(AppTheme.accent.opacity(0.5)).frame(width: 6, height: 6).scaleEffect(isAnimating ? 1.0 : 0.5).animation(Animation.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.2), value: isAnimating)
                }
            }
            if let statusText, !statusText.isEmpty {
                Text(statusText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppTheme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { isAnimating = true }
    }
}

struct ChatView_Previews: PreviewProvider {
    static var previews: some View {
        ChatView()
    }
}
