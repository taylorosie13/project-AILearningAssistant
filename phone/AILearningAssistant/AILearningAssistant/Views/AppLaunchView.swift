import SwiftUI
import AVFoundation
import Photos
import Speech
import UIKit
import Combine

enum PermissionState {
    case idle
    case granted
    case denied
    case unavailable
    case checking

    var title: String {
        switch self {
        case .idle:
            return "待确认"
        case .granted:
            return "已允许"
        case .denied:
            return "未允许"
        case .unavailable:
            return "当前不可用"
        case .checking:
            return "检查中"
        }
    }

    var color: Color {
        switch self {
        case .idle, .checking:
            return .orange
        case .granted:
            return .green
        case .denied:
            return .red
        case .unavailable:
            return .gray
        }
    }
}

@MainActor
final class LaunchPermissionViewModel: ObservableObject {
    static let localNetworkApprovalKey = "startupLocalNetworkApproved"

    struct PermissionItem: Identifiable {
        let id: String
        let title: String
        let detail: String
        var state: PermissionState
    }

    @Published var items: [PermissionItem] = [
        .init(id: "camera", title: "相机", detail: "拍题和拍资料时会用到。", state: .idle),
        .init(id: "photos", title: "相册", detail: "从系统相册选择图片时会用到。", state: .idle),
        .init(id: "microphone", title: "麦克风", detail: "语音提问和录音时会用到。", state: .idle),
        .init(id: "speech", title: "语音识别", detail: "把录音转成文字时会用到。", state: .idle),
        .init(id: "localNetwork", title: "本地网络", detail: "连接你电脑上运行的后端服务时会用到。", state: .idle),
    ]
    @Published private(set) var isRequesting = false
    @Published var hintText: String = "建议第一次启动时把这些权限都确认完，后面使用会顺很多。"

    func requestAllPermissions() {
        guard !isRequesting else { return }

        isRequesting = true
        hintText = "正在依次检查权限，请按系统弹窗授权。"

        Task {
            await updateCurrentStatuses()
            await requestCameraPermission()
            await requestPhotoPermission()
            await requestMicrophonePermission()
            await requestSpeechPermission()
            await requestLocalNetworkPermission()
            await updateCurrentStatuses()
            isRequesting = false

            if items.allSatisfy({ $0.state == .granted || $0.state == .unavailable }) {
                hintText = "权限已经准备好了，可以进入 App 了。"
            } else {
                hintText = "有些权限还没打开，App 也能进，但部分功能会受影响。"
            }
        }
    }

    func updateCurrentStatuses() async {
        setState(currentCameraState(), for: "camera")
        setState(currentPhotoState(), for: "photos")
        setState(currentMicrophoneState(), for: "microphone")
        setState(currentSpeechState(), for: "speech")
    }

    private func setState(_ state: PermissionState, for id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = state

        if id == "localNetwork" {
            switch state {
            case .granted:
                UserDefaults.standard.set(true, forKey: Self.localNetworkApprovalKey)
            case .denied:
                UserDefaults.standard.set(false, forKey: Self.localNetworkApprovalKey)
            default:
                break
            }
        }
    }

    private func currentCameraState() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .idle
        @unknown default:
            return .unavailable
        }
    }

    private func currentPhotoState() -> PermissionState {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .idle
        @unknown default:
            return .unavailable
        }
    }

    private func currentMicrophoneState() -> PermissionState {
        #if os(iOS) || os(visionOS)
        if #available(iOS 17.0, visionOS 1.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                return .granted
            case .denied:
                return .denied
            case .undetermined:
                return .idle
            @unknown default:
                return .unavailable
            }
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
            case .granted:
                return .granted
            case .denied:
                return .denied
            case .undetermined:
                return .idle
            @unknown default:
                return .unavailable
            }
        }
        #else
        return .unavailable
        #endif
    }

    private func currentSpeechState() -> PermissionState {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .idle
        @unknown default:
            return .unavailable
        }
    }

    private func requestCameraPermission() async {
        guard currentCameraState() == .idle else { return }
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        setState(granted ? .granted : .denied, for: "camera")
    }

    private func requestPhotoPermission() async {
        guard currentPhotoState() == .idle else { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        switch status {
        case .authorized, .limited:
            setState(.granted, for: "photos")
        case .denied, .restricted:
            setState(.denied, for: "photos")
        case .notDetermined:
            setState(.idle, for: "photos")
        @unknown default:
            setState(.unavailable, for: "photos")
        }
    }

    private func requestMicrophonePermission() async {
        guard currentMicrophoneState() == .idle else { return }

        #if os(iOS) || os(visionOS)
        let granted = await withCheckedContinuation { continuation in
            if #available(iOS 17.0, visionOS 1.0, *) {
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
            }
        }
        setState(granted ? .granted : .denied, for: "microphone")
        #else
        setState(.unavailable, for: "microphone")
        #endif
    }

    private func requestSpeechPermission() async {
        guard currentSpeechState() == .idle else { return }
        let granted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        setState(granted ? .granted : .denied, for: "speech")
    }

    private func requestLocalNetworkPermission() async {
        await refreshLocalNetworkState(triggeredByUser: true)
    }

    private func refreshLocalNetworkState(triggeredByUser: Bool = false) async {
        setState(.checking, for: "localNetwork")

        guard let url = URL(string: "\(AppConfiguration.apiBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/sessions") else {
            setState(.unavailable, for: "localNetwork")
            return
        }

        let attempts = triggeredByUser ? 6 : 1

        for attempt in 0..<attempts {
            let result = await probeLocalNetwork(url: url)

            switch result {
            case .granted:
                setState(.granted, for: "localNetwork")
                return
            case .denied:
                if triggeredByUser && attempt < attempts - 1 {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    continue
                }
                setState(.denied, for: "localNetwork")
                return
            case .checking:
                if attempt < attempts - 1 {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    continue
                }
                setState(.idle, for: "localNetwork")
                return
            case .unavailable:
                setState(.unavailable, for: "localNetwork")
                return
            case .idle:
                setState(.idle, for: "localNetwork")
                return
            }
        }
    }

    private func probeLocalNetwork(url: URL) async -> PermissionState {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)

        do {
            _ = try await session.data(for: request)
            return .granted
        } catch {
            let nsError = error as NSError
            let loweredDescription = nsError.localizedDescription.lowercased()

            if loweredDescription.contains("local network") || loweredDescription.contains("prohibited") {
                return .denied
            }

            if nsError.domain == NSURLErrorDomain {
                switch nsError.code {
                case URLError.timedOut.rawValue,
                     URLError.cannotConnectToHost.rawValue,
                     URLError.cannotFindHost.rawValue,
                     URLError.networkConnectionLost.rawValue,
                     URLError.badServerResponse.rawValue:
                    return .granted
                case URLError.notConnectedToInternet.rawValue:
                    return .checking
                default:
                    return .checking
                }
            }

            return .unavailable
        }
    }
}

struct AppLaunchView: View {
    @AppStorage("hasCompletedStartupPermissions") private var hasCompletedStartupPermissions = false
    @AppStorage(LaunchPermissionViewModel.localNetworkApprovalKey) private var startupLocalNetworkApproved = false
    @StateObject private var viewModel = LaunchPermissionViewModel()
    private let primaryTextColor = Color(red: 0.17, green: 0.22, blue: 0.17)
    private let secondaryTextColor = Color(red: 0.38, green: 0.43, blue: 0.38)
    private let accentHighlight = Color(red: 0.33, green: 0.47, blue: 0.31)

    private var allPermissionsReady: Bool {
        viewModel.items.allSatisfy { $0.state == .granted || $0.state == .unavailable }
    }

    var body: some View {
        if hasCompletedStartupPermissions {
            ChatView()
        } else {
            NavigationStack {
                VStack(spacing: 24) {
                    VStack(spacing: 12) {
                        Image(systemName: "graduationcap.circle.fill")
                            .font(.system(size: 60))
                            .foregroundColor(AppTheme.accent)
                        Text("先把权限准备好")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundColor(AppTheme.accent)
                        Text(viewModel.hintText)
                            .font(.system(size: 15))
                            .foregroundColor(secondaryTextColor)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                    .padding(.top, 40)

                    VStack(spacing: 12) {
                        ForEach(viewModel.items) { item in
                            HStack(spacing: 14) {
                                Circle()
                                    .fill(item.state.color.opacity(0.15))
                                    .frame(width: 40, height: 40)
                                    .overlay(
                                        Image(systemName: symbolName(for: item.state))
                                            .foregroundColor(item.state.color)
                                    )

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(item.title)
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(primaryTextColor)
                                        Spacer()
                                        Text(item.state.title)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundColor(item.state.color)
                                    }
                                    Text(item.detail)
                                        .font(.system(size: 13))
                                        .foregroundColor(secondaryTextColor)
                                }
                            }
                            .padding(16)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18)
                                    .stroke(Color.black.opacity(0.05), lineWidth: 1)
                            )
                            .shadow(color: AppTheme.shadow, radius: 8, x: 0, y: 4)
                        }
                    }
                    .padding(.horizontal, 20)

                    VStack(spacing: 12) {
                        if !allPermissionsReady {
                            Button(action: { viewModel.requestAllPermissions() }) {
                                HStack(spacing: 10) {
                                    if viewModel.isRequesting {
                                        ProgressView()
                                            .tint(.white)
                                    } else {
                                        Image(systemName: "checkmark.shield.fill")
                                            .font(.system(size: 17))
                                    }
                                    Text(viewModel.isRequesting ? "正在请求权限..." : "一键检查并申请")
                                        .font(.system(size: 16, weight: .bold))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                                .background(
                                    LinearGradient(
                                        colors: [accentHighlight, AppTheme.accent],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 20))
                                .shadow(color: AppTheme.accent.opacity(0.22), radius: 14, x: 0, y: 8)
                            }
                            .disabled(viewModel.isRequesting)

                            Button(action: openSettings) {
                                HStack(spacing: 8) {
                                    Image(systemName: "gearshape.fill")
                                        .font(.system(size: 14))
                                    Text("打开系统设置")
                                        .font(.system(size: 15, weight: .semibold))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.white)
                                .foregroundColor(secondaryTextColor)
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18)
                                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                                    )
                            }
                        }

                        Button(action: enterApp) {
                            HStack(spacing: 10) {
                                Image(systemName: allPermissionsReady ? "arrow.right.circle.fill" : "arrow.right.circle")
                                    .font(.system(size: 18))
                                Text("进入 App")
                                    .font(.system(size: 17, weight: .bold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .background(
                                LinearGradient(
                                    colors: allPermissionsReady
                                        ? [accentHighlight, AppTheme.accent]
                                        : [Color.white, Color.white],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .foregroundColor(allPermissionsReady ? .white : AppTheme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .stroke(AppTheme.accent.opacity(allPermissionsReady ? 0 : 0.18), lineWidth: 1)
                            )
                            .shadow(color: AppTheme.accent.opacity(allPermissionsReady ? 0.25 : 0.08), radius: 14, x: 0, y: 8)
                        }
                    }
                    .padding(.horizontal, 20)

                    Spacer()
                }
                .background(AppTheme.background.ignoresSafeArea())
                .task {
                    await viewModel.updateCurrentStatuses()
                }
            }
        }
    }

    private func symbolName(for state: PermissionState) -> String {
        switch state {
        case .granted:
            return "checkmark"
        case .denied:
            return "xmark"
        case .checking:
            return "ellipsis"
        case .idle, .unavailable:
            return "circle"
        }
    }

    private func enterApp() {
        startupLocalNetworkApproved = viewModel.items.first(where: { $0.id == "localNetwork" })?.state == .granted
        hasCompletedStartupPermissions = true
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
