import SwiftUI

struct KnowledgeCardView: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var noteViewModel: NoteViewModel
    @Environment(\.dismiss) var dismiss
    @State private var searchText = ""
    @State private var collapsedCategories: Set<String> = []
    private let uncategorizedTitle = "未分类"

    private var filteredCards: [KnowledgeCard] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return viewModel.knowledgeCards }

        return viewModel.knowledgeCards.filter { card in
            card.title.localizedCaseInsensitiveContains(keyword) ||
            card.content.localizedCaseInsensitiveContains(keyword) ||
            (card.category?.localizedCaseInsensitiveContains(keyword) ?? false) ||
            card.tags.contains(where: { $0.localizedCaseInsensitiveContains(keyword) })
        }
    }

    private var groupedCards: [(category: String, cards: [KnowledgeCard])] {
        let grouped = Dictionary(grouping: filteredCards) { card in
            let trimmedCategory = card.category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmedCategory.isEmpty ? uncategorizedTitle : trimmedCategory
        }

        return grouped
            .map { key, cards in
                let sortedCards = cards.sorted { lhs, rhs in
                    lhs.created_at > rhs.created_at
                }
                return (category: key, cards: sortedCards)
            }
            .sorted { lhs, rhs in
                if lhs.category == uncategorizedTitle { return false }
                if rhs.category == uncategorizedTitle { return true }
                return lhs.category.localizedStandardCompare(rhs.category) == .orderedAscending
            }
    }
    
    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()
            
            VStack {
                searchBar

                if viewModel.knowledgeCards.isEmpty {
                    VStack(spacing: 20) {
                        Spacer()
                        Image(systemName: "archivebox")
                            .font(.system(size: 60))
                            .foregroundColor(AppTheme.accent.opacity(0.3))
                        Text("暂无卡片")
                            .font(.headline)
                            .foregroundColor(.gray)
                        Text("长按对话内容可收藏为卡片")
                            .font(.subheadline)
                            .foregroundColor(.gray.opacity(0.8))
                        Spacer()
                    }
                } else if filteredCards.isEmpty {
                    VStack(spacing: 18) {
                        Spacer()
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 42))
                            .foregroundColor(AppTheme.accent.opacity(0.35))
                        Text("没有找到匹配的卡片")
                            .font(.headline)
                            .foregroundColor(.gray)
                        Text("试试换个关键词，标题和内容都会参与搜索。")
                            .font(.subheadline)
                            .foregroundColor(.gray.opacity(0.8))
                        Text("分类和标签也会参与搜索。")
                            .font(.subheadline)
                            .foregroundColor(.gray.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Spacer()
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 22) {
                            ForEach(groupedCards, id: \.category) { group in
                                CategorySection(
                                    title: group.category,
                                    count: group.cards.count,
                                    isCollapsed: collapsedCategories.contains(group.category),
                                    viewModel: viewModel,
                                    noteViewModel: noteViewModel,
                                    cards: group.cards,
                                    onToggle: {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                            toggleCategory(group.category)
                                        }
                                    }
                                )
                            }
                        }
                        .padding(16)
                    }
                }
            }
        }
        .navigationTitle("知识卡片盒")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Text("\(filteredCards.count) 张")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .padding(.vertical, 8)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    Task { await viewModel.loadKnowledgeCards() }
                }) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(AppTheme.accent)
                }
            }
        }
        .onAppear {
            Task { await viewModel.loadKnowledgeCards() }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.gray)

            TextField("搜索标题或内容", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray.opacity(0.8))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.white)
        .cornerRadius(16)
        .shadow(color: AppTheme.shadow, radius: 4, x: 0, y: 2)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func toggleCategory(_ category: String) {
        if collapsedCategories.contains(category) {
            collapsedCategories.remove(category)
        } else {
            collapsedCategories.insert(category)
        }
    }
}

struct CategorySection: View {
    let title: String
    let count: Int
    let isCollapsed: Bool
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var noteViewModel: NoteViewModel
    let cards: [KnowledgeCard]
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: onToggle) {
                HStack(alignment: .center) {
                    HStack(spacing: 8) {
                        Image(systemName: title == "未分类" ? "tray.full.fill" : "folder.fill")
                            .foregroundColor(AppTheme.accent)
                        Text(title)
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundColor(AppTheme.accent)
                    }
                    Spacer()
                    Text("\(count) 张")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.gray)
                }
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                ForEach(cards) { card in
                    CardRow(card: card, viewModel: viewModel, noteViewModel: noteViewModel)
                }
            }
        }
    }
}

struct CardRow: View {
    let card: KnowledgeCard
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var noteViewModel: NoteViewModel
    @State private var isExpanded = false
    @State private var showingAskAISheet = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(card.title)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.accent)
                    .lineLimit(1)
                Spacer()
                Text(String(card.created_at.prefix(10)))
                    .font(.caption2)
                    .foregroundColor(.gray)
            }

            if card.category != nil || !card.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if let category = card.category, !category.isEmpty {
                            InfoChip(
                                text: category,
                                icon: "folder.fill",
                                background: AppTheme.userBubble.opacity(0.9),
                                foreground: AppTheme.accent
                            )
                        }

                        ForEach(card.tags, id: \.self) { tag in
                            InfoChip(
                                text: tag,
                                icon: "number",
                                background: Color.orange.opacity(0.12),
                                foreground: Color.orange.opacity(0.85)
                            )
                        }
                    }
                }
            }
            
            if isExpanded {
                MarkdownView(content: card.content, viewModel: viewModel)
                    .transition(.opacity)
            } else {
                Text(card.content)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
            }
            
            HStack {
                Button(action: { showingAskAISheet = true }) {
                    Label("问AI", systemImage: "sparkles")
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(AppTheme.accent)
                        .cornerRadius(20)
                }
                Button(action: { viewModel.prepareExistingCardForEditing(card) }) {
                    Image(systemName: "square.and.pencil")
                        .font(.caption)
                        .foregroundColor(AppTheme.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(AppTheme.userBubble)
                        .cornerRadius(20)
                }
                Button(action: {
                    Task { _ = await noteViewModel.expandCardToNote(card: card) }
                }) {
                    Image(systemName: "book.closed")
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(AppTheme.accent)
                        .cornerRadius(20)
                }
                Button(action: { viewModel.deleteKnowledgeCard(card) }) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(20)
                }
                Spacer()
                Button(action: { withAnimation { isExpanded.toggle() } }) {
                    Text(isExpanded ? "收起" : "展开详情")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(AppTheme.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(AppTheme.userBubble)
                        .cornerRadius(20)
                }
            }
        }
        .padding(16)
        .background(Color.white)
        .cornerRadius(16)
        .shadow(color: AppTheme.shadow, radius: 4, x: 0, y: 2)
        .sheet(isPresented: $showingAskAISheet) {
            ContextQuestionSheet(
                title: "卡片提问",
                placeholder: "比如：这张卡片最值得记住的点是什么？可以怎么理解？",
                chatViewModel: viewModel,
                askAction: { question in
                    try await viewModel.askAIAboutCard(card, question: question)
                }
            )
        }
    }
}

struct InfoChip: View {
    let text: String
    let icon: String
    let background: Color
    let foreground: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(foreground)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(background)
        .cornerRadius(999)
    }
}
