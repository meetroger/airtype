import SwiftUI
import Combine
import CoreAudio
import os.log

private let logFile = FileManager.default.temporaryDirectory.appendingPathComponent("airtype_debug.log")
private let logQueue = DispatchQueue(label: "com.airtype.debuglog")

func debugLog(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    fputs(line, stderr)

    guard let data = line.data(using: .utf8) else { return }
    logQueue.async {
        if FileManager.default.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: logFile)
        }
    }
}

/// Print transcription output to stdout (for terminal streaming)
func streamOutput(_ text: String, newline: Bool = true) {
    if newline {
        print(text)
    } else {
        print(text, terminator: "")
    }
    fflush(stdout)
}

/// Converts explicitly dictated punctuation names into the symbols the speaker
/// intended before enhancement or translation. This keeps the behavior working
/// even when LLM enhancement is disabled.
enum SpokenPunctuationFormatter {
    static func format(_ text: String) -> String {
        var result = text

        // Longer phrases must be replaced first because some contain shorter
        // command names (for example, "左双引号" contains "引号").
        let chineseCommands: [(String, String)] = [
            ("另起一行", "\n"), ("另起一段", "\n\n"),
            ("新的一行", "\n"), ("新的一段", "\n\n"),
            ("換行符", "\n"), ("换行符", "\n"),
            ("左雙引號", "“"), ("左双引号", "“"),
            ("右雙引號", "”"), ("右双引号", "”"),
            ("左括號", "（"), ("左括号", "（"),
            ("右括號", "）"), ("右括号", "）"),
            ("感嘆號", "！"), ("感叹号", "！"),
            ("驚嘆號", "！"), ("惊叹号", "！"),
            ("省略號", "……"), ("省略号", "……"),
            ("破折號", "——"), ("破折号", "——"),
            ("問號", "？"), ("问号", "？"),
            ("句號", "。"), ("句号", "。"),
            ("逗號", "，"), ("逗号", "，"),
            ("頓號", "、"), ("顿号", "、"),
            ("分號", "；"), ("分号", "；"),
            ("冒號", "："), ("冒号", "："),
            ("換行", "\n"), ("换行", "\n"),
            ("空格符", " "), ("空格", " ")
        ]
        for (spoken, symbol) in chineseCommands {
            result = result.replacingOccurrences(of: spoken, with: symbol)
        }

        let englishCommands: [(String, String)] = [
            (#"new\s+paragraph"#, "\n\n"),
            (#"new\s+line|newline"#, "\n"),
            (#"question\s+mark"#, "? "),
            (#"exclamation\s+(?:mark|point)"#, "! "),
            (#"full\s+stop|period"#, ". "),
            (#"semicolon"#, "; "),
            (#"colon"#, ": "),
            (#"comma"#, ", "),
            (#"open\s+(?:parenthesis|paren)"#, "("),
            (#"close\s+(?:parenthesis|paren)"#, ") "),
            (#"open\s+(?:quote|quotation\s+mark)"#, "\""),
            (#"close\s+(?:quote|quotation\s+mark)"#, "\" "),
            (#"backslash"#, "\\"),
            (#"forward\s+slash"#, "/"),
            (#"hyphen"#, "-")
        ]
        for (command, symbol) in englishCommands {
            result = result.replacingOccurrences(
                of: #"(?i)[ \t]*\b(?:"# + command + #")\b[ \t]*"#,
                with: symbol,
                options: .regularExpression
            )
        }

        // Remove recognition-added spaces around Chinese punctuation without
        // otherwise rewriting the user's spacing or code-like content.
        result = result.replacingOccurrences(
            of: #"[ \t]+([，。？！：；、）”])"#,
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"([（“])[ \t]+"#,
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"[ \t]*\n[ \t]*"#,
            with: "\n",
            options: .regularExpression
        )

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState?
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let appState = AppState()
        self.appState = appState
        statusBarController = StatusBarController(appState: appState)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MainWindowController.shared.show()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusBarController = nil
        appState = nil
    }
}

@main
struct AirtypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        SwiftUI.Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    MainWindowController.shared.show()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

/// Owns the native status item so its artwork has an exact pixel footprint and
/// its button action can distinguish a single click from a double click.
@MainActor
final class StatusBarController: NSObject {
    private let appState: AppState
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var lastStatusItemClickTime: TimeInterval = 0

    init(appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: 32)
        super.init()

        configureButton()
        configurePopover()
        observeAppState()
        updateIcon()
    }

    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: .leftMouseUp)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.toolTip = "Airtype — double-click to open Settings"
        button.setAccessibilityLabel("Airtype")
    }

    private func configurePopover() {
        let menuView = MenuBarView(appState: appState)
        let hostingController = NSHostingController(rootView: menuView)
        hostingController.sizingOptions = [.preferredContentSize]

        popover.contentViewController = hostingController
        popover.behavior = .transient
        popover.animates = true
    }

    private func observeAppState() {
        appState.$isRecording
            .combineLatest(appState.$isProcessing)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.updateIcon()
            }
            .store(in: &cancellables)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let clickTime = ProcessInfo.processInfo.systemUptime
        let isRapidSecondClick = lastStatusItemClickTime > 0
            && clickTime - lastStatusItemClickTime <= NSEvent.doubleClickInterval
        let isDoubleClick = (NSApp.currentEvent?.clickCount ?? 1) >= 2 || isRapidSecondClick
        lastStatusItemClickTime = isDoubleClick ? 0 : clickTime

        if isDoubleClick {
            debugLog("Menu bar double-click: opening Settings")
            popover.performClose(nil)
            MainWindowController.shared.show()
            return
        }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover(relativeTo: sender)
        }
    }

    private func showPopover(relativeTo button: NSStatusBarButton) {
        let fittingSize = popover.contentViewController?.view.fittingSize ?? .zero
        if fittingSize.width > 0, fittingSize.height > 0 {
            popover.contentSize = fittingSize
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }

        // All status artwork is a template image. Leave its tint unset in every
        // app state so AppKit can choose a legible color for the current menu
        // bar appearance and its highlighted state.
        button.contentTintColor = nil

        let glyphName: String
        let glyphPointSize: CGFloat
        if appState.isRecording {
            glyphName = "circle.fill"
            glyphPointSize = 8
        } else if appState.isProcessing {
            glyphName = "ellipsis"
            glyphPointSize = 12
        } else {
            glyphName = "mic.fill"
            glyphPointSize = 12
        }

        button.image = Self.makeStatusImage(
            glyphName: glyphName,
            glyphPointSize: glyphPointSize
        )
    }

    /// Produce a 22-point template image whose visible outer disc reaches the
    /// canvas edges. The inner SF Symbol is punched out of that disc.
    private static func makeStatusImage(glyphName: String, glyphPointSize: CGFloat) -> NSImage {
        let imageSize = NSSize(width: 22, height: 22)
        let image = NSImage(size: imageSize, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()

            guard let glyph = NSImage(systemSymbolName: glyphName, accessibilityDescription: nil)?
                .withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: glyphPointSize, weight: .black)
                ) else {
                return true
            }

            let glyphSize = glyph.size
            let glyphRect = NSRect(
                x: rect.midX - glyphSize.width / 2,
                y: rect.midY - glyphSize.height / 2,
                width: glyphSize.width,
                height: glyphSize.height
            )
            glyph.draw(in: glyphRect, from: .zero, operation: .destinationOut, fraction: 1)
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Manages the floating window lifecycle within the app
@MainActor
class FloatingWindowManager: ObservableObject {
    static let shared = FloatingWindowManager()

    private var panel: FloatingPanel?
    @Published var isVisible = false

    private init() {}

    func show(with appState: AppState) {
        if panel == nil {
            createPanel(with: appState)
        }

        updateContent(with: appState)
        panel?.orderFront(nil)
        panel?.position(at: appState.settings.floatingWindowPosition, on: FocusedScreenLocator.current())
        isVisible = true
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }

    func updateContent(with appState: AppState) {
        guard let panel = panel else { return }

        let floatingView = FloatingView(appState: appState)
            .ignoresSafeArea()
        let hostingView = NSHostingView(rootView: floatingView)

        // Make hosting view background fully transparent
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        hostingView.layer?.isOpaque = false

        panel.contentView = hostingView
        panel.backgroundColor = NSColor.clear
        panel.applyRoundedMask()
    }

    func reposition(to position: FloatingWindowPosition) {
        panel?.position(at: position)
    }

    func resize(to size: NSSize) {
        panel?.animateResize(to: size, position: Settings.shared.floatingWindowPosition)
    }

    /// The app that was frontmost before the panel became key (for paste targeting).
    private var previousApp: NSRunningApplication?

    func makeKeyable(_ keyable: Bool) {
        if keyable {
            // Remember the frontmost app before we steal focus
            let front = NSWorkspace.shared.frontmostApplication
            if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
                previousApp = front
            }
        }
        panel?.becomesKeyOnlyIfNeeded = !keyable
    }

    func resignKeyAndActivatePreviousApp() {
        panel?.resignKey()
        panel?.becomesKeyOnlyIfNeeded = true
        previousApp?.activate()
        previousApp = nil
    }

    private func createPanel(with appState: AppState) {
        let initialSize = NSSize(
            width: FloatingView.pillSize.width,
            height: FloatingView.pillSize.height
        )
        let contentRect = NSRect(origin: .zero, size: initialSize)

        panel = FloatingPanel(contentRect: contentRect)

        let floatingView = FloatingView(appState: appState)
            .ignoresSafeArea()
        let hostingView = NSHostingView(rootView: floatingView)
        hostingView.frame = contentRect

        // Make hosting view background fully transparent
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        hostingView.layer?.isOpaque = false

        // Set after contentView is assigned for proper transparency
        panel?.contentView = hostingView
        panel?.backgroundColor = NSColor.clear
        panel?.applyRoundedMask()
    }
}

/// Main application state coordinator
@MainActor
class AppState: ObservableObject {
    enum RecordingMode {
        case transcribe
        case pushToTalkTranscribe
        case translateToTargetLanguage

        var recordingHint: String {
            switch self {
            case .transcribe:
                return "Press the toggle shortcut again to transcribe"
            case .pushToTalkTranscribe:
                return "Release to transcribe"
            case .translateToTargetLanguage:
                return "Release to translate"
            }
        }

        var isPushToTalk: Bool {
            switch self {
            case .transcribe:
                return false
            case .pushToTalkTranscribe, .translateToTargetLanguage:
                return true
            }
        }
    }

    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var processingStage = ""
    @Published var processingProgress: Double = 0.0  // 0.0 to 1.0
    @Published var transcriptionChunkInfo = ""       // e.g., "Chunk 2/5"
    @Published var partialTranscription = ""         // Accumulated text during chunked transcription
    @Published var lastError: String?
    @Published var lastNotice: String?
    @Published var recordingStartTime: Date?
    @Published private(set) var recordingMode: RecordingMode?

    // For streaming output tracking
    private var lastStreamedLength = 0
    // Accumulated finalized utterances from streaming (Doubao resets text per utterance)
    private var finalizedStreamText = ""

    let settings = Settings.shared
    let audioInputDeviceManager = AudioInputDeviceManager()
    let audioRecorder = AudioRecorder()
    let whisperService = WhisperService()
    let elevenlabsService = ElevenLabsService()
    let mistralTranscriptionService = MistralTranscriptionService()
    let mlxTranscriptionService = MLXTranscriptionService()
    let enhancementService = EnhancementService()
    let textInserter = TextInserter()
    let systemAudioMuter = SystemAudioMuter()
    let hotkeyManager = HotkeyManager()
    let floatingWindowManager = FloatingWindowManager.shared
    private var streamingCapture: StreamingAudioCapture?
    private var streamingService: (any StreamingTranscriptionService)?
    private var streamingEventTask: Task<Void, Never>?
    private var preconnectedStreamingService: DoubaoStreamingService?
    private var preconnectTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var isStartingPushToTalk = false
    private var pushToTalkReleasePending = false
    private var isStopRequested = false
    private var sharedShortcutHoldTask: Task<Void, Never>?
    private var sharedShortcutStartedRecording = false
    private var sharedShortcutStopsToggle = false
    private let sharedShortcutHoldDelay: UInt64 = 350_000_000
    private let minimumRecordingDuration: TimeInterval = 2.0

    var menuBarIcon: String {
        if isRecording {
            return "mic.fill"
        } else if isProcessing {
            return "ellipsis.circle"
        } else {
            return "mic"
        }
    }

    private var providerObserver: AnyCancellable?

    init() {
        setupHotkeyCallbacks()
        MainWindowController.shared.hotkeyManager = hotkeyManager
        MainWindowController.shared.audioRecorder = audioRecorder
        Task { @MainActor in
            if !settings.hasCompletedSetup {
                MainWindowController.shared.showWizard()
            }
        }
        // Pre-connect streaming when Doubao is selected; tear down otherwise
        preconnectStreamingIfNeeded()
        providerObserver = settings.$transcriptionProvider.sink { [weak self] _ in
            Task { @MainActor in
                self?.preconnectStreamingIfNeeded()
            }
        }
    }

    private func setupHotkeyCallbacks() {
        // Push-to-talk: start recording on key down
        hotkeyManager.onPushToTalkStart = { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                if self.hotkeyManager.usesSharedShortcut {
                    await self.handleSharedShortcutDown()
                    return
                }
                debugLog("Push-to-talk key down")
                if self.isProcessing {
                    self.cancelProcessing()
                } else {
                    let mode = self.pushToTalkRecordingMode
                    self.pushToTalkReleasePending = false
                    self.isStartingPushToTalk = true
                    await self.startRecording(mode: mode)
                    self.isStartingPushToTalk = false

                    // A quick release can arrive while microphone permission or
                    // the recorder is still starting. Honor it as soon as startup
                    // completes instead of requiring a second key press.
                    if self.pushToTalkReleasePending || !self.hotkeyManager.isPushToTalkPressed {
                        self.pushToTalkReleasePending = false
                        self.requestStop(for: mode)
                    }
                }
            }
        }

        // Push-to-talk: stop and process on key up
        hotkeyManager.onPushToTalkEnd = { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                if self.hotkeyManager.usesSharedShortcut {
                    self.handleSharedShortcutUp()
                    return
                }
                debugLog("Push-to-talk key up, starting: \(self.isStartingPushToTalk), recording: \(self.isRecording), mode: \(String(describing: self.recordingMode))")
                if self.isStartingPushToTalk {
                    self.pushToTalkReleasePending = true
                    return
                }
                guard let mode = self.recordingMode, mode.isPushToTalk else { return }
                self.requestStop(for: mode)
            }
        }

        // Toggle mode: toggle recording state
        hotkeyManager.onToggle = { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                if self.isProcessing {
                    self.cancelProcessing()
                } else if self.isRecording {
                    self.requestStop(for: .transcribe)
                } else {
                    await self.startRecording(mode: .transcribe)
                }
            }
        }
    }

    private var pushToTalkRecordingMode: RecordingMode {
        settings.translateOnLongPress ? .translateToTargetLanguage : .pushToTalkTranscribe
    }

    private func handleSharedShortcutDown() async {
        debugLog("Shared shortcut key down")
        sharedShortcutHoldTask?.cancel()
        sharedShortcutHoldTask = nil
        sharedShortcutStartedRecording = false
        sharedShortcutStopsToggle = false

        if isProcessing {
            cancelProcessing()
            return
        }

        if isRecording {
            // A tap while Toggle recording is active stops that recording.
            sharedShortcutStopsToggle = recordingMode == .transcribe
            return
        }

        sharedShortcutStartedRecording = true
        pushToTalkReleasePending = false
        isStartingPushToTalk = true

        // Recording begins immediately as normal transcription so the first
        // syllable is never lost. Holding past the threshold promotes the same
        // recording to push-to-talk, with optional one-pass English translation.
        sharedShortcutHoldTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: self?.sharedShortcutHoldDelay ?? 350_000_000)
            } catch {
                return
            }
            guard let self,
                  self.hotkeyManager.isPushToTalkPressed,
                  self.sharedShortcutStartedRecording,
                  self.recordingMode == .transcribe else { return }
            self.recordingMode = self.pushToTalkRecordingMode
            debugLog("Shared shortcut promoted to Push-to-talk mode: \(String(describing: self.recordingMode))")
        }

        await startRecording(mode: .transcribe)
        isStartingPushToTalk = false

        if pushToTalkReleasePending,
           let mode = recordingMode,
           mode.isPushToTalk {
            pushToTalkReleasePending = false
            requestStop(for: mode)
        }
    }

    private func handleSharedShortcutUp() {
        debugLog("Shared shortcut key up, recording: \(isRecording), mode: \(String(describing: recordingMode))")
        sharedShortcutHoldTask?.cancel()
        sharedShortcutHoldTask = nil

        if sharedShortcutStopsToggle {
            sharedShortcutStopsToggle = false
            requestStop(for: .transcribe)
        } else if let mode = recordingMode, mode.isPushToTalk {
            if isStartingPushToTalk {
                pushToTalkReleasePending = true
            } else {
                requestStop(for: mode)
            }
        }

        // If this was a quick initial tap, intentionally leave the transcription
        // recording active until the next tap.
        sharedShortcutStartedRecording = false
    }

    private func requestStop(for expectedMode: RecordingMode) {
        guard !isStopRequested,
              isRecording,
              recordingMode == expectedMode else {
            debugLog("Ignoring stop request, requested: \(expectedMode), recording: \(isRecording), mode: \(String(describing: recordingMode)), alreadyRequested: \(isStopRequested)")
            return
        }

        isStopRequested = true
        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.stopAndProcess()
            self.isStopRequested = false
        }
    }

    // MARK: - Streaming Pre-connect

    /// Pre-establish a Doubao WebSocket connection so recording starts instantly
    func preconnectStreamingIfNeeded() {
        // Only pre-connect when Doubao is selected and configured
        guard shouldUseStreaming, settings.isConfigured else {
            disconnectPreconnected()
            return
        }
        // Already have a ready connection
        if preconnectedStreamingService != nil { return }

        preconnectTask?.cancel()
        preconnectTask = Task { [weak self] in
            guard let self = self else { return }
            let service = DoubaoStreamingService(
                appId: self.settings.doubaoAppId,
                accessKey: self.settings.doubaoAccessKey,
                resourceId: self.settings.doubaoResourceId,
                language: self.settings.doubaoLanguage
            )
            do {
                try await service.connect()
                guard !Task.isCancelled else {
                    await service.disconnect()
                    return
                }
                await MainActor.run {
                    self.preconnectedStreamingService = service
                    debugLog("Streaming pre-connected")
                }
            } catch {
                debugLog("Streaming pre-connect failed: \(error)")
            }
        }
    }

    private func disconnectPreconnected() {
        preconnectTask?.cancel()
        preconnectTask = nil
        if let service = preconnectedStreamingService {
            preconnectedStreamingService = nil
            Task { await service.disconnect() }
        }
    }

    // MARK: - Recording Flow

    private var shouldUseStreaming: Bool {
        settings.transcriptionProvider.supportsStreaming
    }

    func startRecording(mode: RecordingMode) async {
        debugLog("startRecording called, mode: \(mode)")
        guard !isRecording && !isProcessing else {
            debugLog("Already recording or processing, skipping")
            return
        }
        guard settings.isConfigured else {
            debugLog("API key not configured")
            lastError = settings.configurationError ?? "Please configure API keys in Settings"
            return
        }
        if mode == .translateToTargetLanguage,
           settings.enhancementProvider.requiresApiKey,
           settings.currentEnhancementApiKey.isEmpty {
            lastError = "\(settings.enhancementProvider.rawValue) API key required for Push-to-talk translation"
            return
        }

        // Set the intent before awaiting microphone permission so a key-up
        // event that arrives during startup still belongs to this recording.
        recordingMode = mode

        do {
            guard await audioRecorder.requestPermission() else {
                throw RecordingError.noPermission
            }

            let selectedDeviceID = audioInputDeviceManager.deviceIDForRecording()
            if shouldUseStreaming {
                try await startStreamingRecording(deviceID: selectedDeviceID)
            } else {
                let url: URL
                do {
                    url = try audioRecorder.startRecording(deviceID: selectedDeviceID)
                } catch where selectedDeviceID != nil {
                    audioInputDeviceManager.fallbackToSystemDefault()
                    url = try audioRecorder.startRecording()
                }
                debugLog("Recording started, saving to: \(url.path)")
            }

            if settings.muteSystemAudioWhileRecording {
                systemAudioMuter.mute()
            }

            isRecording = true
            isStopRequested = false
            recordingStartTime = Date()
            lastError = nil
            lastNotice = nil
            partialTranscription = ""

            floatingWindowManager.show(with: self)
        } catch {
            debugLog("Failed to start recording: \(error)")
            recordingMode = nil
            lastError = error.localizedDescription
        }
    }

    private func startStreamingRecording(deviceID: AudioDeviceID?) async throws {
        let service: DoubaoStreamingService
        if let preconnected = preconnectedStreamingService, await !preconnected.isStale() {
            service = preconnected
            preconnectedStreamingService = nil
            debugLog("Using pre-connected streaming service")
        } else {
            // Discard stale pre-connected service if any
            if let stale = preconnectedStreamingService {
                preconnectedStreamingService = nil
                Task { await stale.disconnect() }
            }
            service = DoubaoStreamingService(
                appId: settings.doubaoAppId,
                accessKey: settings.doubaoAccessKey,
                resourceId: settings.doubaoResourceId,
                language: settings.doubaoLanguage
            )
            try await service.connect()
            debugLog("Streaming WebSocket connected (fresh)")
        }
        // Send init message now — starts the server's audio timeout
        try await service.startSession()
        self.streamingService = service

        finalizedStreamText = ""

        // Listen for events (task runs on @MainActor to avoid per-event hops)
        streamingEventTask = Task { @MainActor [weak self] in
            for await event in service.events {
                guard let self = self else { break }
                switch event {
                case .partial(let text):
                    let fullText = self.finalizedStreamText + text
                    self.partialTranscription = fullText
                    self.processingStage = "Listening..."
                case .final_(let text):
                    self.finalizedStreamText += text
                case .error(let error):
                    debugLog("Streaming error: \(error)")
                    self.lastError = error.localizedDescription
                }
            }
        }

        // Start audio capture and feed to WebSocket
        let capture = StreamingAudioCapture()
        self.streamingCapture = capture
        let levelHandler: (Float, Float) -> Void = { [weak self] average, peak in
            Task { @MainActor [weak self] in
                self?.audioRecorder.updateCapturedLevels(average: average, peak: peak)
            }
        }
        let chunkHandler: (Data) -> Void = { [weak service] data in
            Task { await service?.sendAudio(data) }
        }

        do {
            let recordingURL: URL
            do {
                recordingURL = try capture.start(
                    deviceID: deviceID,
                    onLevel: levelHandler,
                    onChunk: chunkHandler
                )
            } catch where deviceID != nil {
                audioInputDeviceManager.fallbackToSystemDefault()
                recordingURL = try capture.start(
                    onLevel: levelHandler,
                    onChunk: chunkHandler
                )
            }
            audioRecorder.beginCaptureMonitoring(at: recordingURL)
        } catch {
            streamingCapture = nil
            streamingEventTask?.cancel()
            streamingEventTask = nil
            streamingService = nil
            await service.disconnect()
            throw error
        }
        debugLog("Streaming audio capture started")
    }

    private func stopStreamingAndProcess() async {
        let mode = recordingMode ?? .transcribe
        streamingCapture?.stop()
        streamingCapture = nil
        audioRecorder.endCaptureMonitoring()

        let recordedDuration = audioRecorder.recordingDuration
        if recordedDuration < minimumRecordingDuration {
            streamingEventTask?.cancel()
            streamingEventTask = nil
            await streamingService?.disconnect()
            streamingService = nil
            isRecording = false
            recordingStartTime = nil
            recordingMode = nil
            processingStage = ""
            processingProgress = 0.0
            partialTranscription = ""
            lastError = nil
            lastNotice = shortRecordingNotice(duration: recordedDuration)
            preconnectStreamingIfNeeded()
            return
        }

        isRecording = false
        recordingStartTime = nil
        isProcessing = true
        processingStage = "Finalizing..."

        do {
            try await streamingService?.endAudio()
            debugLog("Sent end-of-audio signal")

            // Wait briefly for final result
            try await Task.sleep(nanoseconds: 1_000_000_000)

            streamingEventTask?.cancel()
            streamingEventTask = nil

            // Use the most complete text: partialTranscription has the latest
            // partial view, finalizedStreamText has all locked-in utterances.
            let rawTranscription = partialTranscription.count >= finalizedStreamText.count
                ? partialTranscription : finalizedStreamText
            let transcription = SpokenPunctuationFormatter.format(rawTranscription)
            await streamingService?.disconnect()
            streamingService = nil

            debugLog("Streaming raw transcription result: \(rawTranscription)")
            streamOutput("\n--- Raw transcription (streaming) ---")
            streamOutput(rawTranscription)
            if transcription != rawTranscription {
                debugLog("Spoken punctuation formatted: \(transcription)")
                streamOutput("\n--- Punctuation formatted ---")
                streamOutput(transcription)
            }
            systemAudioMuter.restore()

            if transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw WhisperError.emptyRecording
            }

            let finalText = try await prepareFinalText(from: transcription, mode: mode)

            // Insert (bail out if cancelled while enhancing)
            try Task.checkCancellation()
            processingProgress = 0.95
            if !finalText.isEmpty {
                try await textInserter.insert(text: finalText)
                TranscriptionHistory.shared.save(text: finalText, inserted: true)
                debugLog("Inserted text (\(finalText.count) chars)")
            }
            streamOutput("Done!\n")

            lastError = nil
            lastNotice = nil
            isProcessing = false
            recordingMode = nil
            processingStage = ""
            processingProgress = 0.0
            partialTranscription = ""

            let manager = floatingWindowManager
            Task { try? await Task.sleep(nanoseconds: 500_000_000); manager.hide() }
        } catch is CancellationError {
            debugLog("Streaming processing cancelled")
            return
        } catch {
            debugLog("Streaming processing error: \(error)")
            if case WhisperError.emptyRecording = error {
                lastNotice = error.localizedDescription
            } else {
                lastError = error.localizedDescription
            }
            isProcessing = false
            recordingMode = nil
            processingStage = ""
            processingProgress = 0.0
            streamingEventTask?.cancel()
            streamingEventTask = nil
            await streamingService?.disconnect()
            streamingService = nil
        }

        // Pre-connect for next recording
        preconnectStreamingIfNeeded()
    }

    func stopAndProcess() async {
        debugLog("stopAndProcess called, isRecording: \(isRecording)")
        guard isRecording else {
            debugLog("Not recording, skipping")
            return
        }
        let mode = recordingMode ?? .transcribe

        // Keep other audio muted through transcription/enhancement, and always
        // restore the exact prior output state on every completion path.
        defer { systemAudioMuter.restore() }

        if shouldUseStreaming {
            await stopStreamingAndProcess()
            return
        }

        let audioURL: URL
        do {
            guard let completedURL = try await audioRecorder.stopRecording() else {
                debugLog("No audio URL returned")
                lastError = "No recording to process"
                isRecording = false
                recordingStartTime = nil
                recordingMode = nil
                return
            }
            audioURL = completedURL
        } catch {
            debugLog("Failed to finalize recording: \(error)")
            lastError = error.localizedDescription
            isRecording = false
            recordingStartTime = nil
            recordingMode = nil
            return
        }

        debugLog("Recording stopped, file: \(audioURL.path)")

        let recordedDuration = audioRecorder.recordingDuration
        if recordedDuration < minimumRecordingDuration {
            debugLog("Recording skipped because duration was \(recordedDuration)s")
            isRecording = false
            recordingStartTime = nil
            recordingMode = nil
            lastError = nil
            lastNotice = shortRecordingNotice(duration: recordedDuration)
            return
        }

        // Check file size and validate
        var fileSize: Int64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: audioURL.path),
           let size = attrs[.size] as? Int64 {
            fileSize = size
            debugLog("Audio file size: \(size) bytes")
        }

        // Check for empty/too short recording
        if fileSize < 1000 {  // Less than 1KB is likely empty
            debugLog("Recording file was empty or invalid, skipping")
            lastNotice = "Recording skipped because the audio file was empty or invalid. No transcription or translation was performed."
            isRecording = false
            recordingStartTime = nil
            recordingMode = nil
            return
        }

        // Check for silence (valid file but no speech detected)
        if audioRecorder.recordingWasSilent {
            debugLog("Recording was silent (max level: \(audioRecorder.maxLevelDuringRecording)), skipping API call")
            lastNotice = "No speech detected. Check that the correct microphone is selected in System Settings → Sound → Input."
            isRecording = false
            recordingStartTime = nil
            recordingMode = nil
            return
        }

        isRecording = false
        recordingStartTime = nil
        isProcessing = true
        processingProgress = 0.0
        partialTranscription = ""
        transcriptionChunkInfo = ""

        do {
            // Step 1: Transcribe using selected provider (with progress for OpenAI)
            debugLog("Starting transcription with \(settings.transcriptionProvider.rawValue)...")
            processingStage = "Transcribing..."
            streamOutput("\n--- Transcribing (\(settings.transcriptionProvider.rawValue))... ---")
            lastStreamedLength = 0
            let rawTranscription: String

            switch settings.transcriptionProvider {
            case .openai:
                rawTranscription = try await whisperService.transcribeWithProgress(audioURL: audioURL) { [weak self] progress in
                    Task { @MainActor in
                        guard let self = self else { return }
                        self.processingProgress = progress.progress * 0.7  // Transcription is 70% of total
                        self.partialTranscription = progress.partialText

                        // Stream partial results to terminal (chunk by chunk)
                        if progress.totalChunks > 1 && !progress.partialText.isEmpty {
                            let currentLength = progress.partialText.count
                            if currentLength > self.lastStreamedLength {
                                let startIndex = progress.partialText.index(progress.partialText.startIndex, offsetBy: self.lastStreamedLength)
                                let newText = String(progress.partialText[startIndex...])
                                streamOutput(newText, newline: false)
                                self.lastStreamedLength = currentLength
                            }
                        }

                        // Track chunk info internally for debugging
                        if progress.totalChunks > 1 {
                            self.transcriptionChunkInfo = "(\(progress.currentChunk)/\(progress.totalChunks))"
                        }
                    }
                }
            case .elevenlabs:
                rawTranscription = try await elevenlabsService.transcribe(audioURL: audioURL)
            case .mistral:
                rawTranscription = try await mistralTranscriptionService.transcribe(audioURL: audioURL)
            case .doubao:
                throw WhisperError.emptyRecording // Doubao is streaming-only; non-streaming path shouldn't reach here
            case .localMLX:
                rawTranscription = try await mlxTranscriptionService.transcribe(
                    audioURL: audioURL,
                    model: settings.localMLXModel,
                    language: settings.localMLXLanguage,
                    computeMode: settings.localMLXComputeMode,
                    installedModelIDs: Set(settings.localMLXInstalledModels)
                )
            }

            let transcription = SpokenPunctuationFormatter.format(rawTranscription)

            debugLog("Raw transcription result: \(rawTranscription)")
            streamOutput("\n\n--- Raw transcription ---")
            streamOutput(rawTranscription)
            if transcription != rawTranscription {
                debugLog("Spoken punctuation formatted: \(transcription)")
                streamOutput("\n--- Punctuation formatted ---")
                streamOutput(transcription)
            }
            systemAudioMuter.restore()

            // Check for empty transcription
            if transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw WhisperError.emptyRecording
            }

            // Step 2: Correct and optionally translate according to the hotkey mode.
            let finalText = try await prepareFinalText(from: transcription, mode: mode)

            // Step 3: Insert at cursor
            try Task.checkCancellation()
            debugLog("Inserting text...")
            streamOutput("\n--- Inserting at cursor ---")
            processingProgress = 0.95
            try await textInserter.insert(text: finalText)
            TranscriptionHistory.shared.save(text: finalText, inserted: true)
            debugLog("Text inserted successfully")
            streamOutput("Done!\n")
            processingProgress = 1.0

            lastError = nil
            lastNotice = nil

            // Cleanup
            isProcessing = false
            recordingMode = nil
            processingStage = ""
            processingProgress = 0.0
            partialTranscription = ""
            transcriptionChunkInfo = ""

            // Hide floating window after successful insert (with delay for feedback)
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5 second
                floatingWindowManager.hide()
            }
        } catch is CancellationError {
            debugLog("Processing cancelled")
            return
        } catch {
            debugLog("Error: \(error)")
            let isEmptyRecording: Bool
            if case WhisperError.emptyRecording = error { isEmptyRecording = true }
            else if case MistralTranscriptionError.emptyRecording = error { isEmptyRecording = true }
            else if case LocalMLXTranscriptionError.emptyRecording = error { isEmptyRecording = true }
            else { isEmptyRecording = false }

            if isEmptyRecording {
                lastNotice = error.localizedDescription
            } else {
                lastError = error.localizedDescription
            }
            isProcessing = false
            recordingMode = nil
            processingStage = ""
            processingProgress = 0.0
        }

        transcriptionChunkInfo = ""
        debugLog("Processing complete")
    }

    private func shortRecordingNotice(duration: TimeInterval) -> String {
        let measuredDuration = String(format: "%.1f", max(0, duration))
        return "Recording skipped: \(measuredDuration) seconds is shorter than the 2-second minimum. No transcription or translation was performed."
    }

    private func prepareFinalText(from transcription: String, mode: RecordingMode) async throws -> String {
        if mode == .translateToTargetLanguage {
            let targetLanguage = settings.translationTargetLanguage
            let usesEnhancement = settings.enhancementEnabled
            let operation = usesEnhancement ? "Enhancing and translating" : "Translating"
            debugLog("Starting \(usesEnhancement ? "one-pass enhancement and translation" : "direct translation") to \(targetLanguage.rawValue)...")
            processingStage = "\(operation) to \(targetLanguage.rawValue)..."
            processingProgress = 0.75
            streamOutput("\n--- \(operation) to \(targetLanguage.rawValue)... ---")
            let finalText = try await enhancementService.translate(text: transcription, to: targetLanguage)
            debugLog("\(targetLanguage.rawValue) result: \(finalText)")
            streamOutput("\n--- \(targetLanguage.rawValue) result ---")
            streamOutput(finalText)
            processingProgress = 0.9
            return finalText
        }

        var finalText = transcription
        if settings.enhancementEnabled {
            debugLog("Starting enhancement...")
            processingStage = "Enhancing..."
            processingProgress = 0.75
            streamOutput("\n--- Enhancing text... ---")
            finalText = try await enhancementService.enhance(text: finalText)
            debugLog("Enhanced result: \(finalText)")
            streamOutput("\n--- Enhanced text ---")
            streamOutput(finalText)
        } else if settings.hasCustomVocabulary {
            debugLog("Starting vocabulary alignment...")
            processingStage = "Aligning terminology..."
            processingProgress = 0.75
            streamOutput("\n--- Aligning terminology... ---")
            finalText = try await enhancementService.alignVocabulary(text: finalText)
            debugLog("Vocabulary-aligned result: \(finalText)")
            streamOutput("\n--- Vocabulary-aligned text ---")
            streamOutput(finalText)
        }

        processingProgress = 0.9
        return finalText
    }

    func cancelRecording() {
        if shouldUseStreaming {
            streamingCapture?.stop(discard: true)
            streamingCapture = nil
            audioRecorder.endCaptureMonitoring()
            streamingEventTask?.cancel()
            streamingEventTask = nil
            if let service = streamingService {
                streamingService = nil
                Task { await service.disconnect() }
            }
        } else {
            audioRecorder.cancelRecording()
        }
        isRecording = false
        recordingStartTime = nil
        recordingMode = nil
        isStartingPushToTalk = false
        pushToTalkReleasePending = false
        isStopRequested = false
        sharedShortcutHoldTask?.cancel()
        sharedShortcutHoldTask = nil
        sharedShortcutStartedRecording = false
        sharedShortcutStopsToggle = false
        partialTranscription = ""
        systemAudioMuter.restore()
    }

    func cancelProcessing() {
        debugLog("Cancelling processing/enhancement")
        processingTask?.cancel()
        processingTask = nil
        // Tear down any lingering streaming state
        streamingCapture?.stop(discard: true)
        streamingCapture = nil
        audioRecorder.endCaptureMonitoring()
        streamingEventTask?.cancel()
        streamingEventTask = nil
        if let service = streamingService {
            streamingService = nil
            Task { await service.disconnect() }
        }
        isProcessing = false
        recordingMode = nil
        isStartingPushToTalk = false
        pushToTalkReleasePending = false
        isStopRequested = false
        sharedShortcutHoldTask?.cancel()
        sharedShortcutHoldTask = nil
        sharedShortcutStartedRecording = false
        sharedShortcutStopsToggle = false
        processingStage = ""
        processingProgress = 0.0
        partialTranscription = ""
        lastError = nil
        lastNotice = "Processing cancelled"
        systemAudioMuter.restore()
        let manager = floatingWindowManager
        Task { try? await Task.sleep(nanoseconds: 500_000_000); manager.hide() }
        // Re-establish streaming pre-connection if needed
        preconnectStreamingIfNeeded()
    }
}
