import Foundation

struct MicSource: Identifiable, Equatable {
    let id: UUID
    let name: String
    let isAvailable: Bool
    var label: String { "\(name) · \(id.uuidString.suffix(6))" }
}

/// A selection stays pinned by identity through discovery changes and outages.
/// Advertising freshness is separate from the system's existing HID connection.
struct MicSourceCatalog {
    private var names: [UUID: String] = [:]
    private var lastSeen: [UUID: TimeInterval] = [:]
    private var systemConnected: Set<UUID> = []
    private(set) var selectedID: UUID?
    init(selectedID: UUID?, selectedName: String?) {
        self.selectedID = selectedID
        if let id = selectedID { names[id] = selectedName ?? "BLE 麦克风" }
    }
    mutating func remember(_ id: UUID, name: String?) {
        if let name, !name.isEmpty { names[id] = name }
        else if names[id] == nil { names[id] = "BLE 麦克风" }
    }
    mutating func observe(_ id: UUID, name: String?, now: TimeInterval) {
        remember(id, name: name); lastSeen[id] = now
    }
    mutating func updateSystemConnections(_ ids: Set<UUID>) { systemConnected = ids }
    @discardableResult mutating func select(_ id: UUID) -> Bool {
        guard names[id] != nil, selectedID != id else { return false }
        selectedID = id; return true
    }
    func sources(now: TimeInterval) -> [MicSource] {
        names.map { id, name in
            MicSource(id: id, name: name, isAvailable: systemConnected.contains(id) || lastSeen[id].map { now-$0 < 20 } == true)
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }
}
