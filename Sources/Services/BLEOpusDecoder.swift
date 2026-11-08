import Foundation
import Copus

/// Suppress the microphone power-on transient before audio reaches either the
/// startup prebuffer or ASR. Keep sample timing intact and leave speech after
/// the first 80 ms untouched. Reset per device session, not per app recording.
struct BLEStartupSmoother {
    private var samplesProcessed = 0
    private let mutedSamples = 960 // 60 ms at 16 kHz
    private let fadeSamples = 320 // 20 ms

    mutating func process(_ pcm: Data) -> Data {
        guard samplesProcessed < mutedSamples + fadeSamples else { return pcm }
        var result = pcm
        result.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for offset in stride(from: 0, to: bytes.count - 1, by: 2) {
                let index = samplesProcessed
                samplesProcessed += 1
                guard index < mutedSamples + fadeSamples else { continue }
                let sample = Int16(bitPattern: UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)
                let gain = index < mutedSamples ? 0 : Float(index - mutedSamples) / Float(fadeSamples - 1)
                let scaled = UInt16(bitPattern: Int16(Float(sample) * gain))
                bytes[offset] = UInt8(truncatingIfNeeded: scaled)
                bytes[offset + 1] = UInt8(truncatingIfNeeded: scaled >> 8)
            }
        }
        return result
    }
}

/// The wire format is mono Opus, 20 ms. Decode directly at the ASR rate;
/// libopus handles its internal resampling, with no CoreAudio device involved.
final class OpusDecoderBox {
    private let decoder: OpaquePointer
    init() throws {
        var error: Int32 = 0
        guard let pointer = opus_decoder_create(16000, 1, &error), error == OPUS_OK else {
            throw RecordingError.setupFailed("Opus decoder creation failed: \(error)")
        }
        decoder = pointer
    }
    deinit { opus_decoder_destroy(decoder) }
    func decode(_ packet: [UInt8]?) throws -> Data {
        var output = [Int16](repeating: 0, count: 320)
        let count = output.withUnsafeMutableBufferPointer { pcm -> Int32 in
            if let packet {
                return packet.withUnsafeBufferPointer {
                    opus_decode(decoder, $0.baseAddress, Int32($0.count), pcm.baseAddress!, 320, 0)
                }
            }
            return opus_decode(decoder, nil, 0, pcm.baseAddress!, 320, 0)
        }
        guard count == 320 else {
            throw RecordingError.setupFailed("Invalid Opus 20 ms frame: \(count)")
        }
        return output.withUnsafeBytes { Data($0) }
    }
}
