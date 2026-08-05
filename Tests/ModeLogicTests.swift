import XCTest
@testable import RezBar

/// Tests for the pure menu logic. Every fixture is a synthetic `ModeInfo`: `CGDisplayMode` has no
/// public initializer and can never be constructed here, which is exactly why the CG boundary is
/// converted to value types in `DisplayManager`.
final class ModeLogicTests: XCTestCase {

    // MARK: - Fixtures

    private func mode(
        pt: (Int, Int),
        px: (Int, Int),
        rate: Double
    ) -> ModeInfo {
        ModeInfo(
            pointWidth: pt.0,
            pointHeight: pt.1,
            pixelWidth: px.0,
            pixelHeight: px.1,
            refreshRate: rate
        )
    }

    /// A retina mode: point size is half the pixel size.
    private func retina(_ w: Int, _ h: Int, rate: Double = 60) -> ModeInfo {
        mode(pt: (w, h), px: (w * 2, h * 2), rate: rate)
    }

    /// A 1:1 mode: points equal pixels.
    private func native(_ w: Int, _ h: Int, rate: Double = 60) -> ModeInfo {
        mode(pt: (w, h), px: (w, h), rate: rate)
    }

    private func snapshot(
        id: CGDirectDisplayID,
        name: String,
        modes: [ModeInfo],
        current: ModeInfo? = nil
    ) -> DisplaySnapshot {
        DisplaySnapshot(id: id, name: name, modes: modes, current: current)
    }

    // MARK: - 1. Dedup

    func testDedupCollapsesIdenticalKeys() {
        let duplicate = retina(1440, 900, rate: 60)
        let result = ModeLogic.dedup([duplicate, duplicate, duplicate])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first, duplicate)
    }

    func testDedupKeepsSamePointSizeWithDifferentPixelSize() {
        // Same point resolution, different backing buffer -> genuinely different modes.
        let scaled = mode(pt: (1920, 1080), px: (3840, 2160), rate: 60)
        let oneToOne = mode(pt: (1920, 1080), px: (1920, 1080), rate: 60)

        let result = ModeLogic.dedup([scaled, oneToOne])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Set(result), Set([scaled, oneToOne]))
    }

    func testDedupKeepsDifferentRefreshRates() {
        let result = ModeLogic.dedup([retina(1440, 900, rate: 120), retina(1440, 900, rate: 60)])
        XCTAssertEqual(result.count, 2)
    }

    func testDedupRoundsRefreshRateToTwoDecimals() {
        // The rate reported by CoreGraphics for 59.94 Hz on real hardware, and its nominal value.
        // Both round to 5994 hundredths, so they are the same mode.
        let measured = retina(1440, 900, rate: 59.93998718261719)
        let nominal = retina(1440, 900, rate: 59.94)

        XCTAssertEqual(measured.rateHundredths, 5994)
        XCTAssertEqual(nominal.rateHundredths, 5994)
        XCTAssertEqual(ModeLogic.dedup([measured, nominal]).count, 1)
    }

    func testDedupSeparatesRatesThatDifferBeyondTwoDecimals() {
        let a = retina(1440, 900, rate: 59.94)
        let b = retina(1440, 900, rate: 59.96)
        XCTAssertNotEqual(a.rateHundredths, b.rateHundredths)
        XCTAssertEqual(ModeLogic.dedup([a, b]).count, 2)
    }

    func testDedupPreservesFirstOccurrenceOrder() {
        let first = retina(1440, 900)
        let second = retina(1280, 800)
        let result = ModeLogic.dedup([first, second, first, second])
        XCTAssertEqual(result, [first, second])
    }

    func testDedupOfEmptyInput() {
        XCTAssertTrue(ModeLogic.dedup([]).isEmpty)
    }

    // MARK: - 2. HiDPI detection

    func testHiDPIIsTrueWhenPixelsExceedPoints() {
        XCTAssertTrue(retina(1440, 900).isHiDPI)
        XCTAssertTrue(mode(pt: (1920, 1080), px: (2880, 1620), rate: 60).isHiDPI)
    }

    func testHiDPIIsFalseWhenPointsEqualPixels() {
        XCTAssertFalse(native(1920, 1080).isHiDPI)
    }

    func testHiDPIIsTrueWhenOnlyOneAxisDiffers() {
        // Defensive: pt != px on either axis is enough.
        XCTAssertTrue(mode(pt: (1920, 1080), px: (1920, 2160), rate: 60).isHiDPI)
        XCTAssertTrue(mode(pt: (1920, 1080), px: (3840, 1080), rate: 60).isHiDPI)
    }

    // MARK: - 3. Sorting

    func testSortRule1LargerPointAreaFirst() {
        let small = retina(1280, 800)   // area 1_024_000
        let large = retina(1920, 1080)  // area 2_073_600
        XCTAssertEqual(ModeLogic.sortModes([small, large]), [large, small])
    }

    func testSortRule2HiDPIBeforeNonHiDPIOnEqualArea() {
        let scaled = mode(pt: (1440, 900), px: (2880, 1800), rate: 60)
        let oneToOne = mode(pt: (1440, 900), px: (1440, 900), rate: 60)
        XCTAssertEqual(ModeLogic.sortModes([oneToOne, scaled]), [scaled, oneToOne])
    }

    func testSortRule3HigherRefreshRateFirstOnEqualAreaAndHiDPI() {
        let slow = retina(1440, 900, rate: 60)
        let fast = retina(1440, 900, rate: 120)
        XCTAssertEqual(ModeLogic.sortModes([slow, fast]), [fast, slow])
    }

    func testSortAppliesRulesInPriorityOrder() {
        // A small HiDPI 120 Hz mode must still lose to a large non-HiDPI 60 Hz mode,
        // because area outranks both other rules.
        let bigNative = native(1920, 1080, rate: 60)
        let smallRetinaFast = retina(1280, 800, rate: 120)
        XCTAssertEqual(ModeLogic.sortModes([smallRetinaFast, bigNative]), [bigNative, smallRetinaFast])
    }

    func testSortFullOrdering() {
        let modes = [
            native(1440, 900, rate: 60),
            retina(1440, 900, rate: 60),
            retina(1440, 900, rate: 120),
            retina(1920, 1080, rate: 60),
        ]
        let sorted = ModeLogic.sortModes(modes.shuffled())
        XCTAssertEqual(
            sorted,
            [
                retina(1920, 1080, rate: 60),   // biggest area
                retina(1440, 900, rate: 120),   // then HiDPI, fastest first
                retina(1440, 900, rate: 60),
                native(1440, 900, rate: 60),    // non-HiDPI last within the same area
            ]
        )
    }

    func testSortIsDeterministicForEqualAreaDifferentShapes() {
        // 1920x1080 and 2160x960 share the same area; the result must still be stable.
        let a = native(1920, 1080, rate: 60)
        let b = native(2160, 960, rate: 60)
        XCTAssertEqual(ModeLogic.sortModes([a, b]), ModeLogic.sortModes([b, a]))
    }

    func testSortOfEmptyInput() {
        XCTAssertTrue(ModeLogic.sortModes([]).isEmpty)
    }

    // MARK: - 4. Refresh rate formatting

    func testFormatRateWholeNumbersDropDecimals() {
        XCTAssertEqual(ModeLogic.formatRate(60.0), "60 Hz")
        XCTAssertEqual(ModeLogic.formatRate(120.0), "120 Hz")
        XCTAssertEqual(ModeLogic.formatRate(30.0), "30 Hz")
    }

    func testFormatRateNearWholeNumbersSnapToInteger() {
        // Within 0.05 Hz of a whole number -> integer form.
        XCTAssertEqual(ModeLogic.formatRate(29.97), "30 Hz")     // delta 0.030
        XCTAssertEqual(ModeLogic.formatRate(23.976), "24 Hz")    // delta 0.024
    }

    func testFormatRateFractionalRatesKeepOneDecimal() {
        XCTAssertEqual(ModeLogic.formatRate(59.94), "59.9 Hz")             // delta 0.060
        XCTAssertEqual(ModeLogic.formatRate(119.88), "119.9 Hz")           // delta 0.120
        // Value as actually reported by CoreGraphics for the 47.95 Hz mode on this machine.
        XCTAssertEqual(ModeLogic.formatRate(47.94999694824219), "47.9 Hz") // delta 0.0500031
    }

    /// Boundary documentation, not a preference.
    ///
    /// The rule is `abs(rate - rate.rounded()) < 0.05`. The literal `47.95` is stored as
    /// 47.95000000000000284, whose distance to 48 is 0.04999999999999716 - just *inside* the
    /// threshold - so the formula yields "48 Hz". The hardware value 47.94999694824219 sits
    /// just *outside* it and yields "47.9 Hz" (asserted above). This test pins the behaviour of
    /// the specified formula at its exact tipping point so a future change to the rule is caught.
    func testFormatRateAtExactThreshold() {
        XCTAssertEqual(ModeLogic.formatRate(47.95), "48 Hz")
        XCTAssertLessThan(abs(47.95 - (47.95 as Double).rounded()), 0.05)
        XCTAssertGreaterThan(abs(47.94999694824219 - (47.94999694824219 as Double).rounded()), 0.05)
    }

    // MARK: - 5. Labels

    func testResolutionLabelMarksHiDPI() {
        XCTAssertEqual(
            ModeLogic.resolutionLabel(pointWidth: 1728, pointHeight: 1117, isHiDPI: true),
            "1728 × 1117 (HiDPI)"
        )
    }

    func testResolutionLabelOmitsSuffixForNativeModes() {
        XCTAssertEqual(
            ModeLogic.resolutionLabel(pointWidth: 1920, pointHeight: 1080, isHiDPI: false),
            "1920 × 1080"
        )
    }

    func testGroupLabelMatchesResolutionLabel() {
        let groups = ModeLogic.groups(from: [retina(1728, 1117)])
        XCTAssertEqual(groups.first?.label, "1728 × 1117 (HiDPI)")
    }

    // MARK: - 6. Grouping

    func testGroupsCollapseRatesOfOneResolution() {
        let groups = ModeLogic.groups(from: [
            retina(1440, 900, rate: 60),
            retina(1440, 900, rate: 120),
            retina(1440, 900, rate: 50),
        ])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].modes.map(\.refreshRate), [120, 60, 50])
        XCTAssertTrue(groups[0].needsRateSubmenu)
    }

    func testGroupsSeparateHiDPIFromNative() {
        let groups = ModeLogic.groups(from: [
            mode(pt: (1920, 1080), px: (3840, 2160), rate: 60),
            mode(pt: (1920, 1080), px: (1920, 1080), rate: 60),
        ])

        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups[0].isHiDPI)   // HiDPI sorts first on equal area
        XCTAssertFalse(groups[1].isHiDPI)
        XCTAssertEqual(groups.map(\.label), ["1920 × 1080 (HiDPI)", "1920 × 1080"])
    }

    func testSingleRateGroupNeedsNoSubmenu() {
        let groups = ModeLogic.groups(from: [retina(1440, 900, rate: 60)])
        XCTAssertEqual(groups.count, 1)
        XCTAssertFalse(groups[0].needsRateSubmenu)
    }

    func testGroupsAreOrderedByAreaDescending() {
        let groups = ModeLogic.groups(from: [
            retina(1280, 800),
            retina(1920, 1080),
            retina(1440, 900),
        ])
        XCTAssertEqual(groups.map(\.pointWidth), [1920, 1440, 1280])
    }

    func testGroupsDedupBeforeGrouping() {
        let repeated = Array(repeating: retina(1440, 900, rate: 60), count: 5)
        let groups = ModeLogic.groups(from: repeated)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].modes.count, 1)
        XCTAssertFalse(groups[0].needsRateSubmenu)
    }

    func testGroupingHandlesEqualAreaDifferentShapes() {
        // Same area, different point shapes must not be merged into one entry.
        let groups = ModeLogic.groups(from: [
            native(1920, 1080, rate: 60),
            native(2160, 960, rate: 60),
        ])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(Set(groups.map(\.pointWidth)), [1920, 2160])
    }

    func testGroupsOfEmptyInput() {
        XCTAssertTrue(ModeLogic.groups(from: []).isEmpty)
    }

    // MARK: - 7. Current mode matching

    func testGroupContainsCurrentModeIgnoringCGHandle() {
        // The live current mode carries a CGDisplayMode handle while menu fixtures may not;
        // equality deliberately ignores it so the checkmark still lands.
        let current = retina(1440, 900, rate: 120)
        let groups = ModeLogic.groups(from: [
            retina(1440, 900, rate: 120),
            retina(1440, 900, rate: 60),
        ])
        XCTAssertTrue(groups[0].contains(current))
    }

    func testGroupDoesNotContainUnrelatedMode() {
        let groups = ModeLogic.groups(from: [retina(1440, 900, rate: 60)])
        XCTAssertFalse(groups[0].contains(retina(1280, 800, rate: 60)))
    }

    // MARK: - 8. Menu plan

    func testPlanForSingleDisplayIsTopLevel() {
        let display = snapshot(id: 1, name: "Built-in", modes: [retina(1440, 900)])
        guard case .topLevel(let plan) = ModeLogic.plan(for: [display]) else {
            return XCTFail("expected .topLevel for a single display")
        }
        XCTAssertEqual(plan.display.name, "Built-in")
        XCTAssertEqual(plan.groups.count, 1)
    }

    func testPlanForTwoDisplaysUsesSubmenus() {
        let builtIn = snapshot(id: 1, name: "Built-in", modes: [retina(1440, 900)])
        let external = snapshot(id: 2, name: "Studio Display", modes: [retina(2560, 1440), native(1920, 1080)])

        guard case .submenus(let plans) = ModeLogic.plan(for: [builtIn, external]) else {
            return XCTFail("expected .submenus for two displays")
        }
        XCTAssertEqual(plans.count, 2)
        XCTAssertEqual(plans.map(\.display.name), ["Built-in", "Studio Display"])
        XCTAssertEqual(plans[1].groups.count, 2)
    }

    func testPlanForThreeDisplaysUsesSubmenus() {
        let displays = (1...3).map {
            snapshot(id: CGDirectDisplayID($0), name: "D\($0)", modes: [retina(1440, 900)])
        }
        guard case .submenus(let plans) = ModeLogic.plan(for: displays) else {
            return XCTFail("expected .submenus for three displays")
        }
        XCTAssertEqual(plans.count, 3)
    }

    func testPlanForNoDisplaysIsEmpty() {
        XCTAssertEqual(ModeLogic.plan(for: []), .empty)
    }

    func testPlanForDisplayWithNoModes() {
        let display = snapshot(id: 1, name: "Headless", modes: [])
        guard case .topLevel(let plan) = ModeLogic.plan(for: [display]) else {
            return XCTFail("expected .topLevel")
        }
        XCTAssertTrue(plan.groups.isEmpty)
    }

    func testPlanPreservesCurrentModeForCheckmarks() {
        let current = retina(1440, 900, rate: 120)
        let display = snapshot(
            id: 1,
            name: "Built-in",
            modes: [retina(1440, 900, rate: 120), retina(1440, 900, rate: 60)],
            current: current
        )
        guard case .topLevel(let plan) = ModeLogic.plan(for: [display]) else {
            return XCTFail("expected .topLevel")
        }
        XCTAssertEqual(plan.display.current, current)
        XCTAssertTrue(plan.groups[0].contains(current))
        XCTAssertEqual(plan.groups[0].modes.first, current)
    }
}
