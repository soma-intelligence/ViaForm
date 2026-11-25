import Charts
import SwiftUI
import UniformTypeIdentifiers
import ViaFormFFI
#if os(macOS)
import AppKit
#endif

// The Outcomes screen (VIAFORM-SPEC 7.10.3): the gallery sorted by a chosen figure beside the
// Pareto chart (mass against safety factor, the front highlighted), mesh checks per candidate
// from the engine (`vf_generate_check_mesh`), export of a candidate's surface
// (`vf_generate_export_mesh`, STL, 3MF or OBJ) and two candidates compared side by side.

// MARK: Sort

/// What the gallery is ordered by. Each order puts the better value first.
enum OutcomeSort: String, CaseIterable, Identifiable, Sendable {
    case mass, safety, stress, displacement, cost, iteration

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mass: String(localized: "Mass, lightest first")
        case .safety: String(localized: "Safety factor, highest first")
        case .stress: String(localized: "Peak stress, lowest first")
        case .displacement: String(localized: "Displacement, smallest first")
        case .cost: String(localized: "Cost, cheapest first")
        case .iteration: String(localized: "Iterations, fewest first")
        }
    }

    /// Candidate indices in this order; ties keep the engine's order.
    func ordered(_ cs: [StudyCandidate]) -> [Int] {
        func key(_ c: StudyCandidate) -> Double {
            switch self {
            case .mass: c.massG
            case .safety: c.analysis.safetyFactor.isFinite ? -c.analysis.safetyFactor : -.greatestFiniteMagnitude
            case .stress: c.analysis.worstStress
            case .displacement: c.analysis.worstDisplacement
            case .cost: c.cost ?? .greatestFiniteMagnitude
            case .iteration: Double(c.keptIteration ?? c.history.count)
            }
        }
        return cs.indices.sorted { a, b in
            let ka = key(cs[a]), kb = key(cs[b])
            return ka == kb ? a < b : ka < kb
        }
    }
}

/// The two candidates the compare sheet shows.
struct OutcomePair: Identifiable, Equatable {
    var a: Int
    var b: Int
    var id: String { "\(a)-\(b)" }
}

// MARK: Mesh checks

/// One mesh check as the engine answers it.
struct MeshCheckItem: Identifiable, Sendable, Equatable {
    enum Status: String, Sendable {
        case pass, warning, fail, skipped

        var word: String {
            switch self {
            case .pass: String(localized: "Pass")
            case .warning: String(localized: "Warning")
            case .fail: String(localized: "Fail")
            case .skipped: String(localized: "Not checked")
            }
        }

        var symbol: String {
            switch self {
            case .pass: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .fail: "xmark.octagon.fill"
            case .skipped: "minus.circle"
            }
        }
    }

    var id: String
    var name: String
    var status: Status
    var value: Double?
    var limit: Double?
    var unit: String
    var detail: String
    /// The box around the worst spot, to frame in the preview.
    var spot: (lo: Vec3, hi: Vec3)?

    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.status == b.status && a.value == b.value && a.limit == b.limit && a.detail == b.detail
    }

    /// "0.82 mm, at least 0.8 mm"; counts without decimals. Lengths and areas follow the
    /// reader's length unit (`VFFormat`).
    var figure: String {
        guard let value else { return "–" }
        func text(_ v: Double, limit: Bool) -> String {
            switch unit {
            case "mm": VFFormat.length(v, digits: limit ? 1 : 2)
            case "mm²": VFFormat.area(v)
            default: "\(v.formatted(.number.precision(.fractionLength(0)))) \(unit)"
            }
        }
        // "1 body", not "1 bodies".
        let v = unit == "bodies" && value == 1 ? String(localized: "1 body") : text(value, limit: false)
        guard let limit, status != .skipped, id == "min_wall" || id == "bodies" else { return v }
        return id == "min_wall" ? String(localized: "\(v), at least \(text(limit, limit: true))")
                                : String(localized: "\(v), up to \(limit.formatted(.number.precision(.fractionLength(0))))")
    }

    /// The canvas map that shows this check on the model, when there is one and it applies.
    var map: CandidateMap? { status == .skipped ? nil : CandidateMap(check: id) }
}

/// Every mesh check on one candidate's surface.
struct MeshCheckReport: Sendable, Equatable {
    var items: [MeshCheckItem] = []
    var triangles = 0
    var minWall: Double?
    var passed = false
    var warnings = 0
    var failures = 0
    var seconds = 0.0

    init(items: [MeshCheckItem] = []) { self.items = items }

    init(_ o: [String: Any]) {
        func num(_ v: Any?) -> Double? { (v as? Double) ?? (v as? Int).map(Double.init) }
        func vec(_ v: Any?) -> Vec3? {
            guard let a = v as? [Any], a.count == 3, let x = num(a[0]), let y = num(a[1]), let z = num(a[2]) else { return nil }
            return Vec3(x, y, z)
        }
        items = (o["checks"] as? [[String: Any]] ?? []).map { c in
            let spot = (c["spot"] as? [String: Any]).flatMap { s in vec(s["min"]).flatMap { lo in vec(s["max"]).map { (lo: lo, hi: $0) } } }
            return MeshCheckItem(id: c["id"] as? String ?? "", name: c["name"] as? String ?? "",
                                 status: MeshCheckItem.Status(rawValue: c["status"] as? String ?? "") ?? .skipped,
                                 value: num(c["value"]), limit: num(c["limit"]), unit: c["unit"] as? String ?? "",
                                 detail: c["detail"] as? String ?? "", spot: spot)
        }
        triangles = (o["triangles"] as? Int) ?? 0
        minWall = num(o["min_wall_mm"])
        passed = o["passed"] as? Bool ?? false
        warnings = o["warnings"] as? Int ?? 0
        failures = o["failures"] as? Int ?? 0
        seconds = num(o["seconds"]) ?? 0
    }

    func item(_ id: String) -> MeshCheckItem? { items.first { $0.id == id } }

    /// "All checks pass", "1 warning", "2 failed, 1 warning".
    var summary: String {
        if passed { return String(localized: "All checks pass") }
        var parts: [String] = []
        if failures > 0 { parts.append(failures == 1 ? String(localized: "1 failed") : String(localized: "\(failures) failed")) }
        if warnings > 0 { parts.append(warnings == 1 ? String(localized: "1 warning") : String(localized: "\(warnings) warnings")) }
        return parts.joined(separator: ", ")
    }

    /// The worst status among the checks.
    var status: MeshCheckItem.Status { failures > 0 ? .fail : (warnings > 0 ? .warning : .pass) }
}

// MARK: Export

enum MeshExportFormat: String, CaseIterable, Identifiable, Sendable {
    case stl, threeMF = "3mf", obj

    var id: String { rawValue }
    var title: String {
        switch self {
        case .stl: "STL"
        case .threeMF: "3MF"
        case .obj: "OBJ"
        }
    }
    var menuTitle: String {
        switch self {
        case .stl: String(localized: "STL (printing)")
        case .threeMF: String(localized: "3MF (printing, with units)")
        case .obj: String(localized: "OBJ (rendering)")
        }
    }
    var contentType: UTType { UTType(filenameExtension: rawValue) ?? .data }
}

/// An export that failed, kept so it can be tried again.
struct OutcomeExportFailure: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var candidate: Int
    var format: MeshExportFormat
}

extension GenerateEngine {
    /// Runs the engine's mesh checks on a surface (call off the main actor). `request` is the
    /// engine's JSON request (`CheckRequest`).
    static func checkMesh(_ mesh: StudyMesh, request: String) throws -> MeshCheckReport {
        let reply: UnsafeMutablePointer<CChar>? = mesh.positions.withUnsafeBufferPointer { p in
            mesh.indices.withUnsafeBufferPointer { i in
                vf_generate_check_mesh(p.baseAddress, UInt64(mesh.vertexCount), i.baseAddress, UInt64(mesh.indices.count), request)
            }
        }
        guard let reply else { throw EngineError(message: "No reply from the generative engine") }
        defer { sc_string_free(reply) }
        let obj = try? JSONSerialization.jsonObject(with: Data(String(cString: reply).utf8)) as? [String: Any]
        if let e = obj?["error"] as? String { throw EngineError(message: e) }
        guard let ok = obj?["ok"] as? [String: Any] else { throw EngineError(message: "The engine answered no checks") }
        return MeshCheckReport(ok)
    }

    /// Writes a surface to `url` as `format` (call off the main actor). Answers the bytes written.
    static func exportMesh(_ mesh: StudyMesh, to url: URL, format: MeshExportFormat, name: String) throws -> Int {
        let request: [String: Any] = ["path": url.path, "format": format.rawValue, "name": name]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let reply: UnsafeMutablePointer<CChar>? = mesh.positions.withUnsafeBufferPointer { p in
            mesh.indices.withUnsafeBufferPointer { i in
                vf_generate_export_mesh(p.baseAddress, UInt64(mesh.vertexCount), i.baseAddress, UInt64(mesh.indices.count), text)
            }
        }
        guard let reply else { throw EngineError(message: "No reply from the generative engine") }
        defer { sc_string_free(reply) }
        let obj = try? JSONSerialization.jsonObject(with: Data(String(cString: reply).utf8)) as? [String: Any]
        if let e = obj?["error"] as? String { throw EngineError(message: e) }
        guard let ok = obj?["ok"] as? [String: Any] else { throw EngineError(message: "The engine answered nothing about the file") }
        return (ok["bytes"] as? Int) ?? 0
    }
}

// MARK: Model

extension GenerateModel {
    /// The gallery's order for the shown outcome.
    var sortedOutcomes: [Int] { outcome.map { outcomeSort.ordered($0.candidates) } ?? [] }

    /// The candidates no other beats on both mass (lower) and safety factor (higher).
    var paretoFront: Set<Int> { Self.paretoFront(outcome?.candidates ?? []) }

    nonisolated static func paretoFront(_ cs: [StudyCandidate]) -> Set<Int> {
        func sf(_ c: StudyCandidate) -> Double { c.analysis.safetyFactor.isFinite ? c.analysis.safetyFactor : .greatestFiniteMagnitude }
        var front = Set<Int>()
        for (i, c) in cs.enumerated() {
            let beaten = cs.enumerated().contains { j, d in
                j != i && d.massG <= c.massG && sf(d) >= sf(c) && (d.massG < c.massG || sf(d) > sf(c))
            }
            if !beaten { front.insert(i) }
        }
        return front
    }

    /// The engine's check request for a study: its process (the picked variant's route when one
    /// was pushed), build direction and overhang, and the bodies it allows.
    nonisolated static func checkRequest(_ s: Study, route: Route?) -> String {
        var r: [String: Any] = ["max_bodies": max(1, s.maxBodies), "overhang": s.manufacturing.overhang]
        let process: String
        switch route {
        case .fdm: process = "fdm"
        case .sls: process = "sls"
        case .cnc3: process = "milling"
        case nil:
            switch s.manufacturing.process {
            case .free: process = "free"
            case .additive: process = "additive"
            case .extrusion: process = "extrusion"
            case .milling: process = "milling"
            }
        }
        r["process"] = process
        if process == "additive" || process == "fdm" { r["build"] = s.manufacturing.direction.array }
        return (try? JSONSerialization.data(withJSONObject: r, options: .sortedKeys)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// Checks every candidate's surface off the main actor, once per outcome; a newer outcome
    /// drops the answers of the old one.
    func runMeshChecks() async {
        guard let o = outcome, let s = studied, meshChecksFor != outcomeVersion else { return }
        let version = outcomeVersion
        meshChecksFor = version
        meshChecks = [:]
        meshCheckErrors = [:]
        let request = Self.checkRequest(s, route: pickedRoute)
        // The picked candidate first, so its inspector fills soonest.
        let order = (selected.map { [$0] } ?? []) + o.candidates.indices.filter { $0 != selected }
        for i in order {
            guard let c = o.candidates[safe: i] else { continue }
            let mesh = c.mesh
            let r = await Task.detached(priority: .utility) { () -> Result<MeshCheckReport, any Error> in
                Result { try GenerateEngine.checkMesh(mesh, request: request) }
            }.value
            guard version == outcomeVersion else { return }
            switch r {
            case .success(let rep): meshChecks[i] = rep
            case .failure(let e): meshCheckErrors[i] = e.localizedDescription
            }
        }
    }

    /// Shows a mesh check on the model: its map on the canvas (overhang, wall thickness, tool
    /// access) and its worst spot framed, with some room around it.
    func focus(_ item: MeshCheckItem) {
        if let map = item.map {
            CandidateMapState.of(self).map = map
            display = .result
        }
        guard let spot = item.spot else { return }
        let pad = Vec3(repeating: 4)
        display = .result
        focusBox = (spot.lo - pad, spot.hi + pad)
        focusVersion += 1
    }

    /// The file name an export proposes: "Bracket candidate 2.stl".
    func exportName(_ i: Int) -> String {
        let base = (studied?.name ?? study.name).trimmingCharacters(in: .whitespaces)
        return String(localized: "\(base.isEmpty ? "Generated" : base) candidate \(i + 1)")
    }

    /// Writes candidate `i`'s surface to `url` off the main actor. A failure stays in
    /// `exportFailure` until dismissed or tried again.
    func writeExport(_ i: Int, format: MeshExportFormat, to url: URL) async -> Result<Int, any Error> {
        guard let c = outcome?.candidates[safe: i] else {
            let e = EngineError(message: String(localized: "No candidate \(i + 1) to export."))
            exportFailure = OutcomeExportFailure(message: e.message, candidate: i, format: format)
            return .failure(e)
        }
        exporting = true
        exportFailure = nil
        let mesh = c.mesh, name = exportName(i)
        let r = await Task.detached(priority: .userInitiated) { () -> Result<Int, any Error> in
            Result { try GenerateEngine.exportMesh(mesh, to: url, format: format, name: name) }
        }.value
        exporting = false
        if case .failure(let e) = r {
            exportFailure = OutcomeExportFailure(message: String(localized: "Could not export: \(e.localizedDescription)"), candidate: i, format: format)
        }
        return r
    }

    /// The default pair for Compare: the picked candidate against the best (or the next one).
    var defaultComparePair: OutcomePair? {
        guard let o = outcome, o.candidates.count >= 2 else { return nil }
        let a = selected ?? o.best
        let b = a != o.best ? o.best : (sortedOutcomes.first { $0 != a } ?? (a == 0 ? 1 : 0))
        return OutcomePair(a: a, b: b)
    }
}

// MARK: Bottom panel

/// The outcome gallery sorted by a chosen figure, beside the Pareto chart. Hovering a card or a
/// dot lights the other; a click on either picks the candidate.
struct OutcomesPanel: View {
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: GenerateModel

    var body: some View {
        if let o = model.outcome, let s = model.studied {
            VStack(alignment: .leading, spacing: VFSpace.m) {
                HStack(spacing: VFSpace.l) {
                    // Title over its count, so the sort and compare controls keep their room.
                    VStack(alignment: .leading, spacing: VFSpace.xxs) {
                        Text("Outcomes").font(VFFont.title).foregroundStyle(theme.ink)
                        Text(o.candidates.count == 1 ? String(localized: "1 candidate") : String(localized: "\(o.candidates.count) candidates"))
                            .font(VFFont.row).foregroundStyle(theme.inkSecondary)
                    }
                    .lineLimit(1)
                    .fixedSize()
                    Spacer(minLength: VFSpace.m)
                    VFMenuPicker(String(localized: "Sort by"), selection: $model.outcomeSort,
                                 items: Array(OutcomeSort.allCases), title: { $0.title })
                    .help("Order of the candidates in the gallery")
                    Button { model.comparing = model.defaultComparePair } label: { Label("Compare…", systemImage: "rectangle.split.2x1") }
                        .buttonStyle(.vfSecondary)
                        .fixedSize()
                        .vfDisabled(o.candidates.count < 2, reason: String(localized: "Run at least two candidates to compare (Variants in Study)."))
                }
                .padding(.horizontal, VFSpace.l)
                // Side by side when the strip keeps room for two cards; stacked otherwise
                // (iPad portrait, narrow Mac window), so a card is never cut by the chart.
                let stacked = width > 0 && width < Self.chartWidth + Self.stripMinWidth + VFSpace.l * 3
                let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: VFSpace.l))
                                     : AnyLayout(HStackLayout(alignment: .top, spacing: VFSpace.l))
                layout {
                    CandidateStrip(model: model, order: model.sortedOutcomes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if o.candidates.count > 1 {
                        if stacked { Divider().padding(.horizontal, VFSpace.l) } else { Divider() }
                        ParetoChart(candidates: o.candidates, study: s, front: model.paretoFront, selected: model.selected,
                                    hovered: model.hoveredOutcome,
                                    onSelect: { model.selected = $0; model.display = .result },
                                    onHover: { model.hoveredOutcome = $0 })
                            .frame(maxWidth: stacked ? .infinity : Self.chartWidth)
                            .frame(height: 190)
                            .padding(stacked ? .horizontal : .trailing, VFSpace.l)
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
    }

    @State private var width: CGFloat = 0
    private static let chartWidth: CGFloat = 360
    private static let stripMinWidth: CGFloat = 320
}

// MARK: Pareto chart

/// Mass against safety factor, one dot per candidate: the Pareto front (no candidate is both
/// lighter and safer) drawn as a line, the required safety factor as a dashed rule, dots sized by
/// the first natural frequency when known. Front and dominated dots differ in shape and words,
/// not only colour.
struct ParetoChart: View {
    @Environment(\.viaFormTheme) private var theme
    let candidates: [StudyCandidate]
    let study: Study
    let front: Set<Int>
    let selected: Int?
    let hovered: Int?
    var onSelect: (Int) -> Void
    var onHover: (Int?) -> Void

    struct Point: Identifiable {
        let id: Int
        let mass: Double
        let factor: Double
        /// No stress anywhere: plotted at the top of the scale.
        let unbounded: Bool
        let front: Bool
        let feasible: Bool
        let frequency: Double?
    }

    nonisolated static let frontName = String(localized: "Pareto front")
    nonisolated static let otherName = String(localized: "Dominated")

    var points: [Point] {
        let finite = candidates.map(\.analysis.safetyFactor).filter(\.isFinite)
        let cap = max((finite.max() ?? study.safetyFactor) * 1.25, study.safetyFactor * 1.5)
        return candidates.enumerated().map { i, c in
            let f = c.analysis.safetyFactor
            return Point(id: i, mass: c.massG, factor: f.isFinite ? f : cap, unbounded: !f.isFinite, front: front.contains(i),
                         feasible: c.feasible, frequency: c.analysis.firstFrequency)
        }
    }

    var body: some View {
        let pts = points
        let line = pts.filter(\.front).sorted { $0.mass < $1.mass }
        let freqs = pts.compactMap(\.frequency)
        let (fLo, fHi) = (freqs.min() ?? 0, freqs.max() ?? 0)
        Chart {
            ForEach(line) { p in
                LineMark(x: .value("Mass", p.mass), y: .value("Safety factor", p.factor), series: .value("Line", "front"))
                    .foregroundStyle(theme.accent.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            RuleMark(y: .value("Required", study.safetyFactor))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(theme.inkSecondary)
                .annotation(position: .top, alignment: .trailing) {
                    Text("required \(formatFactor(study.safetyFactor))").font(VFFont.micro).foregroundStyle(theme.inkSecondary)
                }
            ForEach(pts) { p in
                let size: Double = {
                    guard let f = p.frequency, fHi > fLo else { return 70 }
                    return 50 + 110 * (f - fLo) / (fHi - fLo)
                }()
                PointMark(x: .value("Mass", p.mass), y: .value("Safety factor", p.factor))
                    .foregroundStyle(by: .value("Set", p.front ? Self.frontName : Self.otherName))
                    .symbol(by: .value("Set", p.front ? Self.frontName : Self.otherName))
                    .symbolSize(p.id == hovered ? size * 1.6 : size)
            }
            if let s = selected, let p = pts.first(where: { $0.id == s }) {
                PointMark(x: .value("Mass", p.mass), y: .value("Safety factor", p.factor))
                    .symbol {
                        Circle().strokeBorder(theme.ink, lineWidth: 2).frame(width: 18, height: 18)
                    }
                    .annotation(position: .trailing, spacing: 4) {
                        Text("#\(s + 1)").font(VFFont.micro).foregroundStyle(theme.ink)
                    }
            }
        }
        .chartForegroundStyleScale([Self.frontName: theme.accent, Self.otherName: theme.inkTertiary])
        .chartSymbolScale([Self.frontName: BasicChartSymbolShape.circle, Self.otherName: BasicChartSymbolShape.diamond])
        .chartLegend(position: .top, alignment: .leading, spacing: VFSpace.xs)
        .chartXAxisLabel("Mass, g")
        .chartYAxisLabel("Safety factor")
        .chartXScale(domain: .automatic(includesZero: false))
        .chartYScale(domain: .automatic(includesZero: true))
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let at): onHover(nearest(at, proxy: proxy, geo: geo, points: pts))
                        case .ended: onHover(nil)
                        }
                    }
                    .gesture(SpatialTapGesture().onEnded { v in
                        if let i = nearest(v.location, proxy: proxy, geo: geo, points: pts) { onSelect(i) }
                    })
            }
        }
        .accessibilityChartDescriptor(ParetoDescriptor(points: pts, required: study.safetyFactor))
        .accessibilityLabel("Mass against safety factor")
        .accessibilityHint(Text("Pick a candidate in the gallery to show it"))
        .help("Mass against safety factor. Dot size follows the first natural frequency. Click a dot to show that candidate.")
    }

    /// The candidate whose dot is within 18 pt of `at`, the nearest one.
    private func nearest(_ at: CGPoint, proxy: ChartProxy, geo: GeometryProxy, points: [Point]) -> Int? {
        guard let anchor = proxy.plotFrame else { return nil }
        let origin = geo[anchor].origin
        var best: (Int, CGFloat)?
        for p in points {
            guard let pos = proxy.position(for: (x: p.mass, y: p.factor)) else { continue }
            let d = hypot(pos.x + origin.x - at.x, pos.y + origin.y - at.y)
            if d < 18, d < (best?.1 ?? .infinity) { best = (p.id, d) }
        }
        return best?.0
    }
}

/// The Pareto chart for VoiceOver's audio graph and chart summary.
struct ParetoDescriptor: AXChartDescriptorRepresentable {
    let points: [ParetoChart.Point]
    let required: Double

    func makeChartDescriptor() -> AXChartDescriptor {
        let masses = points.map(\.mass), factors = points.map(\.factor)
        let xr = (masses.min() ?? 0)...max(masses.max() ?? 1, (masses.min() ?? 0) + 1e-6)
        let yr = 0...max(factors.max() ?? 1, required, 1e-6)
        let x = AXNumericDataAxisDescriptor(title: String(localized: "Mass"), range: xr, gridlinePositions: []) { VFFormat.mass($0) }
        let y = AXNumericDataAxisDescriptor(title: String(localized: "Safety factor"), range: yr, gridlinePositions: [required]) { formatFactor($0) }
        func series(_ name: String, _ ps: [ParetoChart.Point]) -> AXDataSeriesDescriptor {
            AXDataSeriesDescriptor(name: name, isContinuous: false, dataPoints: ps.sorted { $0.mass < $1.mass }.map { p in
                let fit = p.feasible ? String(localized: "within the limits") : String(localized: "over a limit")
                let sf = p.unbounded ? String(localized: "no stress") : formatFactor(p.factor)
                return AXDataPoint(x: p.mass, y: p.factor, additionalValues: [],
                                   label: String(localized: "Candidate \(p.id + 1), \(VFFormat.mass(p.mass)), safety factor \(sf), \(fit)"))
            })
        }
        let onFront = points.filter(\.front), off = points.filter { !$0.front }
        var all = [series(ParetoChart.frontName, onFront)]
        if !off.isEmpty { all.append(series(ParetoChart.otherName, off)) }
        let lightest = onFront.min { $0.mass < $1.mass }
        let summary = String(localized: "\(points.count) candidates, \(onFront.count) on the Pareto front. Required safety factor \(formatFactor(required)).")
            + (lightest.map { " " + String(localized: "Lightest on the front: candidate \($0.id + 1), \(VFFormat.mass($0.mass)).") } ?? "")
        return AXChartDescriptor(title: String(localized: "Mass against safety factor"), summary: summary, xAxis: x, yAxis: y, additionalAxes: [], series: all)
    }
}

// MARK: Mesh checks in the inspector

/// The picked candidate's mesh checks: each with a status word and shape, its figure against
/// its limit, a sentence, and Show to frame the problem in the preview.
struct MeshChecksSection: View {
    @Environment(\.viaFormTheme) private var theme
    let report: MeshCheckReport?
    let error: String?
    var onShow: (MeshCheckItem) -> Void

    var body: some View {
        Section {
            if let report {
                HStack(spacing: VFSpace.s) {
                    CheckStatusLabel(status: report.status, word: report.summary)
                    Spacer()
                    Text("\(report.triangles.formatted()) triangles").font(VFFont.small).foregroundStyle(theme.inkSecondary)
                }
                ForEach(report.items) { item in
                    MeshCheckRow(item: item, onShow: onShow)
                }
            } else if let error {
                InlineError(String(localized: "The mesh checks did not run: \(error)"))
            } else {
                HStack(spacing: VFSpace.m) {
                    DelayedProgress()
                    Text("Checking the mesh…").font(VFFont.row).foregroundStyle(theme.inkSecondary)
                }
            }
        } header: {
            Text("Mesh checks")
        } footer: {
            Text("Walls are measured along the surface normal; the limit is the process minimum. Show on Model colours the candidate by the check.")
        }
    }
}

struct MeshCheckRow: View {
    @Environment(\.viaFormTheme) private var theme
    let item: MeshCheckItem
    var onShow: (MeshCheckItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpace.xxs) {
            HStack(spacing: VFSpace.m) {
                Text(item.name).font(VFFont.rowEmphasis).foregroundStyle(theme.ink)
                Spacer(minLength: VFSpace.s)
                Text(item.figure).font(VFFont.row).monospacedDigit().foregroundStyle(theme.inkSecondary).lineLimit(1)
                CheckStatusLabel(status: item.status)
                if item.map != nil {
                    Button("Show on Model") { onShow(item) }
                        .buttonStyle(.vfGhost(tint: theme.accentText))
                        .font(VFFont.small)
                        .help("Colour the model by this check and frame its worst spot")
                        .accessibilityLabel(Text("Show \(item.name) on the model"))
                } else if item.spot != nil, item.status == .warning || item.status == .fail {
                    Button("Show") { onShow(item) }
                        .buttonStyle(.vfGhost(tint: theme.accentText))
                        .font(VFFont.small)
                        .help("Frame this in the preview")
                        .accessibilityLabel(Text("Show \(item.name) in the preview"))
                }
            }
            Text(item.detail).font(VFFont.small).foregroundStyle(theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A status as a shape and a word, never the colour alone.
struct CheckStatusLabel: View {
    @Environment(\.viaFormTheme) private var theme
    let status: MeshCheckItem.Status
    var word: String?

    var body: some View {
        let tint: Color = switch status {
        case .pass: theme.success
        case .warning: theme.warning
        case .fail: theme.danger
        case .skipped: theme.inkTertiary
        }
        Label(word ?? status.word, systemImage: status.symbol)
            .labelStyle(.titleAndIcon)
            .font(VFFont.micro)
            .lineLimit(1)
            .padding(.horizontal, VFSpace.s).padding(.vertical, VFSpace.xxs)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Capsule())
            .fixedSize()
    }
}

// MARK: Export menu

/// The picked candidate's secondary actions under Build: Export and Compare, and the last export
/// failure with Try Again (a new save panel on the Mac, since the old place may be the problem).
struct OutcomeActions: View {
    @Bindable var model: GenerateModel
    let candidate: Int

    var body: some View {
        let menu = OutcomeExportMenu(model: model, candidate: candidate)
        VStack(alignment: .leading, spacing: VFSpace.m) {
            HStack(spacing: VFSpace.m) {
                menu
                Button { model.comparing = model.defaultComparePair } label: { Label("Compare…", systemImage: "rectangle.split.2x1") }
                    .buttonStyle(.vfSecondary)
                    .fixedSize()
                    .vfDisabled((model.outcome?.candidates.count ?? 0) < 2, reason: String(localized: "Run at least two candidates to compare (Variants in Study)."))
            }
            if let f = model.exportFailure {
                InlineError(f.message, retry: {
                    model.exportFailure = nil
                    model.retryExport = f
                }, dismiss: { model.exportFailure = nil })
            }
        }
    }
}

/// Export the picked candidate as STL, 3MF or OBJ: a save panel on the Mac, the Files exporter
/// on iPad and iPhone. The file is written by the engine off the main actor; success shows a
/// toast, failure stays inline with Try Again.
struct OutcomeExportMenu: View {
    @Environment(\.vfToasts) private var toasts
    @Bindable var model: GenerateModel
    let candidate: Int
    #if os(iOS)
    @State private var file: MeshExportFile?
    @State private var showExporter = false
    #endif

    private var blocked: String? {
        if model.exporting { return String(localized: "Writing the file now.") }
        if (model.outcome?.candidates[safe: candidate]?.mesh.triangleCount ?? 0) == 0 { return String(localized: "This candidate has no surface to export.") }
        return nil
    }

    var body: some View {
        Menu {
            ForEach(MeshExportFormat.allCases) { f in
                Button(f.menuTitle) { start(f) }
            }
        } label: {
            Label(model.exporting ? String(localized: "Exporting…") : String(localized: "Export"), systemImage: "square.and.arrow.up")
        }
        .menuStyle(.vfPill)
        .vfDisabled(blocked != nil, reason: blocked ?? "")
        .help(blocked ?? String(localized: "Export this candidate's surface as STL, 3MF or OBJ"))
        .onChange(of: model.retryExport) { _, f in
            guard let f, f.candidate == candidate else { return }
            model.retryExport = nil
            start(f.format)
        }
        #if os(iOS)
        .fileExporter(isPresented: $showExporter, document: file, contentType: file?.format.contentType ?? .data,
                      defaultFilename: file.map { model.exportName(candidate) + "." + $0.format.rawValue }) { result in
            switch result {
            case .success(let url): toasts?.show(String(localized: "Exported \(url.lastPathComponent)"))
            case .failure(let e):
                if let f = file {
                    model.exportFailure = OutcomeExportFailure(message: String(localized: "Could not export: \(e.localizedDescription)"), candidate: candidate, format: f.format)
                }
            }
            if let url = file?.url { try? FileManager.default.removeItem(at: url) }
            file = nil
        }
        #endif
    }

    func start(_ format: MeshExportFormat) {
        let i = candidate
        #if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = model.exportName(i) + "." + format.rawValue
        panel.canCreateDirectories = true
        panel.title = String(localized: "Export Candidate \(i + 1)")
        panel.prompt = String(localized: "Export")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                let r = await model.writeExport(i, format: format, to: url)
                if case .success(let bytes) = r {
                    toasts?.show(String(localized: "Exported \(url.lastPathComponent), \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"),
                                 actionTitle: String(localized: "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }
        }
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(model.exportName(i) + "." + format.rawValue)
        Task { @MainActor in
            if case .success = await model.writeExport(i, format: format, to: url) {
                file = MeshExportFile(url: url, format: format)
                showExporter = true
            }
        }
        #endif
    }
}

/// A finished export file handed to the Files exporter (written already, off the main actor).
struct MeshExportFile: FileDocument {
    static let readableContentTypes: [UTType] = [.data]
    let url: URL
    let format: MeshExportFormat

    init(url: URL, format: MeshExportFormat) {
        self.url = url
        self.format = format
    }

    init(configuration: ReadConfiguration) throws { throw CocoaError(.fileReadUnsupportedScheme) }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { try FileWrapper(url: url) }
}

// MARK: Compare

/// Two candidates side by side: their stills, then every figure with the difference from A to B
/// in its unit and in percent, and which is better in words.
struct CompareSheet: View {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: GenerateModel
    @State var pair: OutcomePair

    struct Row: Identifiable {
        let id: String
        let label: String
        let a: Double?
        let b: Double?
        let format: (Double) -> String
        /// +1: higher is better, -1: lower is better, 0: neither.
        let better: Int
        let unit: String
    }

    var body: some View {
        if let o = model.outcome, let s = model.studied {
            let ca = o.candidates[safe: pair.a], cb = o.candidates[safe: pair.b]
            VStack(alignment: .leading, spacing: VFSpace.l) {
                Text("Compare candidates").font(VFFont.heading).foregroundStyle(theme.ink)
                HStack(alignment: .top, spacing: VFSpace.xl) {
                    side("A", selection: $pair.a, candidate: ca, o: o, study: s)
                    side("B", selection: $pair.b, candidate: cb, o: o, study: s)
                }
                if let ca, let cb {
                    table(rows(ca, cb))
                }
                HStack {
                    Button("Show B in the Preview") {
                        model.selected = pair.b
                        model.display = .result
                    }
                    .buttonStyle(.vfSecondary)
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(.vfPrimary)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(VFSpace.xxl)
            .frame(minWidth: 560, idealWidth: 620)
            .background(theme.panel)
        }
    }

    private func side(_ title: String, selection: Binding<Int>, candidate c: StudyCandidate?, o: StudyOutcome, study: Study) -> some View {
        VStack(alignment: .leading, spacing: VFSpace.s) {
            LabeledContent(title) {
                VFMenuPicker(title, selection: selection, items: Array(o.candidates.indices), title: { i in
                    i == o.best ? String(localized: "Candidate \(i + 1), best") : String(localized: "Candidate \(i + 1)")
                })
            }
            if let c {
                CandidateCard(candidate: c, study: study, image: model.thumbnails[selection.wrappedValue],
                              rendered: model.thumbnailsDone.contains(selection.wrappedValue),
                              best: selection.wrappedValue == o.best, selected: false, checks: model.meshChecks[selection.wrappedValue])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rows(_ a: StudyCandidate, _ b: StudyCandidate) -> [Row] {
        let ra = model.meshChecks[pair.a], rb = model.meshChecks[pair.b]
        func finite(_ v: Double) -> Double? { v.isFinite ? v : nil }
        return [
            Row(id: "mass", label: String(localized: "Mass"), a: a.massG, b: b.massG, format: { VFFormat.mass($0) }, better: -1, unit: "g"),
            Row(id: "volume", label: String(localized: "Volume fraction"), a: a.volumeFraction * 100, b: b.volumeFraction * 100,
                format: { String(format: "%.1f %%", $0) }, better: 0, unit: "%"),
            Row(id: "sf", label: String(localized: "Safety factor"), a: finite(a.analysis.safetyFactor), b: finite(b.analysis.safetyFactor),
                format: formatFactor, better: 1, unit: ""),
            Row(id: "stress", label: String(localized: "Peak stress"), a: a.analysis.worstStress, b: b.analysis.worstStress,
                format: { "\(Int($0.rounded())) MPa" }, better: -1, unit: "MPa"),
            Row(id: "disp", label: String(localized: "Displacement"), a: a.analysis.worstDisplacement, b: b.analysis.worstDisplacement,
                format: { VFFormat.lengthSignificant($0) }, better: -1, unit: "mm"),
            Row(id: "f1", label: String(localized: "First mode"), a: a.analysis.firstFrequency, b: b.analysis.firstFrequency,
                format: { VFFormat.value($0, .frequency) }, better: 1, unit: "Hz"),
            Row(id: "cost", label: String(localized: "Cost index"), a: a.cost, b: b.cost, format: { VFFormat.money($0) }, better: -1, unit: "USD"),
            Row(id: "iter", label: String(localized: "Iterations"), a: Double(a.keptIteration ?? a.history.count), b: Double(b.keptIteration ?? b.history.count),
                format: { "\(Int($0))" }, better: 0, unit: ""),
            Row(id: "wall", label: String(localized: "Thinnest wall"), a: ra?.minWall, b: rb?.minWall, format: { VFFormat.length($0, digits: 2) }, better: 1, unit: "mm"),
            Row(id: "checks", label: String(localized: "Mesh check problems"), a: ra.map { Double($0.warnings + $0.failures) }, b: rb.map { Double($0.warnings + $0.failures) },
                format: { "\(Int($0))" }, better: -1, unit: ""),
        ]
    }

    private func table(_ rows: [Row]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: VFSpace.xl, verticalSpacing: VFSpace.m) {
            GridRow {
                Text("Figure")
                Text("A").gridColumnAlignment(.trailing)
                Text("B").gridColumnAlignment(.trailing)
                Text("B against A")
            }
            .font(VFFont.micro)
            .foregroundStyle(theme.inkSecondary)
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(rows) { r in
                GridRow {
                    Text(r.label).foregroundStyle(theme.ink)
                    Text(r.a.map(r.format) ?? "–").monospacedDigit().foregroundStyle(theme.ink)
                    Text(r.b.map(r.format) ?? "–").monospacedDigit().foregroundStyle(theme.ink)
                    diff(r)
                }
                .font(VFFont.row)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("\(r.label): A \(r.a.map(r.format) ?? "none"), B \(r.b.map(r.format) ?? "none"), \(Self.diffText(r).text)"))
            }
        }
    }

    private func diff(_ r: Row) -> some View {
        let d = Self.diffText(r)
        let tint: Color = switch d.verdict {
        case 1: theme.success
        case -1: theme.warning
        default: theme.inkSecondary
        }
        return HStack(spacing: VFSpace.xs) {
            if d.verdict != 0 {
                Image(systemName: d.verdict > 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill").accessibilityHidden(true)
            }
            Text(d.text).monospacedDigit()
        }
        .foregroundStyle(tint)
    }

    /// "+12 g (+8 %), B better", "same", or "–" when a side has no figure. The verdict is +1 when
    /// B is better, -1 when worse, 0 otherwise.
    static func diffText(_ r: Row) -> (text: String, verdict: Int) {
        guard let a = r.a, let b = r.b else { return ("–", 0) }
        let delta = b - a
        let scale = max(abs(a), abs(b), 1e-12)
        if abs(delta) <= scale * 1e-4 { return (String(localized: "same"), 0) }
        let sign = delta > 0 ? "+" : "−"
        let unit = r.unit.isEmpty || r.unit == "%" ? (r.unit == "%" ? " pt" : "") : " \(r.unit)"
        let magnitude: String = switch r.unit {
        case "USD": VFFormat.money(abs(delta))
        case "mm": VFFormat.lengthSignificant(abs(delta))
        default: abs(delta) >= 100 ? String(format: "%.0f", abs(delta)) : String(format: "%.3g", abs(delta))
        }
        let value = r.unit == "USD" || r.unit == "mm" ? "\(sign)\(magnitude)" : "\(sign)\(magnitude)\(unit)"
        let pct = abs(a) > 1e-12 && r.unit != "%" ? String(format: " (%@%.0f %%)", sign, abs(delta / a) * 100) : ""
        guard r.better != 0 else { return (value + pct, 0) }
        let improves = (delta > 0) == (r.better > 0)
        return (value + pct + ", " + (improves ? String(localized: "B better") : String(localized: "B worse")), improves ? 1 : -1)
    }
}
