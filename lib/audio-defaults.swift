#!/usr/bin/env swift
// Save / restore macOS default input and output devices so BlackHole tests
// do not leave the system mic/speakers switched.
// Usage:
//   audio-defaults save <json-path>
//   audio-defaults restore <json-path>
import CoreAudio
import Foundation

func getString(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
    let buf = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
    defer { buf.deallocate() }
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, buf) == noErr, let cf = buf.pointee else { return nil }
    return cf as String
}

func getDefault(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr else { return nil }
    return device
}

func setDefault(_ selector: AudioObjectPropertySelector, _ device: AudioDeviceID) -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var dev = device
    return AudioObjectSetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &addr, 0, nil,
        UInt32(MemoryLayout<AudioDeviceID>.size),
        &dev
    ) == noErr
}

func allDevices() -> [AudioDeviceID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func deviceName(_ id: AudioDeviceID) -> String {
    getString(id, kAudioDevicePropertyDeviceNameCFString)
        ?? getString(id, kAudioObjectPropertyName)
        ?? ""
}

func isVirtualCable(_ name: String) -> Bool {
    let n = name.lowercased()
    return n.contains("blackhole") || n.contains("loopback") || n.contains("soundflower")
}

func findDevice(named: String) -> AudioDeviceID? {
    for id in allDevices() {
        if deviceName(id) == named { return id }
    }
    return nil
}

func findFirst(matching needles: [String], excludingVirtual: Bool = true) -> AudioDeviceID? {
    for needle in needles {
        if let exact = findDevice(named: needle), !(excludingVirtual && isVirtualCable(deviceName(exact))) {
            return exact
        }
    }
    for needle in needles {
        let lower = needle.lowercased()
        for id in allDevices() {
            let name = deviceName(id)
            if excludingVirtual && isVirtualCable(name) { continue }
            if name.lowercased().contains(lower) { return id }
        }
    }
    return nil
}

func builtinOutput() -> AudioDeviceID? {
    findFirst(matching: [
        "MacBook Pro Speakers", "MacBook Air Speakers", "Built-in Output", "Internal Speakers", "Speakers"
    ])
}

func builtinInput() -> AudioDeviceID? {
    findFirst(matching: [
        "MacBook Pro Microphone", "MacBook Air Microphone", "Built-in Microphone", "Internal Microphone", "Microphone"
    ])
}

func deviceInfo(_ id: AudioDeviceID) -> [String: Any] {
    [
        "id": Int(id),
        "name": deviceName(id)
    ]
}

func applyBuiltin() {
    if let spk = builtinOutput() {
        _ = setDefault(kAudioHardwarePropertyDefaultOutputDevice, spk)
        print("Output -> \(deviceName(spk))")
    } else {
        fputs("Could not find Built-in speakers\n", stderr)
    }
    if let mic = builtinInput() {
        _ = setDefault(kAudioHardwarePropertyDefaultInputDevice, mic)
        print("Input  -> \(deviceName(mic))")
    } else {
        fputs("Could not find Built-in microphone\n", stderr)
    }
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("Usage: audio-defaults save|restore <json-path>\n       audio-defaults builtin\n", stderr)
    exit(1)
}
let cmd = args[1]

if cmd == "builtin" {
    applyBuiltin()
    exit(0)
}

guard args.count >= 3 else {
    fputs("Usage: audio-defaults save|restore <json-path>\n", stderr)
    exit(1)
}
let path = args[2]
let url = URL(fileURLWithPath: path)

if cmd == "save" {
    var payload: [String: Any] = [:]
    if let out = getDefault(kAudioHardwarePropertyDefaultOutputDevice) {
        let name = deviceName(out)
        if isVirtualCable(name), let builtin = builtinOutput() {
            payload["output"] = deviceInfo(builtin)
        } else {
            payload["output"] = deviceInfo(out)
        }
    }
    if let inp = getDefault(kAudioHardwarePropertyDefaultInputDevice) {
        let name = deviceName(inp)
        if isVirtualCable(name), let builtin = builtinInput() {
            payload["input"] = deviceInfo(builtin)
        } else {
            payload["input"] = deviceInfo(inp)
        }
    }
    let data = try! JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
    try! data.write(to: url)
    print("Saved audio defaults to \(path)")
    exit(0)
}

if cmd == "restore" {
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        fputs("No saved audio defaults at \(path); using Built-in\n", stderr)
        applyBuiltin()
        exit(0)
    }

    func restore(_ key: String, _ selector: AudioObjectPropertySelector, builtin: AudioDeviceID?) {
        var restored = false
        if let info = json[key] as? [String: Any], let name = info["name"] as? String, !name.isEmpty,
           !isVirtualCable(name) {
            if let id = findDevice(named: name) {
                restored = setDefault(selector, id)
            }
        }
        if !restored, let builtin {
            _ = setDefault(selector, builtin)
        }
    }

    restore("output", kAudioHardwarePropertyDefaultOutputDevice, builtin: builtinOutput())
    restore("input", kAudioHardwarePropertyDefaultInputDevice, builtin: builtinInput())
    print("Restored system mic and speakers")
    exit(0)
}

fputs("Unknown command \(cmd)\n", stderr)
exit(1)
