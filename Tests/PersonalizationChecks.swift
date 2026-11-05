import Foundation

@main
struct PersonalizationChecks {
    static func main() {
        let rules = "foo => bar\nbar => baz\nfoo bar => longest\n爱尔泰普 => Airtype"
        assert(VocabularyCorrections.apply("foo bar foo barista 爱尔泰普项目", rules: rules) == "longest bar barista Airtype项目")
        assert(VocabularyCorrections.apply("foo_bar foo2 food foo", rules: rules) == "foo_bar foo2 food bar")
        assert(VocabularyCorrections.apply("hello", rules: " => bad\nhello => \nx => y => z") == "hello")
        assert(VocabularyCorrections.apply("foo", rules: "foo => first\nfoo => second") == "first")
        print("Personalization checks passed")
    }
}
