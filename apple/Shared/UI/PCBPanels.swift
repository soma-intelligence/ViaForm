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
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: PCBModel

    var body: some View {
        List(selection: Binding(get: { model.selection }, set: { model.selection = $0 })) {
            if let p = model.project {
                Section("Parts") {
                    ForEach(p.components) { c in
                        HStack {
                            Image(systemName: PCBSymbol.part(c.kind)).foregroundStyle(theme.inkSecondary).frame(width: 18).accessibilityHidden(true)
                            Text(c.reference).fontWeight(.semibold)
                            Text(c.value).foregroundStyle(theme.inkSecondary).lineLimit(1)
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
                    Label(String(localized: "\(VFFormat.value(p.board.width, .length, withUnit: false)) x \(VFFormat.length(p.board.height)), \(p.board.tracks.count) tracks"), systemImage: "square.dashed")
                    ForEach(p.board.tracks) { t in
                        Label(String(localized: "\(model.nets[t.net] ?? String(localized: "Net")) on \(t.layer)"), systemImage: "line.diagonal").tag(Optional(t.id))
                    }
                }
            }
        }
    }
}

/// ERC and DRC findings; tapping one selects its first object.
struct PCBChecksPanel: View {
    @Environment(\.viaFormTheme) private var theme
    let model: PCBModel

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpace.s) {
            HStack {
                Image(systemName: model.findings.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(model.findings.isEmpty ? theme.success : theme.warning)
                    .accessibilityHidden(true)
                Text(model.findings.isEmpty ? String(localized: "No ERC or DRC findings")
                                            : (model.findings.count == 1 ? String(localized: "1 finding") : String(localized: "\(model.findings.count) findings")))
                    .font(VFFont.title).foregroundStyle(theme.ink)
                Spacer()
                Text("\(model.checks?.airwires.count ?? 0) unrouted").font(VFFont.small).foregroundStyle(theme.inkSecondary)
            }
            ForEach(Array(model.findings.enumerated()), id: \.offset) { _, f in
                let error = f.severity == "error"
                Button { model.selection = f.objects?.first } label: {
                    HStack(alignment: .top, spacing: VFSpace.s) {
                        // A shape and a word per severity, never the colour alone.
                        Image(systemName: error ? "xmark.octagon.fill" : "exclamationmark.triangle")
                            .foregroundStyle(error ? theme.danger : theme.warning)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(error ? "Error" : "Warning").font(VFFont.caps).foregroundStyle(error ? theme.danger : theme.warning)
                            Text(f.message).font(VFFont.row).foregroundStyle(theme.ink).multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Selects the part it is about")
            }
        }
    }
}

/// Moving the selection without a drag: the arrow keys, the canvas menu, VoiceOver and the
/// inspector's X and Y fields.
extension PCBModel {
    /// Where the selected part sits on the current sheet, in millimetres.
    var selectionPosition: PCBPoint? {
        guard let id = selection else { return nil }
        if sheet == .schematic { return component(id)?.position }
        return footprint(id)?.position
    }

    /// Moves the selected part by `dx`, `dy` millimetres.
    func nudgeSelection(dx: Double, dy: Double) {
        guard let id = selection, let p = selectionPosition else { return }
        move(id, to: PCBPoint(x: p.x + dx, y: p.y + dy))
    }

    /// Moves the selected part to `p`, in millimetres.
    func moveSelection(to p: PCBPoint) {
        guard let id = selection else { return }
        move(id, to: p)
    }
}

/// The ECAD to MCAD link, from either workspace.
extension PCBModel {
    func syncLink(_ design: DesignModel) {
        linkedRevision = PCBLink.linkedRevision(design, self)
    }

    func sendTo3D(_ design: DesignModel) {
        let first = linkedRevision == nil
        if let err = PCBLink.push(self, into: design) {
            message = err; messageIsError = true
        } else {
            message = first ? String(localized: "Board sent to the 3D design") : String(localized: "3D board updated"); messageIsError = false
            if first { design.zoomToFit() }
        }
    }

    /// Asks the design for a face, then seats the board on it. `show` opens the design workspace.
    func startMount(_ design: DesignModel, show: () -> Void) {
        if linkedRevision == nil { sendTo3D(design) }
        guard linkedRevision != nil else { return }
        show()
        design.tool = .select
        design.facePickPrompt = String(localized: "Click the face the board sits on")
        design.facePick = { [weak self, weak design] body, point, normal in
            guard let self, let design else { return }
            if let err = PCBLink.mount(self, in: design, body: body, at: point, normal: normal) {
                design.flash(err, error: true)
            } else {
                design.flash(String(localized: "Board mounted on \(body) with a rigid joint"))
            }
        }
    }
}

/// In the design workspace: the pick prompt while mounting, and a notice when the board changed.
struct PCBLinkBanner: View {
    @Environment(\.viaFormTheme) private var theme
    let design: DesignModel
    let pcb: PCBModel

    var body: some View {
        if let prompt = design.facePickPrompt {
            HStack(spacing: VFSpace.m) {
                Image(systemName: "cpu").foregroundStyle(theme.accentText).accessibilityHidden(true)
                Text(prompt).font(VFFont.row).foregroundStyle(theme.ink)
                Button("Cancel") { design.facePick = nil; design.facePickPrompt = nil }.buttonStyle(.vfSecondary)
            }
            .padding(.horizontal, VFSpace.l).padding(.vertical, VFSpace.m)
            .vfSurface(.floating, radius: VFRadius.touchCapsule)
        } else if pcb.boardOutOfDate {
            HStack(spacing: VFSpace.m) {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath").foregroundStyle(theme.warning).accessibilityHidden(true)
                Text("The board changed in Electronics").font(VFFont.row).foregroundStyle(theme.ink)
                Button("Update 3D") { pcb.sendTo3D(design) }.buttonStyle(.vfPrimary)
            }
            .padding(.horizontal, VFSpace.l).padding(.vertical, VFSpace.m)
            .vfSurface(.floating, radius: VFRadius.touchCapsule)
        }
    }
}

/// The current PCB tool, as a label and a hint.
extension PCBModel {
    var toolHint: String? {
        switch tool {
        case .select: nil
        case let .place(kind): String(localized: "Click to place a \(kind).")
        case .wire: pending == nil ? String(localized: "Click a first pin.") : String(localized: "Click the second pin.")
        case .route: pending == nil ? String(localized: "Click a first pad.") : String(localized: "Click a pad on the same net.")
        }
    }
}
