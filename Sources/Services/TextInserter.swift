import AppKit
import Carbon.HIToolbox
import ApplicationServices

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
    func insert(text: String) async throws {
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
        simulatePaste()

        // Wait for paste to complete
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms

        debugLog("Text insertion complete")
    }

    private func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key down: Cmd+V
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true) else {
            debugLog("Failed to create keyDown event")
            return
        }
        keyDown.flags = .maskCommand

        // Key up: Cmd+V
        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            debugLog("Failed to create keyUp event")
            return
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
    case noAccessibilityPermission
    case clipboardUnavailable

    var errorDescription: String? {
        switch self {
        case .noAccessibilityPermission:
            return "Accessibility permission required. Please enable in System Settings → Privacy & Security → Accessibility"
        case .clipboardUnavailable:
            return "Could not temporarily access the clipboard to insert text"
        }
    }
}
