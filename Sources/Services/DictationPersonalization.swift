import Foundation

/// Explicit correction pairs are applied locally, once, without chaining.
enum VocabularyCorrections {
    static func pairs(from source: String) -> [(String, String)] {
        var seen = Set<String>()
        return source.components(separatedBy: .newlines).compactMap { line in
            let parts = line.components(separatedBy: "=>")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
                  parts[0].count <= 80, parts[1].count <= 80,
                  seen.insert(parts[0]).inserted else { return nil }
            return (parts[0], parts[1])
        }.sorted { $0.0.count > $1.0.count }
    }

    static func relevantTerms(_ terms: [String], in text: String) -> [String] {
        func phonetic(_ value: String) -> String {
            (value.applyingTransform(.toLatin, reverse: false) ?? value)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .filter { $0.isLetter || $0.isNumber }
        }
        let sound = phonetic(text)
        return Array(terms.filter { term in
            if text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return true }
            let candidate = phonetic(term)
            return candidate.count >= 4 && sound.contains(candidate)
        }.prefix(8)).map { String($0.prefix(80)) }
    }

    static func apply(_ text: String, rules: String) -> String {
        let pairs = pairs(from: rules)
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            if let pair = pairs.first(where: { heard, _ in
                guard text[index...].hasPrefix(heard) else { return false }
                let end = text.index(index, offsetBy: heard.count)
                // Latin identifiers require whole-word boundaries; CJK permits compounds.
                let latin: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
                let beforeOK = !latin(heard.first!) || index == text.startIndex || !latin(text[text.index(before: index)])
                let afterOK = !latin(heard.last!) || end == text.endIndex || !latin(text[end])
                return beforeOK && afterOK
            }) {
                output += pair.1
                index = text.index(index, offsetBy: pair.0.count)
            } else {
                output.append(text[index])
                index = text.index(after: index)
            }
        }
        return output
    }
}
