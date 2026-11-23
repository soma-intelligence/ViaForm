import XCTest

/// WCAG checks on the ViaForm tokens. Runs in the ViaFormThemeTests target, which compiles
/// ThemeTokens.swift alone: no app host, no engine, no selftest.
final class ThemeContrastTests: XCTestCase {
    private let textAA = 4.5
    private let nonTextAA = 3.0

    private func check(_ fg: VFColor, on bg: VFColor, min: Double, _ what: String,
                       file: StaticString = #filePath, line: UInt = #line) {
        let ratio = fg.contrast(on: bg)
        XCTAssertGreaterThanOrEqual(ratio, min, "\(what): \(String(format: "%.2f", ratio)):1, needs \(min):1",
                                    file: file, line: line)
    }

    func testContrastMaths() {
        let black = VFColor(hex: 0x000000), white = VFColor(hex: 0xFFFFFF)
        XCTAssertEqual(black.contrast(on: white), 21, accuracy: 0.01)
        XCTAssertEqual(white.contrast(on: white), 1, accuracy: 0.0001)
        // #767676 on white is the classic 4.54:1 limit case.
        XCTAssertEqual(VFColor(hex: 0x767676).contrast(on: white), 4.54, accuracy: 0.01)
        // Half-opaque black over white composites to mid grey.
        let mid = black.opacity(0.5).over(white)
        XCTAssertEqual(mid.red, 0.5, accuracy: 0.0001)
    }

    func testTextTokensPassAAOnEverySurface() {
        for variant in ThemeVariant.allCases {
            let p = variant.palette
            let text: [(String, VFColor)] = [
                ("ink", p.ink), ("inkSecondary", p.inkSecondary), ("inkTertiary", p.inkTertiary),
                ("accentText", p.accentText), ("success", p.success), ("warning", p.warning), ("danger", p.danger),
            ]
            for (name, color) in text {
                for surface in p.textSurfaces {
                    check(color, on: surface.color, min: textAA, "\(variant) \(name) on \(surface.name)")
                }
            }
            for status in VFStatus.allCases {
                check(p.status(status), on: p.panel, min: textAA, "\(variant) status \(status) on panel")
            }
        }
    }

    func testAccentFillLabels() {
        for variant in ThemeVariant.allCases {
            let p = variant.palette
            check(p.onAccent, on: p.accent, min: textAA, "\(variant) onAccent on accent")
            // The accent fill itself must read as a control against the chrome.
            check(p.accent, on: p.chrome, min: nonTextAA, "\(variant) accent fill on chrome")
        }
    }

    /// A secondary button (Cancel) on a light accent wash: its label is ink, never accent on
    /// accent, so it reads in both themes.
    func testSecondaryButtonOnAccentWash() {
        for variant in ThemeVariant.allCases {
            let p = variant.palette
            let wash = p.accent.opacity(0.14).over(p.panel)
            check(p.ink, on: wash, min: textAA, "\(variant) ink on accent wash")
        }
    }

    func testStageChipAccents() {
        for variant in ThemeVariant.allCases {
            let p = variant.palette
            XCTAssertEqual(p.stageTones.count, VFStage.allCases.count, "\(variant): one tone per stage")
            for stage in VFStage.allCases {
                let tone = p.tone(stage)
                check(tone.label, on: tone.fill, min: textAA, "\(variant) \(stage) chip label")
                check(tone.fill, on: p.chrome, min: nonTextAA, "\(variant) \(stage) chip on chrome")
                check(tone.fill, on: p.chromeDeep, min: nonTextAA, "\(variant) \(stage) chip on chromeDeep")
            }
            // Nine distinct accents.
            XCTAssertEqual(Set(p.stageTones.values.map(\.fill)).count, VFStage.allCases.count, "\(variant): distinct tones")
        }
    }

    func testStageIDsMatchTheFlowCore() {
        // core/src/flow.rs stage ids, in pipeline order.
        XCTAssertEqual(VFStage.allCases.map(\.rawValue),
                       ["design", "generate", "assemble", "electronics", "simulate", "train", "render", "make", "robot"])
        XCTAssertEqual(VFStatus.allCases.map(\.rawValue), ["current", "empty", "stale", "running", "failed"])
    }

    func testJetIconsStayReadable() {
        let light = VFPalette.light, dark = VFPalette.dark
        // Light: the satin-black icons sit straight on the chrome.
        check(light.jetInk, on: light.chrome, min: textAA, "light jet icon on chrome")
        check(light.jetInk, on: light.chromeDeep, min: textAA, "light jet icon on chromeDeep")
        // Dark: they sit on a light chip, and the chip must read against the dark chrome.
        check(dark.jetInk, on: dark.toolChip, min: textAA, "dark jet icon on its chip")
        check(dark.toolChipSymbol, on: dark.toolChip, min: textAA, "dark chip symbol on its chip")
        check(dark.toolChip, on: dark.chrome, min: nonTextAA, "dark chip on chrome")
        check(dark.toolChip, on: dark.chromeDeep, min: nonTextAA, "dark chip on chromeDeep")
        // Without the chip the icons would fail in dark: this is why the chip exists.
        XCTAssertLessThan(dark.jetInk.contrast(on: dark.chrome), nonTextAA)
    }

    func testViewportGradientDirection() {
        for variant in ThemeVariant.allCases {
            let p = variant.palette
            XCTAssertGreaterThan(p.viewportTop.luminance, p.viewportBottom.luminance, "\(variant): top lighter")
        }
        // Light by default, grey gradient.
        XCTAssertEqual(ThemeMode.default, .light)
        XCTAssertGreaterThan(VFPalette.light.viewportBottom.luminance, 0.4)
        XCTAssertEqual(VFPalette.dark.chrome, VFColor(hex: 0x1C1E22))
    }

    func testModeResolution() {
        XCTAssertEqual(ThemeMode.light.resolve(systemIsDark: true), .light)
        XCTAssertEqual(ThemeMode.dark.resolve(systemIsDark: false), .dark)
        XCTAssertEqual(ThemeMode.system.resolve(systemIsDark: true), .dark)
        XCTAssertEqual(ThemeMode.system.resolve(systemIsDark: false), .light)
        XCTAssertEqual(ThemeMode(rawValue: "system"), .system)
    }

    func testMetrics() {
        XCTAssertGreaterThanOrEqual(VFSize.touchTarget, 44)
        XCTAssertGreaterThanOrEqual(VFSize.touchRow, VFSize.touchTarget)
        XCTAssertGreaterThanOrEqual(VFSize.touchRail, 44)
        XCTAssertGreaterThanOrEqual(VFTypeScale.all.min() ?? 0, 10)
        XCTAssertEqual(VFTypeScale.all, VFTypeScale.all.sorted(), "type scale ascends")
        for s in [VFSpace.xxs, VFSpace.xs, VFSpace.s, VFSpace.m, VFSpace.l, VFSpace.xl, VFSpace.xxl] {
            XCTAssertEqual(s.truncatingRemainder(dividingBy: 2), 0, "spacing on the 2 pt grid")
        }
        XCTAssertLessThan(VFSize.sidebarMin, VFSize.sidebarMax)
    }
}
