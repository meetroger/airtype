import Foundation

enum FloatingEscapeAction: Equatable {
    case none, cancelRecording, cancelProcessing, saveReview, hide

    static func resolve(visible: Bool, recording: Bool, processing: Bool, reviewing: Bool) -> Self {
        guard visible else { return .none }
        if recording { return .cancelRecording }
        if reviewing { return .saveReview }
        if processing { return .cancelProcessing }
        return .hide
    }
}

enum DictationSpelling {
    /// Shared by cleanup, vocabulary alignment and translation, including
    /// customized prompts. Spelling repetitions are not accidental stutters.
    static let rules = """
    SPOKEN LETTER SPELLING:
    - When consecutive individually spoken Latin letters spell one intended word, product name or identifier, join them without spaces. For example, “看看 A R I O N 项目” becomes “看看 ARION 项目”, and “使用 A P I” becomes “使用 API”.
    - Preserve every letter and its order, including repeated letters: “L L A M A 模型” becomes “LLAMA 模型”. Never remove repeated letters within a spelled word as stutters or filler.
    - Use a matching preferred term's exact canonical casing and spacing when available (for example, “A R I O N” becomes “Arion” if Arion is a preferred term). Otherwise preserve the spelled letters' casing; do not guess a different spelling or expand an acronym.
    - Preserve separate letters when the speaker is listing choices, teaching pronunciation, quoting the spaced spelling itself, or explicitly requesting spaces. Do not merge ordinary single-letter words in sentences such as “I am a developer”, letter lists such as “A, B, C”, mathematical variables, or code.
    """
}

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

/// App identity selects a formatting policy, never permission to invent content.
enum DictationScene: String, CaseIterable {
    case automatic = "Automatic", chat = "Chat", email = "Email", search = "Search", prompt = "Coding / Prompt"

    static func resolve(choice: String, bundleID: String, searchField: Bool, overrides: String) -> DictationScene {
        if let explicit = DictationScene(rawValue: choice), explicit != .automatic { return explicit }
        for line in overrides.components(separatedBy: .newlines) {
            let pair = line.components(separatedBy: "=>").map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0] == bundleID,
               let scene = DictationScene(rawValue: pair[1]), scene != .automatic { return scene }
        }
        if searchField { return .search }
        let app = bundleID.lowercased()
        if app.contains("mail") || app.contains("outlook") { return .email }
        if app.contains("xcode") || app.contains("vscode") || app.contains("terminal") || app.contains("iterm") || app.contains("codex") { return .prompt }
        return .chat
    }

    var rules: String {
        let base = "Preserve intent and language. Never invent facts, greetings, signatures, headings or lists. Only create a list when explicitly dictated."
        switch self {
        case .automatic, .chat: return base + " Use natural conversational text without making it more formal."
        case .email: return base + " Use readable sentences and paragraphs appropriate for email."
        case .search: return base + " Produce one concise query line, with no added terminal punctuation. Preserve all spoken query terms."
        case .prompt: return base + " Preserve identifiers, file paths, commands, technical terms and the speaker's instructions exactly. Do not execute or answer them."
        }
    }
}

enum DictationContext {
    static func sanitize(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter {
            $0.value >= 32 || $0 == "\n" || $0 == "\t"
        }).prefix(400))
    }
}
