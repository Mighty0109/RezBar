import Foundation

/// Pure, side-effect-free menu logic. Nothing here touches CoreGraphics or AppKit, so all of it
/// is directly unit-testable with synthetic `ModeInfo` fixtures.
enum ModeLogic {

    // MARK: - Dedup

    /// CoreGraphics returns a duplicate-heavy list (the same resolution appears once per legacy
    /// colour depth and once per scaling alias). Collapse it on `DedupKey`, keeping the first
    /// occurrence so the original CG ordering is preserved for anything that isn't sorted later.
    static func dedup(_ modes: [ModeInfo]) -> [ModeInfo] {
        var seen = Set<DedupKey>()
        var result: [ModeInfo] = []
        result.reserveCapacity(modes.count)
        for mode in modes where seen.insert(mode.dedupKey).inserted {
            result.append(mode)
        }
        return result
    }

    // MARK: - Sorting

    /// Ordering rules, in priority order:
    ///   1. point area, descending
    ///   2. HiDPI before non-HiDPI
    ///   3. refresh rate, descending
    ///
    /// The remaining comparisons are not part of the specified ordering; they exist only to make
    /// the sort a total order so output is deterministic (Swift's `sort` is not stable).
    static func sortModes(_ modes: [ModeInfo]) -> [ModeInfo] {
        modes.sorted { lhs, rhs in
            if lhs.pointArea != rhs.pointArea { return lhs.pointArea > rhs.pointArea }
            if lhs.isHiDPI != rhs.isHiDPI { return lhs.isHiDPI }
            if lhs.refreshRate != rhs.refreshRate { return lhs.refreshRate > rhs.refreshRate }
            // Deterministic tiebreakers below.
            if lhs.pointWidth != rhs.pointWidth { return lhs.pointWidth > rhs.pointWidth }
            if lhs.pixelWidth != rhs.pixelWidth { return lhs.pixelWidth > rhs.pixelWidth }
            return lhs.pixelHeight > rhs.pixelHeight
        }
    }

    // MARK: - Formatting

    /// Formats a refresh rate for display.
    ///
    /// Rates that sit within 0.05 Hz of a whole number are shown as integers ("60 Hz");
    /// anything else keeps one decimal ("59.9 Hz").
    static func formatRate(_ rate: Double) -> String {
        if abs(rate - rate.rounded()) < 0.05 {
            return "\(Int(rate.rounded())) Hz"
        }
        return String(format: "%.1f Hz", rate)
    }

    static func resolutionLabel(pointWidth: Int, pointHeight: Int, isHiDPI: Bool) -> String {
        let base = "\(pointWidth) × \(pointHeight)"
        return isHiDPI ? "\(base) (HiDPI)" : base
    }

    // MARK: - Grouping

    /// Dedups, sorts, then collapses the result into one entry per (point resolution, HiDPI-ness).
    ///
    /// Grouping walks the sorted array and buckets by key on first appearance rather than assuming
    /// equal keys are adjacent: two different point resolutions can share the same area, which
    /// would interleave them under rules 1-3.
    static func groups(from modes: [ModeInfo]) -> [ResolutionGroup] {
        let ordered = sortModes(dedup(modes))
        var order: [GroupKey] = []
        var buckets: [GroupKey: [ModeInfo]] = [:]

        for mode in ordered {
            let key = mode.groupKey
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = []
            }
            buckets[key]?.append(mode)
        }

        return order.map { key in
            ResolutionGroup(
                pointWidth: key.pointWidth,
                pointHeight: key.pointHeight,
                isHiDPI: key.isHiDPI,
                modes: buckets[key] ?? []
            )
        }
    }

    // MARK: - Menu plan

    /// Decides the overall menu shape: one display goes straight to the top level,
    /// several displays each get a submenu.
    static func plan(for displays: [DisplaySnapshot]) -> MenuPlan {
        let plans = displays.map { DisplayPlan(display: $0, groups: groups(from: $0.modes)) }
        switch plans.count {
        case 0: return .empty
        case 1: return .topLevel(plans[0])
        default: return .submenus(plans)
        }
    }
}
