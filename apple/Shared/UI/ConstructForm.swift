import SwiftUI

/// The 20 construction commands (B-14): planes, axes and points built from model geometry.
enum ConstructKind: String, CaseIterable, Identifiable {
    // Planes
    case offset, atAngle, midplane, planeTwoEdges, planeAxisPoint, planeThreePoints, tangent, planeAlongPath, perpendicular
    // Axes
    case axisCylinder, axisNormalToFace, axisTwoPlanes, axisTwoPoints, axisEdge
    // Points
    case pointVertex, pointTwoEdges, pointThreePlanes, pointCenter, pointEdgePlane, pointAlongPath

    enum Group: String, CaseIterable { case plane, axis, point }

    var id: String { rawValue }

    var command: String {
        switch self {
        case .offset: "construct.plane.offset"
        case .atAngle: "construct.plane.at_angle"
        case .midplane: "construct.plane.midplane"
        case .planeTwoEdges: "construct.plane.two_edges"
        case .planeAxisPoint: "construct.plane.axis_point"
        case .planeThreePoints: "construct.plane.three_points"
        case .tangent: "construct.plane.tangent"
        case .planeAlongPath: "construct.plane.along_path"
        case .perpendicular: "construct.plane.perpendicular"
        case .axisCylinder: "construct.axis.through_cylinder"
        case .axisNormalToFace: "construct.axis.normal_to_face"
        case .axisTwoPlanes: "construct.axis.two_planes"
        case .axisTwoPoints: "construct.axis.two_points"
        case .axisEdge: "construct.axis.edge"
        case .pointVertex: "construct.point.vertex"
        case .pointTwoEdges: "construct.point.two_edges"
        case .pointThreePlanes: "construct.point.three_planes"
        case .pointCenter: "construct.point.center"
        case .pointEdgePlane: "construct.point.edge_plane"
        case .pointAlongPath: "construct.point.along_path"
        }
    }

    var group: Group {
        switch self {
        case .offset, .atAngle, .midplane, .planeTwoEdges, .planeAxisPoint, .planeThreePoints, .tangent, .planeAlongPath, .perpendicular: .plane
        case .axisCylinder, .axisNormalToFace, .axisTwoPlanes, .axisTwoPoints, .axisEdge: .axis
        default: .point
        }
    }

    var title: String {
        switch self {
        case .offset: String(localized: "Offset Plane")
        case .atAngle: String(localized: "Plane at Angle")
        case .midplane: String(localized: "Midplane")
        case .planeTwoEdges: String(localized: "Plane Through Two Edges")
        case .planeAxisPoint: String(localized: "Plane Through Axis and Point")
        case .planeThreePoints: String(localized: "Plane Through Three Points")
        case .tangent: String(localized: "Tangent Plane")
        case .planeAlongPath: String(localized: "Plane Along Path")
        case .perpendicular: String(localized: "Perpendicular Plane")
        case .axisCylinder: String(localized: "Axis Through Cylinder")
        case .axisNormalToFace: String(localized: "Axis Perpendicular to Face")
        case .axisTwoPlanes: String(localized: "Axis Through Two Planes")
        case .axisTwoPoints: String(localized: "Axis Through Two Points")
        case .axisEdge: String(localized: "Axis Through Edge")
        case .pointVertex: String(localized: "Point at Vertex")
        case .pointTwoEdges: String(localized: "Point Through Two Edges")
        case .pointThreePlanes: String(localized: "Point Through Three Planes")
        case .pointCenter: String(localized: "Point at Centre")
        case .pointEdgePlane: String(localized: "Point at Edge and Plane")
        case .pointAlongPath: String(localized: "Point Along Path")
        }
    }

    /// ViaForm's own SF Symbols for the list.
    var symbol: String {
        switch group {
        case .plane: self == .atAngle ? "rotate.3d" : (self == .midplane ? "square.split.2x1" : "square.on.square.dashed")
        case .axis: "line.diagonal"
        case .point: "smallcircle.filled.circle"
        }
    }

    /// The references the command takes, in the order the form asks for them.
    var slots: [ConstructSlot] {
        switch self {
        case .offset: [.init("base", String(localized: "Base"), .planeBase)]
        case .atAngle: [.init("base", String(localized: "Base"), .planeBase), .init("axis", String(localized: "Hinge"), .axisBase)]
        case .midplane, .axisTwoPlanes: [.init("a", String(localized: "First plane"), .planeRef), .init("b", String(localized: "Second plane"), .planeRef)]
        case .planeTwoEdges, .pointTwoEdges: [.init("a", String(localized: "First edge"), .edge), .init("b", String(localized: "Second edge"), .edge)]
        case .planeAxisPoint: [.init("axis", String(localized: "Axis"), .axisRef), .init("point", String(localized: "Point"), .point)]
        case .planeThreePoints: [.init("a", String(localized: "First point"), .point), .init("b", String(localized: "Second point"), .point),
                                 .init("c", String(localized: "Third point"), .point)]
        case .tangent: [.init("face", String(localized: "Round face"), .face)]
        case .planeAlongPath, .pointAlongPath: [.init("path", String(localized: "Path"), .edge)]
        case .perpendicular: [.init("plane", String(localized: "Plane"), .planeRef), .init("line", String(localized: "Line"), .axisRef)]
        case .axisCylinder: [.init("face", String(localized: "Round face or circle"), .faceOrEdge)]
        case .axisNormalToFace: [.init("face", String(localized: "Face"), .face), .init("point", String(localized: "Through point"), .point)]
        case .axisTwoPoints: [.init("a", String(localized: "First point"), .point), .init("b", String(localized: "Second point"), .point)]
        case .axisEdge: [.init("edge", String(localized: "Straight edge"), .edge)]
        case .pointVertex: [.init("point", String(localized: "Vertex"), .point)]
        case .pointThreePlanes: [.init("a", String(localized: "First plane"), .planeRef), .init("b", String(localized: "Second plane"), .planeRef),
                                 .init("c", String(localized: "Third plane"), .planeRef)]
        case .pointCenter: [.init("of", String(localized: "Circle, sphere or torus"), .faceOrEdge)]
        case .pointEdgePlane: [.init("edge", String(localized: "Edge"), .edge), .init("plane", String(localized: "Plane"), .planeRef)]
        }
    }

    /// The values the command takes besides its references.
    var values: [ConstructValue] {
        switch self {
        case .offset: [.init("offset", String(localized: "Distance"), .length, 10)]
        case .atAngle: [.init("angle", String(localized: "Angle"), .angle, 45)]
        case .planeAlongPath, .pointAlongPath: [.init("t", String(localized: "Position"), .none, 0.5, range: 0...1)]
        default: []
        }
    }
}

/// One reference a construction asks for.
struct ConstructSlot: Identifiable, Hashable {
    enum Accepts: Hashable {
        /// `base` of offset and at-angle: XY, XZ, YZ, a plane name, or a planar face.
        case planeBase
        /// A plane reference: `{plane: XY}` or a planar face.
        case planeRef
        /// `axis` of at-angle: X, Y, Z, or a straight or round edge or face.
        case axisBase
        /// An axis reference: `{axis: X}` or a straight edge.
        case axisRef
        case edge
        case face
        case faceOrEdge
        /// A vertex (the one nearest the pick) or a point.
        case point
    }
    let key: String
    let label: String
    let accepts: Accepts
    var id: String { key }

    init(_ key: String, _ label: String, _ accepts: Accepts) {
        self.key = key
        self.label = label
        self.accepts = accepts
    }

    var origins: [String] {
        switch accepts {
        case .planeBase, .planeRef: ["XY", "XZ", "YZ"]
        case .axisBase, .axisRef: ["X", "Y", "Z"]
        default: []
        }
    }

    var hint: String {
        switch accepts {
        case .planeBase, .planeRef: String(localized: "Pick a flat face, or an origin plane")
        case .axisBase: String(localized: "Pick an edge or round face, or an origin axis")
        case .axisRef: String(localized: "Pick a straight edge, or an origin axis")
        case .edge: String(localized: "Pick an edge")
        case .face: String(localized: "Pick a face")
        case .faceOrEdge: String(localized: "Pick a round face or a circular edge")
        case .point: String(localized: "Pick near a vertex")
        }
    }

    /// The reference a viewport pick gives this slot, or nil when the slot does not take it.
    func ref(for pick: Pick) -> ConstructRef? {
        switch (accepts, pick.isFace) {
        case (.planeBase, true), (.planeRef, true), (.axisBase, true), (.face, true), (.faceOrEdge, true): .face(pick.points)
        case (.axisBase, false), (.axisRef, false), (.edge, false), (.faceOrEdge, false): .edge(pick.points)
        case (.point, false): .vertex(pick.points)
        default: nil
        }
    }
}

/// A value field of a construction (distance, angle, position along a path).
struct ConstructValue: Identifiable, Hashable {
    let key: String
    let label: String
    let unit: VFUnit
    let initial: Double
    var range: ClosedRange<Double>?
    var id: String { key }

    init(_ key: String, _ label: String, _ unit: VFUnit, _ initial: Double, range: ClosedRange<Double>? = nil) {
        self.key = key
        self.label = label
        self.unit = unit
        self.initial = initial
        self.range = range
    }
}

/// What a slot holds.
enum ConstructRef: Hashable {
    case plane(String)
    case axis(String)
    case face([Double])
    case edge([Double])
    case vertex([Double])

    var title: String {
        switch self {
        case .plane(let n): String(localized: "\(n) plane")
        case .axis(let n): String(localized: "\(n) axis")
        case .face(let p): String(localized: "Face at \(Self.point(p))")
        case .edge(let p): String(localized: "Edge at \(Self.point(p))")
        case .vertex(let p): String(localized: "Vertex near \(Self.point(p))")
        }
    }

    private static func point(_ p: [Double]) -> String { VFFormat.lengths(p, separator: ", ", digits: 1) }

    /// The JSON the command takes for this slot.
    func json(for accepts: ConstructSlot.Accepts) -> Any {
        switch (self, accepts) {
        case (.plane(let n), .planeBase): n
        case (.axis(let n), .axisBase): n
        case (.plane(let n), _): ["plane": n]
        case (.axis(let n), _): ["axis": n]
        case (.face(let p), _): ["face": p]
        case (.edge(let p), _): ["edge": p]
        case (.vertex(let p), _): ["vertex": p]
        }
    }
}

/// The form's state, kept apart from the view so a test can fill and send it.
struct ConstructDraft: Equatable {
    var kind: ConstructKind
    var refs: [String: ConstructRef] = [:]
    /// Typed values in the field's base unit.
    var numbers: [String: Double] = [:]
    /// Expressions that link a value to parameters (B-10); they win over `numbers`.
    var values: [String: String] = [:]
    var name = ""

    init(kind: ConstructKind) {
        self.kind = kind
        for v in kind.values { numbers[v.key] = v.initial }
    }

    /// The first reference still missing, or nil when the command can run.
    var missing: String? { kind.slots.first { refs[$0.key] == nil }?.label }

    func params() -> [String: Any] {
        var p: [String: Any] = [:]
        for s in kind.slots { if let r = refs[s.key] { p[s.key] = r.json(for: s.accepts) } }
        for v in kind.values {
            if let e = values[v.key], !e.trimmingCharacters(in: .whitespaces).isEmpty {
                p[v.key] = e
            } else if let n = numbers[v.key] {
                // Lengths go in the design's units (mm); angles carry their unit.
                p[v.key] = v.unit == .angle ? "\(VFFormat.editable(n)) deg" : n
            }
        }
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { p["name"] = n }
        return p
    }
}

/// The pick-driven construction form (B-14), for both apps: choose a type, then click the
/// references in the viewport one after the other (the active slot takes the newest pick),
/// type the values (they link to parameters), and OK runs the one `construct.*` command.
/// Present it in the Mac inspector or a popover, and in the iPad tool panel.
struct ConstructForm: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    var onDone: (() -> Void)? = nil
    @State private var draft: ConstructDraft
    @State private var active: String?
    @State private var created: String?
    @State private var error: String?

    init(model: DesignModel, kind: ConstructKind = .offset, onDone: (() -> Void)? = nil) {
        self.model = model
        self.onDone = onDone
        _draft = State(initialValue: ConstructDraft(kind: kind))
        _active = State(initialValue: kind.slots.first?.key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpace.m) {
            typeMenu
            ForEach(draft.kind.slots) { s in slotRow(s) }
            ForEach(draft.kind.values) { v in valueRow(v) }
            HStack(spacing: VFSpace.s) {
                Text("Name").font(VFFont.row).foregroundStyle(theme.inkSecondary)
                TextField(String(localized: "Automatic"), text: $draft.name)
                    .vfField().font(VFFont.row)
                    #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    #endif
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(VFFont.small).foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let created { createdRow(created) }
            HStack(spacing: VFSpace.s) {
                Spacer()
                if let onDone {
                    Button(String(localized: "Cancel")) { onDone() }
                        .buttonStyle(.vfSecondary)
                        .keyboardShortcut(.cancelAction)
                }
                Button(String(localized: "OK")) { run() }
                    .buttonStyle(.vfPrimary)
                    .keyboardShortcut(.defaultAction)
                    .vfDisabled(draft.missing != nil, reason: String(localized: "\(draft.missing ?? "") is missing"))
                    .vfEngineGate()
            }
        }
        .vfParameterLinks(model)
        .onChange(of: model.selection) { _, picks in take(picks.last) }
    }

    private var typeMenu: some View {
        Menu {
            ForEach(ConstructKind.Group.allCases, id: \.self) { g in
                Section(groupTitle(g)) {
                    ForEach(ConstructKind.allCases.filter { $0.group == g }) { k in
                        Button { choose(k) } label: { Label(k.title, systemImage: k.symbol) }
                    }
                }
            }
        } label: {
            Label(draft.kind.title, systemImage: draft.kind.symbol)
                .font(VFFont.rowEmphasis)
        }
        .menuStyle(.vfPill)
        .accessibilityLabel(Text("Construction type, \(draft.kind.title)"))
    }

    private func groupTitle(_ g: ConstructKind.Group) -> String {
        switch g {
        case .plane: String(localized: "Planes")
        case .axis: String(localized: "Axes")
        case .point: String(localized: "Points")
        }
    }

    private func slotRow(_ s: ConstructSlot) -> some View {
        let isActive = active == s.key
        let ref = draft.refs[s.key]
        return VStack(alignment: .leading, spacing: VFSpace.xs) {
            Button { active = s.key } label: {
                HStack(spacing: VFSpace.s) {
                    Image(systemName: ref == nil ? (isActive ? "scope" : "circle.dashed") : "checkmark.circle.fill")
                        .foregroundStyle(ref == nil ? (isActive ? theme.accentText : theme.inkTertiary) : theme.success)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: VFSpace.xxs) {
                        Text(s.label).font(VFFont.row).foregroundStyle(theme.ink)
                        Text(ref?.title ?? s.hint).font(VFFont.small).foregroundStyle(theme.inkSecondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    if ref != nil {
                        VFIconButton("xmark.circle", label: String(localized: "Clear \(s.label)"), size: 11) {
                            draft.refs[s.key] = nil
                            active = s.key
                        }
                    }
                }
                .padding(VFSpace.s)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .vfSurface(.well)
            .overlay(RoundedRectangle(cornerRadius: VFRadius.well).strokeBorder(isActive ? theme.accent : .clear, lineWidth: 1.5))
            .accessibilityLabel(Text("\(s.label), \(ref?.title ?? s.hint)"))
            .accessibilityAddTraits(isActive ? .isSelected : [])
            if isActive, !s.origins.isEmpty {
                HStack(spacing: VFSpace.xs) {
                    ForEach(s.origins, id: \.self) { o in
                        Button(o) {
                            fill(s, s.accepts == .axisBase || s.accepts == .axisRef ? .axis(o) : .plane(o))
                        }
                        .buttonStyle(.vfSecondary)
                        .help(String(localized: "Use the origin \(o)"))
                    }
                }
            }
        }
    }

    private func valueRow(_ v: ConstructValue) -> some View {
        HStack {
            Text(v.label).font(VFFont.row).foregroundStyle(theme.inkSecondary)
            Spacer(minLength: VFSpace.m)
            NumberField(v.label, value: Binding(get: { draft.numbers[v.key] ?? v.initial }, set: { draft.numbers[v.key] = $0 }),
                        unit: v.unit, range: v.range, step: v.unit == .none ? 0.1 : (v.unit == .angle ? 5 : 1), width: 88)
                .labelHiddenVisually()
                .linked(Binding(get: { draft.values[v.key] ?? "" }, set: { draft.values[v.key] = $0 }))
        }
    }

    private func createdRow(_ name: String) -> some View {
        HStack(spacing: VFSpace.s) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.success).accessibilityHidden(true)
            Text("\(name) added").font(VFFont.small).foregroundStyle(theme.ink)
            Spacer(minLength: 0)
            if draft.kind.group == .plane {
                Button(String(localized: "Sketch on \(name)")) {
                    model.startSketch(name)
                    onDone?()
                }
                .buttonStyle(.vfSecondary)
            }
        }
    }

    private func choose(_ k: ConstructKind) {
        let keep = draft.name
        draft = ConstructDraft(kind: k)
        draft.name = keep
        active = k.slots.first?.key
        error = nil
    }

    /// The newest viewport pick fills the active slot, then the next empty slot is active.
    private func take(_ pick: Pick?) {
        guard let pick, let key = active, let s = draft.kind.slots.first(where: { $0.key == key }) else { return }
        guard let r = s.ref(for: pick) else {
            error = s.hint
            return
        }
        fill(s, r)
    }

    private func fill(_ s: ConstructSlot, _ r: ConstructRef) {
        error = nil
        created = nil
        draft.refs[s.key] = r
        let slots = draft.kind.slots
        let after = slots.drop { $0.key != s.key }.dropFirst()
        active = (after.first { draft.refs[$0.key] == nil } ?? slots.first { draft.refs[$0.key] == nil })?.key
    }

    private func run() {
        guard draft.missing == nil else { return }
        let r = model.run(draft.kind.command, draft.params())
        guard let out = r as? [String: Any] else {
            error = model.message ?? String(localized: "The engine refused the construction")
            return
        }
        created = out["name"] as? String ?? draft.kind.title
        let kind = draft.kind
        draft = ConstructDraft(kind: kind)
        active = kind.slots.first?.key
        model.selection = []
    }
}
