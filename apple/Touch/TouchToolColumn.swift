#if os(iOS)
import SwiftUI

// The iPad's left tool column (gaps T-4, T-5, T-17). One column whose content is a function of
// the selection and the tool state, as in the reference tablet layout:
// - nothing selected: Search, Sketch, Add, Transform, Tools (labels always on, the group's mode
//   in grey under each label);
// - a selection: Search, Deselect All, then the verbs the selection takes, More, Delete;
// - a tool running: Search, Deselect All and the running tool with its mode;
// - a sketch open: Exit Sketching first (subtitle = the sketch's name), the sketch tools, then
//   the slot the constraint column (T-2) fills.
// ViaForm names and SF Symbols only.

// MARK: - Context

/// What the column is drawn from: plain values, so the self test feeds it without a view.
struct TouchColumnContext: Equatable {
    var faces = 0
    var edges = 0
    var bodies = 0
    /// The single selected body's name ("Body 02"), for the Deselect All subtitle.
    var bodyName: String?
    var sketchOpen = false
    var sketchName: String?
    var tool: Tool = .select
    /// The running tool's mode or value ("10 mm", "Cut"), shown under its label.
    var toolMode: String?

    var hasSelection: Bool { faces + edges + bodies > 0 }

    init(faces: Int = 0, edges: Int = 0, bodies: Int = 0, bodyName: String? = nil, sketchOpen: Bool = false,
         sketchName: String? = nil, tool: Tool = .select, toolMode: String? = nil) {
        self.faces = faces
        self.edges = edges
        self.bodies = bodies
        self.bodyName = bodyName
        self.sketchOpen = sketchOpen
        self.sketchName = sketchName
        self.tool = tool
        self.toolMode = toolMode
    }

    @MainActor init(model: DesignModel) {
        faces = model.selection.filter(\.isFace).count
        edges = model.selection.filter(\.isEdge).count
        bodies = model.selectedBodies.count
        bodyName = model.selectedBodies.count == 1 ? model.selectedBodies.first : nil
        sketchOpen = model.sketchOpen
        if let id = model.snapshot.active_sketch {
            sketchName = model.snapshot.sketches.first(where: { $0.id == id })?.name
        }
        tool = model.tool
        if let v = model.tool.value, model.tool != .select {
            toolMode = VFFormat.value(model.toolValue, v.unit.isEmpty ? .none : VFUnit(symbol: v.unit))
        }
    }
}

/// The four top level groups after Search. Each one remembers its mode (the tool it last ran),
/// which a tap runs again; a long press lists the group.
enum TouchColumnGroup: String, CaseIterable, Identifiable {
    case sketch, add, transform, tools
    var id: String { rawValue }

    var title: String {
        switch self {
        case .sketch: String(localized: "Sketch")
        case .add: String(localized: "Add")
        case .transform: String(localized: "Transform")
        case .tools: String(localized: "Tools")
        }
    }

    var symbol: String {
        switch self {
        case .sketch: "pencil.and.outline"
        case .add: "plus.square.on.square"
        case .transform: "move.3d"
        case .tools: "wrench.and.screwdriver"
        }
    }

    var tools: [Tool] {
        switch self {
        case .sketch: [.sketch]
        case .add: Tool.primitiveTools
        case .transform: [.move, .mirror]
        case .tools: [.extrude, .revolve, .pressPull, .fillet, .chamfer, .shell, .union, .subtract, .intersect]
        }
    }

    var defaultMode: Tool { tools[0] }

    /// Where the group's mode is kept between launches.
    var storageKey: String { "viaform.touch.column.mode.\(rawValue)" }
}

/// One row of the column.
struct TouchColumnItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case search
        case group(TouchColumnGroup)
        case tool(Tool)
        case deselect
        case exitSketch
        case more
        /// Where the sketch constraint column (T-2) goes.
        case constraintSlot
        /// A verb from outside the design (Stress Here, Fly It), by its `ContextAction` id.
        case extra(String)
    }

    var kind: Kind
    var title: String
    var subtitle: String?
    var symbol: String
    var active = false
    var destructive = false
    /// Other modes of the same tool family (Rectangle: Two Point, Center), offered on long press.
    var modes: [Tool] = []

    var id: String {
        switch kind {
        case .search: "search"
        case let .group(g): "group." + g.rawValue
        case let .tool(t): "tool." + t.rawValue
        case .deselect: "deselect"
        case .exitSketch: "exitSketch"
        case .more: "more"
        case .constraintSlot: "constraints"
        case let .extra(id): "extra." + id
        }
    }

    var tool: Tool? { if case let .tool(t) = kind { t } else { nil } }
}

// MARK: - Layout (pure)

enum TouchColumnLayout {
    /// Sketch tools that share one row, the reference way: Rectangle (Two Point, Center,
    /// 3-Point), Circle (Center, 2-Point, 3-Point) and Tools (Project, Mirror, Rectangular and
    /// Circular Pattern). A tap runs the shown mode, a long press picks another.
    /// Line and Arc share "Line/Arc" (the reference's merged row), Polygon and Slot, Trim and
    /// Extend too, so the column fits a 768 point tall iPad without scrolling.
    static let families: [[Tool]] = [
        [.line, .arc],
        [.rectangle, .centerRectangle, .threePointRectangle],
        [.circle, .twoPointCircle, .threePointCircle],
        [.polygon, .slot],
        [.trim, .extend],
        [.project, .sketchMirror, .sketchRectPattern, .sketchCircPattern],
    ]

    /// The sketch column's rows in order (the reference's: Line/Arc, Spline, Rectangle, Circle,
    /// Ellipse, Polygon, Offset Edge, ..., Trim), each named by its family's first tool. Every
    /// tool of `Tool.sketchTools` and `Tool.moreSketchTools` is on one row.
    static let sketchRows: [Tool] = [.line, .spline, .rectangle, .circle, .ellipse, .polygon, .point, .offset,
                                     .sketchFillet, .project, .dimension, .trim]

    /// Where the sketch families' last modes are kept between launches.
    static let familyModesKey = "viaform.touch.column.sketchFamilies"

    static func decodeFamilyModes(_ raw: String) -> [Tool: Tool] {
        var out: [Tool: Tool] = [:]
        for pair in raw.split(separator: ";") {
            let kv = pair.split(separator: "=").map(String.init)
            if kv.count == 2, let k = Tool(rawValue: kv[0]), let v = Tool(rawValue: kv[1]) { out[k] = v }
        }
        return out
    }

    static func encodeFamilyModes(_ m: [Tool: Tool]) -> String {
        m.map { "\($0.key.rawValue)=\($0.value.rawValue)" }.sorted().joined(separator: ";")
    }

    /// Keeps `t` as its family's mode (the column row then shows it).
    static func rememberFamilyMode(_ t: Tool) {
        let family = family(of: t)
        guard family.count > 1 else { return }
        var m = decodeFamilyModes(UserDefaults.standard.string(forKey: familyModesKey) ?? "")
        m[family[0]] = t
        UserDefaults.standard.set(encodeFamilyModes(m), forKey: familyModesKey)
    }

    static func family(of t: Tool) -> [Tool] { families.first { $0.contains(t) } ?? [t] }

    /// A family's row title: Rectangle, Circle, Tools.
    static func familyTitle(_ family: [Tool]) -> String {
        switch family.first {
        case .project: String(localized: "Tools")
        case .circle: Tool.circle.touchLabel
        case .line: String(localized: "Line/Arc")
        case .polygon: String(localized: "Polygon/Slot")
        case .trim: String(localized: "Trim/Extend")
        default: family.first?.touchLabel ?? ""
        }
    }

    /// A family member's name on its row and in the mode pill: the mode for shape families
    /// (Center, 3-Point), the tool for merged rows (Line, Arc, Slot, Extend).
    static func familyModeName(_ t: Tool) -> String? {
        switch t {
        case .line, .arc, .polygon, .slot, .trim, .extend: t.touchLabel
        default: modeName(t)
        }
    }

    static func modeName(_ t: Tool) -> String? {
        switch t {
        case .rectangle: String(localized: "Two Point")
        case .centerRectangle: String(localized: "Center")
        case .threePointRectangle: String(localized: "3-Point")
        case .arc: String(localized: "Three Point")
        case .spline: String(localized: "Fit Point")
        case .polygon: String(localized: "Inscribed")
        case .slot: String(localized: "Center to Center")
        case .circle: String(localized: "Center")
        case .twoPointCircle: String(localized: "2-Point")
        case .threePointCircle: String(localized: "3-Point")
        case .project: String(localized: "Project")
        case .sketchMirror: String(localized: "Mirror")
        case .sketchRectPattern: String(localized: "Rectangular Pattern")
        case .sketchCircPattern: String(localized: "Circular Pattern")
        default: nil
        }
    }

    /// The column for `c`. `modes` holds each group's remembered tool; `extras` are verbs from
    /// outside the design, shown after the selection's own.
    /// `familyModes` holds each sketch family's last mode, by the family's first tool.
    static func items(_ c: TouchColumnContext, modes: [TouchColumnGroup: Tool] = [:], familyModes: [Tool: Tool] = [:],
                      extras: [(id: String, title: String, symbol: String)] = []) -> [TouchColumnItem] {
        let search = TouchColumnItem(kind: .search, title: String(localized: "Search"), symbol: "magnifyingglass")
        let more = TouchColumnItem(kind: .more, title: String(localized: "More"), symbol: "ellipsis.circle")
        var deselect = TouchColumnItem(kind: .deselect, title: String(localized: "Deselect All"), symbol: "xmark.circle")
        deselect.subtitle = selectionSubtitle(c)

        if c.sketchOpen {
            // Search, then Exit Sketching (subtitle = the sketch's name), as the reference.
            var out = [search, TouchColumnItem(kind: .exitSketch, title: String(localized: "Exit Sketching"),
                                       subtitle: c.sketchName, symbol: "checkmark.circle")]
            for t in sketchRows {
                let family = family(of: t)
                let current = family.contains(c.tool) ? c.tool : (familyModes[family[0]].flatMap { family.contains($0) ? $0 : nil } ?? family[0])
                out.append(TouchColumnItem(kind: .tool(current), title: family.count > 1 ? familyTitle(family) : current.touchLabel,
                                           subtitle: family.count > 1 ? familyModeName(current) : nil,
                                           symbol: current.symbol, active: family.contains(c.tool),
                                           modes: family.count > 1 ? family : []))
            }
            // The iPhone strip puts its constraint menu here; on the iPad the constraint column
            // stands on the panel edge and every tool is on a row, so there is no More.
            out.append(TouchColumnItem(kind: .constraintSlot, title: String(localized: "Constraints"), symbol: "lock"))
            return out
        }

        // A tool running: Search, Deselect All, the tool and its mode.
        if c.tool != .select {
            var out = [search]
            if c.hasSelection { out.append(deselect) }
            var running = toolItem(c.tool, active: true)
            running.subtitle = c.tool == .sketch ? String(localized: "Pick a plane or face") : c.toolMode
            out.append(running)
            return out
        }

        guard c.hasSelection else {
            var out = [search]
            for g in TouchColumnGroup.allCases {
                let mode = modes[g] ?? g.defaultMode
                out.append(TouchColumnItem(kind: .group(g), title: g.title,
                                           subtitle: g == .sketch ? String(localized: "On a plane") : mode.touchLabel,
                                           symbol: g.symbol))
            }
            return out
        }

        var verbs: [Tool]
        if c.bodies > 0 {
            verbs = [.move, .mirror, .shell]
            if c.bodies > 1 { verbs += [.union, .subtract, .intersect] }
            verbs += [.measure]
        } else if c.edges > 0, c.faces == 0 {
            verbs = [.fillet, .chamfer, .move, .measure]
        } else if c.faces == 1, c.edges == 0 {
            verbs = [.sketch, .pressPull, .move, .mirror, .shell, .measure]
        } else {
            verbs = [.move, .shell, .measure]
        }
        var out = [search, deselect] + verbs.map { toolItem($0) }
        out += extras.map { TouchColumnItem(kind: .extra($0.id), title: $0.title, symbol: $0.symbol) }
        out.append(more)
        // Delete takes bodies and faces; picked edges alone have nothing to delete.
        if c.bodies > 0 || c.faces > 0 {
            var del = toolItem(.delete)
            del.destructive = true
            out.append(del)
        }
        return out
    }

    private static func toolItem(_ t: Tool, active: Bool = false) -> TouchColumnItem {
        TouchColumnItem(kind: .tool(t), title: StageLabels.command(t.touchLabel), symbol: t.symbol, active: active)
    }

    /// "Body 02", "2 bodies", "1 face", "3 edges", "1 face & 2 edges".
    static func selectionSubtitle(_ c: TouchColumnContext) -> String? {
        if c.bodies == 1, let n = c.bodyName { return n }
        var parts: [String] = []
        if c.bodies > 0 { parts.append(TouchCount.bodies(c.bodies)) }
        if c.faces > 0 { parts.append(TouchCount.faces(c.faces)) }
        if c.edges > 0 { parts.append(TouchCount.edges(c.edges)) }
        return parts.isEmpty ? nil : parts.joined(separator: " & ")
    }
}

extension TouchColumnLayout {
    /// The column's tiles: Search, Deselect All, Exit Sketching, More and Delete each on a tile
    /// of their own, the runs of tools between them sharing one (the reference's grouping).
    /// The constraint slot is left out (the iPad draws the constraints on the panel edge).
    static func tiles(_ items: [TouchColumnItem]) -> [[TouchColumnItem]] {
        var out: [[TouchColumnItem]] = []
        var run: [TouchColumnItem] = []
        for it in items {
            switch it.kind {
            case .constraintSlot: continue
            case .search, .deselect, .exitSketch, .more:
                if !run.isEmpty { out.append(run); run = [] }
                out.append([it])
            default:
                if it.destructive {
                    if !run.isEmpty { out.append(run); run = [] }
                    out.append([it])
                } else {
                    run.append(it)
                }
            }
        }
        if !run.isEmpty { out.append(run) }
        return out
    }
}

/// Inflected counts ("1 edge", "2 edges"), through the string catalog.
enum TouchCount {
    private static func plain(_ s: AttributedString) -> String { String(s.characters) }
    static func bodies(_ n: Int) -> String { plain(AttributedString(localized: "^[\(n) body](inflect: true)")) }
    static func faces(_ n: Int) -> String { plain(AttributedString(localized: "^[\(n) face](inflect: true)")) }
    static func edges(_ n: Int) -> String { plain(AttributedString(localized: "^[\(n) edge](inflect: true)")) }
}

// MARK: - Column view

/// The adaptive tool column. `axis: .horizontal` gives the same entries as a scrolling strip for
/// the iPhone's bottom row.
struct TouchToolColumn: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    /// Search, More: opens the command palette.
    let showPalette: () -> Void
    var axis: Axis = .vertical
    /// Verbs from outside the design (the root view's Stress Here, Fly It).
    var extra: [ContextAction] = []
    /// The constraint column of an open sketch (T-2). Nil keeps the slot empty.
    var constraintSlot: AnyView?
    var maxHeight: CGFloat = 720
    /// Tiles under the column on the iPad: Delete in a sketch, Done, the options and Cancel of
    /// a running tool.
    var footer: AnyView?

    @AppStorage(TouchColumnGroup.sketch.storageKey) private var sketchMode = Tool.sketch.rawValue
    @AppStorage(TouchColumnGroup.add.storageKey) private var addMode = Tool.box.rawValue
    @AppStorage(TouchColumnGroup.transform.storageKey) private var transformMode = Tool.move.rawValue
    @AppStorage(TouchColumnGroup.tools.storageKey) private var toolsMode = Tool.extrude.rawValue
    /// Each sketch family's last mode ("rectangle=threePointRectangle;circle=circle").
    @AppStorage(TouchColumnLayout.familyModesKey) private var familyModesRaw = ""

    private var modes: [TouchColumnGroup: Tool] {
        var out: [TouchColumnGroup: Tool] = [:]
        for g in TouchColumnGroup.allCases {
            let raw: String = switch g {
            case .sketch: sketchMode
            case .add: addMode
            case .transform: transformMode
            case .tools: toolsMode
            }
            out[g] = Tool(rawValue: raw).flatMap { g.tools.contains($0) ? $0 : nil } ?? g.defaultMode
        }
        return out
    }

    var body: some View {
        let items = TouchColumnLayout.items(TouchColumnContext(model: model), modes: modes,
                                            familyModes: TouchColumnLayout.decodeFamilyModes(familyModesRaw),
                                            extras: extra.map { ($0.id, $0.title, $0.symbol) })
        Group {
            if axis == .vertical {
                // Sized to fit (the root picks the row height); scrolls only in a window too
                // short for the smallest rows.
                ViewThatFits(in: .vertical) {
                    railTiles(items)
                    ScrollView(.vertical, showsIndicators: false) { railTiles(items) }
                        .scrollBounceBehavior(.basedOnSize)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: VFSpace.xxs) { rows(items) }.padding(VFSpace.s)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        // The reference's column floats on the canvas with no card; the iPhone strip keeps one.
        .background { if axis == .horizontal { Color.clear.vfSurface(.control, radius: VFRadius.touchFloating) } }
        .vfAnimation(.snappy(duration: VFMotion.fast), value: items.map(\.id))
    }

    /// The iPad column: one white tile per group of rows, labels floating beside the icons.
    private func railTiles(_ items: [TouchColumnItem]) -> some View {
        let tiles = TouchColumnLayout.tiles(items)
        return VStack(alignment: .leading, spacing: TouchRail.gap) {
            ForEach(tiles, id: \.first!.id) { tile in
                TouchRailGroup { rows(tile) }
            }
            if let footer { footer }
        }
    }

    @ViewBuilder private func rows(_ items: [TouchColumnItem]) -> some View {
        ForEach(items) { it in
            switch it.kind {
            case .constraintSlot:
                if let constraintSlot { constraintSlot }
            case let .group(g):
                groupRow(it, g)
            default:
                if it.modes.count > 1 { modesRow(it) }
                else if axis == .vertical {
                    Button { run(it) } label: { label(it) }
                        .buttonStyle(.touchRail)
                        .hoverEffect(.highlight)
                        .accessibilityLabel(it.title)
                        .accessibilityValue(it.subtitle ?? "")
                        .accessibilityAddTraits(it.active ? .isSelected : [])
                } else {
                    TouchColumnRow(item: it, compact: true) { run(it) }
                }
            }
        }
    }

    /// A group: tap runs its mode, long press lists every tool of the group.
    private func groupRow(_ it: TouchColumnItem, _ g: TouchColumnGroup) -> some View {
        Menu {
            ForEach(g.tools) { t in
                Button(StageLabels.command(t.touchLabel), systemImage: t.symbol) { pick(t, in: g) }
            }
            if g == .tools {
                Divider()
                Button("All Commands…", systemImage: "magnifyingglass", action: showPalette)
            }
        } label: {
            label(it)
        } primaryAction: {
            pick(modes[g] ?? g.defaultMode, in: g)
        }
        .menuStyle(.button)
        .modifier(TouchRailPress(rail: axis == .vertical))
        .hoverEffect(.highlight)
        .accessibilityLabel(it.title)
        .accessibilityValue(it.subtitle ?? "")
        .accessibilityHint(Text("Long press for every tool of the group"))
    }

    /// A tool with modes (Rectangle): tap runs the shown mode, long press picks another.
    private func modesRow(_ it: TouchColumnItem) -> some View {
        Menu {
            ForEach(it.modes) { t in
                Button(TouchColumnLayout.familyModeName(t) ?? t.touchLabel, systemImage: t.symbol) {
                    var m = TouchColumnLayout.decodeFamilyModes(familyModesRaw)
                    m[TouchColumnLayout.family(of: t)[0]] = t
                    familyModesRaw = TouchColumnLayout.encodeFamilyModes(m)
                    TouchToolActions.activate(t, model)
                }
            }
        } label: {
            label(it)
        } primaryAction: {
            run(it)
        }
        .menuStyle(.button)
        .modifier(TouchRailPress(rail: axis == .vertical))
        .hoverEffect(.highlight)
        .accessibilityLabel(it.title)
        .accessibilityValue(it.subtitle ?? "")
        .accessibilityAddTraits(it.active ? .isSelected : [])
    }

    /// The row's look: a rail row on the iPad (the armed sketch tool's icon on a grey square,
    /// the running tool's label on a plate), the chip row in the iPhone strip.
    @ViewBuilder private func label(_ it: TouchColumnItem) -> some View {
        if axis == .vertical {
            TouchRailRow(symbol: it.symbol, title: it.title, subtitle: it.subtitle, active: it.active,
                         destructive: it.destructive, plate: it.active && !model.sketchOpen)
        } else {
            TouchColumnRowLabel(item: it, compact: true)
        }
    }

    private func pick(_ t: Tool, in g: TouchColumnGroup) {
        switch g {
        case .sketch: sketchMode = t.rawValue
        case .add: addMode = t.rawValue
        case .transform: transformMode = t.rawValue
        case .tools: toolsMode = t.rawValue
        }
        TouchToolActions.activate(t, model)
    }

    private func run(_ it: TouchColumnItem) {
        switch it.kind {
        case .search, .more: showPalette()
        case .deselect:
            model.selection = []
            model.selectedBodies = []
            if model.tool != .select, !model.tool.isSketchTool { model.cancelTool() }
        case .exitSketch: model.finishSketch()
        case let .tool(t):
            if model.sketchOpen, t.isSketchTool, model.tool == t { model.tool = .select } else { TouchToolActions.activate(t, model) }
        case let .extra(id): extra.first { $0.id == id }?.run()
        case .group, .constraintSlot: break
        }
    }
}

/// One row: icon chip, label, grey mode subtitle. 48 points tall, accent when active.
struct TouchColumnRow: View {
    let item: TouchColumnItem
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) { TouchColumnRowLabel(item: item, compact: compact) }
            .buttonStyle(.vfTouch)
            .accessibilityLabel(item.title)
            .accessibilityValue(item.subtitle ?? "")
            .accessibilityAddTraits(item.active ? .isSelected : [])
    }
}

struct TouchColumnRowLabel: View {
    @Environment(\.viaFormTheme) private var theme
    let item: TouchColumnItem
    var compact = false

    var body: some View {
        let ink = item.active ? theme.onAccent : (item.destructive ? theme.danger : theme.ink)
        HStack(spacing: VFSpace.m) {
            Group {
                if let t = item.tool { ToolChipIcon(tool: t, size: 20) }
                else { Image(systemName: item.symbol).font(VFFont.glyph(18, weight: .medium)) }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(VFFont.rowEmphasis).lineLimit(1).minimumScaleFactor(0.8)
                if let s = item.subtitle {
                    Text(s).font(VFFont.micro).foregroundStyle(item.active ? theme.onAccent.opacity(0.8) : theme.inkSecondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            if !compact { Spacer(minLength: 0) }
        }
        .foregroundStyle(ink)
        .padding(.horizontal, VFSpace.m)
        .frame(minWidth: compact ? 96 : nil, maxWidth: compact ? nil : .infinity, minHeight: VFSize.touchTarget, alignment: .leading)
        .background(item.active ? theme.accent : .clear, in: RoundedRectangle(cornerRadius: VFRadius.card, style: .continuous))
        .contentShape(Rectangle())
    }
}
#endif
