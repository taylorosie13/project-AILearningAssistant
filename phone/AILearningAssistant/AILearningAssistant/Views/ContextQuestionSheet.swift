import SwiftUI

struct ContextQuestionSheet: View {
    let title: String
    let placeholder: String
    @ObservedObject var chatViewModel: ChatViewModel
    let askAction: (String) async throws -> String

    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var answer = ""
    @State private var errorMessage = ""
    @State private var isLoading = false

    private var trimmedQuestion: String {
        question.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("你的问题")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundColor(AppTheme.accent)

                        TextEditor(text: $question)
                            .frame(minHeight: 120)
                            .padding(10)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .shadow(color: AppTheme.shadow, radius: 4, x: 0, y: 2)
                            .overlay(alignment: .topLeading) {
                                if trimmedQuestion.isEmpty {
                                    Text(placeholder)
                                        .font(.system(size: 15))
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 18)
                                        .allowsHitTesting(false)
                                }
                            }
                    }

                    Button(action: submitQuestion) {
                        HStack {
                            if isLoading {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "sparkles")
                            }
                            Text(isLoading ? "AI 正在回答" : "开始提问")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(trimmedQuestion.isEmpty || isLoading ? AppTheme.accent.opacity(0.45) : AppTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .disabled(trimmedQuestion.isEmpty || isLoading)

                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.system(size: 14))
                            .foregroundColor(.red.opacity(0.85))
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }

                    if !answer.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("AI 回答")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundColor(AppTheme.accent)

                            MarkdownView(content: answer, viewModel: chatViewModel)
                        }
                        .padding(16)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(color: AppTheme.shadow, radius: 4, x: 0, y: 2)
                    }
                }
                .padding(16)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func submitQuestion() {
        let currentQuestion = trimmedQuestion
        guard !currentQuestion.isEmpty else { return }

        errorMessage = ""
        answer = ""
        isLoading = true

        Task {
            do {
                let response = try await askAction(currentQuestion)
                await MainActor.run {
                    answer = response
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "这次提问没成功，请稍后再试。"
                        : error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}
