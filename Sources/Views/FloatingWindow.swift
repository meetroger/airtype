import SwiftUI
import AppKit
import ApplicationServices

/// Resolves the display containing the currently focused input control/window.
/// Accessibility coordinates use Quartz's top-left origin, so compare them
/// against CGDisplayBounds instead of NSScreen.frame.
enum FocusedScreenLocator {
    static func current() -> NSScreen? {
        if AXIsProcessTrusted(),
           let focusedPoint = focusedElementCenter(),
           let screen = screen(containingQuartzPoint: focusedPoint) {
            return screen
        }

        // This also gives intuitive behavior for apps whose focused element
        // does not expose an accessibility frame.
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
    }

    private static func focusedElementCenter() -> CGPoint? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue,
        CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return focusedWindowCenter()
        }

        let element = unsafeBitCast(focusedValue, to: AXUIElement.self)
        return center(of: element) ?? focusedWindowCenter()
    }

    private static func focusedWindowCenter() -> CGPoint? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success,
        let windowValue,
        CFGetTypeID(windowValue) == AXUIElementGetTypeID() else {
            return nil
        }

        return center(of: unsafeBitCast(windowValue, to: AXUIElement.self))
    }

    private static func center(of element: AXUIElement) -> CGPoint? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
        AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &sizeValue
        ) == .success,
        let positionValue,
        let sizeValue,
        CFGetTypeID(positionValue) == AXValueGetTypeID(),
        CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        let positionAXValue = unsafeBitCast(positionValue, to: AXValue.self)
        let sizeAXValue = unsafeBitCast(sizeValue, to: AXValue.self)
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue, .cgPoint, &position),
              AXValueGetValue(sizeAXValue, .cgSize, &size) else {
            return nil
        }

        return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
    }

    private static func screen(containingQuartzPoint point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDisplayBounds(CGDirectDisplayID(number.uint32Value)).contains(point)
        }
    }
}

/// A floating panel that stays on top of all windows
/// Styled like Raycast/Spotlight with dark minimal appearance
class FloatingPanel: NSPanel {

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        // Panel behavior
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true

        // Fully transparent appearance - critical for removing gray border
        isOpaque = false
        backgroundColor = NSColor.clear
        // Use system window shadow for native macOS quality and smooth window dragging.
        hasShadow = true

        // Hide any title bar elements
        titleVisibility = .hidden
        titlebarAppearsTransparent = true

        // Don't show in dock or app switcher
        hidesOnDeactivate = false

        // Allow clicking through to other apps
        becomesKeyOnlyIfNeeded = true
    }

    /// Keep the panel shape consistent with the SwiftUI rounded container.
    func applyRoundedMask(for size: NSSize? = nil) {
        let targetHeight = size?.height ?? frame.height
        let cornerRadius: CGFloat = targetHeight <= 80 ? 30 : 18

        if let frameView = contentView?.superview {
            frameView.wantsLayer = true
            frameView.layer?.cornerCurve = .continuous
            frameView.layer?.cornerRadius = cornerRadius
            frameView.layer?.masksToBounds = true
        }

        if let contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerCurve = .continuous
            contentView.layer?.cornerRadius = cornerRadius
            contentView.layer?.masksToBounds = true
        }

        invalidateShadow()
    }

    /// Position the panel in a corner of the screen
    func position(at corner: FloatingWindowPosition, on targetScreen: NSScreen? = nil) {
        guard let screenFrame = targetScreen?.visibleFrame ?? currentVisibleScreenFrame() else { return }

        let padding: CGFloat = 20

        var origin: NSPoint

        switch corner {
        case .topRight:
            origin = NSPoint(
                x: screenFrame.maxX - frame.width - padding,
                y: screenFrame.maxY - frame.height - padding
            )
        case .bottomRight:
            origin = NSPoint(
                x: screenFrame.maxX - frame.width - padding,
                y: screenFrame.minY + padding
            )
        case .bottomCenter:
            origin = NSPoint(
                x: screenFrame.midX - frame.width / 2,
                y: screenFrame.minY + padding
            )
        case .topLeft:
            origin = NSPoint(
                x: screenFrame.minX + padding,
                y: screenFrame.maxY - frame.height - padding
            )
        case .bottomLeft:
            origin = NSPoint(
                x: screenFrame.minX + padding,
                y: screenFrame.minY + padding
            )
        }

        setFrameOrigin(origin)
        invalidateShadow()
    }

    /// Animate size change for expand/collapse
    func animateResize(to newSize: NSSize, position _: FloatingWindowPosition) {
        guard let screenFrame = currentVisibleScreenFrame() else { return }

        let currentFrame = frame
        let currentCenter = NSPoint(x: currentFrame.midX, y: currentFrame.midY)

        var newOrigin = NSPoint(
            x: currentCenter.x - (newSize.width / 2),
            y: currentCenter.y - (newSize.height / 2)
        )

        // Clamp to visible area so expansion picks available directions near screen edges.
        newOrigin.x = min(max(newOrigin.x, screenFrame.minX), screenFrame.maxX - newSize.width)
        newOrigin.y = min(max(newOrigin.y, screenFrame.minY), screenFrame.maxY - newSize.height)

        let newFrame = NSRect(origin: newOrigin, size: newSize)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(newFrame, display: true)
        }, completionHandler: { [weak self] in
            self?.applyRoundedMask(for: newSize)
        })
    }

    private func currentVisibleScreenFrame() -> NSRect? {
        let center = NSPoint(x: frame.midX, y: frame.midY)

        if let matchingScreen = NSScreen.screens.first(where: { $0.visibleFrame.contains(center) }) {
            return matchingScreen.visibleFrame
        }

        if let currentScreen = screen {
            return currentScreen.visibleFrame
        }

        return NSScreen.main?.visibleFrame
    }

    // Allow the panel to become key for text selection, but not main
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Controller to manage the floating window lifecycle
@MainActor
class FloatingWindowController: ObservableObject {
    private var panel: FloatingPanel?
    @Published var isVisible = false

    private let settings: Settings

    init(settings: Settings = .shared) {
        self.settings = settings
    }

    /// Show the floating window with the given content
    func show<Content: View>(content: Content) {
        if panel == nil {
            createPanel(with: content)
        }

        panel?.orderFront(nil)
        panel?.position(at: settings.floatingWindowPosition, on: FocusedScreenLocator.current())
        isVisible = true
    }

    /// Hide the floating window
    func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }

    /// Toggle visibility
    func toggle<Content: View>(content: Content) {
        if isVisible {
            hide()
        } else {
            show(content: content)
        }
    }

    /// Update the window size (for expand/collapse)
    func resize(to size: NSSize) {
        panel?.animateResize(to: size, position: settings.floatingWindowPosition)
    }

    /// Reposition the window (when settings change)
    func reposition() {
        panel?.position(at: settings.floatingWindowPosition)
    }

    private func createPanel<Content: View>(with content: Content) {
        // Initial size for pill mode
        let initialSize = NSSize(
            width: FloatingView.pillSize.width,
            height: FloatingView.pillSize.height
        )
        let contentRect = NSRect(origin: .zero, size: initialSize)

        panel = FloatingPanel(contentRect: contentRect)

        let hostingView = NSHostingView(rootView: content.ignoresSafeArea())
        hostingView.frame = contentRect

        // Make hosting view background fully transparent (fixes gray border)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        hostingView.layer?.isOpaque = false

        panel?.contentView = hostingView
        panel?.backgroundColor = NSColor.clear
        panel?.applyRoundedMask()
    }

    /// Update the content view
    func updateContent<Content: View>(_ content: Content) {
        guard let panel = panel else { return }

        let hostingView = NSHostingView(rootView: content.ignoresSafeArea())
        hostingView.frame = panel.frame

        // Make hosting view background fully transparent
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        hostingView.layer?.isOpaque = false

        panel.contentView = hostingView
        panel.backgroundColor = NSColor.clear
        panel.applyRoundedMask()
    }
}
