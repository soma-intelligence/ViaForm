import Foundation

// Units, display precision and the expression parser behind every number in the app
// (FRONTEND-SPEC 7.5). One formatter per quantity so the inspector, the handles, the status bar
// and the tables never show the same value with two precisions.

/// The quantity a number field holds. Each has a base unit (what the engine takes), the units a
/// reader may type, and the display precision of FRONTEND-SPEC 7.5.
enum VFUnit: Hashable, Sendable {
    /// A bare number (counts, factors).
    case none
    /// Length, base millimetres.
    case length
    /// Angle, base degrees (radians only inside engines).
    case angle
    /// Mass, base grams.
    case mass
    /// Force, base newtons.
    case force
    /// Stress, base megapascals.
    case stress
    /// Frequency, base hertz.
    case frequency
    /// Time, base seconds.
    case time
    /// A fraction shown in percent (base percent).
    case percent
    /// Any other unit: shown as given, typed as a bare number.
    case custom(String)

    /// The suffix shown after the value.
    var symbol: String {
        switch self {
        case .none: ""
        case .length: "mm"
        case .angle: "°"
        case .mass: "g"
        case .force: "N"
        case .stress: "MPa"
        case .frequency: "Hz"
        case .time: "s"
        case .percent: "%"
        case .custom(let s): s
        }
    }

    /// The unit for a short unit string used across the app ("mm", "deg", "N", "kg").
    init(symbol: String) {
        switch symbol.lowercased().trimmingCharacters(in: .whitespaces) {
        case "": self = .none
        case "mm": self = .length
        case "deg", "°", "degrees": self = .angle
        case "g": self = .mass
        case "n": self = .force
        case "mpa": self = .stress
        case "hz": self = .frequency
        case "s": self = .time
        case "%": self = .percent
        default: self = .custom(symbol)
        }
    }

    /// Factor from a typed unit to the base unit, or nil when the unit does not belong here.
    func factor(for typed: String) -> Double? {
        let u = typed.lowercased()
        switch self {
        case .length:
            return ["mm": 1, "cm": 10, "m": 1000, "um": 0.001, "µm": 0.001, "in": 25.4, "\"": 25.4, "ft": 304.8, "'": 304.8][u]
        case .angle:
            return ["deg": 1, "°": 1, "rad": 180 / Double.pi, "turn": 360, "rev": 360][u]
        case .mass:
            return ["g": 1, "kg": 1000, "mg": 0.001, "lb": 453.59237, "oz": 28.349523125][u]
        case .force:
            return ["n": 1, "kn": 1000, "kgf": 9.80665, "lbf": 4.4482216][u]
        case .stress:
            return ["mpa": 1, "gpa": 1000, "kpa": 0.001, "pa": 0.000001, "psi": 0.00689476][u]
        case .frequency:
            return ["hz": 1, "khz": 1000][u]
        case .time:
            return ["s": 1, "ms": 0.001, "min": 60, "h": 3600][u]
        case .percent:
            return ["%": 1][u]
        case .none, .custom:
            return nil
        }
    }

    /// Fraction digits for display.
    func fractionDigits(for value: Double) -> Int {
        switch self {
        case .length: 1
        case .angle: 1
        case .mass: abs(value) < 1000 ? 0 : 2
        case .force, .stress: 1
        case .frequency: 1
        case .time: 2
        case .percent: 0
        case .none, .custom: abs(value) >= 100 || value.rounded() == value ? 0 : 2
        }
    }
}

enum VFFormat {
    /// "12.0 mm", "45.0°", "820 g", "1.25 kg" (mass switches to kg at 1 kg).
    /// Length, angle and mass follow the reader's display units (`UnitSettings`, P2-23); the
    /// value passed in is always in the engine's base unit.
    static func value(_ v: Double, _ unit: VFUnit, withUnit: Bool = true) -> String {
        guard v.isFinite else { return "n/a" }
        let units = UnitSettings.current
        if let d = units.display(for: unit), d.factor != 1 || units.decimals != nil {
            let s = number(v / d.factor, digits: d.digits)
            guard withUnit else { return s }
            return d.symbol == "°" ? s + "°" : s + " " + d.symbol
        }
        if case .mass = unit, abs(v) >= 1000 {
            return number(v / 1000, digits: 2) + (withUnit ? " kg" : "")
        }
        let s = number(v, digits: unit.fractionDigits(for: v))
        guard withUnit, !unit.symbol.isEmpty else { return s }
        if case .angle = unit { return s + "°" }
        if case .percent = unit { return s + " %" }
        return s + " " + unit.symbol
    }

    /// The editable text of a value: shortest form, no grouping, no unit.
    static func editable(_ v: Double) -> String {
        guard v.isFinite else { return "" }
        if v.rounded() == v, abs(v) < 1e12 { return String(Int(v)) }
        var s = String(format: "%.6f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// A base value (mm, deg, g) in the reader's display unit; other quantities unchanged.
    static func toDisplay(_ v: Double, _ unit: VFUnit) -> Double { v / UnitSettings.current.inputFactor(for: unit) }

    /// The suffix the reader sees for `unit` ("in", "rad", "lb", or the base symbol).
    static func symbol(_ unit: VFUnit) -> String { UnitSettings.current.display(for: unit)?.symbol ?? unit.symbol }

    static func number(_ v: Double, digits: Int) -> String {
        v.formatted(.number.precision(.fractionLength(digits)).grouping(.automatic))
    }

    static func length(_ mm: Double) -> String { value(mm, .length) }
    static func angle(_ deg: Double) -> String { value(deg, .angle) }
    static func mass(_ g: Double) -> String { value(g, .mass) }

    /// Money: always two decimals in the given currency; "No price" for a missing value
    /// (never "0", which reads as free).
    static func money(_ v: Double?, currency: String = "USD") -> String {
        guard let v, v.isFinite, v >= 0 else { return String(localized: "No price") }
        return v.formatted(.currency(code: currency).precision(.fractionLength(2)))
    }

    /// "3 days ago" with the full date for tooltips.
    static func relativeDate(_ d: Date, now: Date = .now) -> String {
        d.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }

    /// An ISO day or timestamp from the engines, shown relative; the raw text when it does not parse.
    static func relativeDate(iso: String) -> String {
        if let d = isoDate(iso) { return relativeDate(d) }
        return iso
    }

    static func isoDate(_ s: String) -> Date? {
        let full = ISO8601DateFormatter()
        if let d = full.date(from: s) { return d }
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        return day.date(from: String(s.prefix(10)))
    }
}

// MARK: - Expressions

/// Parses what a reader types in a number field: numbers, `+ - * /`, parentheses, unary minus and
/// a unit after any number ("25 mm", "1 in + 3", "2*12.5", "90deg - 0.1 rad"). Never throws an
/// Objective-C exception (NSExpression does on "2*"), never evaluates anything but arithmetic.
struct VFExpression {
    enum Failure: Error, Equatable {
        case empty
        case syntax(String)
        case unit(String)
        case divideByZero
    }

    let unit: VFUnit

    /// The value in the base unit.
    func evaluate(_ text: String) -> Result<Double, Failure> {
        var p = Parser(chars: Array(text.replacingOccurrences(of: ",", with: ".")), unit: unit)
        p.skip()
        guard !p.atEnd else { return .failure(.empty) }
        do {
            let v = try p.sum()
            p.skip()
            guard p.atEnd else { throw Failure.syntax(String(p.chars[p.i...])) }
            guard v.isFinite else { throw Failure.divideByZero }
            return .success(v)
        } catch let f as Failure {
            return .failure(f)
        } catch {
            return .failure(.syntax(text))
        }
    }

    private struct Parser {
        let chars: [Character]
        let unit: VFUnit
        var i = 0
        /// Base units per bare number: the reader's display unit (1 in an inch field is 25.4 mm).
        /// Inside parentheses it is 1, and the parenthesis as a whole takes the unit after it.
        var bareFactor: Double

        init(chars: [Character], unit: VFUnit) {
            self.chars = chars
            self.unit = unit
            bareFactor = UnitSettings.current.inputFactor(for: unit)
        }

        var atEnd: Bool { i >= chars.count }
        mutating func skip() { while !atEnd, chars[i].isWhitespace { i += 1 } }
        mutating func peek() -> Character? { skip(); return atEnd ? nil : chars[i] }

        mutating func sum() throws -> Double {
            var v = try product()
            while let c = peek(), c == "+" || c == "-" {
                i += 1
                let r = try product()
                v = c == "+" ? v + r : v - r
            }
            return v
        }

        mutating func product() throws -> Double {
            var v = try factor()
            while let c = peek(), c == "*" || c == "/" || c == "×" || c == "÷" {
                i += 1
                let r = try factor()
                if c == "/" || c == "÷" {
                    guard r != 0 else { throw Failure.divideByZero }
                    v /= r
                } else {
                    v *= r
                }
            }
            return v
        }

        mutating func factor() throws -> Double {
            guard let c = peek() else { throw Failure.syntax("") }
            if c == "-" { i += 1; return -(try factor()) }
            if c == "+" { i += 1; return try factor() }
            if c == "(" {
                i += 1
                let outer = bareFactor
                bareFactor = 1
                defer { bareFactor = outer }
                let v = try sum()
                guard peek() == ")" else { throw Failure.syntax("(") }
                i += 1
                bareFactor = outer
                return try withUnit(v)
            }
            let start = i
            while !atEnd, chars[i].isNumber || chars[i] == "." { i += 1 }
            if !atEnd, chars[i] == "e" || chars[i] == "E", i + 1 < chars.count,
               chars[i + 1].isNumber || chars[i + 1] == "-" || chars[i + 1] == "+" {
                i += 2
                while !atEnd, chars[i].isNumber { i += 1 }
            }
            guard i > start, let v = Double(String(chars[start..<i])) else { throw Failure.syntax(String(c)) }
            return try withUnit(v)
        }

        /// A unit right after a number converts it to the base unit.
        mutating func withUnit(_ v: Double) throws -> Double {
            skip()
            let start = i
            while !atEnd, chars[i].isLetter || chars[i] == "\"" || chars[i] == "'" || chars[i] == "°" || chars[i] == "%" || chars[i] == "µ" { i += 1 }
            guard i > start else { return v * bareFactor }
            let word = String(chars[start..<i])
            if case .custom(let sym) = unit, word.lowercased() == sym.lowercased() { return v }
            if case .none = unit { throw Failure.unit(word) }
            guard let f = unit.factor(for: word) else { throw Failure.unit(word) }
            return v * f
        }
    }
}

extension VFExpression.Failure {
    /// What to tell the reader, beside the field.
    func message(for unit: VFUnit) -> String {
        switch self {
        case .empty: String(localized: "Enter a value.")
        case .syntax: String(localized: "Use a number or arithmetic, like 25 or 2*12.5.")
        case .unit(let u):
            switch unit {
            case .length: String(localized: "\(u) is not a length. Use mm, cm, m or in.")
            case .angle: String(localized: "\(u) is not an angle. Use deg or rad.")
            case .mass: String(localized: "\(u) is not a mass. Use g, kg or lb.")
            default: String(localized: "\(u) is not a unit this field takes.")
            }
        case .divideByZero: String(localized: "Division by zero.")
        }
    }
}
