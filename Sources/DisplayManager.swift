import AppKit
import CoreGraphics

/// The only place that talks to CoreGraphics display APIs. Everything crossing out of here is a
/// plain value type, which keeps the rest of the app testable.
enum DisplayManager {

    /// The authoritative display list.
    ///
    /// `NSScreen.screens` is not usable for this: while mirroring is active it omits the
    /// secondary displays. CoreGraphics is the source of truth; NSScreen is consulted for
    /// human-readable names only.
    static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// Matches a CG display ID to an `NSScreen` to recover its marketing name,
    /// falling back to the raw ID when no screen matches (mirroring, or a display
    /// AppKit does not expose).
    static func name(for id: CGDirectDisplayID) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[key] as? NSNumber else { continue }
            if CGDirectDisplayID(number.uint32Value) == id {
                return screen.localizedName
            }
        }
        return "Display \(id)"
    }

    /// All modes for a display, including the low-resolution aliases that are hidden by default.
    ///
    /// Note: no colour-depth filtering is applied. `CGDisplayMode.pixelEncoding` is deprecated and
    /// returns an identical value for every mode on current hardware, so filtering on it would
    /// either be a no-op or drop everything.
    static func modes(for id: CGDirectDisplayID) -> [ModeInfo] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let raw = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] else {
            return []
        }
        return raw.map(ModeInfo.init(cgMode:))
    }

    static func currentMode(for id: CGDirectDisplayID) -> ModeInfo? {
        CGDisplayCopyDisplayMode(id).map(ModeInfo.init(cgMode:))
    }

    /// Re-reads every display and its modes from scratch. Called on each menu open so that
    /// hot-plugged displays and externally-made resolution changes are always reflected.
    static func snapshot() -> [DisplaySnapshot] {
        activeDisplayIDs().map { id in
            DisplaySnapshot(
                id: id,
                name: name(for: id),
                modes: modes(for: id),
                current: currentMode(for: id)
            )
        }
    }

    /// Applies a mode inside a display configuration transaction.
    /// Returns `.success`, or the first CG error encountered.
    static func apply(_ mode: ModeInfo, to id: CGDirectDisplayID) -> CGError {
        guard let cgMode = mode.cgModeRef else { return .illegalArgument }

        var configRef: CGDisplayConfigRef?
        let beginResult = CGBeginDisplayConfiguration(&configRef)
        guard beginResult == .success, let config = configRef else {
            return beginResult == .success ? .failure : beginResult
        }

        let setResult = CGConfigureDisplayWithDisplayMode(config, id, cgMode, nil)
        guard setResult == .success else {
            CGCancelDisplayConfiguration(config)
            return setResult
        }

        return CGCompleteDisplayConfiguration(config, .permanently)
    }

    /// Human-readable text for the failure alert. The raw CG code is appended so an unexpected
    /// failure is still diagnosable.
    static func message(for error: CGError) -> String {
        let detail: String
        switch error {
        case .success:
            return "Success"
        case .illegalArgument:
            detail = "This display mode is no longer available."
        case .invalidConnection:
            detail = "The connection to the display server was lost."
        case .cannotComplete:
            detail = "The system could not complete the display change."
        case .notImplemented:
            detail = "This operation is not supported on this display."
        default:
            detail = "The display configuration could not be applied."
        }
        return "\(detail) (CGError \(error.rawValue))"
    }
}
