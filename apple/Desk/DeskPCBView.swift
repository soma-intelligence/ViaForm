#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The desktop electronics workspace: a toolbar of SCHEMATIC and BOARD panels, the parts
/// browser on the left, the sheet in the middle and the rule checks on the right.
struct DeskPCBView: View {
    @Bindable var model: PCBModel
    let design: DesignModel
    let openDesign: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                PCBBrowser(model: model).frame(minWidth: 200, idealWidth: 230, maxWidth: 320)
                ZStack(alignment: .top) {
                    PCBCanvas(model: model)
                    VStack(spacing: 6) {
                        if let hint = model.toolHint { pill(hint, color: .secondary) }
                        if let m = model.message { pill(m, color: model.messageIsError ? .red : .primary) }
                    }
                    .padding(10)
                }
                .frame(minWidth: 400)
                ScrollView { PCBChecksPanel(model: model).padding(12) }
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
            }
        }
        .onKeyPress(.escape) { model.tool = .select; return .handled }
        .onKeyPress(.delete) { model.deleteSelection(); return .handled }
        .onKeyPress("r") { model.rotateSelection(); return .handled }
        .onKeyPress("w") { model.tool = .wire; return .handled }
        .onKeyPress("x") { model.tool = .route; return .handled }
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text).font(.callout).foregroundStyle(color)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
    }

    private var toolbar: some View {
        HStack(alignment: .top, spacing: 0) {
            Picker("", selection: $model.sheet) {
                ForEach(PCBModel.Sheet.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            .padding(.horizontal, 10).padding(.top, 18)
            Divider().frame(height: 60)
            if model.sheet == .schematic {
                panel("PLACE") {
                    ForEach(PCBModel.partKinds, id: \.self) { k in
                        big(PCBSymbol.part(k), k.capitalized, on: model.tool == .place(k)) { model.tool = .place(k) }
                    }
                }
                panel("CONNECT") {
                    big(PCBSymbol.wire, "Wire (W)", on: model.tool == .wire) { model.tool = .wire }
                }
                panel("BOARD") {
                    big(PCBSymbol.update, "Update PCB from schematic") { model.updateBoard() }
                }
            } else {
                panel("ROUTE") {
                    big(PCBSymbol.route, "Route (X)", on: model.tool == .route) { model.tool = .route }
                    big(PCBSymbol.routeAll, "Route all airwires") { model.routeAll() }
                    Picker("", selection: $model.layer) { Text("F.Cu").tag("F.Cu"); Text("B.Cu").tag("B.Cu") }
                        .pickerStyle(.segmented).frame(width: 100).padding(.top, 6)
                }
                panel("BOARD") {
                    big(PCBSymbol.update, "Update PCB from schematic") { model.updateBoard() }
                }
            }
            panel("MODIFY") {
                big("cursorarrow", "Select (Esc)", on: model.tool == .select) { model.tool = .select }
                big("rotate.right", "Rotate (R)") { model.rotateSelection() }.disabled(model.selection == nil)
                big("trash", "Delete") { model.deleteSelection() }.disabled(model.selection == nil)
            }
            panel("3D") {
                ZStack(alignment: .topTrailing) {
                    big("cube.transparent", model.linkedRevision == nil ? "Send board to the 3D design" : "Update the 3D board") { model.sendTo3D(design) }
                    if model.boardOutOfDate { Circle().fill(.orange).frame(width: 8, height: 8).offset(x: -4, y: 4) }
                }
                big("square.stack.3d.down.forward", "Mount on a part of the assembly") { model.startMount(design, show: openDesign) }
            }
            panel("OUTPUT") {
                big(PCBSymbol.export, "Export KiCad board") { exportKiCad() }
            }
            Spacer()
        }
        .padding(.horizontal, 6)
        .frame(height: 74)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func panel<Content: View>(_ name: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 2) {
                HStack(spacing: 2) { content() }
                Text(name).font(.system(size: 9.5, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.top, 4)
            Divider().frame(height: 54)
        }
    }

    private func big(_ symbol: String, _ help: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19))
                .frame(width: 40, height: 34)
                .foregroundStyle(on ? Color.white : Color.primary)
                .background(on ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func exportKiCad() {
        let p = NSSavePanel()
        p.nameFieldStringValue = (model.project?.name ?? "board") + ".kicad_pcb"
        p.allowsOtherFileTypes = true
        if p.runModal() == .OK, let url = p.url { model.exportKiCad(to: url) }
    }
}

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
