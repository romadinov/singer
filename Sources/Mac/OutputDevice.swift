import CoreAudio
import Foundation

/// Switches the default output device's nominal sample rate to match the file being played, so
/// macOS doesn't resample (44.1 kHz CDs would otherwise be converted to the device's 48 kHz).
/// The device's original rate is restored when Singer quits.
enum OutputDevice {
    private static var original: (device: AudioDeviceID, rate: Double)?

    static var defaultDevice: AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return err == noErr && id != 0 ? id : nil
    }

    static func nominalRate(_ device: AudioDeviceID) -> Double {
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate)
        return rate
    }

    static func availableRates(_ device: AudioDeviceID) -> [AudioValueRange] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &ranges) == noErr else { return [] }
        return ranges
    }

    /// The device rate to use for a file: the file's own rate if supported, otherwise the highest
    /// supported integer multiple (e.g. 88.2 kHz for a 44.1 kHz file on a DAC without 44.1).
    static func bestRate(for fileRate: Double, among ranges: [AudioValueRange]) -> Double? {
        func supported(_ r: Double) -> Bool { ranges.contains { $0.mMinimum <= r && r <= $0.mMaximum } }
        if supported(fileRate) { return fileRate }
        return [8.0, 4.0, 2.0].map { fileRate * $0 }.first(where: supported)
    }

    /// Returns true if the rate was changed.
    @discardableResult
    static func match(_ fileRate: Double) -> Bool {
        guard let device = defaultDevice,
              let target = bestRate(for: fileRate, among: availableRates(device)) else { return false }
        let current = nominalRate(device)
        guard current != target else { return false }
        if original == nil || original?.device != device { original = (device, current) }
        guard set(target, on: device) else { return false }
        // The switch is asynchronous; wait briefly so the engine starts at the new rate.
        for _ in 0..<50 where nominalRate(device) != target { usleep(10_000) }
        return true
    }

    static func restoreOriginal() {
        guard let o = original else { return }
        if nominalRate(o.device) != o.rate { _ = set(o.rate, on: o.device) }
        original = nil
    }

    private static func set(_ rate: Double, on device: AudioDeviceID) -> Bool {
        var value = Float64(rate)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        return AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &value) == noErr
    }
}
