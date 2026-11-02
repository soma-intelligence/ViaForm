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
