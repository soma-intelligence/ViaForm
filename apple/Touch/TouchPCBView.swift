#if os(iOS)
import SwiftUI

/// The touch electronics space: the sheet fills the screen, the top bar switches schematic and
/// board, a tool column sits at the left edge and the parts and checks open as sidebars.
struct TouchPCBView: View {
    @Bindable var model: PCBModel
    let design: DesignModel
    @Binding var showProject: Bool
    let openDesign: () -> Void
    @State private var side: Side?
    @State private var exportURL: URL?
    @Environment(\.horizontalSizeClass) private var hSize

    enum Side { case parts, checks }

    private var compact: Bool { hSize == .compact }

    @State private var hiddenLayers: Set<String> = []
    @State private var transform: PCBCanvasTransform?
    @State private var cardFrame: CGRect?

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
                        if !compact, let side { sidebar(side).frame(width: 290, height: 380) }
                    }
                }
                Spacer(minLength: 0)
                if let hint = model.toolHint { pill(hint, color: .secondary) }
                if let m = model.message { pill(m, color: model.messageIsError ? .red : .primary) }
                HStack(alignment: .bottom, spacing: 10) {
                    DRCCapsule(pcb: model) { model.refresh() }
                    Spacer(minLength: 0)
                    if !compact, model.sheet == .board {
                        ScrollView(.horizontal, showsIndicators: false) {
                            PCBLayerBar(hidden: $hiddenLayers, active: model.layer) { model.layer = $0 }
                                .padding(.horizontal, 10).frame(minHeight: VFSize.touchTarget)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .vfSurface(.floating, radius: 22)
                    }
                }
                if compact { tools }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .animation(.snappy(duration: VFMotion.standard), value: side)
        .sheet(isPresented: Binding(get: { compact && side != nil }, set: { if !$0 { side = nil } })) {
            if let side { sidebar(side).presentationDetents([.medium, .large]) }
        }
        .sheet(item: Binding(get: { exportURL.map(ExportedFile.init) }, set: { exportURL = $0?.url })) { f in
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
                Text(f.url.lastPathComponent).font(.headline)
                ShareLink(item: f.url) { Label("Share", systemImage: "square.and.arrow.up") }.buttonStyle(.borderedProminent)
            }
            .padding(30)
            .presentationDetents([.height(220)])
        }
    }

    private struct ExportedFile: Identifiable { let url: URL; var id: String { url.path } }

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
            bar("list.bullet.rectangle", "Parts", on: side == .parts) { side = side == .parts ? nil : .parts }
            ZStack(alignment: .topTrailing) {
                bar(PCBSymbol.checks, "Checks", on: side == .checks) { side = side == .checks ? nil : .checks }
                if !model.findings.isEmpty {
                    Text("\(model.findings.count)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .padding(3).background(Color.orange, in: Circle()).offset(x: -2, y: 2)
                }
            }
            Menu {
                Button(model.linkedRevision == nil ? "Send to 3D Design" : "Update 3D Board", systemImage: "cube.transparent") { model.sendTo3D(design) }
                Button("Mount on a Part", systemImage: "square.stack.3d.down.forward") { model.startMount(design, show: openDesign) }
            } label: {
                Image(systemName: "cube.transparent").font(.system(size: 17, weight: .medium)).frame(width: 40, height: 40)
                    .overlay(alignment: .topTrailing) { if model.boardOutOfDate { Circle().fill(.orange).frame(width: 8, height: 8) } }
            }
            bar(PCBSymbol.export, "Export KiCad") { export() }
        }
        .padding(.horizontal, 6)
        .frame(minHeight: 52)
        .vfSurface(.floating, radius: 18)
    }

    @ViewBuilder private var tools: some View {
        let items: [(String, String, Bool, () -> Void)] = {
            var list: [(String, String, Bool, () -> Void)] = [("cursorarrow", "Select", model.tool == .select, { model.tool = .select })]
            if model.sheet == .schematic {
                for k in PCBModel.partKinds { list.append((PCBSymbol.part(k), k.capitalized, model.tool == .place(k), { model.tool = .place(k) })) }
                list.append((PCBSymbol.wire, "Wire", model.tool == .wire, { model.tool = .wire }))
                list.append((PCBSymbol.update, "To Board", false, { model.updateBoard() }))
            } else {
                list.append((PCBSymbol.route, "Route", model.tool == .route, { model.tool = .route }))
                list.append((PCBSymbol.routeAll, "Route All", false, { model.routeAll() }))
                list.append(("square.2.layers.3d", model.layer, false, { model.layer = model.layer == "F.Cu" ? "B.Cu" : "F.Cu" }))
                list.append((PCBSymbol.update, "Update", false, { model.updateBoard() }))
            }
            list.append(("rotate.right", "Rotate", false, { model.rotateSelection() }))
            list.append(("trash", "Delete", false, { model.deleteSelection() }))
            return list
        }()
        let layout = compact ? AnyLayout(HStackLayout(spacing: 2)) : AnyLayout(VStackLayout(spacing: 4))
        ScrollView(compact ? .horizontal : .vertical, showsIndicators: false) {
            layout {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Button(action: item.3) {
                        VStack(spacing: 2) {
                            Image(systemName: item.0).font(.system(size: 19)).frame(height: 24)
                            if !compact { Text(item.1).font(.system(size: 8.5, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7) }
                        }
                        .frame(width: compact ? 44 : 56, height: compact ? 40 : 48)
                        .foregroundStyle(item.2 ? Color.white : Color.primary)
                        .background(item.2 ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.1)
                }
            }
            .padding(compact ? 4 : 6)
        }
        .fixedSize(horizontal: !compact, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: compact ? 24 : 18))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
    }

    @ViewBuilder private func sidebar(_ side: Side) -> some View {
        Group {
            if side == .parts { PCBBrowser(model: model).scrollContentBackground(.hidden) }
            else { ScrollView { PCBChecksPanel(model: model).padding(16) } }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
    }

    private func bar(_ symbol: String, _ label: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 40, height: 40)
                .foregroundStyle(on ? Color.accentColor : Color.primary)
                .background(on ? Color.accentColor.opacity(0.14) : .clear, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text).font(.callout).foregroundStyle(color)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
    }

    private func export() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent((model.project?.name ?? "board").replacingOccurrences(of: "/", with: "-") + ".kicad_pcb")
        model.exportKiCad(to: url)
        if FileManager.default.fileExists(atPath: url.path), !model.messageIsError { exportURL = url }
    }
}
#endif
