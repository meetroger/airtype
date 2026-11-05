import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

/// An immutable, bounded AX anchor captured immediately before our paste.
/// The range stays at the original insertion, never follows another caret.
final class EditLearningField: @unchecked Sendable {
    let target: DictationTarget
    let inserted: String
    let prefix: String
    let suffix: String
    let start: Int
    let outsideLength: Int

    private init(target: DictationTarget, inserted: String, prefix: String, suffix: String, start: Int, outsideLength: Int) {
        self.target = target; self.inserted = inserted; self.prefix = prefix
        self.suffix = suffix; self.start = start; self.outsideLength = outsideLength
    }

    static func capture(target: DictationTarget, inserted: String) -> EditLearningField? {
        guard !inserted.isEmpty, inserted.utf16.count <= EditCorrectionExtractor.maxTextLength,
              safe(target), target.focusMatches(),
              let value = DictationTarget.attribute(target.element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID(),
              let count = count(target) else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &selection),
              selection.location >= 0, selection.length >= 0,
              selection.length <= EditCorrectionExtractor.maxTextLength,
              selection.location <= count, selection.length <= count - selection.location else { return nil }
        let start = max(0, selection.location - 128)
        let end = min(count, selection.location + selection.length + 128)
        guard let text = read(target, range: CFRange(location: start, length: end - start)),
              let before = Range(NSRange(location: 0, length: selection.location - start), in: text),
              let after = Range(NSRange(location: selection.location - start + selection.length,
                  length: end - selection.location - selection.length), in: text) else { return nil }
        return EditLearningField(target: target, inserted: inserted, prefix: String(text[before]),
            suffix: String(text[after]), start: start, outsideLength: count - (end - start))
    }

    func snapshot() -> EditLearningSession.Reading {
        guard Self.safe(target) else { return .unsafe }
        guard target.focusMatches() else { return .focusLost }
        guard let count = Self.count(target) else { return .failed }
        if count == 0 { return .cleared }
        let length = count - outsideLength
        guard length >= 0, length <= 4096, start <= count, length <= count - start else { return .unsafe }
        guard let text = Self.read(target, range: CFRange(location: start, length: length)) else { return .failed }
        // Verify again after reading: no reading from a field that lost ownership.
        guard Self.safe(target) else { return .unsafe }
        guard target.focusMatches() else { return .focusLost }
        return .text(text)
    }

    private static func safe(_ target: DictationTarget) -> Bool {
        let denied = ["1password", "bitwarden", "lastpass", "keychain", "keepass", "dashlane", "passwords"]
        let bundle = target.application.bundleIdentifier?.lowercased() ?? ""
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(), !target.application.isTerminated,
              !denied.contains(where: { bundle.contains($0) }),
              DictationTarget.attribute(target.element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole,
              (DictationTarget.attribute(target.element, "AXProtectedContent") as? Bool) != true,
              let role = DictationTarget.attribute(target.element, kAXRoleAttribute) as? String else { return false }
        return role == kAXTextAreaRole || role == kAXTextFieldRole
    }
    private static func count(_ target: DictationTarget) -> Int? {
        (DictationTarget.attribute(target.element, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue
    }
    private static func read(_ target: DictationTarget, range: CFRange) -> String? {
        guard range.length <= 4096 else { return nil }
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(target.element,
            kAXStringForRangeParameterizedAttribute as CFString, value, &result) == .success else { return nil }
        return result as? String
    }
}

@MainActor
final class EditLearningTracker {
    static let shared = EditLearningTracker(store: .shared, settings: .shared)
    var onLearned: (() -> Void)?
    private let store: EditLearningStore
    private let settings: Settings
    private var task: Task<Void, Never>?
    private var session: EditLearningSession?
    private var token: UUID?

    init(store: EditLearningStore, settings: Settings) { self.store = store; self.settings = settings }

    func start(_ field: EditLearningField) {
        settle()
        guard settings.automaticEditLearningEnabled else { return }
        let id = UUID()
        token = id
        session = EditLearningSession(inserted: field.inserted, prefix: field.prefix,
            suffix: field.suffix, now: ProcessInfo.processInfo.systemUptime)
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000)
            while !Task.isCancelled {
                guard let self, self.token == id else { return }
                guard self.settings.automaticEditLearningEnabled else { self.abandon(); return }
                let reading = await Task.detached(priority: .utility) { field.snapshot() }.value
                guard !Task.isCancelled, self.token == id, var session = self.session else { return }
                guard self.settings.automaticEditLearningEnabled else { self.abandon(); return }
                let outcome = session.observe(reading, now: ProcessInfo.processInfo.systemUptime)
                self.session = session
                if case .finished(let pairs) = outcome {
                    self.abandon(); self.learn(pairs); return
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    func settle() {
        let outcome = session?.finish()
        abandon()
        if case .finished(let pairs) = outcome { learn(pairs) }
    }
    func abandon() {
        token = nil; session = nil; task?.cancel(); task = nil
    }
    private func learn(_ pairs: [LearnedWordPair]) {
        guard settings.automaticEditLearningEnabled,
              store.learn(pairs, manualRules: settings.correctionPairs) else { return }
        onLearned?()
    }
}

/// An inactive notice with a real Undo button; it never takes editor focus.
@MainActor
final class EditLearningNoticeController {
    static let shared = EditLearningNoticeController()
    private class NoticePanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    func show() {
        guard !EditLearningStore.shared.latestPairs.isEmpty else { return }
        hide()
        let panel = NoticePanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 76),
            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: EditLearningNoticeView())
        if let frame = FocusedScreenLocator.current()?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - 250, y: frame.minY + 28))
        }
        self.panel = panel
        panel.orderFrontRegardless()
        dismissTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            self?.hide()
        }
    }
    func hide() { dismissTask?.cancel(); dismissTask = nil; panel?.orderOut(nil); panel = nil }
}

private struct EditLearningNoticeView: View {
    @ObservedObject private var store = EditLearningStore.shared
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 3) {
                Text("Learned your correction").font(.system(size: 12, weight: .semibold))
                Text(store.latestPairs.map { "\($0.from) → \($0.to)" }.joined(separator: ", "))
                    .font(.system(size: 12)).lineLimit(1)
            }
            Spacer()
            Button("Undo") { store.undoLast(); EditLearningTracker.shared.abandon(); EditLearningNoticeController.shared.hide() }
            Button { EditLearningNoticeController.shared.hide() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).help("Dismiss")
        }
        .padding(14)
        .frame(width: 500, height: 76)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
