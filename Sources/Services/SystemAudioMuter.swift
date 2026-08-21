import CoreAudio

/// Temporarily mutes the current default output device and restores its exact
/// previous state. If a device has no mute control, it falls back to its master
/// output volume.
final class SystemAudioMuter {
    private enum SavedState {
        case mute(device: AudioDeviceID, address: AudioObjectPropertyAddress, value: UInt32)
        case volume(device: AudioDeviceID, address: AudioObjectPropertyAddress, value: Float32)
    }

    private var savedState: SavedState?

    func mute() {
        guard savedState == nil, let device = defaultOutputDevice() else { return }

        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if let oldMute: UInt32 = read(device: device, address: &muteAddress),
           isSettable(device: device, address: &muteAddress) {
            var muted: UInt32 = 1
            if write(device: device, address: &muteAddress, value: &muted) {
                savedState = .mute(device: device, address: muteAddress, value: oldMute)
                debugLog("System output muted (previous mute state: \(oldMute))")
                return
            }
        }

        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if let oldVolume: Float32 = read(device: device, address: &volumeAddress),
           isSettable(device: device, address: &volumeAddress) {
            var silentVolume: Float32 = 0
            if write(device: device, address: &volumeAddress, value: &silentVolume) {
                savedState = .volume(device: device, address: volumeAddress, value: oldVolume)
                debugLog("System output volume silenced (previous volume: \(oldVolume))")
                return
            }
        }

        debugLog("Default output device does not expose a writable mute or master-volume control")
    }

    func restore() {
        guard let savedState else { return }
        self.savedState = nil

        switch savedState {
        case .mute(let device, var address, var value):
            if write(device: device, address: &address, value: &value) {
                debugLog("System output mute state restored")
            }
        case .volume(let device, var address, var value):
            if write(device: device, address: &address, value: &value) {
                debugLog("System output volume restored")
            }
        }
    }

    deinit {
        restore()
    }

    private func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &device
        )
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private func isSettable(device: AudioDeviceID, address: inout AudioObjectPropertyAddress) -> Bool {
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private func read<T>(device: AudioDeviceID, address: inout AudioObjectPropertyAddress) -> T? {
        guard AudioObjectHasProperty(device, &address) else { return nil }
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, value)
        return status == noErr ? value.pointee : nil
    }

    private func write<T>(
        device: AudioDeviceID,
        address: inout AudioObjectPropertyAddress,
        value: inout T
    ) -> Bool {
        let size = UInt32(MemoryLayout<T>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
    }
}
