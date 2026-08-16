import AVFoundation
import Photos
import SwiftUI

/// Камера-затвор: телефон стоит, тряхнул браслетом издалека — снялось.
/// Единственный осмысленный вид камеры с браслетом: iOS не даёт снимать из
/// фона, а с телефоном в руке проще нажать самому. Фронталка или основная,
/// фото или видео. Съёмка «на обе разом» — задел на потом (нужен мультикам).
struct ShutterCamera: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = CameraModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: camera.session).ignoresSafeArea()

            VStack {
                HStack {
                    roundButton("xmark") { dismiss() }
                    Spacer()
                    roundButton("arrow.triangle.2.circlepath.camera") { camera.switchCamera() }
                }
                Spacer()

                Text("Тряхни браслетом — спуск")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.bottom, 6)

                HStack(spacing: 40) {
                    Picker("", selection: $camera.isVideo) {
                        Text("Фото").tag(false)
                        Text("Видео").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    .disabled(camera.isRecording)
                }

                Button { camera.capture() } label: {
                    Circle()
                        .fill(camera.isRecording ? Color.red : .white)
                        .frame(width: 72, height: 72)
                        .overlay(Circle().stroke(.white, lineWidth: 4).padding(4))
                }
                .padding(.vertical, 16)
            }
            .padding(20)
        }
        .onAppear {
            camera.start()
            let collector = BraceletCollector.shared
            collector.armShakeForCamera(true)
            collector.cameraShutterHandler = { [weak camera] in camera?.capture() }
        }
        .onDisappear {
            let collector = BraceletCollector.shared
            collector.cameraShutterHandler = nil
            collector.armShakeForCamera(false)
            camera.stop()
        }
    }

    private func roundButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.4), in: Circle())
        }
    }
}

/// Превью сессии камеры.
private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}

/// Модель камеры: сессия, переключение, фото и видео. Спуск — `capture()`.
@MainActor
final class CameraModel: NSObject, ObservableObject {
    let session = AVCaptureSession()
    @Published var isVideo = false
    @Published var isRecording = false

    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var position: AVCaptureDevice.Position = .back
    private let queue = DispatchQueue(label: "braslet.camera")

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { _ in }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        queue.async { [weak self] in
            self?.configure()
            self?.session.startRunning()
        }
    }

    func stop() {
        queue.async { [weak self] in self?.session.stopRunning() }
    }

    func switchCamera() {
        position = position == .back ? .front : .back
        queue.async { [weak self] in self?.configure() }
    }

    /// Спуск: фото или старт/стоп видео — по текущему режиму.
    func capture() {
        if isVideo { toggleRecording() } else { capturePhoto() }
    }

    private func capturePhoto() {
        queue.async { [weak self] in
            guard let self else { return }
            let settings = AVCapturePhotoSettings()
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func toggleRecording() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            } else {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("video-\(Int(Date().timeIntervalSince1970)).mov")
                self.movieOutput.startRecording(to: url, recordingDelegate: self)
                Task { @MainActor in self.isRecording = true }
            }
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .high

        session.inputs.forEach { session.removeInput($0) }
        if let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video,
                                                position: position),
           let input = try? AVCaptureDeviceInput(device: camera),
           session.canAddInput(input) {
            session.addInput(input)
        }
        if let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }

        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        session.commitConfiguration()
    }

    private func save(_ url: URL, isPhoto: Bool) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                if isPhoto {
                    PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: url)
                } else {
                    PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
            } completionHandler: { _, _ in }
        }
    }
}

extension CameraModel: @preconcurrency AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let data = photo.fileDataRepresentation() else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-\(Int(Date().timeIntervalSince1970)).jpg")
        try? data.write(to: url)
        save(url, isPhoto: true)
    }
}

extension CameraModel: @preconcurrency AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor in self.isRecording = false }
        save(outputFileURL, isPhoto: false)
    }
}
