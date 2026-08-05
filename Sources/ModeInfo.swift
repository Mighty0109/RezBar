import CoreGraphics

/// Value-type snapshot of a display mode.
///
/// `CGDisplayMode` is a CoreGraphics object with no public initializer, so it can never be
/// constructed in a unit test. Every CG mode is converted to a `ModeInfo` at the API boundary
/// (`DisplayManager`) and all downstream logic works on these values only.
///
/// `cgModeRef` is the runtime handle needed to actually apply the mode. It is deliberately
/// excluded from `Equatable`/`Hashable` so that synthetic test fixtures (which carry `nil`)
/// compare identically to modes read from the system.
struct ModeInfo {
    let pointWidth: Int
    let pointHeight: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double

    /// Runtime-only handle. `nil` for synthetic values (tests, fixtures).
    let cgModeRef: CGDisplayMode?

    init(
        pointWidth: Int,
        pointHeight: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        refreshRate: Double,
        cgModeRef: CGDisplayMode? = nil
    ) {
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.cgModeRef = cgModeRef
    }

    init(cgMode: CGDisplayMode) {
        self.init(
            pointWidth: cgMode.width,
            pointHeight: cgMode.height,
            pixelWidth: cgMode.pixelWidth,
            pixelHeight: cgMode.pixelHeight,
            refreshRate: cgMode.refreshRate,
            cgModeRef: cgMode
        )
    }

    /// A mode is HiDPI (Retina-scaled) when its backing pixel buffer is larger than its point size.
    var isHiDPI: Bool {
        pixelWidth != pointWidth || pixelHeight != pointHeight
    }

    var pointArea: Int {
        pointWidth * pointHeight
    }

    /// Refresh rate rounded to 2 decimals, expressed as an integer number of hundredths.
    /// Using an integer avoids `Double` equality/hashing pitfalls in the dedup key.
    var rateHundredths: Int {
        Int((refreshRate * 100).rounded())
    }

    var dedupKey: DedupKey {
        DedupKey(
            pointWidth: pointWidth,
            pointHeight: pointHeight,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            rateHundredths: rateHundredths
        )
    }

    var groupKey: GroupKey {
        GroupKey(pointWidth: pointWidth, pointHeight: pointHeight, isHiDPI: isHiDPI)
    }
}

extension ModeInfo: Equatable, Hashable {
    static func == (lhs: ModeInfo, rhs: ModeInfo) -> Bool {
        lhs.pointWidth == rhs.pointWidth
            && lhs.pointHeight == rhs.pointHeight
            && lhs.pixelWidth == rhs.pixelWidth
            && lhs.pixelHeight == rhs.pixelHeight
            && lhs.refreshRate == rhs.refreshRate
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(pointWidth)
        hasher.combine(pointHeight)
        hasher.combine(pixelWidth)
        hasher.combine(pixelHeight)
        hasher.combine(refreshRate)
    }
}

/// Identity used to collapse the duplicate-heavy list CoreGraphics returns.
/// Deliberately contains no colour-depth component: `pixelEncoding` is deprecated and reports
/// the same value for every mode on modern hardware.
struct DedupKey: Hashable {
    let pointWidth: Int
    let pointHeight: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let rateHundredths: Int
}

/// Identity of a top-level menu entry: one point resolution at one HiDPI-ness.
struct GroupKey: Hashable {
    let pointWidth: Int
    let pointHeight: Int
    let isHiDPI: Bool
}

/// One top-level menu entry, holding every refresh rate available at that resolution.
struct ResolutionGroup: Equatable {
    let pointWidth: Int
    let pointHeight: Int
    let isHiDPI: Bool
    /// Sorted by refresh rate, descending.
    let modes: [ModeInfo]

    var label: String {
        ModeLogic.resolutionLabel(pointWidth: pointWidth, pointHeight: pointHeight, isHiDPI: isHiDPI)
    }

    /// A rate submenu is only worth showing when there is an actual choice to make.
    var needsRateSubmenu: Bool {
        modes.count > 1
    }

    func contains(_ mode: ModeInfo) -> Bool {
        modes.contains(mode)
    }
}

/// Everything the menu needs to know about one display, as plain values.
struct DisplaySnapshot: Equatable {
    let id: CGDirectDisplayID
    let name: String
    let modes: [ModeInfo]
    let current: ModeInfo?
}

/// One display plus its menu-ready resolution groups.
struct DisplayPlan: Equatable {
    let display: DisplaySnapshot
    let groups: [ResolutionGroup]
}

/// The shape of the menu to build. A single display puts its modes at the top level;
/// multiple displays each get their own submenu.
enum MenuPlan: Equatable {
    case empty
    case topLevel(DisplayPlan)
    case submenus([DisplayPlan])
}
