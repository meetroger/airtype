import Foundation

@main
struct EditLearningChecks {
    @MainActor
    static func main() {
        func check(_ source: String, _ corrected: String, _ expected: [LearnedWordPair], prefix: String = "", suffix: String = "") {
            let actual = EditCorrectionExtractor.extract(inserted: source, prefix: prefix,
                suffix: suffix, settled: prefix + corrected + suffix)
            assert(actual == expected, "\(source) → \(corrected): got \(actual), expected \(expected)")
        }
        let latin = LearnedWordPair(from: "jason", to: "Jayson")
        let chinese = LearnedWordPair(from: "阿里昂", to: "Arion")
        check("please ask jason about the release", "please ask Jayson about the release", [latin])
        check("we use open ai models", "we use OpenAI models", [.init(from: "open ai", to: "OpenAI")])
        check("我想看看阿里昂项目的设置", "我想看看Arion项目的设置", [chinese])
        check("请打开杰森文件看看内容", "请打开JSON文件看看内容", [.init(from: "杰森", to: "JSON")])
        check("please ask jason about the release", "please ask Jayson about the release", [latin], prefix: "😀 Earlier: ", suffix: "\nOther text")
        check("we meet at 12:30 tomorrow", "we meet at 13:45 tomorrow", [])
        check("我们在这里等他回来", "我们在这里等她回来", [])
        check("we use the old model today", "We use the old model today", [])
        check("I think this is fine", "I think this is fine!", [])
        check("hello world", "a completely different and much longer new sentence", [])
        check("明天开会", "明天开会，记得带电脑", [])
        check("please ask jason about the release", "", [])
        check("please ask jason about the release", "please ask jason about the release", [])
        assert(EditCorrectionExtractor.extract(inserted: "please ask jason about the release", prefix: "Before: ",
            suffix: " END", settled: "Changed: please ask Jayson about the release END").isEmpty)
        assert(!EditCorrectionExtractor.valid(.init(from: "a", to: "an")))
        assert(!EditCorrectionExtractor.valid(.init(from: "long\nword", to: "longword")))

        let source = "please ask jason about the release"
        let edited = "please ask Jayson about the release"
        func established() -> EditLearningSession {
            var session = EditLearningSession(inserted: source, prefix: "", suffix: "", now: 0)
            assert(session.observe(.text(source), now: 0.1) == .watching)
            assert(session.observe(.text(edited), now: 1) == .watching)
            return session
        }
        var session = established()
        assert(session.observe(.text(edited), now: 15.9) == .watching)
        assert(session.observe(.text(edited), now: 16) == .finished([latin]))
        session = established()
        assert(session.observe(.focusLost, now: 2) == .finished([latin]))
        session = established()
        assert(session.observe(.cleared, now: 2) == .finished([latin]))
        assert(established().finish() == .finished([latin]))
        session = established()
        assert(session.observe(.unsafe, now: 2) == .finished([]))
        session = established()
        assert(session.observe(.failed, now: 2) == .watching)
        assert(session.observe(.failed, now: 2.4) == .watching)
        assert(session.observe(.failed, now: 2.8) == .finished([]))
        session = EditLearningSession(inserted: source, prefix: "", suffix: "", now: 0)
        assert(session.observe(.text(edited), now: 0.5) == .watching)
        assert(session.observe(.text(edited), now: 2) == .finished([]), "No learning without verified paste baseline")
        session = established()
        assert(session.observe(.text(edited + "!"), now: 60) == .finished([latin]))
        session = EditLearningSession(inserted: source, prefix: "prefix", suffix: "suffix", now: 0)
        _ = session.observe(.text("prefix" + source + "suffix"), now: 0.1)
        assert(session.observe(.text("outside" + edited + "suffix"), now: 1) == .finished([]))

        let suite = "airtype-learning-checks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EditLearningStore(defaults: defaults)
        assert(store.learn([latin], manualRules: ""))
        assert(store.entries.map(\.pair) == [latin] && store.canUndo)
        assert(!store.learn([latin], manualRules: ""), "No duplicate learning or discarded Undo")
        assert(store.canUndo)
        let replacement = LearnedWordPair(from: "jason", to: "Jasonn")
        assert(store.learn([replacement], manualRules: ""))
        let reopened = EditLearningStore(defaults: defaults)
        reopened.undoLast()
        assert(reopened.entries.map(\.pair) == [latin], "Undo restores the previous mapping after relaunch")
        assert(!reopened.canUndo)
        let rules = "jason => Manual\n" + reopened.rules
        assert(VocabularyCorrections.apply(source, rules: rules) == "please ask Manual about the release")
        assert(VocabularyCorrections.apply(source, rules: reopened.rules) == edited)
        assert(!reopened.learn([replacement], manualRules: "jason => Manual"))
        assert(reopened.learn([chinese], manualRules: ""))
        assert(VocabularyCorrections.apply("看看阿里昂项目", rules: reopened.rules) == "看看Arion项目")
        reopened.undoLast()
        assert(reopened.entries.map(\.pair) == [latin])
        reopened.remove(reopened.entries[0].id)
        assert(reopened.entries.isEmpty && !reopened.canUndo)
        assert(reopened.learn([latin, chinese], manualRules: ""))
        reopened.undoLast()
        assert(reopened.entries.isEmpty, "Undo reverts the complete learned batch")
        reopened.clear()
        print("Edit learning checks passed")
    }
}
