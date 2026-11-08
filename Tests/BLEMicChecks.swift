import Foundation
import Copus

// Standalone codec/protocol checks, without Bluetooth hardware or microphone access.
enum RecordingError: Error { case setupFailed(String) }
@main struct BLEMicChecks {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }
    static func fragment(_ payload: [UInt8], session: UInt16 = 42, sequence: UInt16 = 65535,
                         index: UInt8 = 0, count: UInt8 = 1) -> [UInt8] {
        [1, UInt8(truncatingIfNeeded: session), UInt8(session >> 8),
         UInt8(truncatingIfNeeded: sequence), UInt8(sequence >> 8), index, count, 0] + payload
    }
    static func main() throws {
        // A full-scale startup impulse followed by a steady signal. Processing
        // irregular chunks must preserve timing, silence the first 60 ms, ramp
        // over 20 ms, and preserve all later PCM exactly (including Int16.min).
        let samples = (0..<2000).map { index -> Int16 in
            if index < 960 { return index.isMultiple(of: 2) ? .max : .min }
            return index.isMultiple(of: 2) ? 10000 : -10000
        } + [Int16.min, Int16.max]
        let raw = samples.withUnsafeBytes { Data($0) }
        var smoother = BLEStartupSmoother()
        var filtered = Data()
        for start in stride(from: 0, to: raw.count, by: 246) {
            filtered.append(smoother.process(raw.subdata(in: start..<min(start + 246, raw.count))))
        }
        let output: [Int16] = filtered.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 2).map {
                Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)
            }
        }
        check(output.count == samples.count, "startup smoothing preserves duration")
        check(output.prefix(960).allSatisfy { $0 == 0 }, "startup impulse suppressed")
        check(output[960] == 0 && output[1279] == samples[1279], "fade endpoints")
        check(abs(Int(output[1120])) > 4900 && abs(Int(output[1120])) < 5100, "gradual fade")
        check(Array(output[1280...]) == Array(samples[1280...]), "later speech bit-exact")
        check(smoother.process(raw) == raw, "app recording does not restart warmup")
        smoother = BLEStartupSmoother()
        check(smoother.process(raw).prefix(1920).allSatisfy { $0 == 0 }, "new device session resets warmup")
        print("BLE startup transient suppression, cross-chunk fade and unchanged later speech: PASS")

        var assembler = PacketAssembler()
        check(assembler.push(fragment([1, 2], count: 2), now: 0) == nil, "partial")
        check(assembler.push(fragment([3], index: 1, count: 2), now: 0.02)?.opus == [1, 2, 3], "assembly")
        _ = assembler.push(fragment([1], count: 2), now: 1)
        check(assembler.push(fragment([2], index: 1, count: 2), now: 1.2) == nil, "timeout")
        _ = assembler.push(fragment([1], count: 2), now: 2)
        check(assembler.push(fragment([2], session: 43, index: 1, count: 2), now: 2.01) == nil, "session isolation")
        check(assembler.push(fragment([2], index: 1, count: 2), now: 3) == nil, "missing first")
        check(assembler.push(fragment(Array(repeating: 0, count: 237)), now: 4) == nil, "notification size")
        _ = assembler.push(fragment(Array(repeating: 0, count: 236), count: 2), now: 5)
        check(assembler.push(fragment(Array(repeating: 0, count: 21), index: 1, count: 2), now: 5.01) == nil, "payload limit")
        check(frameGap(expected: 65535, received: 0) == 1, "rollover")
        check(frameGap(expected: 2, received: 1) == nil, "reject replay")
        check(frameGap(expected: 2, received: 7) == 5, "loss count")
        check(MicStatus([1, 1, 42, 0, 0x80, 0x3e, 20, 1])?.session == 42, "status")
        check(MicStatus([1, 1, 42, 0, 0x80, 0x3e, 20, 2]) == nil, "codec mismatch")
        check(MicStatus([1, 2, 42, 0, 0x80, 0x3e, 20, 1]) == nil, "bad recording state")
        var error: Int32 = 0
        let encoder = opus_encoder_create(16000, 1, OPUS_APPLICATION_VOIP, &error)!
        defer { opus_encoder_destroy(encoder) }
        check(error == OPUS_OK, "encoder")
        let decoder = try OpusDecoderBox()
        var totalEnergy: Double = 0
        for frame in 0..<100 {
            let input = (0..<320).map { Int16(8000 * sin(2 * Double.pi * 440 * Double(frame * 320 + $0) / 16000)) }
            var packet = [UInt8](repeating: 0, count: 256)
            let size = input.withUnsafeBufferPointer { pcm in
                packet.withUnsafeMutableBufferPointer { opus_encode(encoder, pcm.baseAddress!, 320, $0.baseAddress!, 256) }
            }
            check(size > 0, "encode")
            let payload = Array(packet.prefix(Int(size)))
            // Exercise the MTU 23 path used by the ESP32: 12 bytes per fragment.
            let parts = stride(from: 0, to: payload.count, by: 12).map { Array(payload[$0..<min($0 + 12, payload.count)]) }
            var complete: AudioPacket?
            for (index, part) in parts.enumerated() {
                complete = assembler.push(fragment(part, sequence: UInt16(truncatingIfNeeded: 65530 + frame),
                    index: UInt8(index), count: UInt8(parts.count)), now: Double(frame) * 0.02)
            }
            check(complete?.opus == payload, "real Opus fragments")
            let pcm = try decoder.decode(complete!.opus)
            check(pcm.count == 640, "16 kHz 20 ms PCM16")
            pcm.withUnsafeBytes { bytes in
                for i in stride(from: 0, to: bytes.count, by: 2) {
                    let sample = Double(Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)) / 32768
                    totalEnergy += sample * sample
                }
            }
        }
        check(totalEnergy > 100, "non-silent decoded speech")
        let concealed = try decoder.decode(nil)
        check(concealed.count == 640, "PLC")
        do {
            _ = try decoder.decode([0xff])
            fatalError("invalid Opus accepted")
        } catch {}
        print("BLE fragmentation, validation, sessions, rollover/replay, Opus -> PCM16 round trip and PLC: PASS")
    }
}
