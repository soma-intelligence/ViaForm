#if os(iOS)
import SwiftUI
import simd

// The iPad's sketch surfaces after the reference tablet layout (docs/research/cad-ui/
// shapr3d-ipad.md 5.2):
// - T-2  the constraint column on the panel edge while a sketch is open: Constraint Settings,
//        Parallel, Perpendicular, Tangent, Coincident, Midpoint, Concentric, Horizontal/Vertical,
//        Equal, Symmetry, Lock, Make Construction, then Delete (Delete Constraints when only
//        glyphs are picked). Entries that do not fit the selection are grey, never hidden.
//        Fed by `model.constraintEntries` (B-4), run through `model.applyConstraint`.
// - the sketch's defined-state chip (`model.sketchState`) under the title pill;
// - T-12 the readout for picked sketch entities ("2 lines & 1 constraint");
// - T-17 the optional exit when the view orbits far from the sketch plane (default off);
// - the selection filter menu bound to `model.selectionFilter` (on the snapping rail).
// ViaForm names and SF Symbols only; every action is an engine command through DesignModel.

// MARK: - Settings

// The keys live in `SketchDisplaySettings` (Shared/Model/SketchDrawing.swift): dimensions,
// constraints, grid and the exit on orbit, one owner for the Mac and the iPad.

// MARK: - Constraint column (pure)

/// One row of the constraint column.
struct TouchConstraintRow: Identifiable, Equatable {
    enum Kind: Equatable {
        /// A `SketchConstraintCatalog` entry by id ("parallel"), or "horizontal_vertical".
        case constraint(String)
        case construction
        case delete
    }

    var kind: Kind
    var title: String
    var symbol: String
    var enabled: Bool
    var destructive = false

    var id: String {
        switch kind {
        case let .constraint(c): "constraint." + c
        case .construction: "construction"
        case .delete: "delete"
        }
    }
}

enum TouchConstraintLayout {
    /// The column's constraint ids, in the reference order. "horizontal_vertical" is one row
    /// that lets the engine choose the nearer of the two; "fix" is shown as Lock.
    static let order = ["parallel", "perpendicular", "tangent", "coincident", "midpoint", "concentric",
                        "horizontal_vertical", "equal", "symmetry", "fix"]

    /// Every row for `picks`: the constraints, Make Construction and Delete, each enabled where
    /// the selection fits it.
    static func rows(for picks: [SketchPick]) -> [TouchConstraintRow] {
        let entries = SketchConstraintCatalog.entries(for: picks)
        var out: [TouchConstraintRow] = []
        for id in order {
            if id == "horizontal_vertical" {
                let h = entries.first { $0.id == "horizontal" }
                out.append(TouchConstraintRow(kind: .constraint(id), title: String(localized: "Horizontal/Vertical"),
                                              symbol: h?.symbol ?? "arrow.left.and.right", enabled: h?.enabled ?? false))
                continue
            }
            guard let e = entries.first(where: { $0.id == id }) else { continue }
            out.append(TouchConstraintRow(kind: .constraint(id), title: id == "fix" ? String(localized: "Lock") : e.label,
                                          symbol: id == "fix" ? "lock" : e.symbol, enabled: e.enabled))
        }
        out.append(TouchConstraintRow(kind: .construction, title: String(localized: "Make Construction"),
                                      symbol: "line.diagonal", enabled: picks.contains(where: \.isCurve)))
        out.append(TouchConstraintRow(kind: .delete, title: deleteTitle(picks), symbol: "trash",
                                      enabled: !picks.isEmpty, destructive: true))
        return out
    }

    /// "Delete Constraints" when every pick is a constraint glyph, else "Delete".
    static func deleteTitle(_ picks: [SketchPick]) -> String {
        !picks.isEmpty && picks.allSatisfy { $0.kind == .constraint } ? String(localized: "Delete Constraints") : String(localized: "Delete")
    }

    /// Runs a row on the model's sketch selection. False when it did not apply.
    @MainActor @discardableResult
    static func run(_ row: TouchConstraintRow, _ model: DesignModel) -> Bool {
        guard row.enabled, model.sketchOpen else { return false }
        switch row.kind {
        case let .constraint(id):
            if id == "horizontal_vertical" {
                guard let e = SketchConstraintCatalog.entry(command: "sketch.constraint.horizontal_vertical", for: model.sketchSelection)
                else { return false }
                model.applyConstraint(e)
                return true
            }
            return model.applyConstraint(id: id)
        case .construction:
            model.toggleConstruction()
            return true
        case .delete:
            model.deleteSketchSelection()
            return true
        }
    }

    /// Why a grey row is grey, for VoiceOver and the long-press hint.
    static func disabledReason(_ row: TouchConstraintRow) -> String {
        switch row.kind {
        case .delete: String(localized: "Select sketch geometry or a constraint first")
        case .construction: String(localized: "Select one or more curves")
        case .constraint: String(localized: "The selection does not take this constraint")
        }
    }
}

// MARK: - Constraint column view

/// The constraint column on the panel edge while a sketch is open (T-2), as the reference:
/// Constraint Settings on a tile of its own, then one tile of constraint icons hugging the edge
/// with their labels floating on the canvas, grey until the selection takes them. Delete sits
/// at the foot of the tool column (`TouchSketchDeleteTile`).
struct TouchConstraintColumn: View {
    let model: DesignModel

    /// Rows the column draws (for the rail's row height): Constraint Settings and the rows
    /// without Delete.
    static var rowCount: Int { TouchConstraintLayout.rows(for: []).filter { $0.kind != .delete }.count + 1 }

    var body: some View {
        let rows = TouchConstraintLayout.rows(for: model.sketchSelection).filter { $0.kind != .delete }
        VStack(alignment: .trailing, spacing: TouchRail.gap) {
            TouchRailGroup { TouchConstraintSettingsMenu(model: model) }
            TouchRailGroup {
                ForEach(rows) { row in
                    TouchConstraintRowButton(row: row) { TouchConstraintLayout.run(row, model) }
                }
            }
        }
        .vfAnimation(.snappy(duration: VFMotion.fast), value: rows.map(\.enabled))
    }
}

/// Delete (or Delete Constraints) for the open sketch's picks, a tile at the foot of the tool
/// column, grey with nothing picked.
struct TouchSketchDeleteTile: View {
    let model: DesignModel

    var body: some View {
        let row = TouchConstraintLayout.rows(for: model.sketchSelection).first { $0.kind == .delete }
        if let row {
            TouchRailGroup {
                Button { TouchConstraintLayout.run(row, model) } label: {
                    TouchRailRow(symbol: row.symbol, title: row.title, enabled: row.enabled, destructive: true)
                }
                .buttonStyle(.touchRail)
                .hoverEffect(.highlight)
                .vfDisabled(!row.enabled, reason: TouchConstraintLayout.disabledReason(row))
                .accessibilityLabel(row.title)
            }
        }
    }
}

/// One constraint row, grey when the selection does not fit it.
struct TouchConstraintRowButton: View {
    let row: TouchConstraintRow
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TouchRailRow(symbol: row.symbol, title: row.title, enabled: row.enabled, destructive: row.destructive && row.enabled)
        }
        .buttonStyle(.touchRail)
        .hoverEffect(.highlight)
        .vfDisabled(!row.enabled, reason: TouchConstraintLayout.disabledReason(row))
        .accessibilityLabel(row.title)
    }
}

/// Constraint Settings: Always Show Constraints, Always Show Dimensions and the exit on orbit.
struct TouchConstraintSettingsMenu: View {
    let model: DesignModel
    var compact = false
    @AppStorage(SketchDisplaySettings.dimensionsKey) private var showDimensions = true
    @AppStorage(SketchDisplaySettings.exitOnOrbitKey) private var exitOnOrbit = false

    var body: some View {
        Menu {
            Toggle(isOn: Binding(get: { model.showConstraints }, set: { model.showConstraints = $0 })) {
                Label("Always Show Constraints", systemImage: "square.on.square")
            }
            Toggle(isOn: $showDimensions) { Label("Always Show Dimensions", systemImage: "ruler") }
            Divider()
            Toggle(isOn: $exitOnOrbit) { Label("Exit Sketch When Orbiting Away", systemImage: "rotate.3d") }
        } label: {
            TouchRailRow(symbol: "gearshape.fill", title: String(localized: "Constraint Settings"))
        }
        .menuStyle(.button)
        .buttonStyle(.touchRail)
        .hoverEffect(.highlight)
        .accessibilityLabel(Text("Constraint Settings"))
    }
}

/// The iPhone strip's slot: Constraint Settings and every constraint row in one menu.
struct TouchConstraintStripMenu: View {
    let model: DesignModel
    @AppStorage(SketchDisplaySettings.dimensionsKey) private var showDimensions = true

    var body: some View {
        let rows = TouchConstraintLayout.rows(for: model.sketchSelection)
        Menu {
            Section("Constraint Settings") {
                Toggle("Always Show Constraints", isOn: Binding(get: { model.showConstraints }, set: { model.showConstraints = $0 }))
                Toggle("Always Show Dimensions", isOn: $showDimensions)
            }
            ForEach(rows) { row in
                Button(row.title, systemImage: row.symbol, role: row.destructive ? .destructive : nil) { TouchConstraintLayout.run(row, model) }
                    .disabled(!row.enabled)
            }
        } label: {
            TouchColumnRowLabel(item: TouchColumnItem(kind: .constraintSlot, title: String(localized: "Constraints"), symbol: "lock"),
                                compact: true)
        }
        .menuStyle(.button)
        .buttonStyle(.vfTouch)
        .accessibilityLabel(Text("Constraints"))
    }
}

// MARK: - Defined state chip

/// "Fully defined", "Under defined (3 DOF)" or "Over-constrained" under the title pill.
struct TouchSketchStateChip: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel

    var body: some View {
        if let state = model.sketchState {
            Label(state.summary, systemImage: state.symbol)
                .font(VFFont.small.weight(.semibold))
                .foregroundStyle(SketchStateStyle.readout(theme, state))
                .padding(.horizontal, VFSpace.l)
                .frame(minHeight: VFSize.chip + VFSpace.s)
                .vfSurface(.control, radius: VFRadius.touchCapsule)
                .overlay(Capsule().strokeBorder(state.overConstrained ? theme.danger : .clear, lineWidth: VFSize.hairline))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("Sketch: \(state.summary)"))
                .vfTransition(.opacity)
        }
    }
}

// MARK: - Readout (T-12)

enum TouchSketchReadout {
    private static func plain(_ s: AttributedString) -> String { String(s.characters) }

    /// "1 line", "2 lines & 1 constraint", "1 point, 1 circle & 2 constraints". Nil for none.
    static func title(_ picks: [SketchPick]) -> String? {
        let order: [SketchPick.Kind] = [.point, .line, .circle, .arc, .curve, .constraint]
        var parts: [String] = []
        for k in order {
            let n = picks.filter { $0.kind == k }.count
            guard n > 0 else { continue }
            parts.append(count(n, k))
        }
        guard let last = parts.popLast() else { return nil }
        return parts.isEmpty ? last : parts.joined(separator: ", ") + " & " + last
    }

    static func count(_ n: Int, _ k: SketchPick.Kind) -> String {
        switch k {
        case .point: plain(AttributedString(localized: "^[\(n) point](inflect: true)"))
        case .line: plain(AttributedString(localized: "^[\(n) line](inflect: true)"))
        case .circle: plain(AttributedString(localized: "^[\(n) circle](inflect: true)"))
        case .arc: plain(AttributedString(localized: "^[\(n) arc](inflect: true)"))
        case .curve: plain(AttributedString(localized: "^[\(n) curve](inflect: true)"))
        case .constraint: plain(AttributedString(localized: "^[\(n) constraint](inflect: true)"))
        }
    }
}

// MARK: - Exit on orbit (T-17)

enum TouchSketchExit {
    /// The view has turned more than 60 degrees away from square to the plane. The orbit path
    /// (`DesignModel`) finishes the sketch on it when `SketchDisplaySettings.exitOnOrbit` is on.
    static func isFarFromPlane(back: SIMD3<Double>, normal: SIMD3<Double>) -> Bool {
        DesignModel.turnedAway(back: back, normal: normal)
    }
}

// MARK: - Selection filter

/// The selection filter (Auto, Bodies, Faces, Edges, Sketch) as a rail menu, bound to
/// `model.selectionFilter`.
struct TouchSelectionFilterMenu: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel

    var body: some View {
        let current = model.selectionFilter
        Menu {
            Picker(selection: Binding(get: { model.selectionFilter }, set: { model.selectionFilter = $0 })) {
                ForEach(SelectionFilter.allCases) { f in Label(f.title, systemImage: f.symbol).tag(f) }
            } label: {
                Text("Select")
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: current == .auto ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                .font(VFFont.glyph(16, weight: .medium))
                .foregroundStyle(current == .auto ? theme.ink : theme.accentText)
                .frame(width: VFSize.touchTarget, height: VFSize.touchTarget).contentShape(Rectangle())
        }
        .hoverEffect(.highlight)
        .accessibilityLabel(Text("Selection filter"))
        .accessibilityValue(current.title)
    }
}

// MARK: - Self test

/// Checks for the touch sketch surfaces (T-2, T-12). iOS only: the lead wires it into
/// SelfTest.swift under `#if os(iOS)`.
enum TouchSketchUISelfTest {
    /// `--touch-sketch-selftest-out=<path>`: writes these checks there and quits (before the lead
    /// wires them into SelfTest.swift).
    @MainActor static func runIfAsked() {
        guard let out = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--touch-sketch-selftest-out=") })?.dropFirst(28)
        else { return }
        let results = checks()
        let failures = results.filter { !$0.0 }.count
        let lines = results.map { ($0.0 ? "PASS " : "FAIL ") + $0.1 } + [failures == 0 ? "ALL PASS" : "\(failures) FAILED"]
        try? lines.joined(separator: "\n").write(toFile: String(out), atomically: true, encoding: .utf8)
        exit(failures == 0 ? 0 : 1)
    }

    @MainActor static func checks() -> [(Bool, String)] {
        var out: [(Bool, String)] = []
        func row(_ rows: [TouchConstraintRow], _ id: String) -> TouchConstraintRow? { rows.first { $0.id == "constraint." + id } }

        // Column entries: every row is listed for any selection; the fitting ones are enabled.
        let one = TouchConstraintLayout.rows(for: [SketchPick(id: "a", kind: .line)])
        let two = TouchConstraintLayout.rows(for: [SketchPick(id: "a", kind: .line), SketchPick(id: "b", kind: .line)])
        let none = TouchConstraintLayout.rows(for: [])
        out.append((one.count == two.count && one.count == none.count && one.count == TouchConstraintLayout.order.count + 2,
                    "T-2 the column lists every entry whatever the selection (\(one.count))"))
        out.append((row(one, "horizontal_vertical")?.enabled == true && row(one, "fix")?.enabled == true
                    && row(one, "parallel")?.enabled == false && row(one, "perpendicular")?.enabled == false
                    && one.first { $0.kind == .construction }?.enabled == true,
                    "T-2 one line: Horizontal/Vertical, Lock and Make Construction on; Parallel and Perpendicular grey"))
        out.append((row(two, "parallel")?.enabled == true && row(two, "perpendicular")?.enabled == true
                    && row(two, "equal")?.enabled == true && row(two, "concentric")?.enabled == false,
                    "T-2 two lines: Parallel, Perpendicular, Equal on; Concentric grey"))
        out.append((none.allSatisfy { !$0.enabled }, "T-2 nothing selected: every row grey, none hidden"))

        // Delete label.
        let glyphs = [SketchPick(id: "g1", kind: .constraint), SketchPick(id: "g2", kind: .constraint)]
        let mixed = [SketchPick(id: "a", kind: .line), SketchPick(id: "g1", kind: .constraint)]
        out.append((TouchConstraintLayout.rows(for: glyphs).last?.title == String(localized: "Delete Constraints")
                    && TouchConstraintLayout.deleteTitle(mixed) == String(localized: "Delete")
                    && TouchConstraintLayout.deleteTitle([SketchPick(id: "a", kind: .line)]) == String(localized: "Delete"),
                    "T-2 Delete reads Delete Constraints when only glyphs are picked"))

        // Readout text.
        let r1 = TouchSketchReadout.title([SketchPick(id: "a", kind: .line), SketchPick(id: "b", kind: .line),
                                           SketchPick(id: "g", kind: .constraint)])
        let r2 = TouchSketchReadout.title([SketchPick(id: "p", kind: .point)])
        out.append((r1 == "2 lines & 1 constraint" && r2 == "1 point" && TouchSketchReadout.title([]) == nil,
                    "T-12 sketch readout reads \"2 lines & 1 constraint\" (\(r1 ?? "nil"), \(r2 ?? "nil"))"))

        // Exit on orbit: square to the plane stays, edge on leaves.
        out.append((!TouchSketchExit.isFarFromPlane(back: SIMD3(0, 0, 1), normal: SIMD3(0, 0, 1))
                    && TouchSketchExit.isFarFromPlane(back: SIMD3(1, 0, 0.2), normal: SIMD3(0, 0, 1)),
                    "T-17 the view leaves the sketch only when far from its plane"))

        // Apply Perpendicular to two real lines through the column path.
        let m = DesignModel()
        m.run("file.new", quiet: true)
        m.startSketch("XY")
        m.run("sketch.line", ["points": [[0, 0], [30, 0]]], quiet: true)
        m.run("sketch.line", ["points": [[0, 20], [10, 40]]], quiet: true)
        m.tool = .select
        let lines = m.sketchInfo?.curves.filter { $0.kind == "line" } ?? []
        guard lines.count == 2 else {
            out.append((false, "T-2 a sketch with two lines opens (\(lines.count) lines)"))
            return out
        }
        let before = m.sketchInfo?.glyphs.count ?? 0
        m.sketchSelection = lines.map { SketchPick(id: $0.id, kind: .line) }
        let rows = TouchConstraintLayout.rows(for: m.sketchSelection)
        let ran = row(rows, "perpendicular").map { TouchConstraintLayout.run($0, m) } ?? false
        let added = m.sketchInfo?.glyphs.contains { $0.name.localizedCaseInsensitiveContains("perpendicular") } ?? false
        out.append((ran && added && (m.sketchInfo?.glyphs.count ?? 0) > before && m.sketchSelection.isEmpty,
                    "T-2 Perpendicular from the column constrains the two lines (\(m.message ?? "ok"))"))
        m.finishSketch()
        return out
    }
}
#endif
