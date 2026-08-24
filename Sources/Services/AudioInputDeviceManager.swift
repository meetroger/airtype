import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Equatable {
    let deviceID: AudioDeviceID
    let uid: String
    let name: String

    var id: String { uid }
}

@MainActor
final class AudioInputDeviceManager: ObservableObject {
    @Published private(set) var devices: [AudioInputDevice] = []
    @Published private(set) var selectedDeviceUID: String
    @Published private(set) var defaultDeviceUID: String?

    private let settings: Settings
    private let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
    private var listenersInstalled = false

    init(settings: Settings = .shared) {
        self.settings = settings
        self.selectedDeviceUID = settings.selectedAudioInputDeviceUID
        refreshDevices()
        installDeviceListeners()
    }

    var selectedDeviceName: String {
        if let selected = devices.first(where: { $0.uid == selectedDeviceUID }) {
            return selected.name
        }
        if let defaultDeviceUID,
           let defaultDevice = devices.first(where: { $0.uid == defaultDeviceUID }) {
            return defaultDevice.name
        }
        return "System Default"
    }

    var systemDefaultLabel: String {
        if let defaultDeviceUID,
           let defaultDevice = devices.first(where: { $0.uid == defaultDeviceUID }) {
            return "System Default (\(defaultDevice.name))"
        }
        return "System Default"
    }

    func selectDevice(uid: String?) {
        let newUID = uid ?? ""
        selectedDeviceUID = newUID
        settings.selectedAudioInputDeviceUID = newUID
    }

    func deviceIDForRecording() -> AudioDeviceID? {
        refreshDevices()
        guard !selectedDeviceUID.isEmpty else { return nil }
        guard let selectedDevice = devices.first(where: { $0.uid == selectedDeviceUID }) else {
            fallbackToSystemDefault()
            return nil
        }
        return selectedDevice.deviceID
    }

    func fallbackToSystemDefault() {
        guard !selectedDeviceUID.isEmpty else { return }
        debugLog("Selected microphone is unavailable; falling back to the system default")
        selectDevice(uid: nil)
    }

    func refreshDevices() {
        let refreshedDevices = Self.loadInputDevices()
        devices = refreshedDevices
        defaultDeviceUID = Self.loadDefaultInputDeviceUID()

        if !selectedDeviceUID.isEmpty,
           !refreshedDevices.contains(where: { $0.uid == selectedDeviceUID }) {
            fallbackToSystemDefault()
        }
    }

    private func installDeviceListeners() {
        guard !listenersInstalled else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        var devicesAddress = Self.devicesPropertyAddress
        var defaultAddress = Self.defaultInputPropertyAddress

        let devicesStatus = AudioObjectAddPropertyListener(
            systemObjectID,
            &devicesAddress,
            Self.propertyListener,
            context
        )
        let defaultStatus = AudioObjectAddPropertyListener(
            systemObjectID,
            &defaultAddress,
            Self.propertyListener,
            context
        )
        listenersInstalled = devicesStatus == noErr && defaultStatus == noErr
    }

    private nonisolated static let propertyListener: AudioObjectPropertyListenerProc = {
        _, _, _, clientData in
        guard let clientData else { return noErr }
        let manager = Unmanaged<AudioInputDeviceManager>
            .fromOpaque(clientData)
            .takeUnretainedValue()
        Task { @MainActor in
            manager.refreshDevices()
        }
        return noErr
    }

    private nonisolated static var devicesPropertyAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private nonisolated static var defaultInputPropertyAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private nonisolated static func loadInputDevices() -> [AudioInputDevice] {
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        var address = devicesPropertyAddress
        var propertySize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            systemObjectID,
            &address,
            0,
            nil,
            &propertySize
        ) == noErr else {
            return []
        }

        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        guard deviceCount > 0 else { return [] }
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(
            systemObjectID,
            &address,
            0,
            nil,
            &propertySize,
            &deviceIDs
        ) == noErr else {
            return []
        }

        return deviceIDs.compactMap { deviceID in
            guard hasInputStreams(deviceID),
                  let uid = stringProperty(kAudioDevicePropertyDeviceUID, for: deviceID),
                  let name = stringProperty(kAudioObjectPropertyName, for: deviceID) else {
                return nil
            }
            return AudioInputDevice(deviceID: deviceID, uid: uid, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private nonisolated static func loadDefaultInputDeviceUID() -> String? {
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        var address = defaultInputPropertyAddress
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            systemObjectID,
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        ) == noErr,
        deviceID != kAudioObjectUnknown else {
            return nil
        }
        return stringProperty(kAudioDevicePropertyDeviceUID, for: deviceID)
    }

    private nonisolated static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var propertySize: UInt32 = 0
        return AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &propertySize
        ) == noErr && propertySize >= MemoryLayout<AudioStreamID>.size
    }

    private nonisolated static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        for objectID: AudioObjectID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var property: Unmanaged<CFString>?
        var propertySize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &propertySize,
            &property
        ) == noErr,
        let property else {
            return nil
        }
        return property.takeUnretainedValue() as String
    }
}
