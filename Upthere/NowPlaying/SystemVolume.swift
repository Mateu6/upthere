import AudioToolbox
import CoreAudio

/// The default output device's volume (what the keyboard volume keys change).
enum SystemVolume {
    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope)
        -> AudioObjectPropertyAddress
    {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static var outputDevice: AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    /// 0…1, or nil when the device has no software volume (e.g. some HDMI outputs).
    static var volume: Float? {
        guard let device = outputDevice else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return isMuted ? 0 : value
    }

    static var isMuted: Bool {
        guard let device = outputDevice else { return false }
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &muted) == noErr && muted != 0
    }

    @discardableResult
    static func set(_ value: Float) -> Float? {
        guard let device = outputDevice else { return nil }
        var volume = Float32(min(1, max(0, value)))
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        guard
            AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume) == noErr
        else { return nil }
        var mute = UInt32(volume == 0 ? 1 : 0)
        var muteAddr = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        AudioObjectSetPropertyData(device, &muteAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &mute)
        return volume
    }
}
