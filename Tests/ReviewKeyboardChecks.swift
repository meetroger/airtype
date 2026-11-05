import AppKit
import SwiftUI
import Carbon.HIToolbox

// Stub only the unrelated controller dependencies; test the production panel.
enum FloatingWindowPosition { case topRight, bottomRight, bottomCenter, topLeft, bottomLeft }
final class Settings {
    static let shared = Settings()
    var floatingWindowPosition: FloatingWindowPosition = .bottomCenter
}
enum FloatingView { static let pillSize = CGSize(width: 280, height: 60) }

private final class CompositionEditor: NSTextView {
    var composing = false
    var receivedKeys = 0
    override func hasMarkedText() -> Bool { composing }
    override func keyDown(with event: NSEvent) { receivedKeys += 1 }
}

@main
struct ReviewKeyboardChecks {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120))
        let editor = CompositionEditor(frame: panel.contentView!.bounds)
        panel.contentView = editor
        panel.becomesKeyOnlyIfNeeded = false
        panel.orderFront(nil)
        panel.makeKey()
        defer { panel.orderOut(nil) }
        assert(panel.isKeyWindow, "Preview should receive keyboard focus without a click")
        assert(panel.makeFirstResponder(editor))
        var inserts = 0
        var reviewing = true
        panel.onReviewInsert = {
            guard reviewing else { return false }
            inserts += 1
            return true
        }
        func send(_ code: Int = kVK_Return, modifiers: NSEvent.ModifierFlags = []) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: modifiers, timestamp: 0, windowNumber: panel.windowNumber,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: UInt16(code))!
            panel.sendEvent(event)
        }
        send()
        assert(inserts == 1 && editor.receivedKeys == 0, "Return should submit instead of adding a newline")
        send(kVK_ANSI_KeypadEnter, modifiers: .numericPad)
        assert(inserts == 2 && editor.receivedKeys == 0, "Keypad Enter should submit")
        send(modifiers: .shift)
        assert(inserts == 2 && editor.receivedKeys == 1, "Shift+Return should reach the editor")
        editor.composing = true
        send()
        assert(inserts == 2 && editor.receivedKeys == 2, "Return should confirm IME composition first")
        editor.composing = false
        send()
        assert(inserts == 3 && editor.receivedKeys == 2, "Return after composition should submit")
        send(modifiers: .option)
        assert(inserts == 3 && editor.receivedKeys == 3, "Modified Return should retain native behavior")
        reviewing = false
        send()
        assert(inserts == 3 && editor.receivedKeys == 4, "Return outside review should retain native behavior")
        let nativeEditor = NSTextView(frame: editor.frame)
        nativeEditor.string = "first"
        panel.contentView = nativeEditor
        assert(panel.makeFirstResponder(nativeEditor))
        nativeEditor.setSelectedRange(NSRange(location: 5, length: 0))
        reviewing = true
        send(modifiers: .shift)
        assert(nativeEditor.string == "first\n" && inserts == 3, "Shift+Enter should insert a real newline")
        print("Review keyboard checks passed")
    }
}
