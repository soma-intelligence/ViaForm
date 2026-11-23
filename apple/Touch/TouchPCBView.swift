#if os(iOS)
import SwiftUI

/// The touch electronics space: the sheet fills the screen, the top bar switches schematic and
/// board, a tool column sits at the left edge and the parts and checks open as sidebars.
struct TouchPCBView: View {
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: PCBModel
    let design: DesignModel
    @Binding var showProject: Bool
    let openDesign: () -> Void
    @State private var side: Side?
    @State private var exporting = false
    @State private var width: CGFloat = 1024
    @Environment(\.horizontalSizeClass) private var hSize

    enum Side { case parts, checks }

    /// The phone layout, also in a narrow iPad window (Split View, Stage Manager).
    private var compact: Bool { hSize == .compact || width < 820 }

    @State private var hiddenLayers: Set<String> = []
    @State private var transform: PCBCanvasTransform?
    @State private var cardFrame: CGRect?
    @Environment(\.vfToasts) private var toasts

    var body: some View {
        let info = BoardLinkInfo.read(design: design, pcb: model)
        ZStack {
            // The dense board, as on the Mac: soldermask, copper by layer, the keep-in from the
            // part it is mounted on and the clearance, the leader to the link card.
            PCBCanvas(model: model, dense: true, hiddenLayers: hiddenLayers, onTransform: { transform = $0 },
                      reserveTrailing: !compact && model.sheet == .board ? 300 : 0)
                .ignoresSafeArea()
            if model.sheet == .board, let t = transform, let p = model.project {
                GeometryReader { g in
                    let origin = g.frame(in: .global).origin
                    BoardLinkAnnotations(info: info, board: CGSize(width: p.board.width, height: p.board.height), transform: t,
                                         card: compact ? nil : cardFrame.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) })
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
            if !compact {
                // The board's tools at mid height on the leading edge, as in the 3D stages.
                HStack(spacing: 0) { tools; Spacer(minLength: 0) }
                    .padding(.leading, 12)
                    .padding(.bottom, 40)
            }
            VStack(spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 10) {
                        header
                        if !compact, model.sheet == .board {
                            LinkCard(info: info, design: design, pcb: model, showIn3D: openDesign)
                                .background(GeometryReader { g in
                                    Color.clear
                                        .onAppear { cardFrame = g.frame(in: .global) }
                                        .onChange(of: g.frame(in: .global)) { _, f in cardFrame = f }
                                })
                        }
                        if !compact, let side { sidebar(side).frame(width: 300).frame(maxHeight: 420) }
                    }
                }
                Spacer(minLength: 0)
                if let hint = model.toolHint { pill(hint) }
                if let m = model.message {
                    if model.messageIsError {
                        ErrorBanner(message: m) { model.message = nil }
                    } else {
                        pill(m)
                    }
                }
                HStack(alignment: .bottom, spacing: 10) {
                    DRCCapsule(pcb: model) { model.refresh() }
                    Spacer(minLength: 0)
                    if !compact, model.sheet == .board {
                        ScrollView(.horizontal, showsIndicators: false) {
                            PCBLayerBar(hidden: $hiddenLayers, active: model.layer) { model.layer = $0 }
                                .padding(.horizontal, 10).frame(minHeight: VFSize.touchTarget)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .vfSurface(.control, radius: VFRadius.touchCapsule)
                    }
                }
                if compact { tools }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .vfAnimation(.snappy(duration: VFMotion.standard), value: side)
        .sheet(isPresented: Binding(get: { compact && side != nil }, set: { if !$0 { side = nil } })) {
            if let side { sidebar(side).presentationDetents([.medium, .large]).viaFormTheme() }
        }
        .sheet(isPresented: $exporting) {
            // The same export flow as the design's: progress, overwrite check, share or retry.
            ExportFlow(model: design, kind: .kicad, pcb: model).viaFormTheme()
        }
    }

    /// The sheet switch and the board's actions in the right column's header card (no second
    /// capsule under the window's own).
    private var header: some View {
        HStack(spacing: 4) {
            Picker("Sheet", selection: $model.sheet) {
                ForEach(PCBModel.Sheet.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: compact ? 150 : 170)
            Spacer(minLength: 4)
            // Browser, undo and redo are in the window's top capsule.
            bar("list.bullet.rectangle", String(localized: "Parts"), on: side == .parts) { side = side == .parts ? nil : .parts }
            ZStack(alignment: .topTrailing) {
                bar(PCBSymbol.checks, model.findings.isEmpty ? String(localized: "Checks") : String(localized: "Checks, \(model.findings.count) findings"),
                    on: side == .checks) { side = side == .checks ? nil : .checks }
                if !model.findings.isEmpty {
                    Text("\(model.findings.count)").font(VFFont.micro.weight(.bold)).foregroundStyle(theme.onAccent)
                        .padding(3).frame(minWidth: 18).background(theme.warning, in: Capsule()).offset(x: -2, y: 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            Menu {
                if model.boardOutOfDate {
                    Section(String(localized: "The 3D board is out of date")) {}
                }
                Button(model.linkedRevision == nil ? String(localized: "Send to 3D Design") : String(localized: "Update 3D Board"), systemImage: "cube.transparent") { model.sendTo3D(design) }
                Button("Mount on a Part", systemImage: "square.stack.3d.down.forward") { model.startMount(design, show: openDesign) }
            } label: {
                Image(systemName: "cube.transparent").font(VFFont.glyph(17, weight: .medium))
                    .foregroundStyle(theme.ink)
                    .frame(width: VFSize.touchTarget, height: VFSize.touchTarget)
                    .overlay(alignment: .topTrailing) {
                        // Out of date: a triangle, not only a colour.
                        if model.boardOutOfDate {
                            Image(systemName: "exclamationmark.triangle.fill").font(VFFont.glyph(9, weight: .bold))
                                .foregroundStyle(theme.warning).offset(x: -2, y: 4)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .hoverEffect(.highlight)
            .accessibilityLabel(model.boardOutOfDate ? String(localized: "3D board, out of date") : String(localized: "3D board"))
            bar(PCBSymbol.export, String(localized: "Export KiCad Board")) { exporting = true }
        }
        .padding(.horizontal, VFSpace.s)
        .frame(minHeight: 52)
        .vfSurface(.control, radius: VFRadius.touchFloating)
    }

    @ViewBuilder private var tools: some View {
        let items: [(String, String, Bool, () -> Void)] = {
            var list: [(String, String, Bool, () -> Void)] = [("cursorarrow", String(localized: "Select"), model.tool == .select, { model.tool = .select })]
            if model.sheet == .schematic {
                for k in PCBModel.partKinds { list.append((PCBSymbol.part(k), k.capitalized, model.tool == .place(k), { model.tool = .place(k) })) }
                list.append((PCBSymbol.wire, String(localized: "Wire"), model.tool == .wire, { model.tool = .wire }))
                list.append((PCBSymbol.update, String(localized: "To Board"), false, { model.updateBoard() }))
            } else {
                list.append((PCBSymbol.route, String(localized: "Route"), model.tool == .route, { model.tool = .route }))
                list.append((PCBSymbol.routeAll, String(localized: "Route All"), false, { model.routeAll() }))
                list.append(("square.2.layers.3d", model.layer == "F.Cu" ? String(localized: "Top Copper") : String(localized: "Bottom Copper"), false,
                             { model.layer = model.layer == "F.Cu" ? "B.Cu" : "F.Cu" }))
                list.append((PCBSymbol.update, String(localized: "Update"), false, { model.updateBoard() }))
            }
            list.append(("rotate.right", String(localized: "Rotate"), false, { model.rotateSelection() }))
            list.append(("trash", String(localized: "Delete"), false, {
                // Undoable: the board's own stack, offered in the toast.
                model.deleteSelection()
                toasts?.show(String(localized: "Deleted"), systemImage: "trash", actionTitle: String(localized: "Undo")) { model.undo() }
            }))
            return list
        }()
        let layout = compact ? AnyLayout(HStackLayout(spacing: 2)) : AnyLayout(VStackLayout(spacing: 4))
        ScrollView(compact ? .horizontal : .vertical, showsIndicators: false) {
            layout {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Button(action: item.3) {
                        VStack(spacing: 2) {
                            Image(systemName: item.0).font(VFFont.glyph(19)).frame(height: 24)
                            if !compact { Text(item.1).font(VFFont.micro).lineLimit(1).minimumScaleFactor(0.6) }
                        }
                        .frame(width: compact ? VFSize.touchTarget : 60, height: compact ? VFSize.touchTarget : 52)
                        .foregroundStyle(item.2 ? theme.onAccent : theme.ink)
                        .background(item.2 ? theme.accent : .clear, in: RoundedRectangle(cornerRadius: VFRadius.card, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.vfTouch)
                    .accessibilityLabel(item.1)
                    .accessibilityAddTraits(item.2 ? .isSelected : [])
                }
            }
            .padding(compact ? VFSpace.xs : VFSpace.s)
        }
        .fixedSize(horizontal: !compact, vertical: true)
        .vfSurface(.control, radius: compact ? VFRadius.touchCapsule : VFRadius.touchFloating)
    }

    @ViewBuilder private func sidebar(_ side: Side) -> some View {
        Group {
            if side == .parts { PCBBrowser(model: model).scrollContentBackground(.hidden) }
            else { ScrollView { PCBChecksPanel(model: model).padding(VFSpace.xl) } }
        }
        .vfSurface(.floating, radius: VFRadius.touchFloating)
    }

    private func bar(_ symbol: String, _ label: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        TouchBarButton(symbol: symbol, label: label, on: on, action: action)
    }

    private func pill(_ text: String) -> some View {
        Text(text).font(VFFont.row).foregroundStyle(theme.ink)
            .padding(.horizontal, VFSpace.l).padding(.vertical, VFSpace.m)
            .vfSurface(.floating, radius: VFRadius.touchCapsule)
    }
}
#endif
