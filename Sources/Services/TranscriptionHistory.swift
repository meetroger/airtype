import Foundation

/// Persists recent transcriptions locally so text is never lost.
class TranscriptionHistory {
    static let shared = TranscriptionHistory()

    private let key = "transcriptionHistory"
    private let maxEntries = 50

    struct Entry: Codable, Identifiable {
        let id: UUID
        let text: String
        let date: Date
        let inserted: Bool

        init(id: UUID = UUID(), text: String, inserted: Bool, date: Date = Date()) {
            self.id = id
            self.text = text
            self.date = date
            self.inserted = inserted
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var entries: [Entry] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else {
            return []
        }
        return decoded
    }

    @discardableResult
    func save(text: String, inserted: Bool, id: UUID? = nil) -> Entry {
        var list = entries
        let previous = id.flatMap { id in list.first { $0.id == id } }
        let entry = Entry(id: id ?? UUID(), text: text, inserted: inserted, date: previous?.date ?? Date())
        list.removeAll { $0.id == entry.id }
        list.insert(entry, at: 0)
        if list.count > maxEntries { list = Array(list.prefix(maxEntries)) }
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: key)
        }
        return entry
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
