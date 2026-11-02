import SwiftUI

/// Tool symbols for the electronics workspace.
enum PCBSymbol {
    static func part(_ kind: String) -> String {
        switch kind {
        case "resistor": "rectangle.portrait"
        case "capacitor": "pause"
        case "led": "lightbulb"
        default: "cable.connector.horizontal"
        }
    }
    static let wire = "point.topleft.down.to.point.bottomright.curvepath"
    static let route = "point.3.connected.trianglepath.dotted"
    static let routeAll = "point.3.filled.connected.trianglepath.dotted"
    static let update = "arrow.triangle.2.circlepath"
    static let checks = "checkmark.shield"
    static let export = "square.and.arrow.up"
}

/// Parts, nets and board items, with selection.
struct PCBBrowser: View {
    @Bindable var model: PCBModel

    var body: some View {
        List(selection: Binding(get: { model.selection }, set: { model.selection = $0 })) {
            if let p = model.project {
                Section("Parts") {
                    ForEach(p.components) { c in
                        HStack {
                            Image(systemName: PCBSymbol.part(c.kind)).foregroundStyle(.secondary).frame(width: 18)
                            Text(c.reference).fontWeight(.semibold)
                            Text(c.value).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .tag(Optional(c.id))
                    }
                }
                Section("Nets") {
                    ForEach(p.nets) { n in
                        Label(n.name, systemImage: "circle.hexagongrid").tag(Optional(n.id))
                    }
                }
                Section("Board") {
                    Label(String(format: "%.0f × %.0f mm, %d tracks", p.board.width, p.board.height, p.board.tracks.count), systemImage: "square.dashed")
                    ForEach(p.board.tracks) { t in
                        Label("\(model.nets[t.net] ?? "net") on \(t.layer)", systemImage: "line.diagonal").tag(Optional(t.id))
                    }
                }
            }
        }
    }
}

/// ERC and DRC findings; tapping one selects its first object.
struct PCBChecksPanel: View {
    let model: PCBModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: model.findings.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(model.findings.isEmpty ? .green : .orange)
                Text(model.findings.isEmpty ? "No ERC or DRC findings" : "\(model.findings.count) findings").font(.headline)
                Spacer()
                Text("\(model.checks?.airwires.count ?? 0) unrouted").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(model.findings.enumerated()), id: \.offset) { _, f in
                Button { model.selection = f.objects?.first } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: f.severity == "error" ? "xmark.octagon.fill" : "exclamationmark.triangle")
                            .foregroundStyle(f.severity == "error" ? .red : .orange)
                        Text(f.message).font(.callout).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The ECAD to MCAD link, from either workspace.
extension PCBModel {
    func syncLink(_ design: DesignModel) {
        linkedRevision = project.flatMap { PCBLink.linkedRevision(design, $0) }
    }

    func sendTo3D(_ design: DesignModel) {
        let first = linkedRevision == nil
        if let err = PCBLink.push(self, into: design) {
            message = err; messageIsError = true
        } else {
            message = first ? "Board sent to the 3D design" : "3D board updated"; messageIsError = false
            if first { design.zoomToFit() }
        }
    }

    /// Asks the design for a face, then seats the board on it. `show` opens the design workspace.
    func startMount(_ design: DesignModel, show: () -> Void) {
        if linkedRevision == nil { sendTo3D(design) }
        guard linkedRevision != nil else { return }
        show()
        design.tool = .select
        design.facePickPrompt = "Click the face the board sits on"
        design.facePick = { [weak self, weak design] body, point, normal in
            guard let self, let design else { return }
            if let err = PCBLink.mount(self, in: design, body: body, at: point, normal: normal) {
                design.flash(err, error: true)
            } else {
                design.flash("Board mounted on \(body) with a rigid joint")
            }
        }
    }
}

/// In the design workspace: the pick prompt while mounting, and a notice when the board changed.
struct PCBLinkBanner: View {
    let design: DesignModel
    let pcb: PCBModel

    var body: some View {
        if let prompt = design.facePickPrompt {
            HStack(spacing: 10) {
                Image(systemName: "cpu").foregroundStyle(Color.accentColor)
                Text(prompt).font(.callout)
                Button("Cancel") { design.facePick = nil; design.facePickPrompt = nil }.buttonStyle(.bordered)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
        } else if pcb.boardOutOfDate {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath").foregroundStyle(.orange)
                Text("The board changed in Electronics").font(.callout)
                Button("Update 3D") { pcb.sendTo3D(design) }.buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
        }
    }
}

/// The current PCB tool, as a label and a hint.
extension PCBModel {
    var toolHint: String? {
        switch tool {
        case .select: nil
        case let .place(kind): "Click to place a \(kind)."
        case .wire: pending == nil ? "Click a first pin." : "Click the second pin."
        case .route: pending == nil ? "Click a first pad." : "Click a pad on the same net."
        }
    }
}
