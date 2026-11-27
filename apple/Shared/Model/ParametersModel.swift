import Foundation
import Observation

/// The design's parameters as the Change Parameters table shows them (B-10): user parameters
/// first, then the model parameters each feature input owns. Every edit is one engine command
/// (`parameters.add`, `parameters.rename`, `parameters.delete`, `parameters.change`,
/// `parameters.comment`); the rows are read back from `parameters.list` after each change.
/// Both apps share it: the Mac inspector and its Change Parameters sheet, the iPad Items panel.
@Observable
final class ParametersModel {
    /// One row of `parameters.list`.
    struct Row: Identifiable, Hashable {
        var name: String
        var expression: String
        var unit: String
        /// In the engine's base unit (mm, or rad for an angle).
        var value: Double?
        /// In the parameter's own unit (degrees for an angle).
        var displayValue: Double?
        /// user, sketch or feature.
        var source: String
        var feature: String?
        var input: String?
        var comment: String
        var favorite: Bool
        var uses: [String]
        var usedBy: [String]
        var error: String?
        var id: String { name }

        var isUser: Bool { source == "user" }
        /// The Parameter column: the feature and its input for a model parameter
        /// ("Box1 Length"), the word User for a user parameter.
        var owner: String {
            if isUser { return String(localized: "User") }
            return [feature, input].compactMap { $0 }.joined(separator: " ")
        }
        /// The value in the field's unit (degrees for an angle), for display.
        var shown: Double? { displayValue ?? value }
        var vfUnit: VFUnit { VFUnit(symbol: unit) }
    }

    /// A completion for the text before the cursor (`parameters.complete`).
    struct Suggestion: Identifiable, Hashable {
        var text: String
        var kind: String
        var detail: String
        var id: String { kind + ":" + text }
    }

    weak var design: DesignModel?
    private(set) var rows: [Row] = []
    /// The last refusal (a taken name, a parameter still used, an expression that does not parse).
    private(set) var error: String?
    /// The design state the rows were read at; a newer one triggers a reload.
    private var readAt: String?

    init(design: DesignModel? = nil) {
        self.design = design
        if design != nil { reload() }
    }

    var userRows: [Row] { rows.filter(\.isUser) }
    var modelRows: [Row] { rows.filter { !$0.isUser } }
    /// Model rows grouped by feature, in timeline order, for the table's folders.
    var modelGroups: [(feature: String, rows: [Row])] {
        var order: [String] = []
        var by: [String: [Row]] = [:]
        for r in modelRows {
            let f = r.feature ?? String(localized: "Sketches")
            if by[f] == nil { order.append(f) }
            by[f, default: []].append(r)
        }
        return order.map { ($0, by[$0] ?? []) }
    }

    func row(_ name: String) -> Row? { rows.first { $0.name == name } }

    /// A token of the design state: changes after every command, undo and redo.
    private func stamp(_ d: DesignModel) -> String {
        let s = d.snapshot
        return "\(s.revision)|\(s.undo)|\(s.redo)|\(s.params.count)"
    }

    /// Reads the rows when the design changed since the last read (cheap to call from a view).
    func reloadIfNeeded() {
        guard let d = design, readAt != stamp(d) else { return }
        reload()
    }

    func reload() {
        guard let d = design else { rows = []; return }
        readAt = stamp(d)
        guard let r = try? d.engine.execute("parameters.list", [:]) as? [String: Any],
              let list = r["parameters"] as? [[String: Any]] else { rows = []; return }
        rows = list.map(Self.row(from:))
    }

    static func row(from p: [String: Any]) -> Row {
        Row(name: p["name"] as? String ?? "",
            expression: (p["expression"] as? String) ?? (p["expression"] as? Double).map { VFFormat.editable($0) } ?? "",
            unit: p["unit"] as? String ?? "",
            value: p["value"] as? Double,
            displayValue: p["display_value"] as? Double,
            source: p["source"] as? String ?? "user",
            feature: p["feature"] as? String,
            input: p["input"] as? String,
            comment: p["comment"] as? String ?? "",
            favorite: p["favorite"] as? Bool ?? false,
            uses: p["uses"] as? [String] ?? [],
            usedBy: p["used_by"] as? [String] ?? [],
            error: p["error"] as? String)
    }

    // MARK: Edits (one engine command each)

    /// Runs one command through the design (undo, the pipeline and the toast follow it) and
    /// returns the refusal, or nil.
    @discardableResult
    private func send(_ id: String, _ params: [String: Any]) -> String? {
        guard let d = design else { return String(localized: "No design is open") }
        let ok = d.run(id, params, quiet: true) != nil
        error = ok ? nil : (d.message ?? String(localized: "The engine refused the change"))
        reload()
        return error
    }

    /// `+ User Parameter`: name, expression, unit ("" for a bare number), optional comment.
    @discardableResult
    func add(name: String, expression: String, unit: String? = nil, comment: String = "") -> String? {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard Self.isValidName(n) else { return refuse(String(localized: "A name starts with a letter and holds letters, digits and _.")) }
        guard row(n) == nil else { return refuse(String(localized: "\(n) is already a parameter.")) }
        var p: [String: Any] = ["name": n, "expression": expression.trimmingCharacters(in: .whitespaces)]
        if let unit { p["unit"] = unit }
        if !comment.isEmpty { p["comment"] = comment }
        return send("parameters.add", p)
    }

    /// Renames a parameter; every expression, feature input and dimension that uses it follows,
    /// so a linked field stays linked.
    @discardableResult
    func rename(_ name: String, to new: String) -> String? {
        let n = new.trimmingCharacters(in: .whitespaces)
        guard n != name else { return nil }
        guard Self.isValidName(n) else { return refuse(String(localized: "A name starts with a letter and holds letters, digits and _.")) }
        guard row(n) == nil else { return refuse(String(localized: "\(n) is already a parameter.")) }
        return send("parameters.rename", ["name": name, "new_name": n])
    }

    /// Deletes a user parameter; the engine refuses while something uses it and names the users.
    @discardableResult
    func delete(_ name: String) -> String? { send("parameters.delete", ["name": name]) }

    /// Sets a parameter's expression ("45 mm", "w * 2"); the model rebuilds once.
    @discardableResult
    func change(_ name: String, expression: String) -> String? {
        let e = expression.trimmingCharacters(in: .whitespaces)
        guard !e.isEmpty else { return refuse(String(localized: "Type a value or an expression.")) }
        guard row(name)?.expression != e else { return nil }
        return send("parameters.change", ["name": name, "expression": e])
    }

    @discardableResult
    func setComment(_ name: String, _ comment: String) -> String? {
        guard row(name)?.comment != comment else { return nil }
        return send("parameters.comment", ["name": name, "comment": comment])
    }

    @discardableResult
    func setFavorite(_ name: String, _ on: Bool) -> String? { send("parameters.favorite", ["name": name, "favorite": on]) }

    func clearError() { error = nil }

    private func refuse(_ text: String) -> String {
        error = text
        return text
    }

    static func isValidName(_ n: String) -> Bool {
        guard let f = n.unicodeScalars.first, CharacterSet.letters.contains(f) || f == "_" else { return false }
        return n.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
    }

    // MARK: Expressions (read only)

    /// Completions for the word before the cursor: parameters first, then functions and units.
    func complete(_ prefix: String) -> [Suggestion] {
        guard let d = design,
              let r = try? d.engine.execute("parameters.complete", ["prefix": prefix]) as? [String: Any],
              let list = r["suggestions"] as? [[String: Any]] else { return [] }
        return list.map { Suggestion(text: $0["text"] as? String ?? "", kind: $0["kind"] as? String ?? "",
                                     detail: $0["detail"] as? String ?? "") }
    }

    /// The value of an expression in the field's base unit (mm, degrees, a bare number), or the
    /// engine's reason it does not evaluate. Reads only (`expr.evaluate`), nothing is changed.
    func evaluate(_ expression: String, unit: VFUnit) -> Result<Double, ParameterContext.Failure> {
        guard let d = design else { return .failure(.init(message: String(localized: "No design is open"))) }
        var p: [String: Any] = ["expression": expression]
        switch unit {
        case .length: p["kind"] = "length"
        case .angle: p["unit"] = "deg"
        default: p["kind"] = "unitless"
        }
        do {
            let r = try d.engine.execute("expr.evaluate", p) as? [String: Any] ?? [:]
            if r["ok"] as? Bool == false {
                return .failure(.init(message: r["error"] as? String ?? String(localized: "The expression does not evaluate")))
            }
            let v = unit == .angle ? (r["display_value"] as? Double ?? r["value"] as? Double) : (r["value"] as? Double)
            guard let v, v.isFinite else { return .failure(.init(message: String(localized: "The expression has no value"))) }
            return .success(v)
        } catch {
            return .failure(.init(message: error.localizedDescription))
        }
    }

    /// What a NumberField needs to link to these parameters: the names, completion and
    /// evaluation. Hand it to the fields with `.environment(\.vfParameters, model.context)`.
    var context: ParameterContext {
        ParameterContext(names: rows.map(\.name),
                         complete: { [weak self] in self?.complete($0) ?? [] },
                         evaluate: { [weak self] e, u in
                             self?.evaluate(e, unit: u) ?? .failure(.init(message: String(localized: "No design is open")))
                         })
    }
}

/// The parameters a value field can link to (B-10). A field that receives one through the
/// environment completes names, evaluates expressions that use them through the engine, and,
/// when its caller keeps an expression binding, stores the link rather than the number.
struct ParameterContext {
    struct Failure: Error, Equatable { var message: String }
    var names: [String]
    var complete: (String) -> [ParametersModel.Suggestion]
    var evaluate: (String, VFUnit) -> Result<Double, Failure>

    /// The parameter names an expression uses ("w * 2 + gap" uses w and gap).
    func references(in text: String) -> [String] {
        Self.identifiers(text).filter { names.contains($0) }
    }

    /// Words that start with a letter or _: candidates for parameter names.
    static func identifiers(_ text: String) -> [String] {
        var out: [String] = []
        var word = ""
        for ch in text {
            if ch.isLetter || ch == "_" || (!word.isEmpty && ch.isNumber) {
                word.append(ch)
            } else {
                if !word.isEmpty { out.append(word) }
                word = ""
            }
        }
        if !word.isEmpty { out.append(word) }
        return out
    }

    /// The identifier being typed at the end of the text ("2*wi" gives "wi"), or nil.
    static func trailingWord(_ text: String) -> String? {
        let w = String(text.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "_" }.reversed())
        guard let f = w.first, f.isLetter || f == "_" else { return nil }
        return w
    }
}

/// Self checks for B-10, B-14 and M-21, run through real engine commands.
enum ParametersSelfTest {
    @MainActor static func checks() -> [(Bool, String)] {
        var out: [(Bool, String)] = []
        let m = DesignModel()
        let p = ParametersModel(design: m)

        // B-10: a user parameter drives a box, changes follow, rename keeps the link.
        out.append((p.add(name: "w", expression: "30", unit: "mm", comment: "width") == nil && p.row("w")?.shown == 30,
                    "B-10 parameters.add w = 30 (mm)"))
        out.append((p.add(name: "w", expression: "5") != nil, "B-10 a taken name is refused"))
        out.append((p.add(name: "2w", expression: "5") != nil, "B-10 a name must start with a letter"))
        m.run("solid.box", ["length": "w", "width": 20, "height": 10])
        p.reload()
        let v0 = m.snapshot.bodies.first.flatMap { _ in measuredVolume(m) } ?? 0
        out.append((abs(v0 - 30 * 20 * 10) < 1, "B-10 box length w gives 6000 mm³ (got \(v0))"))
        let driven = p.modelRows.first { $0.input == "Length" }
        out.append((driven?.expression == "w" && driven?.uses == ["w"], "B-10 the box length is linked to w, not copied (\(driven?.expression ?? "none"))"))
        out.append((p.change("w", expression: "45") == nil, "B-10 parameters.change w to 45 (mm)"))
        let v1 = measuredVolume(m) ?? 0
        out.append((abs(v1 - 45 * 20 * 10) < 1, "B-10 the volume follows w (got \(v1))"))
        out.append((p.rename("w", to: "wide") == nil && p.row("wide") != nil && p.row("w") == nil, "B-10 parameters.rename w to wide"))
        let relinked = p.modelRows.first { $0.input == "Length" }
        out.append((relinked?.expression == "wide", "B-10 rename keeps the link (\(relinked?.expression ?? "none"))"))
        out.append((p.change("wide", expression: "40") == nil && abs((measuredVolume(m) ?? 0) - 8000) < 1,
                    "B-10 the renamed parameter still drives the box"))
        out.append((p.delete("wide") != nil && p.row("wide") != nil, "B-10 a used parameter is not deleted"))
        out.append((p.setComment("wide", "outside X") == nil && p.row("wide")?.comment == "outside X", "B-10 a comment is kept"))
        out.append((p.complete("2*wi").first?.text == "wide", "B-10 name completion finds wide"))
        let ctx = p.context
        out.append((ctx.references(in: "wide*2 + 3") == ["wide"], "B-10 a field sees the names an expression uses"))
        if case .success(let x) = ctx.evaluate("wide * 2", .length) { out.append((abs(x - 80) < 1e-6, "B-10 expressions evaluate through the engine (\(x))")) }
        else { out.append((false, "B-10 expressions evaluate through the engine")) }
        out.append((p.add(name: "spare", expression: "3") == nil && p.delete("spare") == nil && p.row("spare") == nil,
                    "B-10 an unused parameter deletes"))
        out.append((LinkedNumber.linked("wide + 2", names: ctx.names) && !LinkedNumber.linked("2 in", names: ctx.names),
                    "B-10 a field marks a driven value and not a plain number"))

        // B-14: the construct form builds an offset plane 10 mm off XY.
        let before = m.snapshot.timeline.count
        var form = ConstructDraft(kind: .offset)
        form.refs["base"] = .plane("XY")
        form.values["offset"] = "10"
        let sent = form.params()
        out.append((form.missing == nil && sent["base"] as? String == "XY", "B-14 the offset form is complete with base XY"))
        let made = (m.run(ConstructKind.offset.command, sent) as? [String: Any])?["name"] as? String ?? ""
        out.append((m.snapshot.timeline.count == before + 1, "B-14 construct offset plane 10 mm adds a plane (\(m.snapshot.timeline.last?.type ?? "none"))"))
        m.startSketch(made)
        out.append((m.sketchOpen, "B-14 the new plane \(made) is sketchable"))
        m.finishSketch()
        var angled = ConstructDraft(kind: .atAngle)
        angled.refs["base"] = .plane("XY")
        angled.refs["axis"] = .axis("X")
        angled.values["angle"] = "wide"
        let ap = angled.params()
        out.append((ap["axis"] as? String == "X" && ap["angle"] as? String == "wide", "B-14 a value field linked to a parameter sends the expression"))
        out.append((ConstructKind.allCases.count == 20 && Set(ConstructKind.allCases.map(\.command)).count == 20
                    && ConstructKind.allCases.allSatisfy { k in m.commands.contains { c in c.id == k.command } },
                    "B-14 the form covers the 20 construct commands, all in the registry"))
        var mid = ConstructDraft(kind: .midplane)
        out.append((mid.missing != nil, "B-14 an empty midplane says what is missing"))
        mid.refs["a"] = .plane("XY")
        mid.refs["b"] = .face([0, 0, 10])
        let mp = mid.params()
        out.append(((mp["a"] as? [String: Any])?["plane"] as? String == "XY" && (mp["b"] as? [String: Any])?["face"] != nil,
                    "B-14 picks become engine refs"))

        // M-21: the mass report reads the same numbers as inspect.measure.
        let report = MassReport.read(m, bodies: [], about: .centerOfMass)
        let raw = m.run("inspect.measure", [:], quiet: true) as? [String: Any]
        let total = raw?["total"] as? [String: Any]
        out.append((report != nil && abs((report?.mass ?? 0) - (total?["mass_g"] as? Double ?? -1)) < 1e-6
                    && abs((report?.volume ?? 0) - (total?["volume_mm3"] as? Double ?? -1)) < 1e-6
                    && abs((report?.area ?? 0) - (total?["area_mm2"] as? Double ?? -1)) < 1e-6,
                    "M-21 mass, volume and area match inspect.measure"))
        out.append((report.map { abs($0.center.x - 20) < 1e-6 && abs($0.center.y - 10) < 1e-6 && abs($0.center.z - 5) < 1e-6 } == true,
                    "M-21 centre of mass of the 40 x 20 x 10 box"))
        out.append((report?.inertia != nil && report?.principal?.count == 3, "M-21 inertia tensor and principal moments"))
        let origin = MassReport.read(m, bodies: [], about: .origin)
        out.append((origin?.inertia != nil && origin?.inertia != report?.inertia, "M-21 relative to the origin moves the tensor"))
        out.append((report?.clipboardText.contains("Mass") == true, "M-21 the report copies as text"))
        return out
    }

    private static func measuredVolume(_ m: DesignModel) -> Double? {
        let r = m.run("inspect.measure", [:], quiet: true) as? [String: Any]
        return (r?["total"] as? [String: Any])?["volume_mm3"] as? Double
    }
}
