import Foundation

@main struct BLEMicSourceChecks {
static func main() {
let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
let unknown = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
var sources = MicSourceCatalog(selectedID: b, selectedName: "Remembered")
sources.observe(a, name: "Passport Mic", now: 100)
sources.updateSystemConnections([a])
assert(sources.selectedID == b, "A newly available device must not steal a pinned selection")
assert(sources.sources(now: 101).first(where: { $0.id == b })?.isAvailable == false)
sources.observe(b, name: "Passport Mic", now: 101)
let duplicates = sources.sources(now: 102)
assert(duplicates.count == 2 && duplicates[0].label != duplicates[1].label, "Same-name microphones need distinct menu labels")
assert(sources.select(a) && sources.selectedID == a)
assert(!sources.select(unknown) && sources.selectedID == a, "Unknown selections must be ignored")
sources.updateSystemConnections([])
assert(sources.sources(now: 130).allSatisfy { !$0.isAvailable })
assert(sources.selectedID == a, "Losing availability must not fall back to another microphone")
sources.updateSystemConnections([b])
assert(sources.sources(now: 1000).first(where: { $0.id == b })!.isAvailable, "System HID connection remains selectable after advertising stops")
assert(sources.selectedID == a)
sources.observe(a, name: "Renamed microphone", now: 1001)
assert(sources.selectedID == a && sources.sources(now: 1001).contains(where: { $0.id == a && $0.name == "Renamed microphone" }))
var restored = MicSourceCatalog(selectedID: sources.selectedID, selectedName: "Renamed microphone")
restored.observe(b, name: "Other microphone", now: 2000)
assert(restored.selectedID == a)
print("PASS: stable identity, duplicate names, offline pinning, system-connected discovery, rename and restored preference")

}
}
