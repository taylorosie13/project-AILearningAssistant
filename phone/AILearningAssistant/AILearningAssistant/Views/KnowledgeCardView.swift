import SwiftUI

struct KnowledgeCardView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()
            
            VStack {
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
                } else {
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(viewModel.knowledgeCards) { card in
                                CardRow(card: card, viewModel: viewModel)
                            }
                        }
                        .padding(16)
                    }
                }
            }
        }
        .navigationTitle("知识卡片盒")
        .navigationBarTitleDisplayMode(.inline)
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
}

struct CardRow: View {
    let card: KnowledgeCard
    @ObservedObject var viewModel: ChatViewModel
    @State private var isExpanded = false
    
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
    }
}
