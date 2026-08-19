#!/usr/bin/env swift
// Play a file to a named output device WITHOUT changing the system default output.
// Usage: play-to-device.swift "BlackHole 2ch" file.aiff
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

guard CommandLine.arguments.count >= 3 else {
    fputs("Usage: play-to-device.swift \"Device Name\" file\n", stderr)
    exit(1)
}

let deviceName = CommandLine.arguments[1]
let fileURL = URL(fileURLWithPath: CommandLine.arguments[2])

func getStringProperty(_ device: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
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

func findDeviceID(named: String) -> AudioDeviceID? {
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize) == noErr else { return nil }
    let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs) == noErr else { return nil }
    for id in deviceIDs {
        let name = getStringProperty(id, selector: kAudioDevicePropertyDeviceNameCFString)
            ?? getStringProperty(id, selector: kAudioObjectPropertyName)
        if name == named { return id }
    }
    return nil
}

guard let deviceID = findDeviceID(named: deviceName) else {
    fputs("Device not found: \(deviceName)\n", stderr)
    exit(4)
}

do {
    let file = try AVAudioFile(forReading: fileURL)
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)

    var id = deviceID
    let size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioUnitSetProperty(
        engine.outputNode.audioUnit!,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &id,
        size
    )
    if status != noErr {
        fputs("Failed to bind output to \(deviceName) (status \(status))\n", stderr)
        exit(5)
    }

    engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
    engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
    engine.mainMixerNode.outputVolume = 1.0

    try engine.start()
    player.scheduleFile(file, at: nil)
    player.play()
    let seconds = Double(file.length) / file.processingFormat.sampleRate
    Thread.sleep(forTimeInterval: seconds + 0.4)
    player.stop()
    engine.stop()
} catch {
    fputs("Play error: \(error.localizedDescription)\n", stderr)
    exit(6)
}
