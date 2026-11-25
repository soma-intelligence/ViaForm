import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The numbers of the mass properties report (M-21), read from the engine:
/// mass, volume and area from `inspect.measure`; the centre of mass from `component.properties`
/// (material aware) for the whole design, from `inspect.measure` for one body, from
/// `inspect.center_of_mass` for several; the inertia tensor from `component.properties`.
struct MassReport: Equatable {
    enum Frame: String, CaseIterable, Identifiable {
        case centerOfMass, origin
        var id: String { rawValue }
        var title: String {
            switch self {
            case .centerOfMass: String(localized: "Centre of mass")
            case .origin: String(localized: "Origin")
            }
        }
    }

    /// The bodies measured; empty means all of them.
    var bodies: [String]
    var bodyCount: Int
    var mass: Double
    var volume: Double
    var area: Double
    var density: Double?
    var center: SIMD3<Double>
    /// g·mm², about `frame`'s point, world axes; nil when the engine could not tell.
    var inertia: [[Double]]?
    var principal: [Double]?
    var frame: Frame
    var openSkipped: Int
    /// Why the inertia is missing, when it is.
    var note: String?

    static func read(_ m: DesignModel, bodies: [String], about frame: Frame) -> MassReport? {
        let all = bodies.isEmpty || Set(bodies) == Set(m.snapshot.bodies.map(\.name))
        guard let measure = try? m.engine.execute("inspect.measure", all ? [:] : ["bodies": bodies]) as? [String: Any],
              let total = measure["total"] as? [String: Any] else { return nil }
        let rows = measure["bodies"] as? [[String: Any]] ?? []
        var r = MassReport(bodies: all ? [] : bodies, bodyCount: rows.count,
                           mass: total["mass_g"] as? Double ?? 0, volume: total["volume_mm3"] as? Double ?? 0,
                           area: total["area_mm2"] as? Double ?? 0, density: nil, center: .zero, inertia: nil,
                           principal: nil, frame: frame, openSkipped: total["open_bodies_skipped"] as? Int ?? 0)
        if rows.count == 1 { r.density = rows[0]["density_g_cm3"] as? Double }

        let props = try? m.engine.execute("component.properties", frame == .origin ? ["about": [0, 0, 0]] : [:]) as? [String: Any]
        let ptotal = props?["total"] as? [String: Any]
        if all {
            r.center = vec(ptotal?["center_of_mass"]) ?? .zero
            r.inertia = frame == .origin ? matrix((ptotal?["inertia_about"] as? [String: Any])?["inertia_g_mm2"])
                                         : matrix(ptotal?["inertia_g_mm2"])
            r.principal = (ptotal?["principal_moments_g_mm2"] as? [Double])
        } else if rows.count == 1 {
            r.center = vec(rows[0]["center_of_mass"]) ?? .zero
            let own = (props?["bodies"] as? [[String: Any]])?.first { $0["name"] as? String == bodies.first }
            if frame == .centerOfMass { r.inertia = matrix(own?["inertia_g_mm2"]) }
            else { r.note = String(localized: "Relative to the origin needs the whole design selected.") }
        } else {
            let c = try? m.engine.execute("inspect.center_of_mass", ["bodies": bodies]) as? [String: Any]
            r.center = vec(c?["center"]) ?? .zero
            r.note = String(localized: "Inertia is given for one body or the whole design.")
        }
        if r.inertia == nil, r.note == nil, r.mass > 0 { r.note = String(localized: "The engine could not compute the inertia of these bodies.") }
        return r
    }

    private static func vec(_ v: Any?) -> SIMD3<Double>? {
        if let a = v as? [Double], a.count == 3 { return SIMD3(a[0], a[1], a[2]) }
        if let d = v as? [String: Double], let x = d["x"], let y = d["y"], let z = d["z"] { return SIMD3(x, y, z) }
        return nil
    }

    private static func matrix(_ v: Any?) -> [[Double]]? {
        guard let rows = v as? [[Double]], rows.count == 3, rows.allSatisfy({ $0.count == 3 }) else { return nil }
        return rows
    }

    /// The report as plain text, for Copy to Clipboard.
    var clipboardText: String {
        var lines: [String] = []
        lines.append(String(localized: "Mass properties of \(bodies.isEmpty ? String(localized: "all bodies") : bodies.joined(separator: ", "))"))
        lines.append(String(localized: "Mass: \(VFFormat.mass(mass))"))
        lines.append(String(localized: "Volume: \(VFFormat.volume(volume))"))
        lines.append(String(localized: "Surface area: \(VFFormat.area(area))"))
        if let density { lines.append(String(localized: "Density: \(VFFormat.number(density, digits: 3)) g/cm³")) }
        lines.append(String(localized: "Centre of mass: X \(VFFormat.length(center.x)), Y \(VFFormat.length(center.y)), Z \(VFFormat.length(center.z))"))
        if let inertia {
            lines.append(String(localized: "Moments of inertia, relative to \(frame.title.lowercased()), world axes:"))
            for (i, row) in inertia.enumerated() {
                lines.append("  " + ["X", "Y", "Z"][i] + ": " + VFFormat.inertia(row.map { $0 / 1000 }))
            }
        }
        if let principal { lines.append(String(localized: "Principal moments: \(VFFormat.inertia(principal.map { $0 / 1000 }))")) }
        if openSkipped > 0 { lines.append(String(localized: "\(openSkipped) open bodies left out of mass and volume")) }
        return lines.joined(separator: "\n")
    }
}

/// The mass properties report panel (M-21): mass, volume, area, centre of mass, the inertia
/// tensor relative to a chosen frame, and Copy to Clipboard. Reads the selected bodies, else all.
/// Present it in the Mac inspector or a sheet, and in an iPad popover.
struct MassPropertiesView: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    var onDone: (() -> Void)? = nil
    @State private var frame: MassReport.Frame = .centerOfMass
    @State private var report: MassReport?
    @State private var copied = false

    private var bodies: [String] { model.bodiesInSelection }
    private var token: String { "\(model.snapshot.revision)|\(model.snapshot.undo)|\(bodies.joined(separator: ","))|\(frame.rawValue)" }

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpace.m) {
            HStack {
                VFCaption(String(localized: "Mass properties"))
                Spacer()
                if let onDone {
                    VFIconButton("xmark", label: String(localized: "Close"), size: 11) { onDone() }
                }
            }
            if let r = report, r.bodyCount > 0 {
                Text(r.bodies.isEmpty ? String(localized: "All bodies, \(r.bodyCount)") : r.bodies.joined(separator: ", "))
                    .font(VFFont.small).foregroundStyle(theme.inkSecondary).lineLimit(2)
                Picker(String(localized: "Relative to"), selection: $frame) {
                    ForEach(MassReport.Frame.allCases) { f in Text(f.title).tag(f) }
                }
                .pickerStyle(.segmented)
                .font(VFFont.row)
                group {
                    KVRow(String(localized: "Mass"), VFFormat.mass(r.mass))
                    KVRow(String(localized: "Volume"), VFFormat.volume(r.volume))
                    KVRow(String(localized: "Surface area"), VFFormat.area(r.area))
                    if let d = r.density { KVRow(String(localized: "Density"), VFFormat.number(d, digits: 3) + " g/cm³") }
                }
                VFCaption(String(localized: "Centre of mass"))
                group {
                    KVRow("X", VFFormat.length(r.center.x))
                    KVRow("Y", VFFormat.length(r.center.y))
                    KVRow("Z", VFFormat.length(r.center.z))
                }
                VFCaption(String(localized: "Moments of inertia"))
                if let t = r.inertia {
                    tensor(t)
                    if let p = r.principal {
                        KVRow(String(localized: "Principal"), VFFormat.inertia(p.map { $0 / 1000 }))
                            .font(VFFont.small)
                    }
                } else if let n = r.note {
                    Text(n).font(VFFont.small).foregroundStyle(theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if r.openSkipped > 0 {
                    Label(String(localized: "\(r.openSkipped) open bodies left out of mass and volume"), systemImage: "exclamationmark.triangle.fill")
                        .font(VFFont.small).foregroundStyle(theme.warning)
                }
                Button {
                    copy(r.clipboardText)
                } label: {
                    Label(copied ? String(localized: "Copied") : String(localized: "Copy to Clipboard"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.vfSecondary).controlSize(.small)
            } else {
                EmptyState(String(localized: "Nothing to measure"), systemImage: "scalemass",
                           message: String(localized: "Add a solid body, then its mass, centre of mass and inertia show here."))
            }
        }
        .onAppear(perform: reload)
        .onChange(of: token) { _, _ in reload() }
    }

    private func group<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: VFSpace.xxs) { content() }.font(VFFont.row)
    }

    /// The 3 x 3 tensor, one row per axis, in the display units.
    private func tensor(_ t: [[Double]]) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: VFSpace.m, verticalSpacing: VFSpace.xxs) {
            ForEach(0..<3, id: \.self) { i in
                GridRow {
                    Text(["X", "Y", "Z"][i]).font(VFFont.small).foregroundStyle(theme.inkSecondary)
                    ForEach(0..<3, id: \.self) { k in
                        Text(VFFormat.significant(t[i][k] / 1000 / unitFactor, digits: 3))
                            .font(VFFont.small).monospacedDigit().foregroundStyle(theme.ink)
                            .lineLimit(1)
                    }
                }
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                Text(VFFormat.inertiaSymbol()).font(VFFont.micro).foregroundStyle(theme.inkTertiary)
                    .gridCellColumns(3)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Inertia tensor, relative to \(frame.title)"))
    }

    /// kg·mm² per display unit of inertia (as `VFFormat.inertia` converts).
    private var unitFactor: Double {
        let u = UnitSettings.current
        let massFactor = u.mass == .g ? 1 : u.mass.factor / 1000
        return massFactor * u.length.factor * u.length.factor
    }

    private func reload() {
        report = MassReport.read(model, bodies: bodies, about: frame)
        copied = false
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
        copied = true
    }
}
