import AVFoundation
import Foundation

enum CameraError: LocalizedError {
    case notRunning
    case noData

    var errorDescription: String? {
        switch self {
        case .notRunning: return "The camera is not running yet. Try again in a second."
        case .noData: return "The camera returned an empty photo."
        }
    }
}

/// Owns the AVFoundation session. All session work happens on a private queue;
/// only `status` is published back to the main thread for the UI.
final class CameraController: NSObject, ObservableObject {
    enum Status: Equatable {
        case idle
        case unauthorized
        case unavailable
        case running
        case failed(String)
    }

    let session = AVCaptureSession()
    @Published private(set) var status: Status = .idle
    @Published private(set) var hasTorch = false
    @Published private(set) var isTorchOn = false

    private let sessionQueue = DispatchQueue(label: "com.jesseariss.tracebin.camera")
    private let photoOutput = AVCapturePhotoOutput()
    private var isConfigured = false
    private var device: AVCaptureDevice?
    private let continuationLock = NSLock()
    private var captureContinuation: CheckedContinuation<Data, Error>?

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                break
            case .notDetermined:
                let semaphore = DispatchSemaphore(value: 0)
                var granted = false
                AVCaptureDevice.requestAccess(for: .video) { ok in
                    granted = ok
                    semaphore.signal()
                }
                semaphore.wait()
                if !granted {
                    self.publish(.unauthorized)
                    return
                }
            default:
                self.publish(.unauthorized)
                return
            }
            if !self.isConfigured {
                self.configureSession()
            }
            guard self.isConfigured else { return }
            if !self.session.isRunning {
                self.session.startRunning()
            }
            self.publish(self.session.isRunning ? .running : .failed("The camera did not start."))
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.applyTorch(false)
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    /// Turns the LED torch on or off for dim rooms. Stays on until the camera closes.
    func setTorch(_ on: Bool) {
        sessionQueue.async { [weak self] in
            self?.applyTorch(on)
        }
    }

    private func applyTorch(_ on: Bool) {
        guard let device, device.hasTorch, device.isTorchAvailable else { return }
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        if on, device.isTorchModeSupported(.on) {
            try? device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
        } else {
            device.torchMode = .off
        }
        let nowOn = device.torchMode == .on
        DispatchQueue.main.async { [weak self] in
            self?.isTorchOn = nowOn
        }
    }

    /// Takes one still photo and returns the encoded file data (JPEG when available).
    func capturePhoto() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else { return }
                guard self.session.isRunning else {
                    continuation.resume(throwing: CameraError.notRunning)
                    return
                }
                self.continuationLock.lock()
                self.captureContinuation = continuation
                self.continuationLock.unlock()

                let settings: AVCapturePhotoSettings
                if self.photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
                    settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                } else {
                    settings = AVCapturePhotoSettings()
                }
                settings.photoQualityPrioritization = .balanced
                if let connection = self.photoOutput.connection(with: .video),
                   connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90   // app is portrait only
                }
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    // MARK: - Private

    private func configureSession() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            publish(.unavailable)
            return
        }
        session.addInput(input)
        self.device = device
        let torchAvailable = device.hasTorch
        DispatchQueue.main.async { [weak self] in
            self?.hasTorch = torchAvailable
        }

        guard session.canAddOutput(photoOutput) else {
            publish(.failed("Could not attach the photo output."))
            return
        }
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .balanced

        if (try? device.lockForConfiguration()) != nil {
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        }
        isConfigured = true
    }

    private func publish(_ newStatus: Status) {
        DispatchQueue.main.async { [weak self] in
            self?.status = newStatus
        }
    }

    private func takeContinuation() -> CheckedContinuation<Data, Error>? {
        continuationLock.lock()
        defer { continuationLock.unlock() }
        let c = captureContinuation
        captureContinuation = nil
        return c
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let continuation = takeContinuation() else { return }
        if let error {
            continuation.resume(throwing: error)
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            continuation.resume(throwing: CameraError.noData)
            return
        }
        continuation.resume(returning: data)
    }
}
