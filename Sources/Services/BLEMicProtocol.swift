import Foundation

struct AudioPacket: Equatable {
    let session: UInt16
    let sequence: UInt16
    let opus: [UInt8]
}
struct MicStatus {
    let recording: Bool
    let session: UInt16
    init?(_ bytes: [UInt8]) {
        guard bytes.count == 8, bytes[0] == 1, bytes[1] <= 1,
              bytes[4] == 0x80, bytes[5] == 0x3e, bytes[6] == 20, bytes[7] == 1 else { return nil }
        recording = bytes[1] == 1
        session = UInt16(bytes[2]) | UInt16(bytes[3]) << 8
    }
}
struct PacketAssembler {
    private var session: UInt16 = 0
    private var sequence: UInt16 = 0
    private var next = 0
    private var count = 0
    private var payload: [UInt8] = []
    private var started: TimeInterval = 0
    mutating func reset() { next = 0; count = 0; payload.removeAll(keepingCapacity: true) }
    mutating func push(_ b: [UInt8], now: TimeInterval) -> AudioPacket? {
        guard b.count > 8, b.count <= 244, b[0] == 1, b[7] == 0,
              b[6] > 0, b[6] <= 22, b[5] < b[6] else { reset(); return nil }
        let s = UInt16(b[1]) | UInt16(b[2]) << 8
        let q = UInt16(b[3]) | UInt16(b[4]) << 8
        let index = Int(b[5])
        if index == 0 {
            reset(); session = s; sequence = q; count = Int(b[6]); started = now
        }
        guard count > 0, s == session, q == sequence, Int(b[6]) == count,
              index == next, now - started <= 0.15, payload.count + b.count - 8 <= 256 else {
            reset(); return nil
        }
        payload.append(contentsOf: b.dropFirst(8)); next += 1
        guard next == count else { return nil }
        let result = AudioPacket(session: session, sequence: sequence, opus: payload)
        reset(); return result
    }
}

/// Serial-number arithmetic: 65535 -> 0 is forward; old/replayed frames are rejected.
func frameGap(expected: UInt16, received: UInt16) -> Int? {
    let delta = received &- expected
    return delta < 32768 ? Int(delta) : nil
}
