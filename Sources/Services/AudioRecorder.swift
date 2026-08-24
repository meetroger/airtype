import AVFoundation
import CoreAudio
import Foundation

/// Handles microphone audio recording with level monitoring
@MainActor
class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var hasPermission = false
    @Published var errorMessage: String?

    // Audio level monitoring for visual feedback
    @Published var audioLevel: Float = 0.0  // 0.0 to 1.0 normalized
    @Published var peakLevel: Float = 0.0   // Peak level for visual indicator
    @Published var maxLevelDuringRecording: Float = 0.0  // Tracks highest level seen during recording

    // Recording duration tracking
    @Published var recordingDuration: TimeInterval = 0.0
    @Published var recordingStartTime: Date?

    // File size tracking (for chunking decisions)
    @Published var estimatedFileSize: Int64 = 0

    private var audioCapture: StreamingAudioCapture?
    private var recordingURL: URL?
    private var levelTimer: Timer?
    private var durationTimer: Timer?

    // Constants
    private let maxFileSizeBytes: Int64 = 24 * 1024 * 1024  // 24MB (leave buffer below 25MB limit)
    private let levelUpdateInterval: TimeInterval = 0.05    // 50ms for smooth animation

    nonisolated static var recordingsDirectoryURL: URL {
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return applicationSupport
            .appendingPathComponent("Airtype", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    @discardableResult
    nonisolated static func ensureRecordingsDirectory() throws -> URL {
        let directoryURL = recordingsDirectoryURL
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        return directoryURL
    }

    nonisolated static func makeRecordingURL(fileExtension: String) throws -> URL {
        let directoryURL = try ensureRecordingsDirectory()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        let uniqueSuffix = UUID().uuidString.prefix(6)
        return directoryURL.appendingPathComponent(
            "Airtype_\(timestamp)_\(uniqueSuffix).\(fileExtension)"
        )
    }

    override init() {
        super.init()
        checkPermission()
    }

    // MARK: - Permission
    func checkPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            hasPermission = true
        case .notDetermined:
            hasPermission = false
        case .denied, .restricted:
            hasPermission = false
            errorMessage = "Microphone access denied. Please enable in System Settings > Privacy & Security > Microphone"
        @unknown default:
            hasPermission = false
        }
    }

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            hasPermission = true
            errorMessage = nil
            return true
        case .denied, .restricted:
            hasPermission = false
            errorMessage = "Microphone access denied. Please enable in System Settings > Privacy & Security > Microphone"
            return false
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            hasPermission = granted
            errorMessage = granted ? nil : "Microphone access required for voice input"
            return granted
        @unknown default:
            hasPermission = false
            return false
        }
    }

    // MARK: - Recording
    func startRecording(deviceID: AudioDeviceID? = nil) throws -> URL {
        guard hasPermission else {
            throw RecordingError.noPermission
        }

        let capture = StreamingAudioCapture()
        do {
            let url = try capture.start(
                deviceID: deviceID,
                onLevel: { [weak self] average, peak in
                    Task { @MainActor [weak self] in
                        self?.updateCapturedLevels(average: average, peak: peak)
                    }
                },
                onChunk: { _ in }
            )
            audioCapture = capture
            beginCaptureMonitoring(at: url)
            return url
        } catch {
            capture.stop(discard: true)
            throw RecordingError.setupFailed(error.localizedDescription)
        }
    }

    // MARK: - Level Monitoring

    private func startLevelMonitoring() {
        // Audio levels arrive directly from the capture tap. This timer only
        // polls file size for upload-limit warnings.
        levelTimer = Timer.scheduledTimer(withTimeInterval: levelUpdateInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.updateEstimatedFileSize()
            }
        }

        // Duration timer (updates every second)
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.updateDuration()
            }
        }
    }

    private func stopLevelMonitoring() {
        levelTimer?.invalidate()
        levelTimer = nil
        durationTimer?.invalidate()
        durationTimer = nil
    }

    private func updateEstimatedFileSize() {
        if let url = recordingURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64 {
            estimatedFileSize = size
        }
    }

    func updateCapturedLevels(average: Float, peak: Float) {
        guard isRecording else { return }
        audioLevel = average
        peakLevel = peak
        maxLevelDuringRecording = max(maxLevelDuringRecording, average)
    }

    private func updateDuration() {
        guard let startTime = recordingStartTime else { return }
        recordingDuration = Date().timeIntervalSince(startTime)
    }

    func beginCaptureMonitoring(at url: URL) {
        stopLevelMonitoring()
        recordingURL = url
        isRecording = true
        recordingDuration = 0.0
        recordingStartTime = Date()
        audioLevel = 0.0
        peakLevel = 0.0
        maxLevelDuringRecording = 0.0
        estimatedFileSize = 0
        startLevelMonitoring()
    }

    func endCaptureMonitoring() {
        stopLevelMonitoring()
        recordingURL = nil
        isRecording = false
        audioLevel = 0.0
        peakLevel = 0.0
    }

    /// Check if recording was all silence (max level never exceeded threshold)
    var recordingWasSilent: Bool {
        maxLevelDuringRecording < 0.05
    }

    /// Check if recording is approaching file size limit
    var isApproachingLimit: Bool {
        estimatedFileSize > (maxFileSizeBytes - 2 * 1024 * 1024)  // 2MB buffer
    }

    /// Check if recording has exceeded safe duration (estimate: ~10 minutes at 16kHz mono AAC)
    var isLongRecording: Bool {
        recordingDuration > 300  // 5 minutes
    }

    /// Formatted duration string (MM:SS)
    var formattedDuration: String {
        let minutes = Int(recordingDuration) / 60
        let seconds = Int(recordingDuration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    func stopRecording() -> URL? {
        let url = audioCapture?.stop()
        audioCapture = nil
        endCaptureMonitoring()
        return url
    }

    func cancelRecording() {
        audioCapture?.stop(discard: true)
        audioCapture = nil
        endCaptureMonitoring()
        recordingDuration = 0.0
        maxLevelDuringRecording = 0.0
        estimatedFileSize = 0
    }

}

enum RecordingError: LocalizedError {
    case noPermission
    case setupFailed(String)
    case recordingTooShort
    case recordingFailed
    case microphoneInUse

    var errorDescription: String? {
        switch self {
        case .noPermission:
            return "Microphone access required. Please enable in System Settings → Privacy & Security → Microphone."
        case .setupFailed(let reason):
            return "Failed to start recording: \(reason)"
        case .recordingTooShort:
            return "Recording too short. Please speak for longer."
        case .recordingFailed:
            return "Recording failed. Please try again."
        case .microphoneInUse:
            return "Microphone is in use by another app. Please close other recording apps."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .noPermission:
            return "Open System Settings and grant microphone access to Airtype."
        case .setupFailed:
            return "Try closing other apps that may be using the microphone."
        case .recordingTooShort:
            return "Hold the shortcut key longer while speaking."
        case .recordingFailed:
            return "Check that your microphone is connected and working."
        case .microphoneInUse:
            return "Close apps like Zoom, Teams, or other recording software."
        }
    }
}
