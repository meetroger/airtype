import Foundation

@main
struct HistoryChecks {
    static func main() {
        let suite = "airtype-history-checks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = TranscriptionHistory(defaults: defaults)
        let failed = history.save(text: "first draft", inserted: false)
        let retry = history.save(text: "edited draft", inserted: false, id: failed.id)
        assert(history.entries.count == 1)
        assert(retry.id == failed.id && retry.date == failed.date)
        assert(history.entries[0].text == "edited draft" && !history.entries[0].inserted)
        history.save(text: retry.text, inserted: true, id: retry.id)
        assert(history.entries.count == 1 && history.entries[0].inserted)
        history.save(text: "new dictation", inserted: false)
        assert(history.entries.count == 2)
        // Existing persisted entries have no new required fields.
        assert(TranscriptionHistory(defaults: defaults).entries.count == 2)
        for index in 0..<60 { history.save(text: "item \(index)", inserted: false) }
        assert(history.entries.count == 50)
        history.clear()
        assert(history.entries.isEmpty)
        print("History checks passed")
    }
}
