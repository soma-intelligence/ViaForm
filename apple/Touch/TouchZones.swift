#if os(iOS)
import SwiftUI
import simd

// The iPad's screen zones (gap T-6), each a view the root view places:
//   top left      TouchWorkspaceZone   Modeling (the workspace switch), Items under it
//   top centre    TouchTitlePill       home, title with its saved check, Share, "..."
//   top right     TouchViewZone        view cube and the mini rail, History under them
//                 TouchSnapRail        snapping, grid size, view options, a one-tile rail (T-16)
//   bottom left   TouchViewModeStack   Construction (sketch), Isolate, Section View, Measure
//                 TouchUndoCircles     undo and redo tiles
//   bottom centre TouchSelectionReadout "1 edge  5 mm" with (i) (T-12)
//   top centre    NormalToSketchPill   when the view leaves the open sketch's plane (T-17)
// The left-handed setting (T-18) swaps the left and right zones: see `TouchHandedness`. The
// tiles and floating labels are `TouchRail` (TouchRail.swift).

// MARK: - Handedness

/// The left-handed layout: the tool column and the bottom-left stack move right, the view cube,
/// History and the rail move left. Kept per device.
enum TouchHandedness {
    static let key = "viaform.touch.leftHanded"

    /// The edge the tool column and the bottom-left stack ride.
    static func toolEdge(leftHanded: Bool) -> HorizontalEdge { leftHanded ? .trailing : .leading }
    /// The edge the view cube, History, the rail and the side cards ride.
    static func panelEdge(leftHanded: Bool) -> HorizontalEdge { leftHanded ? .leading : .trailing }
    static func toolAlignment(leftHanded: Bool) -> HorizontalAlignment { leftHanded ? .trailing : .leading }
    static func panelAlignment(leftHanded: Bool) -> HorizontalAlignment { leftHanded ? .leading : .trailing }
}

// MARK: - Zone button

/// A labelled rail button: the icon on its tile, the label and a grey state ("Off", "On")
/// floating beside it. Sits in a `TouchRailGroup`.
struct TouchZoneButton: View {
    let symbol: String
    let title: String
    var subtitle: String?
    var on = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TouchRailRow(symbol: symbol, title: title, subtitle: subtitle, active: on)
        }
        .buttonStyle(.touchRail)
        .hoverEffect(.highlight)
        .accessibilityLabel(title)
        .accessibilityValue(subtitle ?? "")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Top left

/// The workspace switch ("Modeling") with Items under it, one tile. Items slides its panel in
/// from the tool edge.
struct TouchWorkspaceZone: View {
    let flow: FlowModel
    let stage: Workspace
    var compact = false
    @Binding var workspacesOpen: Bool
    @Binding var side: TouchSideCard?
    /// Items only where there is a design to list.
    var showsItems = true
    let open: (Workspace) -> Void

    var body: some View {
        TouchRailGroup {
            TouchWorkspaceButton(flow: flow, stage: stage, compact: compact, plain: true, isOpen: $workspacesOpen, open: open)
            if showsItems {
                TouchZoneButton(symbol: "square.stack.3d.up.fill", title: TouchSideCard.items.title, on: side == .items) {
                    side = side == .items ? nil : .items
                }
            }
        }
        .environment(\.touchRailRow, TouchRail.topRow)
    }
}

// MARK: - Top centre

/// The title pill: home (the project browser), the title with its saved check, Share and "...".
/// Nothing else lives at the top centre; jobs join it only while one runs.
struct TouchTitlePill: View {
    @Environment(\.viaFormTheme) private var theme
    let flow: FlowModel
    let stage: Workspace
    let title: String
    var compact = false
    let showBrowser: () -> Void
    let showPalette: () -> Void
    let showShortcuts: () -> Void
    /// `TouchShareMenu(prominent: true, ...)`.
    let share: AnyView
    @AppStorage(TouchHandedness.key) private var leftHanded = false

    var body: some View {
        HStack(spacing: VFSpace.s) {
            Button(action: showBrowser) {
                Image(systemName: "house.fill").font(VFFont.icon(15, weight: .medium)).foregroundStyle(theme.ink)
                    .frame(width: 36, height: TouchRail.titleHeight).contentShape(Rectangle())
            }
            .buttonStyle(.vfTouch)
            .hoverEffect(.highlight)
            .accessibilityLabel(Text("Projects"))
            HStack(spacing: VFSpace.xs) {
                Text(title).font(VFFont.row.weight(.medium)).foregroundStyle(theme.ink).lineLimit(1)
                    .frame(maxWidth: compact ? 140 : 220)
                    .fixedSize(horizontal: true, vertical: false)
                // Saved: the title's check, as the reference's cloud check beside the name.
                Image(systemName: "checkmark.circle.fill").font(VFFont.icon(13)).foregroundStyle(theme.inkTertiary)
                    .accessibilityLabel(Text("Saved"))
            }
            .accessibilityElement(children: .combine)
            if !flow.queue.isEmpty { TouchJobsButton(flow: flow) }
            share
            Menu {
                Button("Search Commands…", systemImage: "magnifyingglass", action: showPalette)
                Button("Keyboard Shortcuts", systemImage: "keyboard", action: showShortcuts)
                Divider()
                Toggle(isOn: $leftHanded) { Label("Left-Handed Layout", systemImage: "hand.raised") }
            } label: {
                Image(systemName: "ellipsis.circle").font(VFFont.icon(17)).foregroundStyle(theme.ink)
                    .frame(width: 36, height: TouchRail.titleHeight).contentShape(Rectangle())
            }
            .hoverEffect(.highlight)
            .accessibilityLabel(Text("More"))
        }
        .padding(.horizontal, VFSpace.s)
        .frame(height: TouchRail.titleHeight)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: TouchRail.radius, style: .continuous))
        .shadow(color: TouchRailColors(theme: theme).shadow, radius: 4, y: 1)
    }
}

// MARK: - Top right

/// The view cube with the snapping rail beside it, and History under them (a clock tile with
/// its floating label).
struct TouchViewZone: View {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.touchRailEdge) private var edge
    let model: DesignModel
    @Binding var side: TouchSideCard?
    @Binding var perspective: Bool
    var showsHistory = true

    var body: some View {
        VStack(alignment: edge == .trailing ? .trailing : .leading, spacing: TouchRail.gap) {
            HStack(alignment: .top, spacing: TouchRail.gap) {
                if edge == .leading { TouchSnapRail(model: model, perspective: $perspective) }
                ViewCube(model: model, size: TouchRail.cubeDraw)
                    .frame(width: TouchRail.cubeDraw, height: TouchRail.cubeDraw)
                if edge == .trailing { TouchSnapRail(model: model, perspective: $perspective) }
            }
            if showsHistory {
                TouchRailGroup {
                    TouchZoneButton(symbol: "clock", title: TouchSideCard.history.title, on: side == .history) {
                        side = side == .history ? nil : .history
                    }
                }
                .environment(\.touchRailRow, TouchRail.tile)
            }
        }
    }
}

/// "View normal to" through the engine (`view.normal_to`), which turns to the selected planar face.
enum TouchNormalTo {
    /// Turns the view to the first picked face. False when nothing planar is picked.
    @MainActor static func selection(_ model: DesignModel) -> Bool {
        guard case let .face(mesh, _, p, _)? = model.selection.first(where: \.isFace), mesh < model.scene.meshes.count else { return false }
        return apply(model, body: model.scene.meshes[mesh].body, point: p)
    }

    /// Selects the face of `body` at `point` in the engine, asks `view.normal_to` for the camera
    /// and takes it.
    @MainActor static func apply(_ model: DesignModel, body: String, point p: SIMD3<Double>) -> Bool {
        do {
            _ = try model.engine.execute("select.set", ["items": [["type": "face", "body": body, "point": [p.x, p.y, p.z]]]])
            let r = try model.engine.execute("view.normal_to", ["camera": model.camera.dictionary])
            guard let cam = (r as? [String: Any])?["camera"],
                  let data = try? JSONSerialization.data(withJSONObject: cam),
                  let c = try? JSONDecoder().decode(OrbitCamera.self, from: data) else { return false }
            model.camera = c
            model.cameraChanged(final: true)
            return true
        } catch {
            return false
        }
    }

    /// Turns the view square to the open sketch. The engine's `view.normal_to` only takes a
    /// selected face or named plane, not the active sketch, so this turns the camera along the
    /// sketch plane's normal (the same turn `sketch.create` makes on entry).
    @MainActor static func sketch(_ model: DesignModel) {
        guard let pl = model.sketchPlane else { return }
        model.look(along: pl.normal)
    }

    /// The view has left the plane: the eye is no longer square to it (about 5 degrees off).
    static func isOffPlane(back: SIMD3<Double>, normal: SIMD3<Double>) -> Bool {
        guard simd_length(back) > 1e-9, simd_length(normal) > 1e-9 else { return false }
        return abs(simd_dot(simd_normalize(back), simd_normalize(normal))) < 0.996
    }
}

/// "Normal to Sketch": a dark pill at the top centre while a sketch is open and the view has
/// turned away from its plane (T-17).
struct NormalToSketchPill: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel

    var body: some View {
        let _ = (model.camera.yaw, model.camera.pitch)
        if model.sketchOpen, let pl = model.sketchPlane, TouchNormalTo.isOffPlane(back: model.camera.back, normal: pl.normal) {
            Button { TouchNormalTo.sketch(model) } label: {
                Label("Normal to Sketch", systemImage: "viewfinder")
                    .font(VFFont.rowEmphasis)
                    .foregroundStyle(theme.onAccent)
                    .padding(.horizontal, VFSpace.xl)
                    .frame(minHeight: VFSize.touchTarget)
                    .background(Capsule().fill(theme.ink))
                    .contentShape(Capsule())
            }
            .buttonStyle(.vfTouch)
            .accessibilityHint(Text("Turns the view square to the sketch plane"))
            .vfTransition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

// MARK: - Snapping and grid rail (T-16)


extension ViewportTheme {
    /// The viewport theme with the grid shown or hidden (the rail's grid switch).
    func touchGrid(_ visible: Bool) -> ViewportTheme {
        var t = self
        if !visible { t.gridOpacity = 0 }
        return t
    }
}

/// The mini rail at the top right, one tile of three icons: the snapping menu (magnet), the
/// grid chip with the grid size (a tap shows or hides the grid through `view.grid`), and the
/// view options (views, perspective, the selection filter).
struct TouchSnapRail: View {
    @Environment(\.viaFormTheme) private var theme
    @ObservedUnits private var units
    let model: DesignModel
    @Binding var perspective: Bool
    /// The grid's visibility: the one `SketchDisplaySettings.gridKey` the Mac Sketch Palette's
    /// Sketch Grid also writes (both send `view.grid`).
    @AppStorage(SketchDisplaySettings.gridKey) private var gridVisible = true
    @AppStorage(SketchSnapSettings.geometryKey) private var snapGeometry = true
    @AppStorage(SketchSnapSettings.snapToGridKey) private var snapGrid = true
    /// The master switch (the Sketch Palette's Snap, shared with the Mac).
    @AppStorage(SketchSnapSettings.snapKey) private var snapOn = true

    var body: some View {
        let _ = (units, model.camera.distance)
        let snapping = snapOn && (snapGeometry || snapGrid)
        VStack(spacing: 0) {
            Menu {
                Section("Snapping") {
                    Toggle(isOn: $snapOn) { Label("Snap", systemImage: "scope") }
                    Toggle(isOn: $snapGeometry) { Label("Points and Curves", systemImage: "smallcircle.filled.circle") }
                    Toggle(isOn: $snapGrid) { Label("Grid", systemImage: "grid") }
                }
            } label: {
                Image(systemName: snapping ? "dot.scope" : "scope")
                    .font(VFFont.icon(16, weight: .medium))
                    .foregroundStyle(snapping ? theme.ink : theme.inkTertiary)
                    .frame(width: TouchRail.tile, height: TouchRail.railRow).contentShape(Rectangle())
            }
            .hoverEffect(.highlight)
            .accessibilityLabel(Text("Snapping"))
            Button {
                gridVisible.toggle()
                Self.setGrid(gridVisible, model)
            } label: {
                VStack(spacing: 0) {
                    Image(systemName: "lock.fill").font(VFFont.icon(9, weight: .semibold))
                    Text(VFFormat.lengthSignificant(model.gridStep, digits: 2)).font(VFFont.micro).lineLimit(1).minimumScaleFactor(0.6)
                }
                .foregroundStyle(gridVisible ? theme.ink : theme.inkTertiary)
                .frame(width: TouchRail.tile, height: TouchRail.railRow).contentShape(Rectangle())
            }
            .buttonStyle(.touchRail)
            .accessibilityLabel(Text("Grid"))
            .accessibilityValue(gridVisible ? String(localized: "Shown, \(VFFormat.length(model.gridStep)) squares") : String(localized: "Hidden"))
            Menu {
                Button("Home View", systemImage: "house") { model.setView(.iso) }
                Toggle("Perspective", isOn: $perspective)
                Button("Zoom to Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") { model.zoomToFit() }
                if model.selection.contains(where: \.isFace) {
                    Button("Normal to Selection", systemImage: "viewfinder") { _ = TouchNormalTo.selection(model) }
                }
                Section("Views") {
                    ForEach(StandardView.allCases, id: \.self) { v in
                        Button(v == .iso ? String(localized: "Isometric") : v.rawValue.capitalized) { model.setView(v) }
                    }
                }
                Picker(selection: Binding(get: { model.selectionFilter }, set: { model.selectionFilter = $0 })) {
                    ForEach(SelectionFilter.allCases) { f in Label(f.title, systemImage: f.symbol).tag(f) }
                } label: {
                    Label("Select", systemImage: "line.3.horizontal.decrease.circle")
                }
                .pickerStyle(.menu)
            } label: {
                Image(systemName: "rotate.3d")
                    .font(VFFont.icon(16, weight: .medium))
                    .foregroundStyle(model.selectionFilter == .auto ? theme.ink : theme.accentText)
                    .frame(width: TouchRail.tile, height: TouchRail.railRow).contentShape(Rectangle())
            }
            .hoverEffect(.highlight)
            .accessibilityLabel(Text("View options"))
        }
        .background(theme.panel, in: RoundedRectangle(cornerRadius: TouchRail.radius, style: .continuous))
        .shadow(color: TouchRailColors(theme: theme).shadow, radius: 4, y: 1)
    }

    /// `view.grid {on}`: the engine validates and echoes it; the viewport hides its grid through
    /// `ViewportTheme.touchGrid`.
    @MainActor @discardableResult
    static func setGrid(_ on: Bool, _ model: DesignModel) -> Bool {
        ((try? model.engine.execute("view.grid", ["on": on])) as? [String: Any])?["on"] as? Bool == on
    }
}

// MARK: - Bottom left

/// Undo and redo, two square tiles side by side.
struct TouchUndoCircles: View {
    let target: TouchUndoTarget
    let stageTitle: String
    let undo: () -> Void
    let redo: () -> Void

    var body: some View {
        HStack(spacing: TouchRail.gap) {
            tile("arrow.uturn.backward", target.undoName.map { String(localized: "Undo \($0)") } ?? String(localized: "Undo"),
                 enabled: target.canUndo, action: undo)
                .vfDisabled(!target.canUndo, reason: String(localized: "Nothing to undo in \(stageTitle)"))
            tile("arrow.uturn.forward", String(localized: "Redo"), enabled: target.canRedo, action: redo)
                .vfDisabled(!target.canRedo, reason: String(localized: "Nothing to redo in \(stageTitle)"))
        }
    }

    private func tile(_ symbol: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { TouchRailSquare(symbol: symbol, enabled: enabled) }
            .buttonStyle(.touchRail)
            .hoverEffect(.highlight)
            .help(label)
            .accessibilityLabel(label)
    }
}

/// Construction (only while sketching), Isolate, Section View and Measure, one tile, with their
/// state in grey under each label.
struct TouchViewModeStack: View {
    var sectionOn: Bool
    var isolateOn: Bool
    /// Shown while a sketch is open; nil hides the row.
    var construction: Binding<Bool>?
    /// Isolate shows with a selection, in a sketch, or while it is on (the reference hides it
    /// with nothing selected).
    var showsIsolate = true
    let toggleSection: () -> Void
    let toggleIsolate: () -> Void
    let measure: () -> Void

    var body: some View {
        TouchRailGroup {
            if let construction {
                TouchZoneButton(symbol: "point.topleft.down.to.point.bottomright.curvepath", title: String(localized: "Construction"),
                                subtitle: state(construction.wrappedValue), on: construction.wrappedValue) { construction.wrappedValue.toggle() }
            }
            if showsIsolate || isolateOn {
                TouchZoneButton(symbol: "circle.dashed.inset.filled", title: String(localized: "Isolate"), subtitle: state(isolateOn),
                                on: isolateOn, action: toggleIsolate)
            }
            TouchZoneButton(symbol: "square.split.1x2.fill", title: String(localized: "Section View"), subtitle: state(sectionOn),
                            on: sectionOn, action: toggleSection)
            TouchZoneButton(symbol: "ruler", title: String(localized: "Measure"), action: measure)
        }
    }

    /// Rows the stack takes (for the rail's row height).
    static func rows(construction: Bool, isolate: Bool) -> Int { 2 + (construction ? 1 : 0) + (isolate ? 1 : 0) }

    private func state(_ on: Bool) -> String { on ? String(localized: "On") : String(localized: "Off") }
}

// MARK: - Selection readout (T-12)

/// What the readout says: the selection ("1 edge", "Body 02") and its measure ("5 mm").
struct TouchReadout: Equatable {
    var title: String
    var value: String?
}

/// One picked face or edge, as `inspect.measure` takes it.
struct TouchMeasureItem: Equatable {
    var face: Bool
    var body: String
    var point: SIMD3<Double>

    var json: [String: Any] { ["type": face ? "face" : "edge", "body": body, "point": [point.x, point.y, point.z]] }
}

enum TouchMeasure {
    /// The selection's picks with their body names (the scene's meshes name them).
    @MainActor static func items(_ model: DesignModel) -> [TouchMeasureItem] {
        model.selection.compactMap { p in
            guard p.mesh < model.scene.meshes.count else { return nil }
            return TouchMeasureItem(face: p.isFace, body: model.scene.meshes[p.mesh].body, point: p.point)
        }
    }

    @MainActor static func readout(_ model: DesignModel) -> TouchReadout? {
        readout(engine: model.engine, items: items(model), bodies: model.selectedBodies.sorted())
    }

    /// Measures through `inspect.measure`: bodies by name (volume), one or two items (length,
    /// area, diameter, distance, angle), or more items one by one (summed when all alike).
    @MainActor static func readout(engine: CADEngine, items: [TouchMeasureItem], bodies: [String]) -> TouchReadout? {
        let c = TouchColumnContext(faces: items.filter(\.face).count, edges: items.filter { !$0.face }.count,
                                   bodies: bodies.count, bodyName: bodies.count == 1 ? bodies.first : nil)
        guard let title = TouchColumnLayout.selectionSubtitle(c) else { return nil }
        func measure(_ p: [String: Any]) -> [String: Any]? { (try? engine.execute("inspect.measure", p)) as? [String: Any] }

        if !bodies.isEmpty, items.isEmpty {
            let r = measure(["bodies": bodies])
            let total = (r?["total"] as? [String: Any])?["volume_mm3"] as? Double
            return TouchReadout(title: title, value: total.map { VFFormat.volume($0) })
        }
        if items.count == 1 || items.count == 2, bodies.isEmpty {
            return TouchReadout(title: title, value: measure(["items": items.map(\.json)]).flatMap { value(from: $0, pair: items.count == 2) })
        }
        guard bodies.isEmpty, items.count <= 24 else { return TouchReadout(title: title, value: nil) }
        let alike = items.allSatisfy { $0.face == items[0].face }
        guard alike else { return TouchReadout(title: title, value: nil) }
        var sum = 0.0
        for it in items {
            guard let r = measure(["items": [it.json]]), let first = (r["items"] as? [[String: Any]])?.first,
                  let v = first[it.face ? "area_mm2" : "length_mm"] as? Double else { return TouchReadout(title: title, value: nil) }
            sum += v
        }
        return TouchReadout(title: title, value: items[0].face ? VFFormat.area(sum) : VFFormat.length(sum))
    }

    /// The words for one `inspect.measure {items}` reply.
    static func value(from r: [String: Any], pair: Bool) -> String? {
        if pair {
            var parts: [String] = []
            if let d = r["distance_mm"] as? Double { parts.append(VFFormat.length(d)) }
            if let a = r["angle_deg"] as? Double { parts.append(VFFormat.angle(a)) }
            return parts.isEmpty ? nil : parts.joined(separator: "  ")
        }
        if let d = r["diameter"] as? Double { return "⌀ " + VFFormat.length(d) }
        guard let first = (r["items"] as? [[String: Any]])?.first else { return nil }
        if let l = first["length_mm"] as? Double { return VFFormat.length(l) }
        if let a = first["area_mm2"] as? Double { return VFFormat.area(a) }
        return nil
    }
}

/// The bottom centre readout: the selection and its measure in small grey words on the canvas
/// ("1 edge  5 mm"), with (i) for the selection's details. Nothing without a selection.
struct TouchSelectionReadout: View {
    @Environment(\.viaFormTheme) private var theme
    @ObservedUnits private var units
    let model: DesignModel
    let showInspector: () -> Void
    @State private var readout: TouchReadout?

    /// Picked sketch entities and glyphs, while a sketch is open: "2 lines & 1 constraint".
    private var sketchTitle: String? {
        model.sketchOpen ? TouchSketchReadout.title(model.sketchSelection) : nil
    }

    private var key: String {
        let picks = model.selection.map { "\($0.mesh):\($0.isFace):\($0.point.x),\($0.point.y),\($0.point.z)" }
        return picks.joined(separator: ";") + "|" + model.selectedBodies.sorted().joined(separator: ",") + "|\(model.snapshot.revision)|\(units)"
    }

    var body: some View {
        // A ZStack that is always there, so the measure task runs before anything is shown.
        ZStack {
            Color.clear.frame(width: 1, height: TouchRail.readoutHeight)
            if let sketchTitle {
                line(sketchTitle, value: nil)
            } else if let readout, !model.selection.isEmpty || !model.selectedBodies.isEmpty {
                line(readout.title, value: readout.value)
            }
        }
        .task(id: key) { readout = TouchMeasure.readout(model) }
    }

    private func line(_ title: String, value: String?) -> some View {
        HStack(spacing: VFSpace.l) {
            Text(title)
            if let value {
                Label { Text(value) } icon: { Image(systemName: "ruler").font(VFFont.icon(10)) }
                    .labelStyle(.titleAndIcon)
            }
            Button(action: showInspector) {
                Image(systemName: "info.circle").font(VFFont.icon(14)).foregroundStyle(theme.inkSecondary)
                    .frame(width: 32, height: TouchRail.readoutHeight).contentShape(Rectangle())
            }
            .buttonStyle(.vfTouch)
            .accessibilityLabel(Text("Details"))
        }
        .font(VFFont.small)
        .foregroundStyle(theme.inkSecondary)
        .lineLimit(1)
        .frame(minHeight: TouchRail.readoutHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Selected: \(title)"))
    }
}
#endif
