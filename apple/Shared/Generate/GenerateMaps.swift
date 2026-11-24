import SwiftUI
import ViaFormFFI
import simd
#if os(macOS)
import AppKit
#endif

// Maps on the candidate canvas (VIAFORM-SPEC 7.10.3, P1-33): the surface coloured by its
// overhang angle (printed parts), its wall thickness, or how much of it the milling tool reaches
// (milled parts), from the engine's per-vertex maps (`vf_generate_mesh_maps`, the same
// computations as the mesh checks). A picker over the canvas chooses None, Stress, Overhang,
// Wall thickness or Tool access; the legend says the bands in words and values, and with
// Differentiate Without Color adds patterns and a count of the regions past the limit, as the
// stress legend does (P2-26). Maps are computed and painted off the main actor.

// MARK: Maps

/// What colours the candidate in the canvas.
enum CandidateMap: String, CaseIterable, Identifiable, Sendable {
    case none, stress, overhang, wall, access

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: String(localized: "None")
        case .stress: String(localized: "Stress")
        case .overhang: String(localized: "Overhang")
        case .wall: String(localized: "Wall thickness")
        case .access: String(localized: "Tool access")
        }
    }

    var symbol: String {
        switch self {
        case .none: "cube"
        case .stress: "flame"
        case .overhang: "arrow.down.to.line"
        case .wall: "arrow.left.and.right"
        case .access: "wrench.and.screwdriver"
        }
    }

    /// The map a mesh check row shows on the model, if any.
    init?(check id: String) {
        switch id {
        case "overhangs": self = .overhang
        case "min_wall": self = .wall
        case "tool_access": self = .access
        default: return nil
        }
    }

    /// The engine paints this map from `vf_generate_mesh_maps`.
    var fromEngine: Bool { self == .overhang || self == .wall || self == .access }

    /// `--generate-map=overhang` (screenshots and checks).
    static var launch: CandidateMap? {
        ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--generate-map=") }
            .flatMap { CandidateMap(rawValue: String($0.dropFirst(15)).lowercased()) }
    }
}

/// The engine's per-vertex maps of one surface, and their figures.
struct MeshMapFields: Sendable {
    struct Overhang: Sendable, Equatable {
        var applies = false
        var limitDeg = 45.0
        var build = Vec3(0, 0, 1)
        var flaggedMM2 = 0.0
        var flaggedShare = 0.0
        var flattestDeg: Double?
    }

    struct Wall: Sendable, Equatable {
        var limitMM: Double?
        var minMM: Double?
        var maxMM: Double?
        var medianMM: Double?
        var thinShare = 0.0
        var measuredShare = 0.0
    }

    struct Access: Sendable, Equatable {
        var applies = false
        var model = ""
        var axes: [Vec3] = []
        var unreachableMM2 = 0.0
        var unreachableShare = 0.0
    }

    /// Degrees from the plate, mm, and the share reached (0 to 1); NaN where not measured or
    /// not applicable.
    var overhang: [Float] = []
    var wall: [Float] = []
    var access: [Float] = []
    var overhangFigures: Overhang?
    var wallFigures: Wall?
    var accessFigures: Access?
    var seconds = 0.0

    init() {}

    init(summary o: [String: Any], overhang: [Float], wall: [Float], access: [Float]) {
        func num(_ v: Any?) -> Double? { (v as? Double) ?? (v as? Int).map(Double.init) }
        self.overhang = overhang
        self.wall = wall
        self.access = access
        func vec(_ v: Any?) -> Vec3? {
            guard let a = v as? [Any], a.count == 3, let x = num(a[0]), let y = num(a[1]), let z = num(a[2]) else { return nil }
            return Vec3(x, y, z)
        }
        if let h = o["overhang"] as? [String: Any] {
            overhangFigures = Overhang(applies: h["applies"] as? Bool ?? false, limitDeg: num(h["limit_deg"]) ?? 45,
                                       build: vec(h["build"]) ?? Vec3(0, 0, 1),
                                       flaggedMM2: num(h["flagged_mm2"]) ?? 0, flaggedShare: num(h["flagged_share"]) ?? 0,
                                       flattestDeg: num(h["flattest_deg"]))
        }
        if let w = o["wall"] as? [String: Any] {
            wallFigures = Wall(limitMM: num(w["limit_mm"]), minMM: num(w["min_mm"]), maxMM: num(w["max_mm"]),
                               medianMM: num(w["median_mm"]), thinShare: num(w["thin_share"]) ?? 0,
                               measuredShare: num(w["measured_share"]) ?? 0)
        }
        if let a = o["access"] as? [String: Any] {
            let axes = (a["axes"] as? [Any] ?? []).compactMap(vec)
            accessFigures = Access(applies: a["applies"] as? Bool ?? false, model: a["model"] as? String ?? "", axes: axes,
                                   unreachableMM2: num(a["unreachable_mm2"]) ?? 0, unreachableShare: num(a["unreachable_share"]) ?? 0)
        }
        seconds = num(o["seconds"]) ?? 0
    }
}

extension GenerateEngine {
    /// The engine's per-vertex maps of a surface, all three at once (call off the main actor).
    /// `request` is the same JSON as the mesh checks' (`GenerateModel.checkRequest`).
    nonisolated static func meshMaps(_ mesh: StudyMesh, request: String) throws -> MeshMapFields {
        let n = mesh.vertexCount
        var over = [Float](repeating: .nan, count: n)
        var wall = [Float](repeating: .nan, count: n)
        var access = [Float](repeating: .nan, count: n)
        let reply: UnsafeMutablePointer<CChar>? = mesh.positions.withUnsafeBufferPointer { p in
            mesh.indices.withUnsafeBufferPointer { i in
                over.withUnsafeMutableBufferPointer { o in
                    wall.withUnsafeMutableBufferPointer { w in
                        access.withUnsafeMutableBufferPointer { a in
                            vf_generate_mesh_maps(p.baseAddress, UInt64(n), i.baseAddress, UInt64(mesh.indices.count), request,
                                                  o.baseAddress, w.baseAddress, a.baseAddress)
                        }
                    }
                }
            }
        }
        guard let reply else { throw EngineError(message: "No reply from the generative engine") }
        defer { sc_string_free(reply) }
        let obj = try? JSONSerialization.jsonObject(with: Data(String(cString: reply).utf8)) as? [String: Any]
        if let e = obj?["error"] as? String { throw EngineError(message: e) }
        guard let ok = obj?["ok"] as? [String: Any] else { throw EngineError(message: "The engine answered no maps") }
        return MeshMapFields(summary: ok, overhang: over, wall: wall, access: access)
    }
}

// MARK: Bands and paint

/// One worded band of a map's legend, along the colour scale (0 good to 1 past the limit).
struct MapBand: Identifiable, Equatable, Sendable {
    var kind: StressColors.Band.Kind
    var title: String
    /// The values the band covers, in words ("0° to 45°").
    var range: String
    var from: Double
    var to: Double
    var id: StressColors.Band.Kind { kind }
}

/// How a map turns values into colours, and its legend's words. Data colours on the same scale
/// as the stress map (Viridis or blue to red), the hot end past the limit.
struct MapScale: Sendable, Equatable {
    var title: String
    /// Left, limit and right tick labels under the bar.
    var low: String
    var mark: String?
    var high: String
    /// Where the limit falls along the bar, 0 to 1.
    var limit: Double?
    var bands: [MapBand]
    /// Words for the bad band in the count line ("need support").
    var overWords: String

    /// Degrees from the plate: 90 (walls, upward faces) on the cool end, flat ceilings hot.
    static func overhang(limit l: Double) -> MapScale {
        let near = min(l + 10, 90)
        let tl = 1 - l / 90, tn = 1 - near / 90
        return MapScale(
            title: String(localized: "Overhang, angle from the build plate"),
            low: VFFormat.angle(90), mark: String(localized: "limit \(VFFormat.angle(l))"), high: VFFormat.angle(0),
            limit: tl,
            bands: [
                MapBand(kind: .low, title: String(localized: "Self-supporting"), range: String(localized: "\(VFFormat.angle(near)) to \(VFFormat.angle(90))"), from: 0, to: tn),
                MapBand(kind: .atLimit, title: String(localized: "Near the limit"), range: String(localized: "\(VFFormat.angle(l)) to \(VFFormat.angle(near))"), from: tn, to: tl),
                MapBand(kind: .over, title: String(localized: "Needs support"), range: String(localized: "\(VFFormat.angle(0)) to \(VFFormat.angle(l))"), from: tl, to: 1),
            ].filter { $0.to > $0.from },
            overWords: String(localized: "need support"))
    }

    /// The full scale of the wall map, mm: twice the limit, else twice the median.
    static func wallTop(limit: Double?, median: Double?) -> Double {
        if let limit, limit > 0 { return 2 * limit }
        return max(2 * (median ?? 1), 1)
    }

    /// Thick walls cool, thin walls hot; the limit sits in the middle of the bar.
    static func wall(limit: Double?, median: Double?) -> MapScale {
        let top = wallTop(limit: limit, median: median)
        guard let l = limit, l > 0 else {
            return MapScale(title: String(localized: "Wall thickness"), low: String(localized: "\(VFFormat.length(top)) and over"), mark: nil,
                            high: VFFormat.length(0), limit: nil, bands: [], overWords: "")
        }
        let near = 1.25 * l
        let tl = 1 - l / top, tn = 1 - near / top
        return MapScale(
            title: String(localized: "Wall thickness"),
            low: String(localized: "\(VFFormat.length(top)) and over"), mark: String(localized: "limit \(VFFormat.length(l))"), high: VFFormat.length(0),
            limit: tl,
            bands: [
                MapBand(kind: .low, title: String(localized: "Thick enough"), range: String(localized: "\(VFFormat.length(near)) and over"), from: 0, to: tn),
                MapBand(kind: .atLimit, title: String(localized: "Near the limit"), range: String(localized: "\(VFFormat.length(l)) to \(VFFormat.length(near))"), from: tn, to: tl),
                MapBand(kind: .over, title: String(localized: "Too thin"), range: String(localized: "under \(VFFormat.length(l))"), from: tl, to: 1),
            ],
            overWords: String(localized: "too thin"))
    }

    /// Share of the surface around a vertex the tool reaches: all of it cool, none hot.
    static var access: MapScale {
        MapScale(
            title: String(localized: "Tool access"),
            low: String(localized: "reached"), mark: nil, high: String(localized: "out of reach"),
            limit: 0.5,
            bands: [
                MapBand(kind: .low, title: String(localized: "Reached"), range: String(localized: "90 to 100 % of the faces"), from: 0, to: 0.1),
                MapBand(kind: .atLimit, title: String(localized: "Partly reached"), range: String(localized: "50 to 90 %"), from: 0.1, to: 0.5),
                MapBand(kind: .over, title: String(localized: "Out of reach"), range: String(localized: "under 50 %"), from: 0.5, to: 1),
            ],
            overWords: String(localized: "out of reach"))
    }
}

/// A map painted on one preview: its vertex colours and what the legend counts.
struct MapPaint: Sendable {
    var colors: Data
    /// Connected patches past the limit, and their share of the vertices.
    var regions = 0
    var share: Float = 0
    /// Vertices with no value (no wall ray came back), drawn grey.
    var unmeasured = 0

    /// Grey for vertices with nothing measured (a data colour of the scene, not a UI token).
    nonisolated static let unmeasuredRGB = SIMD3<Float>(0.55, 0.55, 0.57)

    /// The position along the scale (0 good, 1 past the limit) of each vertex's value.
    nonisolated static func scalePositions(_ map: CandidateMap, fields: MeshMapFields) -> [Float] {
        switch map {
        case .overhang:
            return fields.overhang.map { $0.isFinite ? 1 - min(max($0, 0), 90) / 90 : .nan }
        case .wall:
            let top = Float(MapScale.wallTop(limit: fields.wallFigures?.limitMM, median: fields.wallFigures?.medianMM))
            return fields.wall.map { $0.isFinite ? 1 - min(max($0 / top, 0), 1) : .nan }
        case .access:
            return fields.access.map { $0.isFinite ? 1 - min(max($0, 0), 1) : .nan }
        case .none, .stress:
            return []
        }
    }

    /// Paints `map` over `preview` (call off the main actor). Plain is the material colour; a map
    /// that does not apply to the process paints plain too, and its legend says why.
    nonisolated static func paint(_ map: CandidateMap, fields: MeshMapFields?, preview: PreviewMesh, study: Study,
                                  scale: StressColors.Scale) -> MapPaint {
        let n = preview.vertexCount
        let plain = PreviewMesh.materialRGB(study)
        var t: [Float] = []
        if let fields, applies(map, fields) {
            t = scalePositions(map, fields: fields)
        }
        var colors = [Float](repeating: 1, count: 4 * n)
        var unmeasured = 0
        let painted = t.count == n
        for i in 0..<n {
            let c: SIMD3<Float>
            if painted {
                if t[i].isFinite { c = StressColors.rgb(t[i], scale: scale) } else { c = unmeasuredRGB; unmeasured += 1 }
            } else {
                c = plain
            }
            colors[4 * i] = c.x
            colors[4 * i + 1] = c.y
            colors[4 * i + 2] = c.z
        }
        var out = MapPaint(colors: colors.withUnsafeBufferPointer { Data(buffer: $0) }, unmeasured: unmeasured)
        if painted, let f = fields, let limit = limit(map, fields: f) {
            let tris = preview.indices.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
            let (regions, over) = PreviewMesh.overLimit(stress: t, triangles: tris, limit: Float(limit))
            out.regions = regions
            out.share = n > 0 ? Float(over) / Float(n) : 0
        }
        return out
    }

    /// The map applies to the study's process (overhangs to printing, access to milling).
    nonisolated static func applies(_ map: CandidateMap, _ f: MeshMapFields) -> Bool {
        switch map {
        case .overhang: f.overhangFigures?.applies == true
        case .wall: f.wallFigures != nil
        case .access: f.accessFigures?.applies == true
        case .none, .stress: false
        }
    }

    /// Where the limit falls along the scale, if the map has one.
    nonisolated static func limit(_ map: CandidateMap, fields f: MeshMapFields) -> Double? {
        switch map {
        case .overhang: f.overhangFigures.map { 1 - $0.limitDeg / 90 }
        case .wall: f.wallFigures?.limitMM.flatMap { $0 > 0 ? 1 - $0 / MapScale.wallTop(limit: $0, median: nil) : nil }
        case .access: 0.5
        case .none, .stress: nil
        }
    }
}

// MARK: State

/// The canvas map of one Generate model: the map picked, and the engine's maps per candidate,
/// kept for the outcome they were made for. Lives beside the model so the Outcomes rows ("Show on
/// Model") and the canvas share it.
@MainActor
@Observable
final class CandidateMapState {
    /// The map picked; Stress falls back to None on a surface with no stress.
    var map: CandidateMap = CandidateMap.launch ?? .stress
    private(set) var fields: [String: MeshMapFields] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var loading: Set<String> = []
    /// The last paint, by the key it was made for.
    private(set) var paint: (key: String, value: MapPaint)?

    private static var all: [ObjectIdentifier: (model: WeakModel, state: CandidateMapState)] = [:]
    private struct WeakModel { weak var model: GenerateModel? }

    /// The state of `model`'s canvas.
    static func of(_ model: GenerateModel) -> CandidateMapState {
        let id = ObjectIdentifier(model)
        if let e = all[id], e.model.model === model { return e.state }
        all = all.filter { $0.value.model.model != nil }
        let s = CandidateMapState()
        all[id] = (WeakModel(model: model), s)
        return s
    }

    /// The key of candidate `i`'s maps: its outcome, its surface and the request.
    static func key(_ model: GenerateModel, index i: Int, request: String) -> String {
        "\(model.outcomeVersion)/\(i)/\(model.outcome?.candidates[safe: i]?.mesh.vertexCount ?? 0)/\(request)"
    }

    /// The engine's request for the shown outcome.
    static func request(_ model: GenerateModel) -> String? {
        model.studied.map { GenerateModel.checkRequest($0, route: model.pickedRoute) }
    }

    /// Candidate `i`'s maps, computed off the main actor the first time.
    func load(_ model: GenerateModel, index i: Int) async -> MeshMapFields? {
        guard let request = Self.request(model), let c = model.outcome?.candidates[safe: i] else { return nil }
        let key = Self.key(model, index: i, request: request)
        if let f = fields[key] { return f }
        guard !loading.contains(key) else { return nil }
        loading.insert(key)
        errors[key] = nil
        let mesh = c.mesh
        let r = await Task.detached(priority: .userInitiated) { () -> Result<MeshMapFields, any Error> in
            Result { try GenerateEngine.meshMaps(mesh, request: request) }
        }.value
        loading.remove(key)
        switch r {
        case .success(let f):
            // Keep the shown outcome's maps only.
            fields = fields.filter { $0.key.hasPrefix("\(model.outcomeVersion)/") }
            fields[key] = f
            return f
        case .failure(let e):
            errors[key] = e.localizedDescription
            return nil
        }
    }

    func retry(_ model: GenerateModel, index i: Int) {
        guard let request = Self.request(model) else { return }
        errors[Self.key(model, index: i, request: request)] = nil
    }

    func setPaint(_ key: String, _ value: MapPaint) { paint = (key, value) }
}

// MARK: Canvas overlay

/// The map picker and its legend over the candidate canvas. Picking a map paints the scene off
/// the main actor; Stress keeps the engine's stress colours and the stress legend.
struct CandidateMapOverlay: View {
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: GenerateModel
    let scene: GenerateScene
    let preview: PreviewMesh
    let study: Study
    let index: Int

    private var state: CandidateMapState { CandidateMapState.of(model) }

    /// The map shown: Stress on a surface without stress is None.
    private var shown: CandidateMap {
        let m = state.map
        return m == .stress && !preview.coloredByStress ? .none : m
    }

    private var request: String? { CandidateMapState.request(model) }
    private var fieldsKey: String? { request.map { CandidateMapState.key(model, index: index, request: $0) } }
    private var fields: MeshMapFields? { fieldsKey.flatMap { state.fields[$0] } }
    private var paintKey: String {
        "\(shown.rawValue)/\(index)/\(model.previewsVersion)/\(model.stressScale.rawValue)/\(fieldsKey ?? "")/\(fields != nil)/\(state.errors[fieldsKey ?? ""] ?? "")"
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: VFSpace.m) {
            picker
            switch shown {
            case .stress:
                StressLegend(preview: preview, study: study, scale: $model.stressScale)
            case .none:
                EmptyView()
            case .overhang, .wall, .access:
                MapLegend(map: shown, fields: fields, paint: state.paint.flatMap { $0.key == paintKey ? $0.value : nil },
                          loading: fieldsKey.map { state.loading.contains($0) } ?? false,
                          error: fieldsKey.flatMap { state.errors[$0] }, study: study,
                          retry: { state.retry(model, index: index) })
            }
        }
        .task(id: paintKey) { await apply() }
    }

    private var picker: some View {
        Picker(selection: Binding(get: { shown }, set: { state.map = $0 })) {
            ForEach(CandidateMap.allCases.filter { $0 != .stress || preview.coloredByStress }) { m in
                Label(m.title, systemImage: m.symbol).tag(m)
            }
        } label: {
            Label("Map", systemImage: "square.3.layers.3d")
        }
        .pickerStyle(.menu)
        .fixedSize()
        .padding(.horizontal, VFSpace.m)
        .frame(minHeight: VFSize.minTarget)
        .vfSurface(.control, radius: VFRadius.control)
        .help("Colour the candidate by a check")
        .accessibilityLabel("Map")
        .accessibilityValue(Text(shown.title))
    }

    /// Paints the scene for the shown map: the engine's maps first (off the main actor), then
    /// the colours (off the main actor), then the scene.
    private func apply() async {
        let map = shown, key = paintKey, p = preview, s = study, scale = model.stressScale, version = model.previewsVersion
        if map == .stress {
            scene.applyMap(nil, index: index, version: version)
            return
        }
        var f: MeshMapFields?
        if map.fromEngine {
            f = await state.load(model, index: index)
            guard !Task.isCancelled else { return }
            // Not ready (another load is running) or failed: keep the preview as it is.
            if f == nil { return }
        }
        let painted = await Task.detached(priority: .userInitiated) {
            MapPaint.paint(map, fields: f, preview: p, study: s, scale: scale)
        }.value
        guard !Task.isCancelled else { return }
        state.setPaint(key, painted)
        scene.applyMap(painted.colors, index: index, version: version)
    }
}

// MARK: Legend

/// A map's legend: its scale with the limit marked, the figures that matter in words and
/// values, and with Differentiate Without Color worded bands with patterns and a count of the
/// regions past the limit (as the stress legend, P2-26).
struct MapLegend: View {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateSetting
    let map: CandidateMap
    let fields: MeshMapFields?
    let paint: MapPaint?
    let loading: Bool
    let error: String?
    let study: Study
    var retry: () -> Void = {}
    /// Pins the Differentiate Without Color look (snapshots); nil follows the setting.
    var differentiateOverride: Bool? = nil

    private let barWidth: CGFloat = 220
    private var differentiate: Bool { differentiateOverride ?? (differentiateSetting || StressColors.forceDifferentiate) }

    private var scale: MapScale? {
        guard let f = fields else { return nil }
        switch map {
        case .overhang: return f.overhangFigures.map { MapScale.overhang(limit: $0.limitDeg) }
        case .wall: return f.wallFigures.map { MapScale.wall(limit: $0.limitMM, median: $0.medianMM) }
        case .access: return .access
        case .none, .stress: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpace.xs) {
            if let error {
                InlineError(String(localized: "The map did not run: \(error)"), retryTitle: String(localized: "Try Again"), retry: retry)
                    .frame(width: barWidth)
            } else if let f = fields, let scale {
                if MapPaint.applies(map, f) {
                    Text(scale.title).font(VFFont.rowEmphasis).foregroundStyle(theme.ink)
                    bar(scale)
                    ticks(scale)
                    if differentiate { bandRows(scale) }
                    figures(f)
                    if differentiate, scale.limit != nil { countLine(scale) }
                    if let paint, paint.unmeasured > 0 { unmeasuredRow }
                } else {
                    Text(scale.title).font(VFFont.rowEmphasis).foregroundStyle(theme.ink)
                    Text(notApplicable).font(VFFont.small).foregroundStyle(theme.inkSecondary)
                        .frame(width: barWidth, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: VFSpace.m) {
                    DelayedProgress()
                    Text("Mapping the surface…").font(VFFont.row).foregroundStyle(theme.inkSecondary)
                }
                .frame(width: barWidth, alignment: .leading)
            }
        }
        .monospacedDigit()
        .padding(VFSpace.panelPadding)
        .vfSurface(.floating)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(accessibilitySummary))
    }

    private func bar(_ s: MapScale) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: VFRadius.mark)
                    .fill(LinearGradient(gradient: StressColors.gradient(), startPoint: .leading, endPoint: .trailing))
                if differentiate {
                    ForEach(s.bands) { b in
                        MapBandPattern(kind: b.kind, ink: theme.ink, halo: theme.panel)
                            .frame(width: max(g.size.width * (b.to - b.from), 0), height: g.size.height)
                            .offset(x: g.size.width * b.from)
                    }
                }
                if let l = s.limit {
                    Rectangle().fill(theme.ink).frame(width: 2, height: g.size.height + 6).offset(x: min(max(l, 0), 1) * g.size.width - 1)
                }
            }
        }
        .frame(width: barWidth, height: differentiate ? 16 : 10)
        .accessibilityHidden(true)
    }

    private func ticks(_ s: MapScale) -> some View {
        HStack {
            Text(s.low)
            Spacer()
            if let m = s.mark { Text(m); Spacer() }
            Text(s.high)
        }
        .font(VFFont.micro)
        .foregroundStyle(theme.inkSecondary)
        .frame(width: barWidth)
        .accessibilityHidden(true)
    }

    /// One row per band: its pattern swatch, its word and its values.
    private func bandRows(_ s: MapScale) -> some View {
        VStack(alignment: .leading, spacing: VFSpace.xxs) {
            ForEach(s.bands) { b in
                HStack(spacing: VFSpace.s) {
                    ZStack {
                        Rectangle().fill(Color(scene: SIMD3<Double>(StressColors.rgb(Float((b.from + b.to) / 2)))))
                        MapBandPattern(kind: b.kind, ink: theme.ink, halo: theme.panel)
                    }
                    .frame(width: 22, height: 12)
                    .clipShape(RoundedRectangle(cornerRadius: VFRadius.mark))
                    .overlay(RoundedRectangle(cornerRadius: VFRadius.mark).strokeBorder(theme.hairline))
                    .accessibilityHidden(true)
                    Text(b.title).font(VFFont.rowEmphasis).foregroundStyle(theme.ink)
                    Spacer(minLength: VFSpace.s)
                    Text(b.range).font(VFFont.small).foregroundStyle(theme.inkSecondary)
                }
                .frame(width: barWidth)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.top, VFSpace.xxs)
    }

    /// The figures of the map in words, with a warning shape when past the limit.
    @ViewBuilder private func figures(_ f: MeshMapFields) -> some View {
        switch map {
        case .overhang:
            if let o = f.overhangFigures {
                if o.flaggedMM2 > 0 {
                    warn(String(localized: "\(percent(o.flaggedShare)) of the surface needs support (\(VFFormat.area(o.flaggedMM2)))"))
                } else {
                    plain(String(localized: "No face is flatter than \(VFFormat.angle(o.limitDeg)) off the plate"))
                }
                plain(String(localized: "Build direction \(direction(o.build)), limit \(VFFormat.angle(o.limitDeg))"), secondary: true)
            }
        case .wall:
            if let w = f.wallFigures {
                if let l = w.limitMM, w.thinShare > 0 {
                    warn(String(localized: "\(percent(w.thinShare)) of the surface is under \(VFFormat.length(l))"))
                } else if let l = w.limitMM {
                    plain(String(localized: "Every wall is at least \(VFFormat.length(l))"))
                } else {
                    plain(String(localized: "No process minimum: pick a process to hold the walls to one."), secondary: true)
                }
                if let lo = w.minMM, let mid = w.medianMM {
                    plain(String(localized: "At least \(VFFormat.length(lo, digits: 2)) over 99 % of the surface, median \(VFFormat.length(mid, digits: 1))"), secondary: true)
                }
            }
        case .access:
            if let a = f.accessFigures {
                if a.unreachableMM2 > 0 {
                    warn(String(localized: "\(percent(a.unreachableShare)) of the surface is out of reach (\(VFFormat.area(a.unreachableMM2)))"))
                } else {
                    plain(String(localized: "The tool reaches every face"))
                }
                plain(accessModel(a), secondary: true)
            }
        case .none, .stress:
            EmptyView()
        }
    }

    private func warn(_ s: String) -> some View {
        Label(s, systemImage: "exclamationmark.triangle.fill")
            .font(VFFont.rowEmphasis)
            .foregroundStyle(theme.warning)
            .frame(width: barWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func plain(_ s: String, secondary: Bool = false) -> some View {
        Text(s)
            .font(secondary ? VFFont.small : VFFont.rowEmphasis)
            .foregroundStyle(secondary ? theme.inkSecondary : theme.ink)
            .frame(width: barWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func countLine(_ s: MapScale) -> some View {
        Text(regionsLine(s))
            .font(VFFont.small)
            .foregroundStyle(theme.ink)
            .frame(width: barWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var unmeasuredRow: some View {
        HStack(spacing: VFSpace.s) {
            Rectangle().fill(Color(scene: SIMD3<Double>(MapPaint.unmeasuredRGB)))
                .frame(width: 22, height: 12)
                .clipShape(RoundedRectangle(cornerRadius: VFRadius.mark))
                .overlay(RoundedRectangle(cornerRadius: VFRadius.mark).strokeBorder(theme.hairline))
                .accessibilityHidden(true)
            Text("Grey: not measured").font(VFFont.small).foregroundStyle(theme.inkSecondary)
        }
        .frame(width: barWidth, alignment: .leading)
    }

    private func regionsLine(_ s: MapScale) -> String {
        guard let paint, paint.regions > 0 else { return String(localized: "No region past the limit") }
        let pct = max(Int((paint.share * 100).rounded()), 1)
        return paint.regions == 1
            ? String(localized: "1 region \(s.overWords), \(pct) % of the surface")
            : String(localized: "\(paint.regions) regions \(s.overWords), \(pct) % of the surface")
    }

    private var notApplicable: String {
        switch map {
        case .overhang: String(localized: "Overhangs are checked for printed parts. Set the process to Additive under Manufacturing to see them.")
        case .access: String(localized: "Tool access is checked for milled parts. Set the process to Milling under Manufacturing to see it.")
        default: ""
        }
    }

    private func accessModel(_ a: MeshMapFields.Access) -> String {
        let axes = a.axes.isEmpty ? [Vec3(0, 0, 1)] : a.axes
        let setup = axes.count == 1 && axes[0].z > 0.999
            ? String(localized: "3-axis, tool from the top.")
            : String(localized: "\(axes.count) tool axes: \(axes.map(direction).joined(separator: ", ")).")
        return setup + " " + String(localized: "Line of sight from each face along the tool axis; the cutter's width is not modelled.")
    }

    private func percent(_ share: Double) -> String {
        let p = share * 100
        return p > 0 && p < 0.1 ? String(localized: "under 0.1 %") : "\(p.formatted(.number.precision(.fractionLength(1)))) %"
    }

    private func direction(_ v: Vec3) -> String {
        let l = simd_length(v)
        let u = l > 0 ? v / l : Vec3(0, 0, 1)
        for (axis, name) in [(Vec3(1, 0, 0), "X"), (Vec3(0, 1, 0), "Y"), (Vec3(0, 0, 1), "Z")] {
            if simd_dot(u, axis) > 0.999 { return "+" + name }
            if simd_dot(u, axis) < -0.999 { return "−" + name }
        }
        return "(\(u.x.formatted(.number.precision(.fractionLength(2)))), \(u.y.formatted(.number.precision(.fractionLength(2)))), \(u.z.formatted(.number.precision(.fractionLength(2)))))"
    }

    private var accessibilitySummary: String {
        guard let f = fields, let scale else { return String(localized: "\(map.title) map, not ready") }
        guard MapPaint.applies(map, f) else { return String(localized: "\(map.title) map. \(notApplicable)") }
        var parts = [String(localized: "\(map.title) map")]
        switch map {
        case .overhang:
            if let o = f.overhangFigures { parts.append(String(localized: "limit \(VFFormat.angle(o.limitDeg)), \(percent(o.flaggedShare)) needs support")) }
        case .wall:
            if let w = f.wallFigures {
                if let l = w.limitMM { parts.append(String(localized: "limit \(VFFormat.length(l)), \(percent(w.thinShare)) under it")) }
                if let lo = w.minMM { parts.append(String(localized: "thinnest \(VFFormat.length(lo, digits: 2))")) }
            }
        case .access:
            if let a = f.accessFigures { parts.append(String(localized: "\(percent(a.unreachableShare)) out of reach")) }
        case .none, .stress:
            break
        }
        if scale.limit != nil { parts.append(regionsLine(scale)) }
        return parts.joined(separator: ", ")
    }
}

/// A band's mark that does not rely on colour: nothing for the good band, dots near the limit,
/// a hatch and an outline past it. Each stroke has a halo so it reads on any colour of the scale.
struct MapBandPattern: View {
    let kind: StressColors.Band.Kind
    let ink: Color
    let halo: Color

    var body: some View {
        Canvas { ctx, size in
            let r = CGRect(origin: .zero, size: size)
            switch kind {
            case .low:
                break
            case .atLimit:
                var dots = Path()
                var x: CGFloat = 3
                while x < size.width {
                    dots.addEllipse(in: CGRect(x: x - 1.5, y: size.height / 2 - 1.5, width: 3, height: 3))
                    x += 6
                }
                ctx.stroke(dots, with: .color(halo), lineWidth: 1.5)
                ctx.fill(dots, with: .color(ink))
            case .over:
                var hatch = Path()
                var x = -size.height
                while x < size.width {
                    hatch.move(to: CGPoint(x: x, y: size.height))
                    hatch.addLine(to: CGPoint(x: x + size.height, y: 0))
                    x += 5
                }
                ctx.clip(to: Path(r))
                ctx.stroke(hatch, with: .color(halo), lineWidth: 2.6)
                ctx.stroke(hatch, with: .color(ink), lineWidth: 1.2)
                ctx.stroke(Path(r.insetBy(dx: 0.75, dy: 0.75)), with: .color(ink), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: Checks

/// P1-33 for `--selftest`: the engine's maps on a real candidate follow the process (overhangs
/// for printing, tool access for milling, walls for both), agree with the mesh checks, paint a
/// colour per vertex, and the check rows lead to their maps.
@MainActor
enum MapsSelfTest {
    static func checks() -> [(Bool, String)] {
        var out: [(Bool, String)] = []
        out.append((CandidateMap(check: "overhangs") == .overhang && CandidateMap(check: "min_wall") == .wall
                    && CandidateMap(check: "tool_access") == .access && CandidateMap(check: "voids") == nil,
                    "P1-33 Show on Model opens the overhang, wall thickness and tool access maps"))
        // The request keys the cached maps: the same study must give the same text on every call,
        // or the canvas maps again on every redraw and never shows.
        var printed = GenerateModel.study(.cantilever)
        printed.manufacturing.process = .additive
        let requests = Set((0..<8).map { _ in GenerateModel.checkRequest(printed, route: nil) })
        out.append((requests.count == 1, "P1-33 map request is the same text on every call (\(requests.count) seen)"))
        let wall = MeshCheckItem(id: "min_wall", name: "Thinnest wall", status: .pass, value: 1.234, limit: 0.8, unit: "mm", detail: "", spot: nil)
        out.append((wall.figure == "\(VFFormat.length(1.234, digits: 2)), at least \(VFFormat.length(0.8, digits: 1))" && wall.map == .wall,
                    "P1-33 check figures follow the length unit: \(wall.figure)"))
        let bands = MapScale.overhang(limit: 45).bands
        out.append((bands.map(\.kind) == [.low, .atLimit, .over] && bands.allSatisfy { !$0.title.isEmpty && !$0.range.isEmpty }
                    && MapScale.wall(limit: 0.8, median: 3).bands.count == 3 && MapScale.access.bands.count == 3,
                    "P1-33 map legends have worded bands with values"))
        var s = GenerateModel.study(.cantilever)
        s.iterations = 10
        s.variants = 1
        s.voxel = 3
        s.manufacturing.process = .additive
        do {
            let job = try GenerateJob(json: try GenerateEngine.json(s))
            let o = try job.summary()
            guard let c = o.candidates.first else { return out + [(false, "P1-33 maps: the study gave no candidate")] }
            let n = c.mesh.vertexCount
            let request = GenerateModel.checkRequest(s, route: nil)
            let t = Date()
            let printed = try GenerateEngine.meshMaps(c.mesh, request: request)
            let seconds = Date().timeIntervalSince(t)
            let report = try GenerateEngine.checkMesh(c.mesh, request: request)
            let flagged = printed.overhangFigures?.flaggedMM2 ?? -1
            let checked = report.item("overhangs")?.value ?? -2
            out.append((printed.overhang.count == n && printed.overhangFigures?.applies == true
                        && printed.overhang.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 90 }
                        && abs(flagged - checked) <= 1e-6 * max(1, checked),
                        "P1-33 overhang map on \(n) vertices, \(String(format: "%.0f", flagged)) mm² needs support (the check says \(String(format: "%.0f", checked))) in \(String(format: "%.2f", seconds)) s"))
            let measured = printed.wallFigures?.measuredShare ?? 0
            out.append((printed.wall.count == n && measured > 0.75 && printed.wallFigures?.limitMM == 0.8
                        && printed.accessFigures?.applies == false && printed.access.allSatisfy(\.isNaN),
                        "P1-33 wall map measures \(Int(measured * 100)) % of the surface, thinnest \(String(format: "%.2f", printed.wallFigures?.minMM ?? 0)) mm; no tool map for printing"))
            var milled = s
            milled.manufacturing.process = .milling
            let mreq = GenerateModel.checkRequest(milled, route: nil)
            let m = try GenerateEngine.meshMaps(c.mesh, request: mreq)
            let mcheck = try GenerateEngine.checkMesh(c.mesh, request: mreq)
            let share = m.accessFigures?.unreachableShare ?? -1
            out.append((m.accessFigures?.applies == true && m.overhangFigures?.applies == false
                        && m.access.count == n && m.access.allSatisfy { $0.isNaN || (0...1).contains($0) }
                        && share >= 0 && share < 1 && mcheck.item("tool_access")?.status != .skipped,
                        "P1-33 tool access map (3-axis from the top): \(String(format: "%.1f", share * 100)) % out of reach, check \(mcheck.item("tool_access")?.status.word ?? "none")"))
            let p = PreviewMesh.make(c, study: s)
            let paint = MapPaint.paint(.overhang, fields: printed, preview: p, study: s, scale: .viridis)
            let plain = MapPaint.paint(.access, fields: printed, preview: p, study: s, scale: .viridis)
            out.append((paint.colors.count == 16 * p.vertexCount && plain.colors.count == paint.colors.count && plain.regions == 0 && paint.colors != plain.colors,
                        "P1-33 overhang paint colours every vertex, \(paint.regions) regions need support; a map that does not apply paints plain"))
        } catch {
            out.append((false, "P1-33 maps: \(error.localizedDescription)"))
        }
        if let dir = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--map-snapshot=") })?.dropFirst(15) {
            out.append(snapshot(dir: String(dir)))
        }
        return out
    }

    /// `--map-snapshot=<dir>`: the bracket template printed, its best candidate on the canvas
    /// with the overhang and the wall thickness maps and their legends, both themes, drawn by the
    /// scene's own offscreen renderer (map-overhang-light.png, map-wall-dark.png, and the
    /// Differentiate Without Color legends as map-overhang-dwc-light.png, map-wall-dwc-dark.png).
    private static func snapshot(dir: String) -> (Bool, String) {
        #if os(macOS)
        var s = GenerateModel.study(.bracket)
        s.iterations = 40
        s.variants = 1
        s.manufacturing.process = .additive
        do {
            let o = try GenerateJob(json: try GenerateEngine.json(s)).summary()
            guard let c = o.candidates.first else { return (false, "P1-33 map snapshots: no candidate") }
            let fields = try GenerateEngine.meshMaps(c.mesh, request: GenerateModel.checkRequest(s, route: nil))
            let base = PreviewMesh.make(c, study: s)
            var written: [String] = []
            for map in [CandidateMap.overhang, .wall] {
                let paint = MapPaint.paint(map, fields: fields, preview: base, study: s, scale: .viridis)
                var painted = base
                painted.colors = paint.colors
                for mode in [ThemeMode.light, .dark] {
                    let theme = ViaFormTheme(mode: mode, systemIsDark: mode == .dark, highContrast: false)
                    guard let shot = GenerateScene.thumbnail(painted, size: CGSize(width: 2200, height: 1440), theme: theme.viewportTheme) else { continue }
                    for dwc in [false, true] where !dwc || (map == .overhang) == (mode == .light) {
                        let board = MapCanvasBoard(image: shot, map: map, fields: fields, paint: paint, study: s, differentiate: dwc).viaFormTheme(mode)
                        let r = ImageRenderer(content: board)
                        r.scale = 2
                        guard let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { continue }
                        let name = "map-\(map.rawValue)\(dwc ? "-dwc" : "")-\(mode.rawValue).png"
                        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
                        written.append(name)
                    }
                }
            }
            return (written.count == 6, "P1-33 map snapshots written to \(dir): \(written.joined(separator: ", "))")
        } catch {
            return (false, "P1-33 map snapshots: \(error.localizedDescription)")
        }
        #else
        return (true, "P1-33 map snapshots are drawn on the Mac")
        #endif
    }
}

/// The canvas as a snapshot: the scene's render with the map picker's label and the legend over
/// its top right corner, where the canvas puts them.
private struct MapCanvasBoard: View {
    @Environment(\.viaFormTheme) private var theme
    let image: CGImage
    let map: CandidateMap
    let fields: MeshMapFields
    let paint: MapPaint
    let study: Study
    let differentiate: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(decorative: image, scale: 2)
            VStack(alignment: .trailing, spacing: VFSpace.m) {
                HStack(spacing: VFSpace.s) {
                    Image(systemName: "square.3.layers.3d")
                    Text("Map: \(map.title)").font(VFFont.row)
                    Image(systemName: "chevron.up.chevron.down").font(VFFont.glyph(9))
                }
                .foregroundStyle(theme.ink)
                .padding(.horizontal, VFSpace.l)
                .frame(minHeight: VFSize.minTarget)
                .vfSurface(.control, radius: VFRadius.control)
                MapLegend(map: map, fields: fields, paint: paint, loading: false, error: nil, study: study, differentiateOverride: differentiate)
            }
            .padding(VFSpace.panelPadding)
        }
        .environment(\.vfFlatSurfaces, true)
    }
}
