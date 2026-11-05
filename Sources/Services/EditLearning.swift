import Foundation
import NaturalLanguage
import Combine

struct LearnedWordPair: Codable, Equatable {
    let from: String
    let to: String
}

/// Local word-level extraction inspired by Arion's domain/learning.go.
/// Both surrounding anchors must survive. Additions, deletions, number edits,
/// grammatical homophones and sentence rewrites do not create vocabulary.
enum EditCorrectionExtractor {
    static let maxTextLength = 2000
    static let maxPairLength = 16

    static func extract(inserted: String, prefix: String, suffix: String, settled: String) -> [LearnedWordPair] {
        guard !inserted.isEmpty, inserted.utf16.count <= maxTextLength,
              settled.hasPrefix(prefix), settled.hasSuffix(suffix),
              settled.utf16.count >= prefix.utf16.count + suffix.utf16.count,
              let range = Range(NSRange(location: prefix.utf16.count,
                  length: settled.utf16.count - prefix.utf16.count - suffix.utf16.count), in: settled) else { return [] }
        let edited = String(settled[range])
        guard !edited.isEmpty, edited != inserted, edited.utf16.count <= maxTextLength else { return [] }
        let a = units(inserted), b = units(edited)
        guard a.count <= 512, b.count <= 512 else { return [] }
        // Bounded LCS keeps complete local word boundaries, including CJK.
        let width = b.count + 1
        var lcs = [UInt16](repeating: 0, count: (a.count + 1) * width)
        for i in a.indices.reversed() {
            for j in b.indices.reversed() {
                lcs[i * width + j] = a[i] == b[j] ? lcs[(i + 1) * width + j + 1] + 1
                    : max(lcs[(i + 1) * width + j], lcs[i * width + j + 1])
            }
        }
        struct Hunk { var removed = ""; var added = ""; var start = 0 }
        var hunks: [Hunk] = []
        var current: Hunk?
        var gap = ""
        var i = 0, j = 0
        var removedWeight = 0, addedWeight = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                if let h = current {
                    if a[i].allSatisfy(\.isWhitespace), gap.isEmpty {
                        gap = a[i]
                    } else {
                        hunks.append(h)
                        current = nil
                        gap = ""
                    }
                }
                i += 1; j += 1
            } else {
                if current == nil { current = Hunk(start: i) }
                if !gap.isEmpty {
                    current!.removed += gap; current!.added += gap; gap = ""
                }
                if j < b.count, i == a.count || lcs[i * width + j + 1] >= lcs[(i + 1) * width + j] {
                    current!.added += b[j]; addedWeight += weight(b[j]); j += 1
                } else {
                    current!.removed += a[i]; removedWeight += weight(a[i]); i += 1
                }
            }
        }
        if let current { hunks.append(current) }
        let total = weight(inserted)
        guard hunks.count <= 3, removedWeight * 3 <= total * 2, addedWeight <= total * 2 else { return [] }
        var result: [LearnedWordPair] = []
        for hunk in hunks {
            let pair = LearnedWordPair(from: trim(hunk.removed), to: trim(hunk.added))
            guard valid(pair) else { continue }
            if pair.from.lowercased() == pair.to.lowercased() {
                // Lowercase stylistic edits and sentence-initial capitals are not terms.
                let before = a.prefix(hunk.start).joined().trimmingCharacters(in: .whitespaces)
                if pair.to.filter(\.isUppercase).count <= pair.from.filter(\.isUppercase).count
                    || before.isEmpty || before.last.map({ ".!?。！？\n".contains($0) }) == true { continue }
            }
            if !result.contains(pair) { result.append(pair) }
        }
        return result
    }

    static func valid(_ pair: LearnedWordPair) -> Bool {
        let from = pair.from, to = pair.to
        guard from != to, from.count >= 2, to.count >= 2,
              from.count <= maxPairLength, to.count <= maxPairLength,
              weight(from) > 0, weight(to) > 0,
              !(from + to).contains("=>"),
              !(from + to).unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !(numeric(from) && numeric(to)) else { return false }
        let groups = ["他她它祂", "的地得", "在再", "那哪", "做作", "以已", "即既", "象像"]
        let left = Array(from), right = Array(to)
        if left.count == right.count,
           zip(left, right).allSatisfy({ a, b in a == b || groups.contains { $0.contains(a) && $0.contains(b) } }) { return false }
        return true
    }

    private static func units(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var result: [String] = []
        var last = text.startIndex
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if last < range.lowerBound { result += text[last..<range.lowerBound].map(String.init) }
            result.append(String(text[range])); last = range.upperBound
            return true
        }
        if last < text.endIndex { result += text[last...].map(String.init) }
        return result
    }

    private static func weight(_ text: String) -> Int { text.filter { $0.isLetter || $0.isNumber }.count }
    private static func trim(_ text: String) -> String {
        String(text.drop(while: { !$0.isLetter && !$0.isNumber }).reversed()
            .drop(while: { !$0.isLetter && !$0.isNumber }).reversed())
    }
    private static func numeric(_ text: String) -> Bool {
        text.allSatisfy { $0.isNumber || $0.isWhitespace || "〇零一二三四五六七八九十百千万亿两.,:：".contains($0) }
    }
}

/// One tracked insertion: readings are already bounded and tied to its field.
/// Timings follow Arion: 2s to observe paste, 15s edit idle, 60s maximum.
struct EditLearningSession {
    enum Reading { case text(String), focusLost, cleared, failed, unsafe }
    enum Outcome: Equatable { case watching, finished([LearnedWordPair]) }
    let inserted: String
    let prefix: String
    let suffix: String
    let started: TimeInterval
    private(set) var baselineSeen = false
    private(set) var last: String?
    private var changed: TimeInterval
    private var failures = 0

    init(inserted: String, prefix: String, suffix: String, now: TimeInterval) {
        self.inserted = inserted; self.prefix = prefix; self.suffix = suffix
        started = now; changed = now
    }

    mutating func observe(_ reading: Reading, now: TimeInterval) -> Outcome {
        if case .unsafe = reading { return .finished([]) }
        switch reading {
        case .failed:
            failures += 1
            if failures >= 3 { return .finished([]) }
        case .focusLost, .cleared:
            return finish()
        case .text(let text):
            failures = 0
            if !baselineSeen {
                if text == prefix + inserted + suffix { baselineSeen = true; last = text; changed = now }
            } else {
                guard text.hasPrefix(prefix), text.hasSuffix(suffix) else { return .finished([]) }
                if text != last { last = text; changed = now }
            }
        case .unsafe: return .finished([])
        }
        if !baselineSeen, now - started >= 2 { return .finished([]) }
        if now - started >= 60 || (baselineSeen && now - changed >= 15) { return finish() }
        return .watching
    }

    func finish() -> Outcome {
        guard baselineSeen, let last else { return .finished([]) }
        return .finished(EditCorrectionExtractor.extract(inserted: inserted, prefix: prefix, suffix: suffix, settled: last))
    }
}

/// Automatic vocabulary is separate from manually authored correction pairs.
/// Undo restores only this store, including the replaced rule, across restarts.
@MainActor
final class EditLearningStore: ObservableObject {
    static let shared = EditLearningStore()
    struct Entry: Codable, Equatable, Identifiable {
        let id: UUID
        let pair: LearnedWordPair
        let date: Date
    }
    struct Undo: Codable { let before: [Entry]; let learned: [Entry] }
    struct State: Codable { var entries: [Entry] = []; var undo: Undo? }
    @Published private(set) var state: State
    private let defaults: UserDefaults
    private let key = "automatic_edit_learning_state"
    var entries: [Entry] { state.entries }
    var canUndo: Bool { state.undo != nil }
    var latestPairs: [LearnedWordPair] { state.undo?.learned.map(\.pair) ?? [] }
    var rules: String { entries.map { "\($0.pair.from) => \($0.pair.to)" }.joined(separator: "\n") }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        state = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    @discardableResult
    func learn(_ pairs: [LearnedWordPair], manualRules: String) -> Bool {
        let manual = Set(VocabularyCorrections.pairs(from: manualRules).map(\.0))
        let before = entries
        var next = state
        var learned: [Entry] = []
        for pair in pairs where EditCorrectionExtractor.valid(pair) && !manual.contains(pair.from) {
            guard next.entries.first(where: { $0.pair.from == pair.from })?.pair != pair else { continue }
            next.entries.removeAll { $0.pair.from == pair.from }
            let entry = Entry(id: UUID(), pair: pair, date: Date())
            next.entries.insert(entry, at: 0); learned.append(entry)
        }
        guard !learned.isEmpty else { return false }
        next.entries = Array(next.entries.prefix(200))
        next.undo = Undo(before: before, learned: learned)
        state = next; persist()
        return true
    }

    func undoLast() {
        guard let undo = state.undo else { return }
        state = State(entries: undo.before, undo: nil); persist()
    }
    func remove(_ id: UUID) {
        var next = state
        next.entries.removeAll { $0.id == id }; next.undo = nil
        state = next; persist()
    }
    func clear() { state = State(); persist() }
    private func persist() {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: key) }
    }
}
