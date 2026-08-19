#!/usr/bin/env swift
// Hold a virtual key via CGEvent (HID level) for dictation PTT simulation.
// Usage: hold-key.swift <keycode> <seconds>
import CoreGraphics
import Foundation

guard CommandLine.arguments.count >= 3,
      let keyCode = CGKeyCode(CommandLine.arguments[1]),
      let seconds = Double(CommandLine.arguments[2]) else {
    fputs("Usage: hold-key.swift <keycode> <seconds>\n", stderr)
    exit(1)
}

let src = CGEventSource(stateID: .hidSystemState)
let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
down?.flags = []
down?.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: seconds)
let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
up?.flags = []
up?.post(tap: .cghidEventTap)
