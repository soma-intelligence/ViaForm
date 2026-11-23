#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The desktop electronics workspace, laid out like the design one: SCHEMATIC and PCB tabs over
/// their panels, the sheet filling the window, a floating browser on the left and a floating
/// inspector (the link to 3D and the rule checks) on the right.
struct DeskPCBView: View {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.vfToasts) private var toasts
    @Bindable var model: PCBModel
    let design: DesignModel
    /// Inside the project window: the window's sidebar lists the parts and nets, so the floating
    /// browser starts closed (its button brings it back).
    var embedded = false
    /// Board layers hidden by the window's layer bar (embedded only).
    var hiddenLayers: Set<String> = []
    /// Runs the rule checks the way the stage verb does (embedded only).
    var runChecks: (() -> Void)?
    /// The window's workspace dropdown, at the far left of the board ribbon (embedded only).
    var ribbonLeading: AnyView?
    let openDesign: () -> Void
    @State private var transform: PCBCanvasTransform?
    @State private var cardFrame: CGRect?
    @State private var showBrowser = true
    @State private var showInspector = true
    @State private var open: Set<String> = ["Parts", "Board"]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ZStack(alignment: .top) {
                PCBCanvas(model: model, dense: embedded, hiddenLayers: hiddenLayers, onTransform: { transform = $0 },
                          reserveTrailing: embedded && model.sheet == .board ? 300 : 0)
                if embedded { linkLayer }
                if !embedded {
                HStack(alignment: .top) {
                    if showBrowser { browser.frame(width: 250) } else { reopen("sidebar.left", String(localized: "Show the browser")) { showBrowser = true } }
                    Spacer()
                    if showInspector { inspector.frame(width: VFSize.inspector) } else { reopen("sidebar.right", String(localized: "Show the inspector")) { showInspector = true } }
                }
                .padding(VFSpace.m)
                }
                VStack(spacing: VFSpace.s) {
                    if let hint = model.toolHint { pill(hint) }
                    if let m = model.message, model.messageIsError {
                        ErrorBanner(message: m, dismiss: { model.message = nil })
                    }
                }
                .padding(VFSpace.m)
            }
            .coordinateSpace(name: "pcbStage")
        }
        .onAppear { if embedded { showBrowser = false } }
        // Confirmations ("Saved", "Board sent to the 3D design") are toasts, not a lasting pill.
        .onChange(of: model.message) { _, m in
            guard let m, !model.messageIsError, let toasts else { return }
            toasts.show(m)
            model.message = nil
        }
        .onKeyPress(.escape) { model.tool = .select; return .handled }
        .onKeyPress(.delete) { model.deleteSelection(); return .handled }
        .onKeyPress("r") { model.rotateSelection(); return .handled }
        .onKeyPress("w") { model.tool = .wire; return .handled }
        .onKeyPress("x") { model.tool = .route; return .handled }
        // The arrow keys move the selected part 1 mm (Shift: 10 mm): moving is never drag-only.
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            guard model.selectionPosition != nil else { return .ignored }
            let d = press.modifiers.contains(.shift) ? 10.0 : 1.0
            switch press.key {
            case .leftArrow: model.nudgeSelection(dx: -d, dy: 0)
            case .rightArrow: model.nudgeSelection(dx: d, dy: 0)
            case .upArrow: model.nudgeSelection(dx: 0, dy: -d)
            default: model.nudgeSelection(dx: 0, dy: d)
            }
            return .handled
        }
    }

    /// Embedded in the project window: the 3D link card (top right) with its leader, the keep-in
    /// and clearance dimensions over the board, and the rule-check capsule (bottom left). The
    /// window's sidebar and inspector stand in for the floating browser and inspector.
    @ViewBuilder private var linkLayer: some View {
        let info = BoardLinkInfo.read(design: design, pcb: model)
        if model.sheet == .board, let t = transform, let p = model.project {
            BoardLinkAnnotations(info: info, board: CGSize(width: p.board.width, height: p.board.height), transform: t, card: cardFrame)
        }
        if model.sheet == .board {
            LinkCard(info: info, design: design, pcb: model, showIn3D: openDesign)
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { cardFrame = g.frame(in: .named("pcbStage")) }
                        .onChange(of: g.frame(in: .named("pcbStage"))) { _, f in cardFrame = f }
                })
                .padding(VFSpace.overlayInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        DRCCapsule(pcb: model) { runChecks?() ?? model.refresh() }
            .padding(VFSpace.overlayInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private func pill(_ text: String) -> some View {
        Text(text).font(VFFont.row).foregroundStyle(theme.inkSecondary)
            .padding(.horizontal, VFSpace.l).padding(.vertical, VFSpace.s)
            .vfSurface(.floating, radius: VFRadius.touchCapsule)
    }

    // MARK: Floating panels

    private func floating<Content: View>(_ title: String, closeLabel: String, close: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VFCaption(title)
                Spacer()
                VFIconButton("minus", label: closeLabel, size: 10, action: close)
            }
            .padding(.horizontal, VFSpace.m).frame(minHeight: 26)
            .background(theme.chromeDeep)
            ScrollView { content().padding(.vertical, VFSpace.xs) }.frame(maxHeight: 420)
        }
        .vfSurface(.floating, radius: VFRadius.card)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func reopen(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        VFIconButton(symbol, label: help, action: action)
            .vfSurface(.control, radius: VFRadius.control)
    }

    private var browser: some View {
        floating(String(localized: "Browser"), closeLabel: String(localized: "Hide the browser"), close: { showBrowser = false }) {
            VStack(alignment: .leading, spacing: 1) {
                if let p = model.project {
                    treeRow(0, "cpu", p.name ?? String(localized: "Untitled circuit"), bold: true)
                    folder("Parts", "folder", count: p.components.count) {
                        ForEach(p.components) { c in
                            treeRow(2, PCBSymbol.part(c.kind), c.reference, detail: c.value, selected: model.selection == c.id) { model.selection = c.id }
                        }
                    }
                    folder("Nets", "folder", count: p.nets.count) {
                        ForEach(p.nets) { n in
                            treeRow(2, "circle.hexagongrid", n.name, selected: model.selection == n.id) { model.selection = n.id }
                        }
                    }
                    folder("Board", "folder", detail: String(localized: "\(VFFormat.value(p.board.width, .length, withUnit: false)) x \(VFFormat.length(p.board.height))")) {
                        ForEach(p.board.tracks) { t in
                            treeRow(2, "line.diagonal", model.nets[t.net] ?? String(localized: "Net"), detail: String(localized: "on \(t.layer)"),
                                    selected: model.selection == t.id) { model.selection = t.id }
                        }
                    }
                }
            }
        }
    }

    private var inspector: some View {
        floating(String(localized: "Inspector"), closeLabel: String(localized: "Hide the inspector"), close: { showInspector = false }) {
            VStack(alignment: .leading, spacing: VFSpace.m) {
                if let p = model.selectionPosition { position(p) }
                Text("Board in 3D").font(VFFont.rowEmphasis).foregroundStyle(theme.ink)
                Text(model.linkedRevision.map { linked in
                    model.boardOutOfDate ? String(localized: "Built from revision \(linked); the board is now at \(model.revision).")
                                         : String(localized: "Up to date with board revision \(model.revision).")
                } ?? String(localized: "The board is not in the 3D design yet."))
                    .font(VFFont.small).foregroundStyle(theme.inkSecondary)
                HStack {
                    Button(model.linkedRevision == nil ? "Send to 3D" : "Update 3D") { model.sendTo3D(design) }.buttonStyle(.vfPrimary)
                    Button("Mount on a Part") { model.startMount(design, show: openDesign) }.buttonStyle(.vfSecondary)
                }
                Divider().padding(.vertical, VFSpace.xxs)
                PCBChecksPanel(model: model)
            }
            .padding(.horizontal, VFSpace.m).padding(.vertical, VFSpace.s)
        }
    }

    /// The selected part's place: typed X and Y, the drag's equivalent.
    private func position(_ p: PCBPoint) -> some View {
        VStack(alignment: .leading, spacing: VFSpace.s) {
            Text("Position").font(VFFont.rowEmphasis).foregroundStyle(theme.ink)
            HStack(spacing: VFSpace.l) {
                NumberField("X", value: Binding(get: { p.x }, set: { model.moveSelection(to: PCBPoint(x: $0, y: p.y)) }), unit: .length, step: 1, width: 64)
                NumberField("Y", value: Binding(get: { p.y }, set: { model.moveSelection(to: PCBPoint(x: p.x, y: $0)) }), unit: .length, step: 1, width: 64)
            }
            Text("Arrow keys move it 1 mm, Shift-arrow 10 mm.").font(VFFont.micro).foregroundStyle(theme.inkTertiary)
            Divider().padding(.vertical, VFSpace.xxs)
        }
    }

    private func folder<Content: View>(_ key: String, _ symbol: String, count: Int? = nil, detail: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                if open.contains(key) { open.remove(key) } else { open.insert(key) }
            } label: {
                HStack(spacing: VFSpace.xs) {
                    Image(systemName: open.contains(key) ? "chevron.down" : "chevron.right").font(VFFont.glyph(8, weight: .bold)).frame(width: 10)
                        .accessibilityHidden(true)
                    Image(systemName: symbol).foregroundStyle(theme.inkSecondary).accessibilityHidden(true)
                    Text(LocalizedStringKey(key))
                    if let d = detail ?? count.map(String.init) { Text(d).foregroundStyle(theme.inkSecondary) }
                    Spacer()
                }
                .font(VFFont.row)
                .foregroundStyle(theme.ink)
                .padding(.leading, VFSpace.l).frame(minHeight: VFSize.macRow - 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(open.contains(key) ? .isSelected : [])
            .accessibilityHint(open.contains(key) ? Text("Collapse") : Text("Expand"))
            if open.contains(key) { content() }
        }
    }

    private func treeRow(_ indent: Int, _ symbol: String, _ text: String, detail: String? = nil, bold: Bool = false, selected: Bool = false,
                         select: (() -> Void)? = nil) -> some View {
        let row = HStack(spacing: VFSpace.s) {
            Image(systemName: symbol).foregroundStyle(theme.inkSecondary).frame(width: 14).accessibilityHidden(true)
            Text(text).fontWeight(bold ? .semibold : .regular).lineLimit(1)
            if let detail { Text(detail).foregroundStyle(theme.inkSecondary).lineLimit(1) }
            Spacer()
        }
        .font(VFFont.row)
        .foregroundStyle(theme.ink)
        .padding(.leading, CGFloat(10 + indent * 13)).frame(minHeight: VFSize.macRow - 7)
        .background(selected ? theme.selection : .clear)
        .contentShape(Rectangle())
        return Group {
            if let select {
                Button(action: select) { row }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
            } else {
                row
            }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 0) {
            if let ribbonLeading {
                ribbonLeading
                VFHairline(vertical: true)
            }
            ribbonRows
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(theme.chrome)
    }

    private var ribbonRows: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(PCBModel.Sheet.allCases, id: \.self) { s in
                    let name = s == .schematic ? String(localized: "SCHEMATIC") : String(localized: "PCB")
                    Button { model.sheet = s; model.tool = .select } label: {
                        Text(name).font(VFFont.caps).tracking(VFTypeScale.capsTracking)
                            .padding(.horizontal, VFSpace.m).frame(height: 24)
                            .foregroundStyle(model.sheet == s ? theme.accentText : theme.ink)
                            .overlay(alignment: .bottom) { if model.sheet == s { Rectangle().fill(theme.accent).frame(height: 2) } }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.sheet == s ? .isSelected : [])
                }
                Spacer()
            }
            .frame(height: 24)
            panels.frame(height: 60)
        }
        .background(theme.chrome)
    }

    private var panels: some View {
        HStack(alignment: .top, spacing: 0) {
            if model.sheet == .schematic {
                panel("PLACE") {
                    ForEach(PCBModel.partKinds, id: \.self) { k in
                        big(PCBSymbol.part(k), String(localized: "Place \(k)"), on: model.tool == .place(k)) { model.tool = .place(k) }
                    }
                }
                panel("CONNECT") {
                    big(PCBSymbol.wire, String(localized: "Wire (W)"), on: model.tool == .wire) { model.tool = .wire }
                }
                panel("BOARD") {
                    big(PCBSymbol.update, String(localized: "Update PCB from schematic")) { model.updateBoard() }
                }
            } else {
                panel("ROUTE") {
                    big(PCBSymbol.route, String(localized: "Route (X)"), on: model.tool == .route) { model.tool = .route }
                    big(PCBSymbol.routeAll, String(localized: "Route all airwires")) { model.routeAll() }
                    Picker("Copper layer", selection: $model.layer) { Text("F.Cu").tag("F.Cu"); Text("B.Cu").tag("B.Cu") }
                        .labelsHidden()
                        .pickerStyle(.segmented).frame(width: 100).padding(.top, VFSpace.s)
                }
                panel("BOARD") {
                    big(PCBSymbol.update, String(localized: "Update PCB from schematic")) { model.updateBoard() }
                }
            }
            panel("MODIFY") {
                big("cursorarrow", String(localized: "Select (Esc)"), on: model.tool == .select) { model.tool = .select }
                big("rotate.right", String(localized: "Rotate (R)")) { model.rotateSelection() }
                    .vfDisabled(model.selection == nil, reason: String(localized: "Select a part first"))
                big("trash", String(localized: "Delete")) { model.deleteSelection() }
                    .vfDisabled(model.selection == nil, reason: String(localized: "Select a part first"))
            }
            panel("CHECK") {
                // Design and electrical rules in one run; the capsule on the canvas shows the result.
                big("checkmark.seal", String(localized: "Run the design and electrical rule checks")) { if let runChecks { runChecks() } else { model.refresh() } }
            }
            panel("3D") {
                ZStack(alignment: .topTrailing) {
                    big("cube.transparent", model.boardOutOfDate ? String(localized: "Update the 3D board (the board changed)")
                                            : (model.linkedRevision == nil ? String(localized: "Send board to the 3D design") : String(localized: "Update the 3D board"))) {
                        model.sendTo3D(design)
                    }
                    // A badge with a shape, not a colour dot alone: the 3D board is behind.
                    if model.boardOutOfDate {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(VFFont.glyph(10, weight: .bold))
                            .foregroundStyle(theme.warning)
                            .background(Circle().fill(theme.chrome))
                            .offset(x: -2, y: 2)
                            .accessibilityHidden(true)
                    }
                }
                big("square.stack.3d.down.forward", String(localized: "Mount on a part of the assembly")) { model.startMount(design, show: openDesign) }
            }
            panel("OUTPUT") {
                big(PCBSymbol.export, String(localized: "Export KiCad board")) { exportKiCad() }
            }
            Spacer()
        }
        .padding(.horizontal, 6)
    }

    private func panel<Content: View>(_ name: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 2) {
                HStack(spacing: 2) { content() }
                // The ribbon's caption, on one line (it wrapped to "BOAR D" at 9.5 pt bold).
                Text(name).font(VFFont.caps).tracking(VFTypeScale.capsTracking).foregroundStyle(theme.inkSecondary).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, VFSpace.m).padding(.top, VFSpace.xs)
            VFHairline(vertical: true).frame(height: 42)
        }
    }

    private func big(_ symbol: String, _ help: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(VFFont.glyph(17))
                .frame(width: 36, height: 32)
                .foregroundStyle(on ? theme.onAccent : theme.ink)
                .background(on ? theme.accent : .clear, in: RoundedRectangle(cornerRadius: VFRadius.control, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func exportKiCad() {
        let p = NSSavePanel()
        p.nameFieldStringValue = (model.project?.name ?? "board") + ".kicad_pcb"
        p.allowsOtherFileTypes = true
        guard p.runModal() == .OK, let url = p.url else { return }
        model.exportKiCad(to: url)
        // "Exported board.kicad_pcb" with Reveal, instead of a lasting pill.
        if !model.messageIsError, let toasts {
            model.message = nil
            toasts.show(String(localized: "Exported \(url.lastPathComponent)"), actionTitle: String(localized: "Reveal")) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
}

@MainActor
enum PCBFileActions {
    static func open(_ model: PCBModel) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "pcbcraft"), .json].compactMap { $0 }
        p.allowsOtherFileTypes = true
        if p.runModal() == .OK, let url = p.url { model.open(url) }
    }

    static func save(_ model: PCBModel) {
        let p = NSSavePanel()
        p.nameFieldStringValue = (model.project?.name ?? "board") + ".pcbcraft"
        p.allowsOtherFileTypes = true
        if p.runModal() == .OK, let url = p.url { model.save(to: url) }
    }
}
#endif
