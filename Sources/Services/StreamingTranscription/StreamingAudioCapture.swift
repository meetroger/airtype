import AVFoundation
import Foundation

class StreamingAudioCapture {
    private var engine: AVAudioEngine?
    private var onChunk: ((Data) -> Void)?
    private let recordingQueue = DispatchQueue(label: "com.airtype.streaming-recording")
    private var recordingFileHandle: FileHandle?
    private var recordingURL: URL?
    private var recordedByteCount: UInt64 = 0

    private let targetSampleRate: Double = 16000

    func start(onChunk: @escaping (Data) -> Void) throws {
        self.onChunk = onChunk
        let recordingURL = try AudioRecorder.makeRecordingURL(fileExtension: "wav")
        guard FileManager.default.createFile(
            atPath: recordingURL.path,
            contents: Self.wavHeader(dataByteCount: 0)
        ) else {
            throw StreamingAudioCaptureError.recordingFileCreationFailed
        }
        do {
            let fileHandle = try FileHandle(forWritingTo: recordingURL)
            try fileHandle.seekToEnd()
            self.recordingFileHandle = fileHandle
            self.recordingURL = recordingURL
            recordedByteCount = 0
        } catch {
            try? FileManager.default.removeItem(at: recordingURL)
            throw error
        }

        let engine = AVAudioEngine()
        self.engine = engine

        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        debugLog("StreamingAudioCapture native format: \(nativeFormat)")

        let nativeSR = nativeFormat.sampleRate
        let nativeChannels = max(1, Int(nativeFormat.channelCount))
        let downsampleRatio = max(1, Int(nativeSR / targetSampleRate))

        // Tap in native format — passing nil lets the system use the hardware format
        inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(nativeSR * 0.1), format: nil) { [weak self] buffer, _ in
            guard let self = self else { return }

            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { return }

            let channelCount = Int(buffer.format.channelCount)
            let isInterleaved = buffer.format.isInterleaved

            let outputFrameCount = frameCount / downsampleRatio
            guard outputFrameCount > 0 else { return }

            var int16Data = Data(count: outputFrameCount * 2)
            int16Data.withUnsafeMutableBytes { rawBuf in
                let int16Buf = rawBuf.bindMemory(to: Int16.self)

                if isInterleaved {
                    // Interleaved: samples are [ch0 ch1 ch2 ch0 ch1 ch2 ...]
                    guard let floatData = buffer.floatChannelData?[0] else { return }
                    for i in 0..<outputFrameCount {
                        let srcFrame = i * downsampleRatio
                        var sum: Float = 0
                        for ch in 0..<channelCount {
                            sum += floatData[srcFrame * channelCount + ch]
                        }
                        let sample = sum / Float(channelCount)
                        let clamped = max(-1.0, min(1.0, sample))
                        int16Buf[i] = Int16(clamped * 32767.0)
                    }
                } else {
                    // Deinterleaved: each channel is a separate buffer
                    guard let floatChannels = buffer.floatChannelData else { return }
                    for i in 0..<outputFrameCount {
                        let srcIdx = i * downsampleRatio
                        var sum: Float = 0
                        for ch in 0..<channelCount {
                            sum += floatChannels[ch][srcIdx]
                        }
                        let sample = sum / Float(channelCount)
                        let clamped = max(-1.0, min(1.0, sample))
                        int16Buf[i] = Int16(clamped * 32767.0)
                    }
                }
            }

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

        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop(discard: true)
            throw error
        }
        debugLog("StreamingAudioCapture started (channels=\(nativeChannels), downsample=\(downsampleRatio), interleaved=\(nativeFormat.isInterleaved))")
    }

    @discardableResult
    func stop(discard: Bool = false) -> URL? {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        onChunk = nil

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
    case recordingFileCreationFailed

    var errorDescription: String? {
        switch self {
        case .converterCreationFailed:
            return "Failed to create audio format converter"
        case .recordingFileCreationFailed:
            return "Failed to create a file for the recording history"
        }
    }
}
