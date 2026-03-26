import SwiftUI
import PhotosUI

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
    @StateObject private var viewModel = ChatViewModel()
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var cameraImage: UIImage? = nil
    @State private var showSidebar = false
    
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
                                            LoadingIndicator()
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
                            showCamera: $showCamera
                        )
                        .opacity(showSidebar ? 0.3 : 1.0)
                    }
                    
                    if showSidebar {
                        Color.black.opacity(0.2)
                            .ignoresSafeArea()
                            .onTapGesture {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showSidebar = false }
                            }
                    }
                    
                    // 侧边栏：使用 geometry 获取的动态宽度
                    SidebarView(showSidebar: $showSidebar, viewModel: viewModel, screenWidth: screenWidth)
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
                .sheet(isPresented: $showCamera) {
                    ImagePicker(image: $cameraImage, sourceType: .camera)
                }
                .sheet(isPresented: $viewModel.showingCardEditor) {
                    CardEditSheet(viewModel: viewModel)
                }
                .onChange(of: cameraImage) { oldImage, newImage in
                    if let image = newImage {
                        viewModel.selectedImages.append(image)
                        cameraImage = nil
                    }
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
                Section("卡片内容") {
                    TextEditor(text: $viewModel.editingCardContent)
                        .frame(minHeight: 200)
                }
            }
            .navigationTitle("存为知识卡片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        viewModel.confirmSaveCard()
                    }
                    .disabled(viewModel.editingCardTitle.isEmpty || viewModel.editingCardContent.isEmpty)
                }
            }
        }
    }
}

// MARK: - 侧边栏视图
struct SidebarView: View {
    @Binding var showSidebar: Bool
    @ObservedObject var viewModel: ChatViewModel
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
                    Text("记录您的知识成长")
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
                                        Label("物理删除", systemImage: "trash")
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
                            ImageGrid(filePaths: filePaths)
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
                        ImageGrid(filePaths: filePaths)
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

struct ImageGrid: View {
    let filePaths: [String]
    var body: some View {
        ForEach(filePaths, id: \.self) { path in
            let imageUrl = "\(NetworkManager.shared.baseURL)/\(path)"
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
        }
    }
}

// MARK: - 底部输入区域
struct InputArea: View {
    @ObservedObject var viewModel: ChatViewModel
    @Binding var selectedItems: [PhotosPickerItem]
    @Binding var showCamera: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            if !viewModel.selectedImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(0..<viewModel.selectedImages.count, id: \.self) { index in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: viewModel.selectedImages[index])
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 60, height: 60)
                                    .cornerRadius(10)
                                    .clipped()
                                Button(action: { viewModel.removeImage(at: index) }) {
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
            }
            HStack(alignment: .bottom, spacing: 12) {
                Button(action: { showCamera = true }) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 20))
                        .foregroundColor(AppTheme.accent)
                        .padding(.bottom, 10)
                }
                PhotosPicker(selection: $selectedItems, matching: .images) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 20))
                        .foregroundColor(AppTheme.accent)
                        .padding(.bottom, 10)
                }
                .onChange(of: selectedItems) { oldValue, newValue in
                    Task {
                        for item in newValue {
                            if let data = try? await item.loadTransferable(type: Data.self),
                               let image = UIImage(data: data) {
                                viewModel.selectedImages.append(image)
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
                        .foregroundColor((viewModel.inputText.isEmpty && viewModel.selectedImages.isEmpty) ? Color.gray.opacity(0.3) : AppTheme.accent)
                        .padding(.bottom, 4)
                }
                .disabled((viewModel.inputText.isEmpty && viewModel.selectedImages.isEmpty) || viewModel.isLoading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.white)
        }
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
                Text("拍照解题 · 文档总结 · 知识问答").font(.subheadline).foregroundColor(.gray)
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
    @State private var isAnimating = false
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle().fill(AppTheme.accent.opacity(0.5)).frame(width: 6, height: 6).scaleEffect(isAnimating ? 1.0 : 0.5).animation(Animation.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.2), value: isAnimating)
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
