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
        // Follows the system by default (D-20); the light variant keeps its grey gradient.
        XCTAssertEqual(ThemeMode.default, .system)
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

    /// The e-stop and destructive buttons: white on the danger fill in both variants.
    func testDangerFillLabel() {
        for variant in ThemeVariant.allCases {
            let p = variant.palette
            check(p.onDanger, on: p.dangerFill, min: textAA, "\(variant) onDanger on dangerFill")
            check(p.dangerFill, on: p.chrome, min: nonTextAA, "\(variant) dangerFill on chrome")
            check(p.dangerFill, on: p.panel, min: nonTextAA, "\(variant) dangerFill on panel")
        }
    }

    /// Increase Contrast never lowers a text ratio and lifts hairlines to a visible 3:1-ish mark.
    func testIncreasedContrastVariant() {
        for variant in ThemeVariant.allCases {
            let p = variant.palette, hc = variant.highContrastPalette
            for (name, a, b) in [("ink", p.ink, hc.ink), ("inkSecondary", p.inkSecondary, hc.inkSecondary),
                                 ("inkTertiary", p.inkTertiary, hc.inkTertiary), ("accentText", p.accentText, hc.accentText)] {
                XCTAssertGreaterThanOrEqual(b.contrast(on: hc.panel), a.contrast(on: p.panel) - 0.01, "\(variant) \(name) not lower")
                check(b, on: hc.panel, min: textAA, "\(variant) high contrast \(name) on panel")
            }
            XCTAssertGreaterThan(hc.hairline.contrast(on: hc.panel), p.hairline.contrast(on: p.panel), "\(variant) hairline stronger")
            XCTAssertEqual(hc.floating.alpha, 1, "\(variant) opaque floating fill")
        }
    }

    /// Badges on status fills (workspace dropdown): the label colour picked by `bestLabel` passes.
    func testStatusBadgeLabels() {
        for variant in ThemeVariant.allCases {
            let p = variant.palette
            for fill in [p.warning, p.danger, p.accent] {
                let label = fill.bestLabel(light: VFColor(hex: 0xFFFFFF), dark: VFColor(hex: 0x111215))
                check(label, on: fill, min: textAA - 0.5, "\(variant) badge label")
            }
        }
    }

    // MARK: Toasts and banners (UI-UX-AUDIT P2-20)

    /// Every palette the app can draw with: light, dark, and both under Increase Contrast.
    private var allPalettes: [(name: String, palette: VFPalette)] {
        ThemeVariant.allCases.flatMap { v in
            [("\(v)", v.palette), ("\(v) high contrast", v.highContrastPalette)]
        }
    }

    /// What a floating overlay (toast, banner) shows under it: the flat fill over both viewport ends
    /// and over the panels, and the glass build (material plus the fill at 85 %) over the viewport.
    private func floatingBackdrops(_ p: VFPalette) -> [(name: String, color: VFColor)] {
        let glass = p.floating.opacity(0.85)
        return [("floating/viewportTop", p.floating.over(p.viewportTop)),
                ("floating/viewportBottom", p.floating.over(p.viewportBottom)),
                ("floating/panel", p.floating.over(p.panel)),
                ("floating/chrome", p.floating.over(p.chrome)),
                ("glass/viewportTop", glass.over(p.viewportTop)),
                ("glass/viewportBottom", glass.over(p.viewportBottom))]
    }

    /// ToastView: ink text, accentText action, success or danger icon, over the floating fill.
    func testToastPairs() {
        for (name, p) in allPalettes {
            for bg in floatingBackdrops(p) {
                check(p.ink, on: bg.color, min: textAA, "\(name) toast text on \(bg.name)")
                check(p.accentText, on: bg.color, min: textAA, "\(name) toast action on \(bg.name)")
                check(p.success, on: bg.color, min: nonTextAA, "\(name) toast success icon on \(bg.name)")
                check(p.danger, on: bg.color, min: nonTextAA, "\(name) toast error icon on \(bg.name)")
            }
        }
    }

    /// InlineError and ErrorBanner, both severities: the tint at 10 % over the surface it sits on
    /// (panel and well inline, the floating fill as a banner). Message ink, Details link, raw
    /// details text, icon and the 45 % stroke.
    func testInlineErrorAndBannerPairs() {
        for (name, p) in allPalettes {
            let bases = [("panel", p.panel), ("well", p.well), ("chrome", p.chrome)] + floatingBackdrops(p)
            for (severity, tint) in [("error", p.danger), ("warning", p.warning)] {
                for base in bases {
                    let fill = tint.opacity(0.10).over(base.color)
                    let what = "\(name) \(severity) on \(base.name)"
                    check(p.ink, on: fill, min: textAA, "\(what): message")
                    check(p.accentText, on: fill, min: textAA, "\(what): Details link")
                    check(p.inkSecondary, on: fill, min: textAA, "\(what): details text")
                    check(tint, on: fill, min: nonTextAA, "\(what): icon")
                }
            }
        }
    }

    /// The stale or failed stage banner (StaleBanner): ink text, warning or danger icon, over the
    /// floating fill; its primary action is onAccent on accent (tested above).
    func testWarningBannerPairs() {
        for (name, p) in allPalettes {
            for bg in floatingBackdrops(p) {
                check(p.ink, on: bg.color, min: textAA, "\(name) stale banner text on \(bg.name)")
                check(p.warning, on: bg.color, min: nonTextAA, "\(name) stale banner icon on \(bg.name)")
                check(p.danger, on: bg.color, min: nonTextAA, "\(name) failed banner icon on \(bg.name)")
                check(p.inkSecondary, on: bg.color, min: textAA, "\(name) banner close glyph on \(bg.name)")
            }
        }
    }
}
