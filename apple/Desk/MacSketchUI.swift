#if os(macOS)
import SwiftUI
import simd

// Mac sketch surfaces (gaps M-1, M-3, M-11; M-5 check):
//   ConstraintRibbon / ConstraintRibbonPanel   the CONSTRAINTS ribbon panel on the B-4 catalog:
//                                              invalid entries greyed, applied to the sketch
//                                              selection; the registry form is the fallback
//                                              when nothing is picked.
//   SketchPill                                 the same valid list in the context pill, beside
//                                              the last pick (SolidWorks "Better than Fusion" 1).
//   SketchPalette                              the docked palette in the inspector column while
//                                              a sketch is open, with the DOF readout.
//   SketchDefinedStates / SketchStatusText     defined state of every sketch (browser rows,
//                                              timeline tiles) and the status bar text.
// Everything runs engine commands through DesignModel; nothing here computes geometry.

// MARK: Defined state per sketch (M-11)

/// The defined state of any sketch, open or not. The open one comes live from
/// `model.sketchState`; the others from `sketch.inspect`, read once per document revision with
/// the rest of the outline (`DesignOutlineCache`, kept per model and purged with it). Views read
/// the states they loaded in `.task(id: revision)` through `state(_:sketch:in:)`, which never
/// calls the engine.
@MainActor
enum SketchDefinedStates {
    /// Every sketch's state from the engine, for `DesignOutlineData.load`.
    static func load(_ model: DesignModel) -> [Int: SketchDefinedState] {
        var out: [Int: SketchDefinedState] = [:]
        for s in model.snapshot.sketches {
            if let st = read(model, sketch: s.id) { out[s.id] = st }
        }
        return out
    }

    /// For view bodies: the live state of the open sketch, else the loaded one. No engine call.
    static func state(_ model: DesignModel, sketch id: Int, in states: [Int: SketchDefinedState]) -> SketchDefinedState? {
        if model.sketchOpen, model.sketchInfo?.id == id, let s = model.sketchState { return s }
        return states[id]
    }

    /// For view bodies: the state of the sketch a timeline feature makes, by its name.
    static func state(_ model: DesignModel, feature: DesignSnapshot.Feature, in states: [Int: SketchDefinedState]) -> SketchDefinedState? {
        guard feature.type.lowercased() == "sketch",
              let s = model.snapshot.sketches.first(where: { $0.name == feature.name }) else { return nil }
        return state(model, sketch: s.id, in: states)
    }

    /// Outside view bodies: through the shared per-revision cache.
    static func state(_ model: DesignModel, sketch id: Int) -> SketchDefinedState? {
        state(model, sketch: id, in: DesignOutlineCache.shared.data(model).sketchStates)
    }

    /// The state of the sketch a timeline feature makes, through the shared cache.
    static func state(_ model: DesignModel, feature: DesignSnapshot.Feature) -> SketchDefinedState? {
        state(model, feature: feature, in: DesignOutlineCache.shared.data(model).sketchStates)
    }

    /// The browser row's symbol: a closed lock when fully defined, a warning when over-defined,
    /// the sketch pencil otherwise.
    static func rowSymbol(_ state: SketchDefinedState?) -> String {
        state?.symbol ?? "pencil.line"
    }

    static func rowSymbol(_ model: DesignModel, sketch id: Int) -> String {
        rowSymbol(state(model, sketch: id))
    }

    private static func read(_ model: DesignModel, sketch id: Int) -> SketchDefinedState? {
        // `sketch.glyphs` needs the sketch open; `sketch.inspect` reports any evaluated sketch.
        guard let r = (try? model.engine.execute("sketch.inspect", ["sketch": id])) as? [String: Any] else { return nil }
        let conflicts = (r["failing"] as? [Any])?.count ?? 0
        return SketchDefinedState(dof: r["dof"] as? Int,
                                  fullyConstrained: (r["fully_constrained"] as? Bool ?? false) && conflicts == 0,
                                  overConstrained: conflicts > 0, conflicts: conflicts)
    }
}

/// The defined state in the status bar's words (SolidWorks): "Fully Defined",
/// "Under Defined (3 DOF)", "Over Defined".
enum SketchStatusText {
    static func text(_ s: SketchDefinedState) -> String {
        if s.overConstrained { return String(localized: "Over Defined") }
        if s.fullyConstrained { return String(localized: "Fully Defined") }
        if let d = s.dof { return String(localized: "Under Defined (\(d) DOF)") }
        return String(localized: "Under Defined")
    }

    /// The status bar's leading text while a sketch is open: its name, its state, the picks.
    @MainActor static func statusLine(_ model: DesignModel) -> String? {
        guard model.sketchOpen, let state = model.sketchState else { return nil }
        var parts: [String] = []
        if let id = model.snapshot.active_sketch, let s = model.snapshot.sketches.first(where: { $0.id == id }) {
            parts.append(s.name)
        }
        parts.append(text(state))
        let n = model.sketchSelection.count
        if n > 0 { parts.append(String(localized: "\(n) selected")) }
        return parts.joined(separator: " · ")
    }
}

// MARK: Constraints on pre-selection (M-1)

@MainActor
enum ConstraintRibbon {
    struct Item: Identifiable {
        let entry: SketchConstraintEntry
        let enabled: Bool
        let reason: String?
        var id: String { entry.id }
    }

    /// Every catalog entry, in the catalog's order. With picks, the ones that fit are enabled
    /// (Fusion); with nothing picked, the entry opens its command's form (pick after).
    static func items(_ model: DesignModel) -> [Item] {
        let picked = !model.sketchSelection.isEmpty
        return model.constraintEntries.map { e in
            if picked {
                return Item(entry: e, enabled: e.enabled, reason: e.enabled ? nil : String(localized: "Not for this selection"))
            }
            let has = model.commands.contains { $0.id == e.command }
            return Item(entry: e, enabled: has, reason: has ? nil : String(localized: "Select sketch geometry first"))
        }
    }

    /// Runs an entry: on the selection when it fits, else the registry command (its form).
    static func apply(_ e: SketchConstraintEntry, _ model: DesignModel) {
        if !model.sketchSelection.isEmpty {
            if e.enabled { model.applyConstraint(e) }
            return
        }
        if let c = model.commands.first(where: { $0.id == e.command }) { CommandRouter.run(c, model) }
    }

    static func help(_ item: Item) -> String {
        item.reason.map { "\(item.entry.label): \($0)" } ?? item.entry.label
    }
}

/// The CONSTRAINTS panel of the SKETCH tab while a sketch is open: the panel's other keyed
/// command (Dimension) as a big icon, then every constraint as a small icon in two rows, greyed
/// when the selection does not fit it. The legend lists them all, with the panel's other commands.
struct ConstraintRibbonPanel: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    let panel: RibbonPanelModel
    /// Fusion's panel: one row of big constraint icons over "CONSTRAINTS ▾".
    var fusion = false

    private var others: [CommandInfo] { panel.commands.filter { !$0.id.hasPrefix("sketch.constraint.") } }

    var body: some View {
        if fusion { fusionBody } else { classicBody }
    }

    private var fusionBody: some View {
        let items = ConstraintRibbon.items(model)
        let f = theme.fusion
        return VStack(spacing: 2) {
            HStack(spacing: 1) {
                ForEach(items) { item in
                    Button { ConstraintRibbon.apply(item.entry, model) } label: {
                        Image(systemName: item.entry.symbol)
                            .font(VFFont.glyph(16))
                            .foregroundStyle(item.enabled ? f.iconTint : f.inkFaint)
                            .frame(width: 26, height: FusionTokens.iconCell.height)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!item.enabled)
                    .help(ConstraintRibbon.help(item))
                    .accessibilityLabel(item.entry.label)
                    .accessibilityHint(item.reason ?? "")
                }
            }
            Menu {
                ForEach(items) { item in
                    Button { ConstraintRibbon.apply(item.entry, model) } label: {
                        Label(item.entry.label, systemImage: item.entry.symbol)
                    }
                    .disabled(!item.enabled)
                    .help(ConstraintRibbon.help(item))
                }
                if !others.isEmpty {
                    Divider()
                    ForEach(others) { c in RibbonMenuRow(model: model, command: c) }
                }
                Divider()
                PinMenu(commands: panel.commands)
            } label: {
                FusionLegend(text: panel.name)
            }
            .menuStyle(.button).buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Constraints"))
    }

    private var classicBody: some View {
        let items = ConstraintRibbon.items(model)
        let half = (items.count + 1) / 2
        return VStack(spacing: 1) {
            HStack(spacing: VFSpace.xs) {
                ForEach(others.filter { $0.key != nil }.prefix(1)) { c in
                    let on = model.tool.commandID == c.id && model.tool != .select
                    Button { CommandRouter.run(c, model) } label: {
                        ToolChipIcon(icon: c.icon, id: c.id, size: 22)
                            .frame(width: 36, height: 32)
                            .background(RoundedRectangle(cornerRadius: VFRadius.control, style: .continuous).fill(on ? theme.accent.opacity(0.22) : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(RibbonPins.tooltip(c))
                    .accessibilityLabel(StageLabels.command(c.label))
                }
                VStack(spacing: 1) {
                    row(Array(items.prefix(half)))
                    row(Array(items.dropFirst(half)))
                }
            }
            Menu {
                ForEach(items) { item in
                    Button { ConstraintRibbon.apply(item.entry, model) } label: {
                        Label(item.entry.label, systemImage: item.entry.symbol)
                    }
                    .disabled(!item.enabled)
                    .help(ConstraintRibbon.help(item))
                }
                if !others.isEmpty {
                    Divider()
                    ForEach(others) { c in RibbonMenuRow(model: model, command: c) }
                }
                Divider()
                PinMenu(commands: panel.commands)
            } label: {
                VFCaption(StageLabels.panel(panel.name))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
        }
        .padding(.horizontal, VFSpace.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Constraints"))
    }

    private func row(_ items: [ConstraintRibbon.Item]) -> some View {
        HStack(spacing: 1) {
            ForEach(items) { item in
                Button { ConstraintRibbon.apply(item.entry, model) } label: {
                    Image(systemName: item.entry.symbol)
                        .font(VFFont.glyph(11, weight: .medium))
                        .foregroundStyle(item.enabled ? theme.ink : theme.inkTertiary)
                        .frame(width: 20, height: 15)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!item.enabled)
                .help(ConstraintRibbon.help(item))
                .accessibilityLabel(item.entry.label)
                .accessibilityHint(item.reason ?? "")
            }
        }
    }
}

/// The context pill for the sketch selection: the valid constraints first, then Dimension,
/// Construction and Delete, beside the last pick.
@MainActor
enum SketchPill {
    /// A box around the last pick on screen, or nil when nothing is picked in an open sketch.
    static func rect(_ model: DesignModel, size: CGSize) -> CGRect? {
        guard model.sketchOpen, model.tool == .select, let info = model.sketchInfo, let last = model.sketchSelection.last else { return nil }
        let cam = model.camera
        func screen(_ q: SIMD2<Double>) -> CGPoint { cam.project(info.plane.toWorld(q), size: size) }
        var at: CGPoint?
        switch last.kind {
        case .point:
            at = info.points.first { $0.id == last.id }.map { screen($0.at) }
        case .constraint:
            at = SketchGlyphLayout.spots(info, camera: cam, size: size).first { $0.glyph.id == last.id }?.at
        default:
            if let c = info.curves.first(where: { $0.id == last.id }), !c.polyline.isEmpty {
                at = screen(c.polyline[c.polyline.count / 2])
            }
        }
        guard let p = at else { return nil }
        return CGRect(x: p.x - 24, y: p.y - 24, width: 48, height: 48)
    }

    static func title(_ model: DesignModel) -> String {
        let picks = model.sketchSelection
        guard picks.count == 1, let k = picks.first?.kind else {
            return WorkspaceMenu.inflected("^[\(picks.count) entity](inflect: true)")
        }
        switch k {
        case .point: return String(localized: "Point")
        case .line: return String(localized: "Line")
        case .circle: return String(localized: "Circle")
        case .arc: return String(localized: "Arc")
        case .curve: return String(localized: "Curve")
        case .constraint: return String(localized: "Constraint")
        }
    }

    /// The pill's verbs, at most `limit` constraints.
    static func actions(_ model: DesignModel, limit: Int = 5) -> [PillAction] {
        let picks = model.sketchSelection
        var out = SketchConstraintCatalog.valid(for: picks).prefix(limit).map { e in
            PillAction(id: "constraint.\(e.id)", title: e.label, symbol: e.symbol) { model.applyConstraint(e) }
        }
        let geo = picks.filter { $0.kind != .constraint }
        if geo.count == picks.count, (1...2).contains(geo.count) {
            out.append(PillAction(id: "dimension", title: String(localized: "Dimension"), symbol: "ruler") { model.beginDimension() })
        }
        if picks.contains(where: \.isCurve) {
            out.append(PillAction(id: "construction", title: String(localized: "Construction"), symbol: "line.diagonal") { model.toggleConstruction() })
        }
        out.append(PillAction(id: "delete", title: String(localized: "Delete"), symbol: "trash") { model.deleteSketchSelection() })
        return out
    }
}

// MARK: Sketch Palette (M-3)

/// The docked Sketch Palette (Fusion): Linetype, Look At, then the display options, then the
/// defined state and Finish Sketch. It sits at the top of the inspector column while a sketch
/// is open, also under a running sketch tool's dialog.
struct SketchPalette: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    // The palette's options live in the app, not in the document, kept per user under the keys
    // their Shared owners declare (the renderer, the snap and the iPad read the same keys), so
    // the checkboxes follow a change made anywhere else.
    @AppStorage(SketchDisplaySettings.gridKey) private var grid = true
    @AppStorage(SketchSnapSettings.snapKey) private var snap = true
    @AppStorage(SketchDisplaySettings.profileKey) private var profile = true
    @AppStorage(SketchDisplaySettings.pointsKey) private var points = true
    @AppStorage(SketchDisplaySettings.dimensionsKey) private var dimensions = true
    @AppStorage(SketchDisplaySettings.projectedKey) private var projected = true

    /// The palette's DOF readout, as the status bar says it.
    @MainActor static func dofText(_ model: DesignModel) -> String? {
        model.sketchState.map(SketchStatusText.text)
    }

    /// Fusion's floating palette (1.10): header, Feature Options for a tool with variants,
    /// Options as label and control rows, Finish Sketch at the foot.
    var fusion = false
    @State private var folded = false

    var body: some View {
        if fusion { fusionBody } else { classicBody }
    }

    /// The armed tool's variants, Fusion's Feature Options (Rectangle: 2-point, 3-point, center).
    private var variants: (String, [Tool])? {
        switch model.tool {
        case .rectangle, .threePointRectangle, .centerRectangle:
            (String(localized: "Rectangle"), [.rectangle, .threePointRectangle, .centerRectangle])
        case .circle, .twoPointCircle, .threePointCircle:
            (String(localized: "Circle"), [.circle, .twoPointCircle, .threePointCircle])
        default: nil
        }
    }

    private var fusionBody: some View {
        let f = theme.fusion
        return VStack(alignment: .leading, spacing: 0) {
            FusionCardHeader(title: "Sketch Palette", folded: $folded)
            if !folded {
                VStack(alignment: .leading, spacing: 0) {
                    if let v = variants {
                        FusionSection(title: "Feature Options")
                        fusionLine(v.0) {
                            HStack(spacing: 2) {
                                ForEach(v.1, id: \.self) { t in
                                    Button { model.tool = t } label: {
                                        Image(systemName: t.symbol).font(VFFont.glyph(11))
                                            .foregroundStyle(model.tool == t ? f.onBlue : f.inkSoft)
                                            .frame(width: 18, height: 18)
                                            .background(RoundedRectangle(cornerRadius: 2).fill(model.tool == t ? f.blue : .clear))
                                    }
                                    .buttonStyle(.plain)
                                    .help(t.label)
                                    .accessibilityLabel(t.label)
                                    .accessibilityAddTraits(model.tool == t ? .isSelected : [])
                                }
                            }
                        }
                    }
                    FusionSection(title: "Options")
                    fusionLine(String(localized: "Linetype")) {
                        Button { model.toggleConstruction() } label: {
                            Image(systemName: "line.diagonal").font(VFFont.glyph(11))
                                .foregroundStyle(model.constructionMode || selectedConstruction ? f.onBlue : f.inkSoft)
                                .frame(width: 18, height: 18)
                                .background(RoundedRectangle(cornerRadius: 2).fill(model.constructionMode || selectedConstruction ? f.blue : .clear))
                        }
                        .buttonStyle(.plain).help(construction).accessibilityLabel(construction)
                    }
                    fusionLine(String(localized: "Look At")) {
                        Button { if let pl = model.sketchPlane { model.look(along: pl.normal) } } label: {
                            Image(systemName: "viewfinder").font(VFFont.glyph(11)).foregroundStyle(f.inkSoft).frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain).help("Look at the sketch plane").accessibilityLabel("Look At")
                    }
                    check("Sketch Grid", Binding(get: { grid }, set: { v in
                        grid = v
                        model.run("view.grid", ["on": v], quiet: true)
                    }))
                    check("Snap", $snap)
                    check("Profile", $profile)
                    check("Points", $points)
                    check("Dimensions", $dimensions)
                    check("Constraints", Binding(get: { model.showConstraints }, set: { model.showConstraints = $0 }))
                    check("Projected Geometries", $projected)
                    HStack {
                        Spacer()
                        Button("Finish Sketch") { model.finishSketch() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help(String(localized: "Finish the sketch (Return)"))
                    }
                    .padding(VFSpace.s)
                }
                .padding(.bottom, VFSpace.xxs)
            }
        }
        .background(f.card)
        .overlay(Rectangle().strokeBorder(f.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Sketch Palette"))
    }

    private func fusionLine<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: VFSpace.s) {
            Text(label).font(FusionTokens.header).foregroundStyle(theme.fusion.ink)
            Spacer(minLength: VFSpace.s)
            content().frame(width: 64, alignment: .leading)
        }
        .padding(.horizontal, VFSpace.s)
        .frame(height: 20)
    }

    private func check(_ label: LocalizedStringResource, _ on: Binding<Bool>) -> some View {
        fusionLine(String(localized: label)) {
            Toggle(String(localized: label), isOn: on).labelsHidden().toggleStyle(.checkbox).controlSize(.small)
        }
    }

    private var classicBody: some View {
        VStack(alignment: .leading, spacing: VFSpace.s) {
            HStack {
                VFCaption("Sketch Palette")
                Spacer()
            }
            if let state = model.sketchState {
                Label(SketchStatusText.text(state), systemImage: state.symbol)
                    .font(VFFont.small.weight(.medium))
                    .foregroundStyle(SketchStateStyle.readout(theme, state))
                    .accessibilityLabel(String(localized: "Sketch state: \(SketchStatusText.text(state))"))
            }
            VStack(alignment: .leading, spacing: VFSpace.xs) {
                line(String(localized: "Linetype")) {
                    VFIconButton("line.diagonal", label: construction, isOn: model.constructionMode || selectedConstruction) {
                        model.toggleConstruction()
                    }
                    .help(construction)
                }
                line(String(localized: "Look At")) {
                    VFIconButton("viewfinder", label: String(localized: "Look at the sketch plane")) {
                        if let pl = model.sketchPlane { model.look(along: pl.normal) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: VFSpace.xxs) {
                Toggle("Sketch Grid", isOn: Binding(get: { grid }, set: { v in
                    grid = v
                    model.run("view.grid", ["on": v], quiet: true)
                }))
                Toggle("Snap", isOn: $snap)
                Toggle("Show Profile", isOn: $profile)
                Toggle("Points", isOn: $points)
                Toggle("Dimensions", isOn: $dimensions)
                Toggle("Constraints", isOn: Binding(get: { model.showConstraints }, set: { model.showConstraints = $0 }))
                Toggle("Projected", isOn: $projected)
            }
            .toggleStyle(.checkbox)
            .font(VFFont.small)
            Button { model.finishSketch() } label: {
                Text("Finish Sketch").frame(maxWidth: .infinity)
            }
            .buttonStyle(.vfPrimary)
            .help(String(localized: "Finish the sketch (Return)"))
        }
        .padding(VFSpace.m)
        .vfSurface(.well)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Sketch Palette"))
    }

    private var selectedConstruction: Bool {
        let ids = Set(model.sketchSelection.filter(\.isCurve).map(\.id))
        guard !ids.isEmpty, let info = model.sketchInfo else { return false }
        return info.curves.filter { ids.contains($0.id) }.allSatisfy(\.construction)
    }

    private var construction: String {
        model.sketchSelection.contains(where: \.isCurve)
            ? String(localized: "Switch the selected curves between normal and construction")
            : (model.constructionMode ? String(localized: "Construction on: new curves are construction geometry")
                                      : String(localized: "Draw construction geometry"))
    }

    private func line<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack {
            Text(label).font(VFFont.small).foregroundStyle(theme.inkSecondary)
            Spacer(minLength: VFSpace.m)
            content()
        }
    }
}

// MARK: Self test

enum MacSketchUISelfTest {
    @MainActor private static var started = false

    /// `--mac-sketch-selftest`: runs only these checks, prints them and quits (until the lead
    /// wires them into SelfTest.swift). `--mac-sketch-selftest-out=<path>` also writes them there.
    @MainActor static func runIfAsked() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--mac-sketch-selftest"), !started else { return }
        started = true
        DispatchQueue.main.async {
            let results = checks()
            let failures = results.filter { !$0.0 }.count
            let lines = results.map { ($0.0 ? "PASS " : "FAIL ") + $0.1 } + [failures == 0 ? "ALL PASS" : "\(failures) FAILED"]
            print(lines.joined(separator: "\n"))
            fflush(stdout)
            if let out = args.first(where: { $0.hasPrefix("--mac-sketch-selftest-out=") })?.dropFirst(26) {
                try? lines.joined(separator: "\n").write(toFile: String(out), atomically: true, encoding: .utf8)
            }
            exit(failures == 0 ? 0 : 1)
        }
    }

    @MainActor static func checks() -> [(Bool, String)] {
        var out: [(Bool, String)] = []
        let m = DesignModel()
        m.run("file.new", quiet: true)
        m.startSketch("XY")
        m.run("sketch.line", ["points": [[0, 0], [30, 10]]], quiet: true)
        m.tool = .select
        guard let line = m.sketchInfo?.curves.first(where: { $0.kind == "line" }) else {
            return [(false, "M-1 a sketch with one line opens")]
        }
        m.sketchSelection = [SketchPick(id: line.id, kind: .line)]
        let items = ConstraintRibbon.items(m)
        let h = items.first { $0.id == "horizontal" }, t = items.first { $0.id == "tangent" }
        out.append((h?.enabled == true && t?.enabled == false && items.count == SketchConstraintCatalog.order.count,
                    "M-1 the ribbon lists every constraint for one line: Horizontal enabled, Tangent disabled"))
        let pill = SketchPill.actions(m).map(\.id)
        out.append((pill.contains("constraint.horizontal") && !pill.contains("constraint.tangent") && pill.contains("delete"),
                    "M-1 the context pill offers the valid constraints (\(pill))"))

        let dofText = SketchPalette.dofText(m) ?? ""
        out.append((dofText.contains("DOF") || dofText == String(localized: "Under Defined"),
                    "M-3 the palette shows the DOF readout (\(dofText))"))
        let status = SketchStatusText.statusLine(m) ?? ""
        out.append((status.contains(String(localized: "Under Defined")), "M-11 the status bar says Under Defined while sketching (\(status))"))

        let before = m.sketchInfo?.glyphs.count ?? 0
        if let h { ConstraintRibbon.apply(h.entry, m) }
        let after = m.sketchInfo?.glyphs.count ?? 0
        out.append((after == before + 1 && m.sketchInfo?.glyphs.contains { $0.name == "Horizontal" } == true,
                    "M-1 Horizontal from the ribbon adds a constraint (\(before) to \(after))"))
        m.finishSketch()

        // A rectangle with every corner fixed is fully defined: the browser row shows the lock.
        m.startSketch("XY")
        m.run("sketch.rectangle.two_point", ["p0": [50, 0], "p1": [80, 20]], quiet: true)
        let points = m.sketchInfo?.points.map { SketchPick(id: $0.id, kind: .point) } ?? []
        m.sketchSelection = points
        _ = m.applyConstraint(id: "fix")
        let open = m.snapshot.active_sketch
        let live = m.sketchState
        m.finishSketch()
        if let id = open {
            let s = SketchDefinedStates.state(m, sketch: id)
            out.append((s?.fullyConstrained == true && SketchDefinedStates.rowSymbol(m, sketch: id) == "lock.fill",
                        "M-11 a fully constrained rectangle shows the lock in the browser (\(s.map(SketchStatusText.text) ?? "no state"), live \(live.map(SketchStatusText.text) ?? "none"))"))
        } else {
            out.append((false, "M-11 the rectangle sketch opens"))
        }
        if let first = m.snapshot.sketches.first, first.id != open {
            let s = SketchDefinedStates.state(m, sketch: first.id)
            out.append((s != nil && s?.fullyConstrained == false && SketchDefinedStates.rowSymbol(m, sketch: first.id) == "pencil.line",
                        "M-11 the under-defined line sketch keeps the pencil (\(s.map(SketchStatusText.text) ?? "no state"))"))
        }

        // M-5: the marking menu's OK follows the command dialog's rule.
        m.tool = .fillet
        let ok = MarkingWheel.overflow(m).first { $0.id == "ok" }
        out.append((ok != nil && ok?.enabled == false && !CommandDialog.canFinish(m),
                    "M-5 the marking menu OK is there and greyed while Fillet has no edge"))
        m.tool = .select
        out.append((!MarkingWheel.overflow(m).contains { $0.id == "ok" }, "M-5 no OK in the marking menu without a command"))
        return out
    }
}
#endif
