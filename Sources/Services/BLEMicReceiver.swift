import Foundation
import CoreBluetooth

final class BLEMicReceiver: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let service = CBUUID(string: "666f6c6f-7061-7373-706f-727400000001")
    static let audio = CBUUID(string: "666f6c6f-7061-7373-706f-727400000002")
    static let status = CBUUID(string: "666f6c6f-7061-7373-706f-727400000003")
    static let shared = BLEMicReceiver()
    var onPCM: ((Data) -> Void)?
    var onFailure: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    private var prebuffer = Data()
    // Keep decoded PCM unchanged while diagnosing microphone firmware startup.
    private static let startupSmoothingEnabled = false
    private var startupSmoother = BLEStartupSmoother()
    var recentPCM: Data { active ? prebuffer : Data() }
    private func emit(_ pcm: Data) {
        let pcm = Self.startupSmoothingEnabled ? startupSmoother.process(pcm) : pcm
        prebuffer.append(pcm)
        if prebuffer.count > 32_000 { prebuffer.removeFirst(prebuffer.count - 32_000) }
        onPCM?(pcm)
    }
    var onSourcesChanged: (() -> Void)?
    private var knownPeripherals: [UUID: CBPeripheral] = [:]
    private var catalog: MicSourceCatalog
    private var publishedSources: [MicSource] = []
    private var lastScanRestart: TimeInterval = 0
    private var retiring: CBPeripheral?
    private var retirePending: Set<CBUUID> = []
    private var retireDeadline: TimeInterval = 0
    private var retireCancelSent = false
    private var audioCharacteristic: CBCharacteristic?
    private var statusCharacteristic: CBCharacteristic?
    private let preferences: UserDefaults
    private static let selectionKey = "AirtypeBLEMicSelectedPeripheral"
    private static let selectionNameKey = "AirtypeBLEMicSelectedPeripheralName"
    var selectedSourceID: UUID? { catalog.selectedID }
    var connectedSourceID: UUID? { subscribed ? peripheral?.identifier : nil }
    var sources: [MicSource] { catalog.sources(now: ProcessInfo.processInfo.systemUptime) }
    private var sourceName: String { sources.first(where: { $0.id == selectedSourceID })?.name ?? "BLE 麦克风" }
    private var idleMessage: String { "已连接 \(sourceName) · 按设备 MIC 键开始录音" }
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var assembler = PacketAssembler()
    private var decoder: OpusDecoderBox?
    private var currentSession: UInt16?
    private var expectedSequence: UInt16?
    private var active = false
    private var lastAudio: TimeInterval = 0
    private var timer: Timer?
    private var received = 0
    private var lost = 0
    private var previousPacketAt: TimeInterval = 0
    private var maxPacketGap: TimeInterval = 0
    private var logAt: TimeInterval = 0
    private var lastLoggedReceived = 0
    private var pendingStatus: CBCharacteristic?
    private var receivingEnabled = false
    private var stopped = false
    private var connectingAt: TimeInterval = 0
    private var lastSearch: TimeInterval = 0
    private var lastStatusAt: TimeInterval = 0
    private var subscribed = false
    var isSubscribed: Bool { subscribed }
    private override init() {
        preferences = .standard
        let text = preferences.string(forKey: Self.selectionKey)
            ?? preferences.string(forKey: "AirtypeBLEMicPeripheral")
        catalog = MicSourceCatalog(selectedID: text.flatMap(UUID.init(uuidString:)),
            selectedName: preferences.string(forKey: Self.selectionNameKey))
        super.init()
    }
    private func persistSelection() {
        guard let id = selectedSourceID else { return }
        preferences.set(id.uuidString, forKey: Self.selectionKey)
        preferences.set(sourceName, forKey: Self.selectionNameKey)
    }
    private func publishSources(force: Bool = false) {
        let current = sources
        if force || current != publishedSources {
            publishedSources = current; onSourcesChanged?()
        }
    }
    func selectSource(_ id: UUID) {
        guard sources.contains(where: { $0.id == id }) else { return }
        let changed = catalog.select(id)
        persistSelection(); publishSources(force: true)
        if !changed, peripheral?.identifier == id { return }
        report("正在切换到 \(sourceName)…")
        if let old = peripheral { retire(old) }
        else if retiring == nil { reset(); connectSelected() }
    }
    func refreshSources() {
        guard !stopped, central?.state == .poweredOn else { return }
        central.stopScan(); lastScanRestart = 0; scan()
    }
    private func register(_ p: CBPeripheral, name: String? = nil, seen: Bool = false) {
        knownPeripherals[p.identifier] = p
        if seen { catalog.observe(p.identifier, name: name ?? p.name, now: ProcessInfo.processInfo.systemUptime) }
        else { catalog.remember(p.identifier, name: name ?? p.name) }
    }
    private func chooseInitialSourceIfNeeded() {
        guard selectedSourceID == nil, let first = sources.first(where: { $0.isAvailable }) else { return }
        catalog.select(first.id); persistSelection()
    }
    private func connectSelected() {
        guard receivingEnabled, !stopped, central?.state == .poweredOn, peripheral == nil, retiring == nil,
              let id = selectedSourceID else { return }
        if knownPeripherals[id] == nil,
           let p = central.retrievePeripherals(withIdentifiers: [id]).first { register(p) }
        if let p = knownPeripherals[id] { connect(p) }
        else { report("等待 \(sourceName) 上线 · 可从输入来源菜单选择其他设备") }
    }
    private func retire(_ old: CBPeripheral) {
        // Reject old audio immediately, while allowing only its unsubscribe ACKs.
        let chars = [audioCharacteristic, statusCharacteristic].compactMap { $0 }
        peripheral = nil; reset(); retiring = old; retireCancelSent = false
        retirePending = []; retireDeadline = ProcessInfo.processInfo.systemUptime + 2
        if old.state == .connected {
            for c in chars { retirePending.insert(c.uuid); old.setNotifyValue(false, for: c) }
        }
        if retirePending.isEmpty { cancelRetiringConnection() }
        publishSources(force: true)
    }
    private func cancelRetiringConnection() {
        guard let old = retiring, !retireCancelSent else { return }
        retireCancelSent = true; retireDeadline = ProcessInfo.processInfo.systemUptime + 2
        if old.state == .disconnected { finishRetiring() }
        else { central.cancelPeripheralConnection(old) }
    }
    private func finishRetiring() {
        retiring?.delegate = nil; retiring = nil; retirePending = []; retireDeadline = 0
        connectSelected(); publishSources(force: true)
    }
    private func unsubscribe(_ p: CBPeripheral) {
        if p.state == .connected {
            for c in [audioCharacteristic, statusCharacteristic].compactMap({ $0 }) { p.setNotifyValue(false, for: c) }
        }
    }
    // Keep discovery available while a traditional microphone is selected,
    // without subscribing to audio from any BLE device.
    func setReceivingEnabled(_ enabled: Bool) {
        guard receivingEnabled != enabled else { return }
        receivingEnabled = enabled
        if enabled {
            connectSelected()
        } else if let old = peripheral {
            retire(old)
        }
    }
    func start(receiving: Bool = true) {
        setReceivingEnabled(receiving)
        guard central == nil else { return }
        stopped = false
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: true])
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        publishSources(force: true)
    }
    func stop() {
        stopped = true; timer?.invalidate(); timer = nil
        central?.delegate = nil; central?.stopScan()
        if let p = peripheral { unsubscribe(p); p.delegate = nil; central?.cancelPeripheralConnection(p) }
        if let p = retiring { p.delegate = nil; central?.cancelPeripheralConnection(p) }
        retiring = nil; retirePending = []
        peripheral = nil; central = nil
        knownPeripherals.removeAll()
        reset(); catalog.updateSystemConnections([]); publishSources(force: true)
    }
    private func reset() {
        if active { onFailure?("BLE microphone disconnected during recording") }
        active = false; currentSession = nil; expectedSequence = nil; decoder = nil
        startupSmoother = BLEStartupSmoother()
        assembler.reset(); prebuffer.removeAll(); pendingStatus = nil
        audioCharacteristic = nil; statusCharacteristic = nil
        connectingAt = 0; lastStatusAt = 0; subscribed = false
        received = 0; lost = 0; previousPacketAt = 0; maxPacketGap = 0
        lastLoggedReceived = 0
    }
    private func report(_ message: String) {
        NSLog("Airtype BLE: %@", message)
        onStatus?(message)
    }
    private func connect(_ p: CBPeripheral) {
        guard !stopped, peripheral == nil else { return }
        peripheral = p; p.delegate = self
        connectingAt = ProcessInfo.processInfo.systemUptime
        central.connect(p)
        report("正在连接 \(p.name ?? "Passport Mic")…")
    }
    private func scan() {
        guard !stopped, central.state == .poweredOn else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lastSearch = now
        // Include peripherals already owned by the OS keyboard connection.
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.service])
        catalog.updateSystemConnections(Set(connected.map(\.identifier)))
        for p in connected { register(p) }
        chooseInitialSourceIfNeeded(); publishSources()
        if !central.isScanning || now-lastScanRestart >= 10 {
            central.stopScan()
            central.scanForPeripherals(withServices: [Self.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            lastScanRestart = now
        }
        connectSelected()
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !stopped, central === self.central else { return }
        if central.state != .poweredOn {
            peripheral?.delegate = nil; peripheral = nil
            retiring?.delegate = nil; retiring = nil; retirePending = []
            knownPeripherals.removeAll()
            catalog.updateSystemConnections([]); reset(); publishSources(force: true)
        }
        switch central.state {
        case .poweredOn: scan()
        case .unauthorized: reset(); report("请在系统设置中允许蓝牙访问")
        case .poweredOff: reset(); report("蓝牙已关闭")
        case .unsupported: reset(); report("此 Mac 不支持 BLE")
        default: reset(); report("蓝牙正在准备…")
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !stopped, central === self.central else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? p.name
        register(p, name: name, seen: true)
        chooseInitialSourceIfNeeded(); publishSources(); connectSelected()
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard !stopped, central === self.central, p === peripheral else { return }
        connectingAt = ProcessInfo.processInfo.systemUptime
        report("蓝牙已连接，正在读取音频服务…")
        p.discoverServices([Self.service])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard !stopped, central === self.central else { return }
        if p === retiring { finishRetiring(); return }
        guard p === peripheral else { return }
        reset(); peripheral = nil; report("连接失败：\(error?.localizedDescription ?? "unknown")"); retry()
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard !stopped, central === self.central else { return }
        if p === retiring { finishRetiring(); return }
        guard p === peripheral else { return }
        reset(); peripheral = nil; audioCharacteristic = nil; statusCharacteristic = nil
        publishSources(force: true); report("\(sourceName) 已断开，正在等待重连"); retry()
    }
    private func retry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.scan() }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard !stopped, p === peripheral else { return }
        guard error == nil, let service = p.services?.first(where: { $0.uuid == Self.service }) else { fail("找不到麦克风服务"); return }
        p.discoverCharacteristics([Self.audio, Self.status], for: service)
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard !stopped, p === peripheral else { return }
        guard error == nil, let chars = service.characteristics,
              let audio = chars.first(where: { $0.uuid == Self.audio }),
              let status = chars.first(where: { $0.uuid == Self.status }) else { fail("固件音频服务不完整"); return }
        report("已找到音频服务，正在订阅音频…")
        audioCharacteristic = audio; statusCharacteristic = status
        pendingStatus = status
        // Status is subscribed last: firmware refuses recording until audio is ready.
        p.setNotifyValue(true, for: audio)
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard !stopped else { return }
        if p === retiring {
            if error != nil || !c.isNotifying { retirePending.remove(c.uuid) }
            if retirePending.isEmpty { cancelRetiringConnection() }
            return
        }
        guard p === peripheral else { return }
        guard error == nil, c.isNotifying else { fail("蓝牙音频订阅失败"); return }
        if c.uuid == Self.audio, let status = pendingStatus {
            p.setNotifyValue(true, for: status); pendingStatus = nil
        } else if c.uuid == Self.status {
            connectingAt = 0; subscribed = true; lastStatusAt = ProcessInfo.processInfo.systemUptime
            persistSelection(); publishSources(force: true)
            p.readValue(for: c); report(idleMessage)
        }
    }
    private func fail(_ message: String) {
        report(message)
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard !stopped, p === peripheral else { return }
        guard error == nil, let value = c.value else { return }
        let bytes = [UInt8](value)
        if c.uuid == Self.status {
            guard let status = MicStatus(bytes) else { fail("固件音频协议版本不兼容"); return }
            lastStatusAt = ProcessInfo.processInfo.systemUptime
            if status.recording {
                if !active || currentSession != status.session {
                    do { decoder = try OpusDecoderBox() } catch { fail(String(describing: error)); return }
                    startupSmoother = BLEStartupSmoother()
                    assembler.reset(); prebuffer.removeAll(); expectedSequence = nil
                    currentSession = status.session; received = 0; lost = 0; lastAudio = ProcessInfo.processInfo.systemUptime
                    previousPacketAt = 0; maxPacketGap = 0; logAt = lastAudio; lastLoggedReceived = 0
                }
                active = true; report("正在接收 \(sourceName) · Opus / BLE")
            } else {
                if active { NSLog("HS audio ended: %@", statistics) }
                active = false; assembler.reset(); prebuffer.removeAll(); report(idleMessage)
            }
        } else if c.uuid == Self.audio {
            guard active, let packet = assembler.push(bytes, now: ProcessInfo.processInfo.systemUptime), packet.session == currentSession else { return }
            guard let decoder else { return }
            do {
                if let expected = expectedSequence {
                    guard let gap = frameGap(expected: expected, received: packet.sequence) else { return }
                    lost += gap
                    // PLC is bounded. Large discontinuities start a fresh decoder.
                    if gap > 5 {
                        self.decoder = try OpusDecoderBox(); prebuffer.removeAll()
                    } else {
                        for _ in 0..<gap { emit(try decoder.decode(nil)) }
                    }
                }
                let pcm = try self.decoder!.decode(packet.opus)
                emit(pcm); expectedSequence = packet.sequence &+ 1
                lastAudio = ProcessInfo.processInfo.systemUptime; received += 1
                if previousPacketAt > 0 { maxPacketGap = max(maxPacketGap, lastAudio - previousPacketAt) }
                previousPacketAt = lastAudio
            } catch { report("音频解码错误：\(error)") }

        }
    }
    private func recover(_ reason: String) {
        guard !stopped else { return }
        stop()
        report(reason)
        start(receiving: receivingEnabled)
    }
    private func tick() {
        guard !stopped else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastSearch > 3 { scan() }
        if retiring != nil, now > retireDeadline {
            if !retireCancelSent { cancelRetiringConnection() }
            else { recover("旧麦克风断开超时，正在恢复所选输入…") }
            return
        }
        if connectingAt > 0, now - connectingAt > 10 {
            recover("连接或订阅超时，正在自动恢复…"); return
        }
        if subscribed, now - lastStatusAt > 6 {
            recover("设备状态通知中断，正在自动恢复…"); return
        }
        if active, now - logAt >= 1 {
            NSLog("HS audio: frames/s=%d %@", received-lastLoggedReceived, statistics)
            lastLoggedReceived=received; logAt=now
        }
        if active, now - lastAudio > 0.3 {
            prebuffer.removeAll() // Never loop stale speech if audio notifications stop.
            if now - lastAudio > 2 { recover("音频中断，正在重新连接所选麦克风…") }
        }
    }
    var statistics: String { "收到 \(received) 帧，丢失 \(lost) 帧 gapMax=\(Int(maxPacketGap*1000))ms" }
}
