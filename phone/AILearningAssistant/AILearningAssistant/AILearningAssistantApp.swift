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

                Text("学伴")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text("正在进入...")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(AppTheme.accent.opacity(0.7))

                ProgressView()
                    .tint(AppTheme.accent)
            }
            .padding(.horizontal, 32)
        }
        .preferredColorScheme(.light)
    }
}
