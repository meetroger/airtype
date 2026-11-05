import Foundation

@main
struct PersonalizationChecks {
    static func main() {
        assert(FloatingEscapeAction.resolve(visible: false, recording: true, processing: false, reviewing: false) == .none)
        assert(FloatingEscapeAction.resolve(visible: true, recording: true, processing: false, reviewing: false) == .cancelRecording)
        assert(FloatingEscapeAction.resolve(visible: true, recording: false, processing: true, reviewing: false) == .cancelProcessing)
        assert(FloatingEscapeAction.resolve(visible: true, recording: false, processing: false, reviewing: true) == .saveReview)
        assert(FloatingEscapeAction.resolve(visible: true, recording: false, processing: true, reviewing: true) == .saveReview)
        assert(FloatingEscapeAction.resolve(visible: true, recording: false, processing: false, reviewing: false) == .hide)
        let rules = "foo => bar\nbar => baz\nfoo bar => longest\n爱尔泰普 => Airtype"
        assert(VocabularyCorrections.apply("foo bar foo barista 爱尔泰普项目", rules: rules) == "longest bar barista Airtype项目")
        assert(VocabularyCorrections.apply("foo_bar foo2 food foo", rules: rules) == "foo_bar foo2 food bar")
        assert(VocabularyCorrections.apply("hello", rules: " => bad\nhello => \nx => y => z") == "hello")
        assert(VocabularyCorrections.apply("foo", rules: "foo => first\nfoo => second") == "first")
        assert(VocabularyCorrections.relevantTerms(["Airtype", "OpenAI", "无关"], in: "airtype uses openai") == ["Airtype", "OpenAI"])
        assert(VocabularyCorrections.relevantTerms(["Arion", "LLAMA", "OpenAI"], in: "看看 A R I O N 和 L L A M A") == ["Arion", "LLAMA"])
        assert(DictationScene.resolve(choice: "Automatic", bundleID: "com.apple.mail", searchField: false, overrides: "") == .email)
        assert(DictationScene.resolve(choice: "Chat", bundleID: "com.apple.mail", searchField: true, overrides: "") == .chat)
        assert(DictationScene.resolve(choice: "Automatic", bundleID: "app", searchField: true, overrides: "app => Email") == .email)
        assert(DictationScene.resolve(choice: "Automatic", bundleID: "app", searchField: true, overrides: "invalid") == .search)
        assert(DictationContext.sanitize("a\u{0}b\nc\t") == "ab\nc\t")
        assert(DictationContext.sanitize(String(repeating: "中", count: 500)).count == 400)
        print("Personalization checks passed")
    }
}
