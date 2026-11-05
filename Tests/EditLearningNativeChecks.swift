import AppKit
import ApplicationServices
import Darwin

// The production reader, paste transaction, tracker and store are compiled.
// Only application-wide settings, screen positioning and logging are stubbed.
final class Settings {
    static let shared = Settings()
    var automaticEditLearningEnabled = true
    var correctionPairs = ""
}
enum FocusedScreenLocator { static func current() -> NSScreen? { NSScreen.main } }
func debugLog(_ message: String) {}

@MainActor
private final class EditorFixture: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var other: NSWindow!
    var editor: NSTextView!
    var signals: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu(title: "Fixture")
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
        editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 160))
        editor.string = "Before: \n END"
        window = NSWindow(contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Airtype learning test — temporary editor"
        window.contentView = editor
        window.center(); window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 8, length: 0))
        NSApp.activate(ignoringOtherApps: true)
        signal(SIGUSR1, SIG_IGN); signal(SIGUSR2, SIG_IGN)
        let edit = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        edit.setEventHandler { [weak self] in
            guard let editor = self?.editor else { return }
            editor.string = editor.string.replacingOccurrences(of: "jason", with: "Jayson")
                .replacingOccurrences(of: "阿里昂", with: "Arion")
            editor.didChangeText()
        }
        let leave = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        leave.setEventHandler { [weak self] in
            guard let self else { return }
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
            text.string = "Another editor: must never be learned"
            self.other = NSWindow(contentRect: text.frame, styleMask: [.titled], backing: .buffered, defer: false)
            self.other.contentView = text
            self.other.makeKeyAndOrderFront(nil); self.other.makeFirstResponder(text)
        }
        signals = [edit, leave]
        signals.forEach { $0.resume() }
    }
}

@main
struct EditLearningNativeChecks {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--fixture") {
            let delegate = EditorFixture()
            app.setActivationPolicy(.regular)
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        } else {
            guard AXIsProcessTrusted() else {
                print("Native edit learning checks skipped: test host has no Accessibility permission")
                return
            }
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                do {
                    if CommandLine.arguments.contains("--window-only") {
                        try await runWindowFallbackCase()
                        exit(0)
                    }
                    try await runCase("please ask jason about the release", expected: .init(from: "jason", to: "Jayson"))
                    try await runCase("我想看看阿里昂项目的设置", expected: .init(from: "阿里昂", to: "Arion"))
                    try await runCase("please ask jason about the release", expected: .init(from: "jason", to: "Jayson"), enabled: false)
                    try await runWindowFallbackCase()
                    print("Native edit learning checks passed (paste → AX observation → focus settlement → persisted learning → undo)")
                    exit(0)
                } catch {
                    fputs("Native edit learning check failed: \(error)\n", stderr)
                    exit(1)
                }
            }
            app.run()
        }
    }

    @MainActor
    private static func runCase(_ inserted: String, expected: LearnedWordPair, enabled: Bool = true) async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--fixture"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        var captured: DictationTarget?
        for _ in 0..<100 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == child.processIdentifier,
               let target = try? DictationTarget.capture(),
               EditLearningField.capture(target: target, inserted: inserted) != nil {
                captured = target; break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let target = captured, let field = EditLearningField.capture(target: target, inserted: inserted) else {
            throw Failure(message: "Could not capture temporary native editor")
        }
        let suite = "airtype-native-learning-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EditLearningStore(defaults: defaults)
        let settings = Settings()
        settings.automaticEditLearningEnabled = enabled
        let tracker = EditLearningTracker(store: store, settings: settings)
        defer { tracker.abandon() }
        var notices = 0
        tracker.onLearned = { notices += 1 }
        try await TextInserter().insert(text: inserted, target: target)
        tracker.start(field)
        try await Task.sleep(nanoseconds: 650_000_000)
        let snapshot = field.snapshot()
        guard case .text(let pasted) = snapshot, pasted == "Before: " + inserted + "\n END" else {
            throw Failure(message: "Paste was not observed in its captured range: \(snapshot)")
        }
        kill(child.processIdentifier, SIGUSR1)
        try await Task.sleep(nanoseconds: 800_000_000)
        kill(child.processIdentifier, SIGUSR2)
        for _ in 0..<40 {
            if !store.entries.isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if !enabled {
            guard store.entries.isEmpty, notices == 0 else { throw Failure(message: "Disabled learning still stored a correction") }
            return
        }
        guard store.entries.map(\.pair) == [expected], notices == 1 else {
            throw Failure(message: "Unexpected learning or missing notice: \(store.entries)")
        }
        let reopened = EditLearningStore(defaults: defaults)
        guard VocabularyCorrections.apply(inserted, rules: reopened.rules) == inserted.replacingOccurrences(of: expected.from, with: expected.to) else {
            throw Failure(message: "Learned correction did not apply on the next transcription")
        }
        reopened.undoLast()
        guard reopened.entries.isEmpty, VocabularyCorrections.apply(inserted, rules: reopened.rules) == inserted else {
            throw Failure(message: "Undo did not remove the learned correction")
        }
    }

    private struct Failure: Error { let message: String }

    @MainActor
    private static func runWindowFallbackCase() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--fixture"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let inserted = "Window fallback works without reading the editor"
        var captured: DictationTarget?
        for _ in 0..<100 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == child.processIdentifier,
               let target = try? DictationTarget.capture(),
               EditLearningField.capture(target: target, inserted: inserted) != nil {
                captured = target; break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let readable = captured, let field = EditLearningField.capture(target: readable, inserted: inserted) else {
            throw Failure(message: "Window fallback fixture unavailable")
        }
        let target = try DictationTarget.captureWindowTarget(for: readable.application)
        guard target.usesWindowFallback, target.element == nil, target.readCursorContext().isEmpty,
              EditLearningField.capture(target: target, inserted: inserted) == nil else {
            throw Failure(message: "Window-only delivery unexpectedly inspected editor contents")
        }
        try await TextInserter().insert(text: inserted, target: target, learnEdits: true)
        var snapshot = field.snapshot()
        for _ in 0..<20 {
            if case .text(let pasted) = snapshot, pasted == "Before: " + inserted + "\n END" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
            snapshot = field.snapshot()
        }
        guard case .text(let pasted) = snapshot, pasted == "Before: " + inserted + "\n END" else {
            throw Failure(message: "Window-only paste did not reach the native editor: \(snapshot)")
        }
        kill(child.processIdentifier, SIGUSR2)
        for _ in 0..<40 {
            if !target.focusMatches() { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let changeCount = NSPasteboard.general.changeCount
        do {
            try await TextInserter().insert(text: "MUST NOT PASTE INTO ANOTHER WINDOW", target: target)
            throw Failure(message: "Window-only target followed another window")
        } catch TextInsertionError.targetChanged {}
        guard NSPasteboard.general.changeCount == changeCount else {
            throw Failure(message: "Rejected window-only paste still changed clipboard")
        }
        print("Window fallback checks passed (no AX editor → real paste; changed window → refused)")
    }
}
