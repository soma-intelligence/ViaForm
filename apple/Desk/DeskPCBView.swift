#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The desktop electronics workspace, laid out like the design one: SCHEMATIC and PCB tabs over
/// their panels, the sheet filling the window, a floating browser on the left and a floating
/// inspector (the link to 3D and the rule checks) on the right.
struct DeskPCBView: View {
    @Bindable var model: PCBModel
    let design: DesignModel
    let openDesign: () -> Void
    @State private var showBrowser = true
    @State private var showInspector = true
    @State private var open: Set<String> = ["Parts", "Board"]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ZStack(alignment: .top) {
                PCBCanvas(model: model)
                HStack(alignment: .top) {
                    if showBrowser { browser.frame(width: 250) } else { reopen("sidebar.left", "Show the browser") { showBrowser = true } }
                    Spacer()
                    if showInspector { inspector.frame(width: 280) } else { reopen("sidebar.right", "Show the inspector") { showInspector = true } }
                }
                .padding(10)
                VStack(spacing: 6) {
                    if let hint = model.toolHint { pill(hint, color: .secondary) }
                    if let m = model.message { pill(m, color: model.messageIsError ? .red : .primary) }
                }
                .padding(10)
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

    // MARK: Floating panels

    private func floating<Content: View>(_ title: String, close: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                Spacer()
                Button(action: close) { Image(systemName: "minus").font(.system(size: 10, weight: .bold)) }.buttonStyle(.plain)
            }
            .padding(.horizontal, 10).frame(height: 26)
            .background(Color(nsColor: .controlBackgroundColor))
            ScrollView { content().padding(.vertical, 4) }.frame(maxHeight: 420)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.12)))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func reopen(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 28, height: 24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain).help(help)
    }

    private var browser: some View {
        floating("BROWSER", close: { showBrowser = false }) {
            VStack(alignment: .leading, spacing: 1) {
                if let p = model.project {
                    treeRow(0, "cpu", p.name ?? "Untitled circuit", bold: true)
                    folder("Parts", "folder", count: p.components.count) {
                        ForEach(p.components) { c in
                            treeRow(2, PCBSymbol.part(c.kind), c.reference, detail: c.value, selected: model.selection == c.id)
                                .onTapGesture { model.selection = c.id }
                        }
                    }
                    folder("Nets", "folder", count: p.nets.count) {
                        ForEach(p.nets) { n in
                            treeRow(2, "circle.hexagongrid", n.name, selected: model.selection == n.id)
                                .onTapGesture { model.selection = n.id }
                        }
                    }
                    folder("Board", "folder", detail: String(format: "%.0f × %.0f mm", p.board.width, p.board.height)) {
                        ForEach(p.board.tracks) { t in
                            treeRow(2, "line.diagonal", model.nets[t.net] ?? "net", detail: "on \(t.layer)", selected: model.selection == t.id)
                                .onTapGesture { model.selection = t.id }
                        }
                    }
                }
            }
        }
    }

    private var inspector: some View {
        floating("INSPECTOR", close: { showInspector = false }) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Board in 3D").font(.system(size: 12, weight: .semibold))
                Text(model.linkedRevision.map { linked in
                    model.boardOutOfDate ? "Built from revision \(linked); the board is now at \(model.revision)." : "Up to date with board revision \(model.revision)."
                } ?? "The board is not in the 3D design yet.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    Button(model.linkedRevision == nil ? "Send to 3D" : "Update 3D") { model.sendTo3D(design) }.buttonStyle(.borderedProminent)
                    Button("Mount on a part") { model.startMount(design, show: openDesign) }
                }
                .controlSize(.small)
                Divider().padding(.vertical, 2)
                PCBChecksPanel(model: model)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
    }

    private func folder<Content: View>(_ name: String, _ symbol: String, count: Int? = nil, detail: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                if open.contains(name) { open.remove(name) } else { open.insert(name) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: open.contains(name) ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold)).frame(width: 10)
                    Image(systemName: symbol).foregroundStyle(.secondary)
                    Text(name)
                    if let d = detail ?? count.map(String.init) { Text(d).foregroundStyle(.secondary) }
                    Spacer()
                }
                .font(.system(size: 12))
                .padding(.leading, 14).frame(height: 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open.contains(name) { content() }
        }
    }

    private func treeRow(_ indent: Int, _ symbol: String, _ text: String, detail: String? = nil, bold: Bool = false, selected: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 14)
            Text(text).fontWeight(bold ? .semibold : .regular).lineLimit(1)
            if let detail { Text(detail).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
        }
        .font(.system(size: 12))
        .padding(.leading, CGFloat(10 + indent * 13)).frame(height: 20)
        .background(selected ? Color.accentColor.opacity(0.2) : .clear)
        .contentShape(Rectangle())
    }

    // MARK: Toolbar

    private var toolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(PCBModel.Sheet.allCases, id: \.self) { s in
                    let name = s == .schematic ? "SCHEMATIC" : "PCB"
                    Button { model.sheet = s; model.tool = .select } label: {
                        Text(name).font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .foregroundStyle(model.sheet == s ? Color.accentColor : .primary)
                            .overlay(alignment: .bottom) { if model.sheet == s { Rectangle().fill(Color.accentColor).frame(height: 2) } }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .frame(height: 28)
            panels.frame(height: 70)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var panels: some View {
        HStack(alignment: .top, spacing: 0) {
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
