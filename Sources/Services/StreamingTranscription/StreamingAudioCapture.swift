import AVFoundation
import CoreAudio
import Foundation

class StreamingAudioCapture {
    private var engine: AVAudioEngine?
    private var onChunk: ((Data) -> Void)?
    private var onLevel: ((Float, Float) -> Void)?
    private let recordingQueue = DispatchQueue(label: "com.airtype.streaming-recording")
    private var recordingFileHandle: FileHandle?
    private var recordingURL: URL?
    private var recordedByteCount: UInt64 = 0
    private var tapInstalled = false

    private let targetSampleRate: Double = 16000

    @discardableResult
    func start(
        deviceID: AudioDeviceID? = nil,
        onLevel: ((Float, Float) -> Void)? = nil,
        onChunk: @escaping (Data) -> Void
    ) throws -> URL {
        self.onChunk = onChunk
        self.onLevel = onLevel

        do {
            let engine = AVAudioEngine()
            self.engine = engine

            let inputNode = engine.inputNode
            if let deviceID {
                try inputNode.auAudioUnit.setDeviceID(deviceID)
            }

            let nativeFormat = inputNode.outputFormat(forBus: 0)
            debugLog("StreamingAudioCapture native format: \(nativeFormat)")

            let nativeSR = nativeFormat.sampleRate
            let nativeChannels = max(1, Int(nativeFormat.channelCount))
            guard nativeSR > 0, nativeFormat.channelCount > 0 else {
                throw StreamingAudioCaptureError.invalidInputFormat
            }

            let recordingURL = try AudioRecorder.makeRecordingURL(fileExtension: "wav")
            guard FileManager.default.createFile(
                atPath: recordingURL.path,
                contents: Self.wavHeader(dataByteCount: 0)
            ) else {
                throw StreamingAudioCaptureError.recordingFileCreationFailed
            }
            self.recordingURL = recordingURL
            let fileHandle = try FileHandle(forWritingTo: recordingURL)
            try fileHandle.seekToEnd()
            self.recordingFileHandle = fileHandle
            recordedByteCount = 0

            let sourceFramesPerOutputFrame = nativeSR / targetSampleRate

            // Tap in native format — passing nil lets the system use the hardware format.
            inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(nativeSR * 0.1), format: nil) { [weak self] buffer, _ in
                guard let self = self else { return }

                let frameCount = Int(buffer.frameLength)
                guard frameCount > 0 else { return }

                let channelCount = Int(buffer.format.channelCount)
                let isInterleaved = buffer.format.isInterleaved
                let outputFrameCount = Int(Double(frameCount) / sourceFramesPerOutputFrame)
                guard outputFrameCount > 0 else { return }

                var squareSum: Float = 0
                var peakAmplitude: Float = 0
                var int16Data = Data(count: outputFrameCount * 2)
                int16Data.withUnsafeMutableBytes { rawBuf in
                    let int16Buf = rawBuf.bindMemory(to: Int16.self)

                    if isInterleaved {
                        // Interleaved: samples are [ch0 ch1 ch2 ch0 ch1 ch2 ...]
                        guard let floatData = buffer.floatChannelData?[0] else { return }
                        for i in 0..<outputFrameCount {
                            let srcFrame = min(frameCount - 1, Int(Double(i) * sourceFramesPerOutputFrame))
                            var sum: Float = 0
                            for ch in 0..<channelCount {
                                sum += floatData[srcFrame * channelCount + ch]
                            }
                            let sample = max(-1.0, min(1.0, sum / Float(channelCount)))
                            int16Buf[i] = Int16(sample * 32767.0)
                            squareSum += sample * sample
                            peakAmplitude = max(peakAmplitude, abs(sample))
                        }
                    } else {
                        // Deinterleaved: each channel is a separate buffer
                        guard let floatChannels = buffer.floatChannelData else { return }
                        for i in 0..<outputFrameCount {
                            let srcFrame = min(frameCount - 1, Int(Double(i) * sourceFramesPerOutputFrame))
                            var sum: Float = 0
                            for ch in 0..<channelCount {
                                sum += floatChannels[ch][srcFrame]
                            }
                            let sample = max(-1.0, min(1.0, sum / Float(channelCount)))
                            int16Buf[i] = Int16(sample * 32767.0)
                            squareSum += sample * sample
                            peakAmplitude = max(peakAmplitude, abs(sample))
                        }
                    }
                }

                let rmsAmplitude = sqrt(squareSum / Float(outputFrameCount))
                self.onLevel?(
                    Self.normalizedLevel(rmsAmplitude),
                    Self.normalizedLevel(peakAmplitude)
                )
                self.onChunk?(int16Data)
                self.recordingQueue.async { [weak self] in
                    guard let self, let fileHandle = self.recordingFileHandle else { return }
                    do {
                        try fileHandle.write(contentsOf: int16Data)
                        self.recordedByteCount += UInt64(int16Data.count)
                    } catch {
                        debugLog("Failed to archive streaming audio: \(error.localizedDescription)")
                    }
                }
            }
            tapInstalled = true

            engine.prepare()
            try engine.start()
            debugLog("StreamingAudioCapture started (device=\(deviceID.map(String.init) ?? "system default"), channels=\(nativeChannels), sampleRate=\(nativeSR), interleaved=\(nativeFormat.isInterleaved))")
            return recordingURL
        } catch {
            stop(discard: true)
            throw error
        }
    }

    @discardableResult
    func stop(discard: Bool = false) -> URL? {
        if tapInstalled {
            engine?.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine?.stop()
        engine = nil
        onChunk = nil
        onLevel = nil

        let completedURL = recordingURL
        recordingQueue.sync {
            if let fileHandle = recordingFileHandle {
                if !discard {
                    do {
                        try fileHandle.seek(toOffset: 0)
                        try fileHandle.write(contentsOf: Self.wavHeader(dataByteCount: recordedByteCount))
                    } catch {
                        debugLog("Failed to finalize streaming recording: \(error.localizedDescription)")
                    }
                }
                try? fileHandle.close()
            }
            recordingFileHandle = nil
            recordingURL = nil
            recordedByteCount = 0
        }

        if discard, let completedURL {
            try? FileManager.default.removeItem(at: completedURL)
        }
        return completedURL
    }

    private static func normalizedLevel(_ amplitude: Float) -> Float {
        let decibels = 20 * log10(max(amplitude, 0.000_001))
        return max(0, min(1, (decibels + 60) / 60))
    }

    private static func wavHeader(dataByteCount: UInt64) -> Data {
        let boundedDataSize = UInt32(min(dataByteCount, UInt64(UInt32.max - 36)))
        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        header.appendLittleEndian(UInt32(36) + boundedDataSize)
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        header.appendLittleEndian(UInt32(16))
        header.appendLittleEndian(UInt16(1))
        header.appendLittleEndian(UInt16(1))
        header.appendLittleEndian(UInt32(16_000))
        header.appendLittleEndian(UInt32(32_000))
        header.appendLittleEndian(UInt16(2))
        header.appendLittleEndian(UInt16(16))
        header.append("data".data(using: .ascii)!)
        header.appendLittleEndian(boundedDataSize)
        return header
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { bytes in
            append(contentsOf: bytes)
        }
    }
}

enum StreamingAudioCaptureError: LocalizedError {
    case converterCreationFailed
    case invalidInputFormat
    case recordingFileCreationFailed

    var errorDescription: String? {
        switch self {
        case .converterCreationFailed:
            return "Failed to create audio format converter"
        case .invalidInputFormat:
            return "The selected microphone does not provide a usable audio format"
        case .recordingFileCreationFailed:
            return "Failed to create a file for the recording history"
        }
    }
}
