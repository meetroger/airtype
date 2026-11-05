import AppKit
import Carbon.HIToolbox
import ApplicationServices

/// A recording owns one editor and selection. Never retarget a delayed result.
struct DictationTarget {
    let application: NSRunningApplication
    let element: AXUIElement
    private let selection: CFTypeRef?

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func capture() throws -> DictationTarget {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let focused = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            throw TextInsertionError.targetUnavailable
        }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.2)
        let role = attribute(element, kAXSubroleAttribute) as? String
        guard role != kAXSecureTextFieldSubrole else { throw TextInsertionError.secureField }
        return DictationTarget(application: app, element: element,
                               selection: attribute(element, kAXSelectedTextRangeAttribute))
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
        guard !application.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
              let current = Self.attribute(AXUIElementCreateApplication(application.processIdentifier), kAXFocusedUIElementAttribute),
              CFEqual(current, element) else { throw TextInsertionError.targetChanged }
        if let selection {
            guard let currentSelection = Self.attribute(element, kAXSelectedTextRangeAttribute),
                  CFEqual(selection, currentSelection) else { throw TextInsertionError.targetChanged }
        }
    }
}

/// Inserts text at the current cursor position using system paste
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
    func insert(text: String, target: DictationTarget) async throws {
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

        // Wait for paste to complete
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms

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
            return "The input target changed. Your text is saved in History for copying."
        case .secureField:
            return "Dictation is unavailable in password fields."
        case .noAccessibilityPermission:
            return "Accessibility permission required. Please enable in System Settings → Privacy & Security → Accessibility"
        case .clipboardUnavailable:
            return "Could not temporarily access the clipboard to insert text"
        }
    }
}
