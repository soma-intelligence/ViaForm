import SwiftUI

// Display units (UI-UX-AUDIT P2-23): the reader picks the length, angle and mass units and the
// decimal places numbers show with. The engines keep millimetres, degrees and grams; only
// `VFFormat` (display) and `NumberField` (display and typing) convert.

/// Length shown in the app. The raw value is what a reader types after a number.
enum LengthDisplay: String, CaseIterable, Identifiable, Sendable {
    case mm, cm, m
    case inch = "in"

    var id: String { rawValue }
    /// Millimetres per one of this unit.
    var factor: Double {
        switch self {
        case .mm: 1
        case .cm: 10
        case .m: 1000
        case .inch: 25.4
        }
    }
    var title: String {
        switch self {
        case .mm: String(localized: "Millimetres (mm)")
        case .cm: String(localized: "Centimetres (cm)")
        case .m: String(localized: "Metres (m)")
        case .inch: String(localized: "Inches (in)")
        }
    }
    /// The reader's length unit now.
    static var current: LengthDisplay { UnitSettings.current.length }

    /// The unit's name in a sentence: "millimetres", "inches".
    var plural: String {
        switch self {
        case .mm: String(localized: "millimetres")
        case .cm: String(localized: "centimetres")
        case .m: String(localized: "metres")
        case .inch: String(localized: "inches")
        }
    }

    /// Default fraction digits: 0.1 mm, 0.01 cm, 0.001 m, 0.001 in.
    var digits: Int {
        switch self {
        case .mm: 1
        case .cm: 2
        case .m, .inch: 3
        }
    }
}

enum AngleDisplay: String, CaseIterable, Identifiable, Sendable {
    case deg, rad

    var id: String { rawValue }
    /// Degrees per one of this unit.
    var factor: Double { self == .deg ? 1 : 180 / Double.pi }
    var symbol: String { self == .deg ? "°" : "rad" }
    var title: String { self == .deg ? String(localized: "Degrees (°)") : String(localized: "Radians (rad)") }
    var digits: Int { self == .deg ? 1 : 3 }
}

enum MassDisplay: String, CaseIterable, Identifiable, Sendable {
    case g, kg, lb

    var id: String { rawValue }
    /// Grams per one of this unit.
    var factor: Double {
        switch self {
        case .g: 1
        case .kg: 1000
        case .lb: 453.59237
        }
    }
    var title: String {
        switch self {
        case .g: String(localized: "Grams (g)")
        case .kg: String(localized: "Kilograms (kg)")
        case .lb: String(localized: "Pounds (lb)")
        }
    }
    var digits: Int { self == .g ? 0 : 2 }
}

/// The reader's display units, in UserDefaults. Read through `current`; tests set `override`.
struct UnitSettings: Equatable, Sendable {
    var length: LengthDisplay = .mm
    var angle: AngleDisplay = .deg
    var mass: MassDisplay = .g
    /// Fraction digits for every length, angle and mass; nil follows each unit's default.
    var decimals: Int? = nil

    static let lengthKey = "viaform.units.length"
    static let angleKey = "viaform.units.angle"
    static let massKey = "viaform.units.mass"
    /// -1 (or missing) is Automatic.
    static let decimalsKey = "viaform.units.decimals"
    static let decimalChoices = [-1, 0, 1, 2, 3, 4]

    /// The engine's own units: what the app shows until the reader picks others.
    static let base = UnitSettings()

    /// Set by the self test; wins over the stored choice.
    nonisolated(unsafe) static var override: UnitSettings?

    /// The stored choice. The self test always formats in base units unless it sets `override`,
    /// so a reader's inch setting never fails a check written in millimetres.
    static var current: UnitSettings {
        if let override { return override }
        if ProcessInfo.processInfo.arguments.contains("--selftest") { return .base }
        let d = UserDefaults.standard
        let dec = d.object(forKey: decimalsKey) as? Int ?? -1
        var u = UnitSettings(length: LengthDisplay(rawValue: d.string(forKey: lengthKey) ?? "") ?? .mm,
                             angle: AngleDisplay(rawValue: d.string(forKey: angleKey) ?? "") ?? .deg,
                             mass: MassDisplay(rawValue: d.string(forKey: massKey) ?? "") ?? .g,
                             decimals: dec < 0 ? nil : min(dec, 6))
        // Launch flags for captures and checks, never stored: --length-unit=in, --angle-unit=rad,
        // --mass-unit=kg.
        for arg in ProcessInfo.processInfo.arguments {
            if let v = arg.flagValue("--length-unit="), let l = LengthDisplay(rawValue: v) { u.length = l }
            if let v = arg.flagValue("--angle-unit="), let a = AngleDisplay(rawValue: v) { u.angle = a }
            if let v = arg.flagValue("--mass-unit="), let m = MassDisplay(rawValue: v) { u.mass = m }
        }
        return u
    }

    /// How a quantity shows: base units per display unit, the suffix, and fraction digits.
    /// Nil for quantities that are not converted (force, time, bare numbers).
    func display(for unit: VFUnit) -> (factor: Double, symbol: String, digits: Int)? {
        switch unit {
        case .length: (length.factor, length.rawValue, decimals ?? length.digits)
        case .angle: (angle.factor, angle.symbol, decimals ?? angle.digits)
        case .mass: (mass.factor, mass.rawValue, decimals ?? mass.digits)
        default: nil
        }
    }

    /// Base units per typed unit for a bare number in a field of `unit` (1 when not converted).
    func inputFactor(for unit: VFUnit) -> Double { display(for: unit)?.factor ?? 1 }

    /// A step in base units turned into a round step in display units (1 mm is 0.1 in, 1° is
    /// 0.01 rad), so the arrows and the scrub move by a number the reader can read.
    func displayStep(_ baseStep: Double, for unit: VFUnit) -> Double {
        guard let f = display(for: unit)?.factor, f != 1, baseStep > 0 else { return baseStep }
        return pow(10, (log10(baseStep / f)).rounded())
    }
}

private extension String {
    /// The text after `prefix` when this argument starts with it.
    func flagValue(_ prefix: String) -> String? { hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil }
}

/// Makes a view redraw when the reader changes a display unit. A view that shows a length, an
/// angle or a mass through `VFFormat` declares `@ObservedUnits private var units` and reads it in
/// `body` (`let _ = units`), or uses it directly. Its value is `UnitSettings.current`.
@propertyWrapper
struct ObservedUnits: DynamicProperty {
    @AppStorage(UnitSettings.lengthKey) private var length = LengthDisplay.mm.rawValue
    @AppStorage(UnitSettings.angleKey) private var angle = AngleDisplay.deg.rawValue
    @AppStorage(UnitSettings.massKey) private var mass = MassDisplay.g.rawValue
    @AppStorage(UnitSettings.decimalsKey) private var decimals = -1

    init() {}

    var wrappedValue: UnitSettings {
        _ = (length, angle, mass, decimals)
        return UnitSettings.current
    }
}

// MARK: - Settings form

/// The Units settings: one picker per quantity, decimal places, and a line that shows the result.
struct UnitSettingsForm: View {
    @AppStorage(UnitSettings.lengthKey) private var length = LengthDisplay.mm.rawValue
    @AppStorage(UnitSettings.angleKey) private var angle = AngleDisplay.deg.rawValue
    @AppStorage(UnitSettings.massKey) private var mass = MassDisplay.g.rawValue
    @AppStorage(UnitSettings.decimalsKey) private var decimals = -1

    var body: some View {
        Form { UnitSettingsSection(length: $length, angle: $angle, mass: $mass, decimals: $decimals) }
            .formStyle(.grouped)
    }
}

/// The pickers alone, for a Form section (Mac Settings tab, iPad browser sheet).
struct UnitSettingsSection: View {
    @Binding var length: String
    @Binding var angle: String
    @Binding var mass: String
    @Binding var decimals: Int

    var body: some View {
        Section {
            Picker("Length", selection: $length) {
                ForEach(LengthDisplay.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Picker("Angle", selection: $angle) {
                ForEach(AngleDisplay.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Picker("Mass", selection: $mass) {
                ForEach(MassDisplay.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Picker("Decimal Places", selection: $decimals) {
                ForEach(UnitSettings.decimalChoices, id: \.self) { n in
                    if n < 0 { Text("Automatic").tag(n) } else { Text(verbatim: "\(n)").tag(n) }
                }
            }
        } header: {
            Text("Display Units")
        } footer: {
            let _ = (length, angle, mass, decimals)
            Text("Example: \(VFFormat.length(25.4)), \(VFFormat.angle(90)), \(VFFormat.mass(1500)). Models keep their exact values; only what you see and type changes. A unit typed after a number (25 mm, 1 in) always wins.")
                .font(VFFont.small)
                .foregroundStyle(.secondary)
        }
    }
}

/// The same section, owning its storage (for a list that has no other unit state).
struct UnitSettingsStoredSection: View {
    @AppStorage(UnitSettings.lengthKey) private var length = LengthDisplay.mm.rawValue
    @AppStorage(UnitSettings.angleKey) private var angle = AngleDisplay.deg.rawValue
    @AppStorage(UnitSettings.massKey) private var mass = MassDisplay.g.rawValue
    @AppStorage(UnitSettings.decimalsKey) private var decimals = -1

    var body: some View {
        UnitSettingsSection(length: $length, angle: $angle, mass: $mass, decimals: $decimals)
    }
}

// MARK: - Self test

/// Unit conversion and formatting checks for `SelfTest` (P2-23).
enum UnitSettingsSelfTest {
    static func checks() -> [(Bool, String)] {
        var out: [(Bool, String)] = []
        let saved = UnitSettings.override
        defer { UnitSettings.override = saved }
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 * max(1, abs(b)) }

        // Round trips through each display unit: typed bare number in, base value, shown back.
        UnitSettings.override = UnitSettings(length: .inch)
        let inMM = (try? VFExpression(unit: .length).evaluate("1").get()) ?? .nan
        out.append((near(inMM, 25.4), "P2-23 a bare 1 in an inch field is 25.4 mm (\(inMM))"))
        out.append((VFFormat.length(25.4) == VFFormat.number(1, digits: 3) + " in", "P2-23 25.4 mm shows as 1.000 in (\(VFFormat.length(25.4)))"))
        let back = (try? VFExpression(unit: .length).evaluate(VFFormat.editable(VFFormat.toDisplay(127, .length))).get()) ?? .nan
        out.append((near(back, 127), "P2-23 127 mm round trips through inches (\(back))"))
        out.append(((try? VFExpression(unit: .length).evaluate("10 mm").get()) == 10, "P2-23 a typed mm still wins in an inch field"))

        UnitSettings.override = UnitSettings(angle: .rad)
        let rad = VFFormat.toDisplay(180, .angle)
        out.append((near(rad, .pi), "P2-23 180 deg is pi rad (\(rad))"))
        let deg = (try? VFExpression(unit: .angle).evaluate(VFFormat.editable(rad)).get()) ?? .nan
        out.append((abs(deg - 180) < 1e-4, "P2-23 pi rad round trips to 180 deg (\(deg))"))
        out.append((VFFormat.angle(90) == VFFormat.number(.pi / 2, digits: 3) + " rad", "P2-23 90 deg shows in rad (\(VFFormat.angle(90)))"))
        out.append((near(UnitSettings.current.displayStep(1, for: .angle), 0.01), "P2-23 a 1 deg step is 0.01 rad"))

        UnitSettings.override = UnitSettings(mass: .lb)
        out.append((VFFormat.mass(453.59237) == VFFormat.number(1, digits: 2) + " lb", "P2-23 453.6 g shows as 1.00 lb (\(VFFormat.mass(453.59237)))"))
        UnitSettings.override = UnitSettings(mass: .kg)
        out.append((VFFormat.mass(250) == VFFormat.number(0.25, digits: 2) + " kg", "P2-23 250 g shows as 0.25 kg"))

        UnitSettings.override = UnitSettings(length: .cm, decimals: 0)
        out.append((VFFormat.length(123) == VFFormat.number(12, digits: 0) + " cm", "P2-23 decimal places 0: 123 mm shows as 12 cm (\(VFFormat.length(123)))"))
        UnitSettings.override = UnitSettings(length: .m)
        out.append((VFFormat.length(1500) == VFFormat.number(1.5, digits: 3) + " m", "P2-23 1500 mm shows as 1.500 m"))

        // Base units keep the old strings, and units that are not converted are untouched.
        UnitSettings.override = .base
        out.append((VFFormat.length(12) == VFFormat.number(12, digits: 1) + " mm" && VFFormat.mass(1500) == VFFormat.number(1.5, digits: 2) + " kg",
                    "P2-23 base units format as before (\(VFFormat.length(12)), \(VFFormat.mass(1500)))"))
        UnitSettings.override = UnitSettings(length: .inch, angle: .rad, mass: .lb, decimals: 4)
        out.append((VFFormat.value(5, .force) == VFFormat.number(5, digits: 1) + " N", "P2-23 force stays in newtons"))
        return out
    }
}
