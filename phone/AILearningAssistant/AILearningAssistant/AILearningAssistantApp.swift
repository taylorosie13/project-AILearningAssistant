import SwiftUI

@main
struct AILearningAssistantApp: App {
    var body: some Scene {
        WindowGroup {
            RootBootstrapView()
        }
    }
}

private struct RootBootstrapView: View {
    @State private var isReady = false

    var body: some View {
        Group {
            if isReady {
                AppLaunchView()
            } else {
                LaunchPlaceholderView()
            }
        }
        .task {
            guard !isReady else { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            isReady = true
        }
    }
}

private struct LaunchPlaceholderView: View {
    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            VStack(spacing: 14) {
                Image(systemName: "graduationcap.circle.fill")
                    .font(.system(size: 64))
                    .foregroundColor(AppTheme.accent)

                Text("正在准备学习助手")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.accent)

                ProgressView()
                    .tint(AppTheme.accent)
                    .padding(.top, 4)
            }
        }
        .preferredColorScheme(.light)
    }
}
