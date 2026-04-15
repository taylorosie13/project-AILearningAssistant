import AVFoundation
import Combine
import SwiftUI
import UIKit

struct ImagePicker: View {
    @Binding var image: UIImage?
    var sourceType: UIImagePickerController.SourceType = .camera

    var body: some View {
        Group {
            if sourceType == .camera {
                CameraCaptureView(image: $image)
            } else {
                LibraryImagePicker(image: $image, sourceType: sourceType)
            }
        }
    }
}

private struct LibraryImagePicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss
    let sourceType: UIImagePickerController.SourceType

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: LibraryImagePicker

        init(_ parent: LibraryImagePicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let uiImage = info[.originalImage] as? UIImage {
                parent.image = uiImage
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

private struct CameraCaptureView: View {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = CameraSessionController()
    @State private var previewImage: UIImage?

    var body: some View {
        GeometryReader { geometry in
            let safeTop = geometry.safeAreaInsets.top
            let safeBottom = geometry.safeAreaInsets.bottom

            ZStack {
                CameraPreviewView(session: camera.session)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [Color.black.opacity(0.55), Color.black.opacity(0.18), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 180 + safeTop)

                    Spacer()

                    LinearGradient(
                        colors: [.clear, Color.black.opacity(0.18), Color.black.opacity(0.72)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 250 + safeBottom)
                }
                .ignoresSafeArea()

                if let previewImage {
                    CameraReviewOverlay(
                        image: previewImage,
                        safeTop: safeTop,
                        safeBottom: safeBottom,
                        onRetake: {
                            self.previewImage = nil
                            camera.resetCapturedImage()
                            camera.start()
                        },
                        onUsePhoto: {
                            image = previewImage
                            dismiss()
                        },
                        onClose: dismiss.callAsFunction
                    )
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            overlayIconButton(systemName: "xmark", action: dismiss.callAsFunction)
                            Spacer()
                            overlayIconButton(systemName: "arrow.triangle.2.circlepath.camera", action: camera.switchCamera)
                                .disabled(!camera.canSwitchCamera)
                                .opacity(camera.canSwitchCamera ? 1 : 0.45)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, max(safeTop - 18, 0))

                        Spacer(minLength: 2)

                        Spacer()

                        VStack(spacing: 18) {
                            if let errorMessage = camera.errorMessage {
                                Text(errorMessage)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                    .background(Color.black.opacity(0.42))
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                    .padding(.horizontal, 24)
                            } else {
                                Text("优先拍整道题，避免切掉题干和选项哦")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white.opacity(0.92))
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 10)
                                    .background(Color.black.opacity(0.30))
                                    .clipShape(Capsule())
                            }

                            HStack {
                                Color.clear
                                    .frame(width: 48, height: 48)

                                Spacer()

                                Button(action: camera.capturePhoto) {
                                    ZStack {
                                        Circle()
                                            .fill(Color.white)
                                            .frame(width: 80, height: 80)

                                        Circle()
                                            .stroke(Color.white.opacity(0.35), lineWidth: 6)
                                            .frame(width: 96, height: 96)
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(!camera.isReady)
                                .opacity(camera.isReady ? 1 : 0.55)

                                Spacer()

                                Color.clear
                                    .frame(width: 48, height: 48)
                            }
                            .padding(.horizontal, 28)
                            .padding(.bottom, max(safeBottom - 6, 0))
                        }
                    }
                }
            }
            .background(Color.black.ignoresSafeArea())
            .animation(.easeInOut(duration: 0.2), value: previewImage != nil)
        }
        .onAppear {
            camera.start()
        }
        .onDisappear {
            camera.stop()
            camera.resetCapturedImage()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                if previewImage == nil {
                    camera.start()
                }
            case .inactive, .background:
                camera.stop()
            @unknown default:
                camera.stop()
            }
        }
        .onReceive(camera.$capturedImage.compactMap { $0 }) { capturedImage in
            previewImage = capturedImage
            camera.stop()
        }
    }

    private func overlayIconButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 46, height: 46)
                .background(Color.black.opacity(0.36))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct CameraReviewOverlay: View {
    let image: UIImage
    let safeTop: CGFloat
    let safeBottom: CGFloat
    let onRetake: () -> Void
    let onUsePhoto: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            GeometryReader { geo in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.black.opacity(0.62), Color.black.opacity(0.18), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 160 + safeTop)

                Spacer()

                LinearGradient(
                    colors: [.clear, Color.black.opacity(0.24), Color.black.opacity(0.74)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 240 + safeBottom)
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 46, height: 46)
                            .background(Color.black.opacity(0.36))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 0)

                Spacer()

                HStack(spacing: 14) {
                    Button(action: onRetake) {
                        Text("重拍")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(Color.white.opacity(0.16))
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)

                    Button(action: onUsePhoto) {
                        Text("使用照片")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
    }
}

private struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .black
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = session
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.previewLayer.session = session
    }
}

private final class PreviewUIView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds

        guard let connection = previewLayer.connection else { return }

        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }
}

private final class CameraSessionController: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published private(set) var capturedImage: UIImage?
    @Published private(set) var isReady = false
    @Published private(set) var canSwitchCamera = false
    @Published private(set) var errorMessage: String?

    private let sessionQueue = DispatchQueue(label: "ai-learning-assistant.camera-session")
    private let photoOutput = AVCapturePhotoOutput()
    private var currentInput: AVCaptureDeviceInput?
    private var pendingPhotoDelegate: PhotoCaptureProcessor?
    private var isConfigured = false

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStartIfNeeded()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }

                if granted {
                    self.configureAndStartIfNeeded()
                } else {
                    Task { @MainActor in
                        self.errorMessage = "没有相机权限，请去系统设置里打开相机权限。"
                        self.isReady = false
                    }
                }
            }
        default:
            errorMessage = "没有相机权限，请去系统设置里打开相机权限。"
            isReady = false
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func switchCamera() {
        sessionQueue.async { [weak self] in
            guard let self, let currentInput = self.currentInput else { return }

            let targetPosition: AVCaptureDevice.Position = currentInput.device.position == .back ? .front : .back
            guard let device = self.findCamera(for: targetPosition) else { return }

            do {
                let newInput = try AVCaptureDeviceInput(device: device)
                self.session.beginConfiguration()
                self.session.removeInput(currentInput)

                if self.session.canAddInput(newInput) {
                    self.session.addInput(newInput)
                    self.currentInput = newInput
                } else {
                    self.session.addInput(currentInput)
                }

                self.session.commitConfiguration()

                Task { @MainActor in
                    self.canSwitchCamera = self.findCamera(for: targetPosition == .back ? .front : .back) != nil
                }
            } catch {
                Task { @MainActor in
                    self.errorMessage = "切换摄像头失败，请重试。"
                }
            }
        }
    }

    func capturePhoto() {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured else { return }

            let settings = AVCapturePhotoSettings()

            if let connection = self.photoOutput.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
                if connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = self.currentInput?.device.position == .front
                }
            }

            let delegate = PhotoCaptureProcessor(
                onPhotoCaptured: { [weak self] image in
                    guard let self else { return }
                    Task { @MainActor in
                        self.capturedImage = image
                        self.pendingPhotoDelegate = nil
                    }
                },
                onFailure: { [weak self] in
                    guard let self else { return }
                    Task { @MainActor in
                        self.errorMessage = "拍照失败，请再试一次。"
                        self.pendingPhotoDelegate = nil
                    }
                }
            )

            self.pendingPhotoDelegate = delegate
            self.photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    func resetCapturedImage() {
        capturedImage = nil
    }

    private func configureAndStartIfNeeded() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if !self.isConfigured {
                do {
                    try self.configureSession()
                    self.isConfigured = true
                } catch {
                    Task { @MainActor in
                        self.errorMessage = "相机启动失败，请稍后再试。"
                        self.isReady = false
                    }
                    return
                }
            }

            guard !self.session.isRunning else { return }
            self.session.startRunning()

            Task { @MainActor in
                self.errorMessage = nil
                self.isReady = true
            }
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .photo

        guard let device = findCamera(for: .back) else {
            throw CameraError.noCamera
        }

        try configureCaptureDevice(device)

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CameraError.cannotAddInput
        }

        session.addInput(input)
        currentInput = input

        guard session.canAddOutput(photoOutput) else {
            throw CameraError.cannotAddOutput
        }

        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .quality

        Task { @MainActor in
            self.canSwitchCamera = self.findCamera(for: .front) != nil
        }
    }

    private func findCamera(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        for deviceType in preferredDeviceTypes(for: position) {
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [deviceType],
                mediaType: .video,
                position: position
            )

            if let device = discovery.devices.first {
                return device
            }
        }

        return nil
    }

    private func preferredDeviceTypes(for position: AVCaptureDevice.Position) -> [AVCaptureDevice.DeviceType] {
        switch position {
        case .back:
            return [
                .builtInWideAngleCamera,
                .builtInDualCamera,
                .builtInDualWideCamera,
                .builtInTripleCamera,
                .builtInUltraWideCamera
            ]
        case .front:
            return [
                .builtInTrueDepthCamera,
                .builtInWideAngleCamera
            ]
        default:
            return [
                .builtInWideAngleCamera
            ]
        }
    }

    private func configureCaptureDevice(_ device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        } else if device.isFocusModeSupported(.autoFocus) {
            device.focusMode = .autoFocus
        }

        if device.isSmoothAutoFocusSupported {
            device.isSmoothAutoFocusEnabled = true
        }

        if device.isSubjectAreaChangeMonitoringEnabled == false {
            device.isSubjectAreaChangeMonitoringEnabled = true
        }

        if device.minAvailableVideoZoomFactor <= 1.0, device.maxAvailableVideoZoomFactor >= 1.0 {
            device.videoZoomFactor = 1.0
        }
    }

    private enum CameraError: Error {
        case noCamera
        case cannotAddInput
        case cannotAddOutput
    }
}

nonisolated private final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let onPhotoCaptured: @Sendable (UIImage) -> Void
    private let onFailure: @Sendable () -> Void

    init(
        onPhotoCaptured: @escaping @Sendable (UIImage) -> Void,
        onFailure: @escaping @Sendable () -> Void
    ) {
        self.onPhotoCaptured = onPhotoCaptured
        self.onFailure = onFailure
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if error != nil {
            onFailure()
            return
        }

        guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
            onFailure()
            return
        }

        onPhotoCaptured(image)
    }
}
