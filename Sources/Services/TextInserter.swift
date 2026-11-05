import AppKit
import Carbon.HIToolbox
import ApplicationServices

/// A recording owns one editor and selection. Never retarget a delayed result.
struct DictationTarget {
    let application: NSRunningApplication
    let element: AXUIElement
    private let selection: CFTypeRef?
    private let window: AXUIElement?
    private let characterCount: Int?

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func capture() throws -> DictationTarget {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let focused = attribute(applicationElement(app), kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            throw TextInsertionError.targetUnavailable
        }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.2)
        let role = attribute(element, kAXSubroleAttribute) as? String
        guard role != kAXSecureTextFieldSubrole else { throw TextInsertionError.secureField }
        let windowValue = attribute(element, kAXWindowAttribute)
        let window = windowValue.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        if let window { AXUIElementSetMessagingTimeout(window, 0.2) }
        return DictationTarget(application: app, element: element,
                               selection: attribute(element, kAXSelectedTextRangeAttribute), window: window,
                               characterCount: (attribute(element, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue)
    }

    var applicationName: String { application.localizedName ?? "original app" }

    /// Explicit Insert may return to the captured editor. Automatic delivery
    /// never calls this: it must not steal focus while the user is working.
    @MainActor
    func restoreFocus() async throws {
        guard AXIsProcessTrusted() else { throw TextInsertionError.noAccessibilityPermission }
        guard !application.isTerminated,
              Self.attribute(element, kAXRoleAttribute) != nil,
              Self.attribute(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else {
            throw TextInsertionError.targetUnavailable
        }
        try Task.checkCancellation()
        guard application.activate() else { throw TextInsertionError.targetUnavailable }
        // Wait for observed activation instead of assuming a fixed delay is enough.
        for _ in 0..<28 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try Task.checkCancellation()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else {
            throw TextInsertionError.targetChanged
        }
        if let window {
            _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        // Restoring a field can be asynchronous in browser and Electron editors.
        for _ in 0..<12 {
            try Task.checkCancellation()
            if focusMatches() { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        guard focusMatches() else { throw TextInsertionError.targetChanged }
        if let selection, let current = Self.attribute(element, kAXSelectedTextRangeAttribute),
           !CFEqual(selection, current) {
            // A length change makes the old range unsafe to restore. Do not
            // overwrite text at a stale offset after the document was edited.
            if let characterCount,
               (Self.attribute(element, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue != characterCount {
                throw TextInsertionError.targetChanged
            }
            guard AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, selection) == .success else {
                throw TextInsertionError.targetChanged
            }
        }
        try validate()
    }

    func focusMatches() -> Bool {
        let app = Self.applicationElement(application)
        guard !application.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
              let current = Self.attribute(app, kAXFocusedUIElementAttribute),
              CFEqual(current, element) else { return false }
        if let window {
            guard let currentWindow = Self.attribute(app, kAXFocusedWindowAttribute),
                  CFEqual(currentWindow, window) else { return false }
        }
        return Self.attribute(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole
    }

    private static func applicationElement(_ application: NSRunningApplication) -> AXUIElement {
        let element = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.2)
        return element
    }

    var isSearchField: Bool {
        Self.attribute(element, kAXSubroleAttribute) as? String == "AXSearchField"
    }

    /// Request only a bounded range; never read the complete editor value.
    func readCursorContext() -> String {
        let denied = ["1password", "bitwarden", "lastpass", "keychain", "keepass", "dashlane", "passwords"]
        let bundle = application.bundleIdentifier?.lowercased() ?? ""
        guard !denied.contains(where: { bundle.contains($0) }),
              Self.attribute(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole,
              let selection, CFGetTypeID(selection) == AXValueGetTypeID(),
              let count = Self.attribute(element, kAXNumberOfCharactersAttribute) as? NSNumber else { return "" }
        var cursor = CFRange()
        guard AXValueGetValue(selection as! AXValue, .cfRange, &cursor), cursor.location >= 0,
              cursor.location <= count.intValue else { return "" }
        let start = max(0, cursor.location - 200)
        var range = CFRange(location: start, length: min(400, count.intValue - start))
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return "" }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element,
            kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &result) == .success,
              let text = result as? String else { return "" }
        return DictationContext.sanitize(text)
    }

    func validate() throws {
        guard focusMatches() else { throw TextInsertionError.targetChanged }
        if let selection {
            guard let currentSelection = Self.attribute(element, kAXSelectedTextRangeAttribute),
                  CFEqual(selection, currentSelection) else { throw TextInsertionError.targetChanged }
        }
    }
}

/// Inserts text at the current cursor position using system paste
@MainActor
class TextInserter {

    /// A data-backed copy of every readable pasteboard item and type. Keeping
    /// the full representation preserves rich text, images, files, and custom
    /// application formats instead of restoring only a plain-text string.
    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]

        init(pasteboard: NSPasteboard) {
            items = (pasteboard.pasteboardItems ?? []).compactMap { item in
                let representations = Dictionary(
                    uniqueKeysWithValues: item.types.compactMap { type in
                        item.data(forType: type).map { (type, $0) }
                    }
                )
                return representations.isEmpty ? nil : representations
            }
        }

        @discardableResult
        func restore(to pasteboard: NSPasteboard) -> Bool {
            pasteboard.clearContents()
            guard !items.isEmpty else { return true }

            let restoredItems = items.map { representations in
                let item = NSPasteboardItem()
                for (type, data) in representations {
                    item.setData(data, forType: type)
                }
                return item
            }
            return pasteboard.writeObjects(restoredItems)
        }
    }

    /// Check if accessibility is enabled
    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Insert text at current cursor position
    /// Uses clipboard + paste for reliable cross-app insertion
    func insert(text: String, target: DictationTarget, learnEdits: Bool = false) async throws {
        try target.validate()
        EditLearningTracker.shared.settle()
        let learningField: EditLearningField?
        if learnEdits && Settings.shared.automaticEditLearningEnabled {
            learningField = await Task.detached(priority: .utility) {
                EditLearningField.capture(target: target, inserted: text)
            }.value
        } else { learningField = nil }
        try Task.checkCancellation()
        try target.validate()
        debugLog("TextInserter.insert called with \(text.count) characters")

        // Check accessibility permission
        if !hasAccessibilityPermission {
            debugLog("WARNING: Accessibility permission NOT granted!")
            debugLog("Requesting accessibility permission...")
            // This will prompt the user
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            let trusted = AXIsProcessTrustedWithOptions(options)
            debugLog("AXIsProcessTrustedWithOptions returned: \(trusted)")

            if !trusted {
                throw TextInsertionError.noAccessibilityPermission
            }
        } else {
            debugLog("Accessibility permission granted")
        }

        // Store every readable clipboard representation so the temporary paste
        // operation is invisible to the user's existing clipboard contents.
        let pasteboard = NSPasteboard.general
        let previousContents = PasteboardSnapshot(pasteboard: pasteboard)

        // Set our text to clipboard
        pasteboard.clearContents()
        let success = pasteboard.setString(text, forType: .string)
        debugLog("Clipboard set success: \(success)")
        guard success else {
            _ = previousContents.restore(to: pasteboard)
            throw TextInsertionError.clipboardUnavailable
        }

        // Only restore if the clipboard still contains our temporary value. If
        // the user or another app changes it while insertion is in progress,
        // that newer content must win.
        let temporaryClipboardChangeCount = pasteboard.changeCount
        defer {
            if pasteboard.changeCount == temporaryClipboardChangeCount {
                let restored = previousContents.restore(to: pasteboard)
                debugLog("Previous clipboard restored: \(restored)")
            } else {
                debugLog("Clipboard changed externally; preserving newer contents")
            }
        }

        // Small delay to ensure clipboard is ready
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // Simulate Cmd+V paste
        debugLog("Simulating Cmd+V...")
        try Task.checkCancellation()
        try target.validate()
        try simulatePaste()
        if let learningField { EditLearningTracker.shared.start(learningField) }

        // Wait for paste to complete
        // Once Cmd+V is posted, cancellation must not turn this into a
        // retryable failure and cause a duplicate paste.
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms

        debugLog("Text insertion complete")
    }

    private func simulatePaste() throws {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key down: Cmd+V
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true) else {
            debugLog("Failed to create keyDown event")
            throw TextInsertionError.clipboardUnavailable
        }
        keyDown.flags = .maskCommand

        // Key up: Cmd+V
        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            debugLog("Failed to create keyUp event")
            throw TextInsertionError.clipboardUnavailable
        }
        keyUp.flags = .maskCommand

        // Post events
        keyDown.post(tap: .cghidEventTap)
        debugLog("Posted keyDown event")

        // Small delay between key down and up
        usleep(50000) // 50ms

        keyUp.post(tap: .cghidEventTap)
        debugLog("Posted keyUp event")
    }
}

enum TextInsertionError: LocalizedError {
    case targetUnavailable, targetChanged, secureField
    case noAccessibilityPermission
    case clipboardUnavailable

    var errorDescription: String? {
        switch self {
        case .targetUnavailable:
            return "Focus an editor and enable Accessibility before recording."
        case .targetChanged:
            return "Could not return to the original editor. Your text is kept here; retry Insert or Copy it."
        case .secureField:
            return "Dictation is unavailable in password fields."
        case .noAccessibilityPermission:
            return "Accessibility permission required. Please enable in System Settings → Privacy & Security → Accessibility"
        case .clipboardUnavailable:
            return "Could not temporarily access the clipboard to insert text"
        }
    }
}
