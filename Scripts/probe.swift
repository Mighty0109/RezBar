#!/usr/bin/env swift

//  probe.swift
//  A standalone sanity check for the CoreGraphics display APIs RezBar depends on.
//
//  It runs under the Command Line Tools `swift` interpreter, with no Xcode project and no
//  app bundle, so the underlying system behaviour can be verified independently of the build:
//
//      swift Scripts/probe.swift            enumerate displays and modes (read-only)
//      swift Scripts/probe.swift --switch   change resolution, verify, restore, verify
//
//  The --switch run briefly changes the resolution of the main display and puts it straight
//  back. Expect one short flicker.
//
//  Exit code 0 means every check passed.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Output helpers

var failures: [String] = []

func check(_ condition: Bool, _ description: String) {
    if condition {
        print("  PASS  \(description)")
    } else {
        print("  FAIL  \(description)")
        failures.append(description)
    }
}

func describe(_ mode: CGDisplayMode) -> String {
    let hiDPI = (mode.pixelWidth != mode.width || mode.pixelHeight != mode.height) ? " HiDPI" : ""
    return "\(mode.width)x\(mode.height) pt / \(mode.pixelWidth)x\(mode.pixelHeight) px "
        + "@ \(String(format: "%.2f", mode.refreshRate)) Hz\(hiDPI)"
}

func sameMode(_ lhs: CGDisplayMode, _ rhs: CGDisplayMode) -> Bool {
    lhs.width == rhs.width
        && lhs.height == rhs.height
        && lhs.pixelWidth == rhs.pixelWidth
        && lhs.pixelHeight == rhs.pixelHeight
        && Int((lhs.refreshRate * 100).rounded()) == Int((rhs.refreshRate * 100).rounded())
}

// MARK: - Display access

func activeDisplayIDs() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
    return Array(ids.prefix(Int(count)))
}

func allModes(_ id: CGDirectDisplayID, includeDuplicates: Bool) -> [CGDisplayMode] {
    let options = includeDuplicates
        ? [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        : nil
    return (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
}

func displayName(_ id: CGDirectDisplayID) -> String {
    let key = NSDeviceDescriptionKey("NSScreenNumber")
    for screen in NSScreen.screens {
        if let number = screen.deviceDescription[key] as? NSNumber,
           CGDirectDisplayID(number.uint32Value) == id {
            return screen.localizedName
        }
    }
    return "Display \(id)"
}

func applyMode(_ mode: CGDisplayMode, to id: CGDirectDisplayID) -> CGError {
    var configRef: CGDisplayConfigRef?
    let begin = CGBeginDisplayConfiguration(&configRef)
    guard begin == .success, let config = configRef else {
        return begin == .success ? .failure : begin
    }
    let set = CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
    guard set == .success else {
        CGCancelDisplayConfiguration(config)
        return set
    }
    return CGCompleteDisplayConfiguration(config, .permanently)
}

// MARK: - Enumeration

print("RezBar display probe")
print(String(repeating: "=", count: 60))

let displays = activeDisplayIDs()
print("\nActive displays: \(displays.count)")
check(!displays.isEmpty, "at least one active display")

var totalHiDPI = 0

for id in displays {
    let withDuplicates = allModes(id, includeDuplicates: true)
    let withoutDuplicates = allModes(id, includeDuplicates: false)
    let hiDPI = withDuplicates.filter { $0.pixelWidth != $0.width || $0.pixelHeight != $0.height }
    totalHiDPI += hiDPI.count

    print("\n[\(id)] \(displayName(id))\(CGDisplayIsMain(id) != 0 ? "  (main)" : "")")
    print("  modes, duplicates included: \(withDuplicates.count)")
    print("  modes, duplicates excluded: \(withoutDuplicates.count)")
    print("  HiDPI modes:                \(hiDPI.count)")
    if let current = CGDisplayCopyDisplayMode(id) {
        print("  current mode:               \(describe(current))")
    }

    check(
        withDuplicates.count > withoutDuplicates.count,
        "[\(id)] duplicate-included count (\(withDuplicates.count)) > excluded count (\(withoutDuplicates.count))"
    )
    check(withoutDuplicates.count > 0, "[\(id)] duplicate-excluded count (\(withoutDuplicates.count)) > 0")
}

print("")
check(totalHiDPI >= 1, "at least one HiDPI mode across all displays (found \(totalHiDPI))")

// MARK: - Switch round trip

if CommandLine.arguments.contains("--switch") {
    print("\n" + String(repeating: "-", count: 60))
    print("Switch round trip (the screen will flicker once)")

    guard let id = displays.first(where: { CGDisplayIsMain($0) != 0 }) ?? displays.first else {
        print("  FAIL  no display to switch")
        exit(1)
    }

    guard let original = CGDisplayCopyDisplayMode(id) else {
        print("  FAIL  could not read the current mode")
        exit(1)
    }
    print("\n  original: \(describe(original))")

    // Pick a safe target: usable for the desktop, HiDPI, a different point size than the
    // current one, same refresh rate if possible, and as close in area as possible so the
    // visual disruption is minimal.
    let originalArea = original.width * original.height
    let candidates = allModes(id, includeDuplicates: true).filter { mode in
        mode.isUsableForDesktopGUI()
            && (mode.width != original.width || mode.height != original.height)
            && (mode.pixelWidth != mode.width || mode.pixelHeight != mode.height)
    }
    let sameRate = candidates.filter {
        Int(($0.refreshRate * 100).rounded()) == Int((original.refreshRate * 100).rounded())
    }
    let pool = sameRate.isEmpty ? candidates : sameRate
    let target = pool.min {
        abs($0.width * $0.height - originalArea) < abs($1.width * $1.height - originalArea)
    }

    guard let target else {
        print("  FAIL  no alternative desktop-usable mode to switch to")
        exit(1)
    }
    print("  target:   \(describe(target))\n")

    let switchResult = applyMode(target, to: id)
    check(switchResult == .success, "switch returned .success (got \(switchResult.rawValue))")
    Thread.sleep(forTimeInterval: 1.5)

    let afterSwitch = CGDisplayCopyDisplayMode(id)
    check(
        afterSwitch.map { sameMode($0, target) } ?? false,
        "display reports the target mode after switching"
            + (afterSwitch.map { " (got \(describe($0)))" } ?? "")
    )

    // Restore, whatever happened above.
    let restoreResult = applyMode(original, to: id)
    check(restoreResult == .success, "restore returned .success (got \(restoreResult.rawValue))")
    Thread.sleep(forTimeInterval: 1.5)

    let afterRestore = CGDisplayCopyDisplayMode(id)
    check(
        afterRestore.map { sameMode($0, original) } ?? false,
        "display is back on the original mode"
            + (afterRestore.map { " (got \(describe($0)))" } ?? "")
    )

    if let afterRestore, !sameMode(afterRestore, original) {
        print("\n  !! The original mode was NOT restored. Set it manually in")
        print("     System Settings > Displays: \(describe(original))")
    }
}

// MARK: - Result

print("\n" + String(repeating: "=", count: 60))
if failures.isEmpty {
    print("All checks passed.")
    exit(0)
} else {
    print("\(failures.count) check(s) failed:")
    for failure in failures { print("  - \(failure)") }
    exit(1)
}
