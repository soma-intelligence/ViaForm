#if os(iOS)
import SwiftUI

// The iPad History sidebar after Shapr3D (docs/research/cad-ui/shapr3d-ipad.md 5.1): variables at
// the top (B-10), then one row per step. Tap or the chevron opens the row in place with its values
// (T-1, Edit Feature); the grip drags a row to reorder it; the grey Breakpoint bar is the history
// marker and drags too; rows below it are greyed. A long press opens the row menu: Edit, Rename,
// Insert Breakpoint, Roll Back Here, Suppress, Delete. "Related to Selection" narrows the list to
// the steps of the selected bodies. Every action is an engine command (PanelOps).

/// The actions of one timeline step, shared by the context menus and the visible menus of the
/// history list and the history bar (P1-28). Delete offers Undo in a toast (P0-10).
struct TimelineStepActions: View {
    let model: DesignModel
    let index: Int
    let feature: DesignSnapshot.Feature
    let toasts: ToastCenter?

    var body: some View {
        Button("Roll Back Here", systemImage: "backward.end") { model.rollTimeline(to: index) }
        Button(feature.suppressed == true ? String(localized: "Unsuppress") : String(localized: "Suppress"),
               systemImage: feature.suppressed == true ? "eye" : "eye.slash") {
            model.run("timeline.suppress", ["feature": feature.id])
        }
        Button(String(localized: "Delete \(feature.name)"), systemImage: "trash", role: .destructive) {
            Self.delete(feature, model: model, toasts: toasts)
        }
    }

    @MainActor static func delete(_ f: DesignSnapshot.Feature, model: DesignModel, toasts: ToastCenter?) {
        guard model.run("timeline.delete", ["feature": f.id]) != nil else { return }
        let step = DesignStep(model)
        toasts?.show(String(localized: "Deleted \(f.name)"), systemImage: "trash", actionTitle: String(localized: "Undo")) { step.undo() }
    }
}

/// Steps the roll marker with the arrow keys of a hardware keyboard.
struct TimelineArrowKeys: ViewModifier {
    let model: DesignModel
    let keys: (back: KeyEquivalent, forward: KeyEquivalent)

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(keys: [keys.back, keys.forward]) { press in
                let count = model.snapshot.timeline.count
                guard count > 0 else { return .ignored }
                let now = min(max(model.snapshot.marker, 0), count)
                let next = press.key == keys.back ? max(0, now - 1) : min(count, now + 1)
                if next != now { model.rollTimeline(to: next) }
                return .handled
            }
    }
}

/// The History sidebar: variables, then the steps with the breakpoint bar.
struct HistorySidebar: View {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.vfToasts) private var toasts
    let model: DesignModel
    /// A panel over the viewport (iPad); false inside a sheet (iPhone).
    var floating = true

    @State private var expanded: Int?
    @State private var renaming: Int?
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool
    @State private var relatedOnly = false
    @State private var related: Set<Int> = []
    @State private var mids: [HistoryEntry: CGFloat] = [:]
    @State private var dragging: HistoryEntry?
    @State private var dragOffset: CGFloat = 0
    @State private var dragY: CGFloat = 0
    @State private var error: String?

    private static let space = "viaform.history"

    var body: some View {
        VStack(spacing: 0) {
            header
            VFHairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HistoryVariablesSection(model: model)
                    VFHairline().padding(.vertical, VFSpace.xs)
                    if model.snapshot.timeline.isEmpty {
                        Text("No steps yet. Sketch and extrude to start the history.")
                            .font(VFFont.row).foregroundStyle(theme.inkSecondary)
                            .padding(VFSpace.l)
                    }
                    steps
                }
                .padding(.bottom, VFSpace.l)
                .coordinateSpace(.named(Self.space))
            }
            if let error {
                InlineError(error, dismiss: { self.error = nil })
                    .padding(VFSpace.m)
            }
        }
        .modifier(TimelineArrowKeys(model: model, keys: (.upArrow, .downArrow)))
        .modifier(TouchPanelCard(on: floating, width: TouchRail.historyWidth))
        .onChange(of: model.snapshot.revision) { _, _ in if relatedOnly { refreshRelated() } }
        .onChange(of: model.bodiesInSelection) { _, b in
            if b.isEmpty { relatedOnly = false } else if relatedOnly { refreshRelated() }
        }
    }

    // MARK: Header

    /// "History" with its menu in the middle, the related-to-selection filter and Roll to End
    /// beside it, as the reference sidebar's title row.
    private var header: some View {
        let canFilter = !model.bodiesInSelection.isEmpty || relatedOnly
        let rolled = PanelOps.marker(model.snapshot) < model.snapshot.timeline.count
        return ZStack {
            Menu {
                Toggle(isOn: Binding(get: { relatedOnly }, set: { on in
                    relatedOnly = on
                    if on { refreshRelated() }
                })) {
                    Label("Related to Selection", systemImage: "line.3.horizontal.decrease")
                }
                .disabled(!canFilter)
                if rolled {
                    Button("Roll to End", systemImage: "forward.end") { error = PanelOps.deleteBreakpoint(model) }
                }
            } label: {
                HStack(spacing: VFSpace.xs) {
                    Text("History").font(VFFont.rowEmphasis)
                    Image(systemName: "chevron.down").font(VFFont.icon(10, weight: .semibold)).accessibilityHidden(true)
                }
                .foregroundStyle(theme.ink)
                .frame(minHeight: VFSize.touchTarget)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("History options"))
            HStack(spacing: VFSpace.xs) {
                Spacer(minLength: 0)
                Button {
                    relatedOnly.toggle()
                    if relatedOnly { refreshRelated() }
                } label: {
                    Image(systemName: relatedOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .font(VFFont.icon(17, weight: .regular))
                        .foregroundStyle(canFilter ? theme.accentText : theme.inkTertiary)
                        .frame(width: VFSize.touchTarget, height: VFSize.touchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.vfTouch)
                .disabled(!canFilter)
                .accessibilityLabel(Text("Related to Selection"))
                .accessibilityAddTraits(relatedOnly ? .isSelected : [])
                .accessibilityHint(Text("Shows only the steps of the selected bodies"))
                if rolled {
                    Button { error = PanelOps.deleteBreakpoint(model) } label: {
                        Text("Roll to End").font(VFFont.row.weight(.medium)).foregroundStyle(theme.accentText)
                            .frame(minHeight: VFSize.touchTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.vfTouch)
                }
            }
        }
        .padding(.horizontal, VFSpace.l)
        .frame(minHeight: 52)
    }

    // MARK: Steps

    private var order: [HistoryEntry] { PanelOps.entries(model.snapshot) }

    /// Where the dragged row would land, for the drop line.
    private var dropSlot: Int? {
        guard let dragging else { return nil }
        return PanelOps.slot(at: dragY, mids: mids, order: order, dragged: dragging)
    }

    @ViewBuilder private var steps: some View {
        let order = order
        let others = order.filter { $0 != dragging }
        let slot = dropSlot
        let features = Dictionary(model.snapshot.timeline.enumerated().map { ($0.element.id, ($0.offset, $0.element)) },
                                  uniquingKeysWith: { a, _ in a })
        ForEach(Array(order.enumerated()), id: \.element) { _, entry in
            if let slot, entry != dragging, others.firstIndex(of: entry) == slot { dropLine }
            Group {
                switch entry {
                case .breakpoint:
                    if !relatedOnly { breakpointRow }
                case .feature(let id):
                    if let pair = features[id] {
                        let (i, f) = pair
                        if !relatedOnly || related.contains(id) {
                            featureRow(f, index: i)
                        } else if let gap = hiddenRun(startingAt: i), gap > 0 {
                            Text("\(gap) hidden")
                                .font(VFFont.micro).foregroundStyle(theme.inkTertiary)
                                .padding(.horizontal, VFSpace.l).padding(.vertical, VFSpace.xxs)
                        }
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.space)).midY } action: { mids[entry] = $0 }
            .offset(y: dragging == entry ? dragOffset : 0)
            .zIndex(dragging == entry ? 1 : 0)
        }
        if let slot, slot == others.count { dropLine }
    }

    /// With the related filter, one "n hidden" line stands for a run of hidden rows: it shows on
    /// the first row of the run.
    private func hiddenRun(startingAt i: Int) -> Int? {
        let t = model.snapshot.timeline
        if i > 0, !related.contains(t[i - 1].id) { return nil }
        var n = 0
        var j = i
        while j < t.count, !related.contains(t[j].id) { n += 1; j += 1 }
        return n
    }

    private var dropLine: some View {
        Capsule().fill(theme.accent).frame(height: 3)
            .padding(.horizontal, VFSpace.l)
            .accessibilityHidden(true)
    }

    private func grip(_ entry: HistoryEntry, label: String) -> some View {
        // The reference rows show no handle: the strip left of the icon is the drag handle,
        // its glyph shows only while a row is dragged.
        Image(systemName: "line.3.horizontal")
            .font(VFFont.glyph(14, weight: .medium))
            .foregroundStyle(theme.inkTertiary)
            .opacity(dragging == nil ? 0 : 1)
            .frame(width: 32, height: VFSize.touchTarget)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
                    .onChanged { v in
                        dragging = entry
                        dragOffset = v.translation.height
                        dragY = v.location.y
                    }
                    .onEnded { v in finishDrag(entry, y: v.location.y) }
            )
            .accessibilityLabel(label)
            .accessibilityHint(Text("Drag up or down to move it"))
            .accessibilityAction(named: Text("Move Up")) { nudge(entry, by: -1) }
            .accessibilityAction(named: Text("Move Down")) { nudge(entry, by: 1) }
    }

    private func finishDrag(_ entry: HistoryEntry, y: CGFloat) {
        let order = order
        let slot = PanelOps.slot(at: y, mids: mids, order: order, dragged: entry)
        dragging = nil
        dragOffset = 0
        error = PanelOps.apply(PanelOps.drop(order, dragged: entry, slot: slot), model)
    }

    /// VoiceOver and keyboard: one row up or down.
    private func nudge(_ entry: HistoryEntry, by delta: Int) {
        let order = order
        guard let i = order.firstIndex(of: entry) else { return }
        error = PanelOps.apply(PanelOps.drop(order, dragged: entry, slot: max(0, i + delta)), model)
    }

    private var breakpointRow: some View {
        HStack(spacing: VFSpace.s) {
            grip(.breakpoint, label: String(localized: "Breakpoint"))
            Menu {
                Button(String(localized: "Delete Breakpoint"), systemImage: "trash", role: .destructive) {
                    error = PanelOps.deleteBreakpoint(model)
                }
            } label: {
                HStack {
                    Text("Breakpoint").font(VFFont.caps).foregroundStyle(theme.inkSecondary)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: VFSize.touchTarget)
                .contentShape(Rectangle())
            }
            .accessibilityHint(Text("Steps below it are not built. Opens Delete Breakpoint"))
        }
        .padding(.trailing, VFSpace.l)
        .background(theme.well, in: RoundedRectangle(cornerRadius: VFRadius.card, style: .continuous))
        .padding(.horizontal, VFSpace.s)
        .padding(.vertical, VFSpace.xxs)
    }

    @ViewBuilder private func featureRow(_ f: DesignSnapshot.Feature, index i: Int) -> some View {
        let rolled = f.rolled_back ?? false
        let open = expanded == f.id
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: VFSpace.xs) {
                if relatedOnly {
                    Color.clear.frame(width: 32, height: VFSize.touchTarget)
                } else {
                    grip(.feature(f.id), label: String(localized: "Move \(f.name)"))
                }
                Image(systemName: FeatureSymbol.of(f.type)).frame(width: 20).foregroundStyle(theme.inkSecondary).accessibilityHidden(true)
                if renaming == f.id {
                    TextField(String(localized: "Name"), text: $renameText)
                        .font(VFFont.row)
                        .textFieldStyle(.roundedBorder)
                        .focused($renameFocused)
                        .submitLabel(.done)
                        .onSubmit { commitRename(f.id) }
                        .onChange(of: renameFocused) { _, on in if !on, renaming == f.id { commitRename(f.id) } }
                } else {
                    Button { toggle(f.id) } label: {
                        HStack(spacing: VFSpace.s) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.name).font(VFFont.row.weight(.medium)).foregroundStyle(theme.ink).lineLimit(1)
                                // Only a step that is not plainly built says so (the reference row is its name alone).
                                if f.error != nil || f.suppressed == true || f.rolled_back == true {
                                    Text(stateText(f)).font(VFFont.micro)
                                        .foregroundStyle(f.error != nil ? theme.danger : theme.inkSecondary)
                                }
                            }
                            Spacer(minLength: 0)
                            if f.error != nil {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.warning)
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(minHeight: VFSize.touchTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(open ? String(localized: "Expanded") : String(localized: "Collapsed"))
                    .accessibilityHint(Text("Shows its values to edit"))
                }
                // (i): the step's values in place; a long press on the row lists its actions.
                Button { toggle(f.id) } label: {
                    Image(systemName: open ? "info.circle.fill" : "info.circle").font(VFFont.icon(15))
                        .foregroundStyle(open ? theme.accentText : theme.inkTertiary)
                        .frame(width: VFSize.touchTarget, height: VFSize.touchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.vfTouch)
                .hoverEffect(.highlight)
                .accessibilityLabel(String(localized: "Values of \(f.name)"))
            }
            .padding(.trailing, VFSpace.xs)
            .contentShape(Rectangle())
            .contextMenu { rowMenu(f, index: i) }
            if open {
                HistoryFeatureEditor(model: model, feature: f)
                    .padding(.leading, 56)
                    .padding(.trailing, VFSpace.l)
                    .padding(.bottom, VFSpace.m)
                    .vfTransition(.opacity)
            }
        }
        .opacity(rolled ? 0.45 : 1)
        .background(open ? theme.selection.opacity(0.5) : Color.clear)
    }

    @ViewBuilder private func rowMenu(_ f: DesignSnapshot.Feature, index i: Int) -> some View {
        Button(expanded == f.id ? String(localized: "Close") : String(localized: "Edit"), systemImage: "slider.horizontal.3") { toggle(f.id) }
        if PanelOps.isSketch(f) {
            Button("Edit Sketch", systemImage: "pencil") { PanelOps.editSketch(f.id, model) }
        }
        Button("Rename", systemImage: "character.cursor.ibeam") {
            renameText = f.name
            renaming = f.id
            renameFocused = true
        }
        Button("Insert Breakpoint", systemImage: "pause.rectangle") { error = PanelOps.insertBreakpoint(after: i, model) }
        Divider()
        TimelineStepActions(model: model, index: i, feature: f, toasts: toasts)
    }

    private func toggle(_ id: Int) {
        withAnimation(.snappy(duration: VFMotion.standard)) { expanded = expanded == id ? nil : id }
    }

    private func commitRename(_ id: Int) {
        let text = renameText
        renaming = nil
        error = PanelOps.renameFeature(id, to: text, model)
    }

    private func refreshRelated() {
        related = PanelOps.related(model, bodies: model.bodiesInSelection)
    }

    /// The type and state in words (never colour alone): "Extrude · Rolled back".
    private func stateText(_ f: DesignSnapshot.Feature) -> String {
        if f.error != nil { return String(localized: "\(f.type) · Error") }
        if f.suppressed == true { return String(localized: "\(f.type) · Suppressed") }
        if f.rolled_back == true { return String(localized: "\(f.type) · Rolled back") }
        return f.type
    }
}

// MARK: - Edit Feature in the row (T-1)

/// A step's values in place (`timeline.inspect`), sent back with `timeline.edit` on Return or
/// Apply. Numbers take expressions and variable names. A sketch row offers Edit Sketch, a
/// construction plane Sketch on Plane.
struct HistoryFeatureEditor: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    let feature: DesignSnapshot.Feature
    @State private var initial: [FeatureField] = []
    @State private var fields: [FeatureField] = []
    @State private var texts: [String: String] = [:]
    @State private var loaded = false
    @State private var error: String?

    private var edited: [FeatureField] {
        fields.map { f in
            var f = f
            if let t = texts[f.key], t != PanelOps.text(f) { PanelOps.set(&f, text: t) }
            return f
        }
    }

    private var changed: Bool { !FeatureField.changes(from: initial, to: edited).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpace.s) {
            if PanelOps.isSketch(feature) {
                Button { PanelOps.editSketch(feature.id, model) } label: {
                    Label("Edit Sketch", systemImage: "pencil").frame(maxWidth: .infinity, minHeight: VFSize.touchTarget)
                }
                .buttonStyle(.vfSecondary)
            } else {
                if feature.type == "ConstructionPlane" {
                    Button { model.startSketch(feature.name) } label: {
                        Label("Sketch on Plane", systemImage: "pencil.and.outline").frame(maxWidth: .infinity, minHeight: VFSize.touchTarget)
                    }
                    .buttonStyle(.vfSecondary)
                }
                if FeatureEditor.hasDialog(model, feature: feature.name) {
                    // The step's own tool, with handles and a live preview (agent B).
                    Button { FeatureEditor.edit(model, feature: feature.name) {} } label: {
                        Label("Open in Tool", systemImage: "hand.draw").frame(maxWidth: .infinity, minHeight: VFSize.touchTarget)
                    }
                    .buttonStyle(.vfSecondary)
                }
                if loaded, fields.isEmpty, error == nil {
                    Text("This step has no values to edit here.").font(VFFont.small).foregroundStyle(theme.inkSecondary)
                }
                ForEach($fields) { $f in fieldRow($f) }
                if !fields.isEmpty {
                    HStack {
                        Button("Revert") { load() }
                            .buttonStyle(.vfSecondary)
                            .vfDisabled(!changed, reason: String(localized: "Nothing changed"))
                        Spacer()
                        Button("Apply") { apply() }
                            .buttonStyle(.vfPrimary)
                            .vfDisabled(!changed, reason: String(localized: "Nothing changed"))
                            .vfEngineGate()
                    }
                }
            }
            if let error { InlineError(error, dismiss: { self.error = nil }) }
        }
        .onAppear(perform: load)
        .onChange(of: model.snapshot.revision) { _, _ in if !changed { load() } }
    }

    @ViewBuilder private func fieldRow(_ f: Binding<FeatureField>) -> some View {
        let label = f.wrappedValue.label
        switch f.wrappedValue.value {
        case .flag(let on):
            Toggle(label, isOn: Binding(get: { on }, set: { v in
                f.wrappedValue.value = .flag(v)
                apply()
            }))
            .font(VFFont.row).foregroundStyle(theme.ink)
            .frame(minHeight: VFSize.touchTarget)
        case .number, .text:
            HStack(spacing: VFSpace.s) {
                Text(label).font(VFFont.small).foregroundStyle(theme.inkSecondary).lineLimit(2)
                Spacer(minLength: VFSpace.s)
                TextField(label, text: Binding(get: { texts[f.wrappedValue.key] ?? PanelOps.text(f.wrappedValue) },
                                               set: { texts[f.wrappedValue.key] = $0 }))
                    .font(VFFont.row)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .onSubmit(apply)
                    .frame(width: 130)
            }
            .frame(minHeight: VFSize.touchTarget)
        }
    }

    private func load() {
        switch PanelOps.inspect(feature.id, model) {
        case .success(let r):
            initial = r.fields
            fields = r.fields
            texts = [:]
            error = nil
        case .failure(let e):
            error = e.localizedDescription
        }
        loaded = true
    }

    private func apply() {
        let after = edited
        if let why = PanelOps.edit(feature.id, from: initial, to: after, model) {
            error = why
            return
        }
        load()
    }
}

// MARK: - Variables (B-10)

/// The design's variables at the top of History (Shapr3D): the shared compact parameters table
/// (`ParametersTable`, add, rename, expression), folded under a "Variables" header.
struct HistoryVariablesSection: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    @State private var open = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy(duration: VFMotion.fast)) { open.toggle() } } label: {
                HStack(spacing: VFSpace.s) {
                    Image(systemName: "chevron.right")
                        .font(VFFont.glyph(11, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(theme.inkTertiary)
                    Image(systemName: "function").foregroundStyle(theme.inkSecondary)
                    Text("Variables").font(VFFont.rowEmphasis).foregroundStyle(theme.ink)
                    Text("\(model.snapshot.params.count)").font(VFFont.micro).foregroundStyle(theme.inkSecondary)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: VFSize.touchTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? String(localized: "Expanded") : String(localized: "Collapsed"))
            .padding(.horizontal, VFSpace.l)
            if open {
                ParametersTable(design: model, style: .compact)
                    .padding(.horizontal, VFSpace.l)
                    .padding(.bottom, VFSpace.s)
            }
        }
    }
}

// MARK: - History bar

/// The parametric history: one chip per step; tapping one rolls the design back to it. Each
/// step's actions are in its long-press menu and in the Steps menu at the end of the bar.
struct HistoryBar: View {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.vfToasts) private var toasts
    let model: DesignModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: VFSpace.s) {
                    ForEach(Array(model.snapshot.timeline.enumerated()), id: \.element.id) { i, f in
                        let rolled = f.rolled_back ?? false
                        Button { model.rollTimeline(to: i + 1) } label: {
                            HStack(spacing: VFSpace.xs) {
                                Image(systemName: FeatureSymbol.of(f.type)).accessibilityHidden(true)
                                Text(f.name).font(VFFont.small.weight(.medium))
                                if f.error != nil {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.warning)
                                        .accessibilityLabel(Text("Error"))
                                }
                            }
                            .foregroundStyle(theme.ink)
                            .padding(.horizontal, VFSpace.m).frame(minHeight: 32)
                            .background(rolled ? Color.clear : theme.accent.opacity(0.12), in: Capsule())
                            // Rolled back steps are outlined and dimmed, and say so to VoiceOver.
                            .overlay(Capsule().strokeBorder(theme.accent.opacity(rolled ? 0.35 : 0), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                            .opacity(rolled ? 0.55 : 1)
                            .frame(minHeight: VFSize.touchTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.vfTouch)
                        .accessibilityValue(rolled ? String(localized: "Rolled back") : "")
                        .accessibilityHint(Text("Rolls the design back to this step"))
                        .contextMenu { TimelineStepActions(model: model, index: i, feature: f, toasts: toasts) }
                    }
                }
                .padding(.horizontal, VFSpace.m)
            }
            VFIconButton("forward.end.fill", label: String(localized: "Roll to End"), size: 14) {
                model.run("timeline.roll_to", ["position": "end"], quiet: true)
            }
            Menu {
                ForEach(Array(model.snapshot.timeline.enumerated()).reversed(), id: \.element.id) { i, f in
                    Menu(f.name) { TimelineStepActions(model: model, index: i, feature: f, toasts: toasts) }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(VFFont.glyph(16)).foregroundStyle(theme.inkSecondary)
                    .frame(width: VFSize.touchTarget, height: VFSize.touchTarget)
                    .contentShape(Rectangle())
            }
            .hoverEffect(.highlight)
            .accessibilityLabel(Text("Step actions"))
            .padding(.trailing, VFSpace.xs)
        }
        .frame(minHeight: 52)
        .frame(maxWidth: 900)
        .modifier(TimelineArrowKeys(model: model, keys: (.leftArrow, .rightArrow)))
        .vfSurface(.control, radius: VFRadius.touchCapsule)
    }
}

#endif
