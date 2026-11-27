import SwiftUI

enum Workspace: String, CaseIterable, Identifiable, Hashable {
    case design = "Design", generative = "Generative", mechanics = "Mechanics", electronics = "Electronics"
    case simulation = "Simulation", training = "Training", render = "Render", manufacture = "Manufacture"
    var id: String { rawValue }
    var shortcut: KeyEquivalent { KeyEquivalent(Character(String((Workspace.allCases.firstIndex(of: self) ?? 0) + 1))) }
}

enum SidebarMode: String, Hashable { case items = "Items", history = "History" }

// MARK: Title bar

/// Prototype stand-in for the unified toolbar. In the app this is
/// `.toolbar { ToolbarItem(.navigation) ... ToolbarItem(.principal) { Picker(.segmented) } ... }`
/// with `.toolbarBackground(.ultraThinMaterial)` and the viewport running under it.
struct TitleBar: View {
    let title: String
    @Binding var workspace: Workspace
    var onSearch: () -> Void = {}

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                TrafficLights().padding(.trailing, 22)
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(VF.text)
                    .lineLimit(1).fixedSize()
                    .padding(.trailing, 22)
                IconButton(glyph: "arrow.uturn.backward", size: 14)
                IconButton(glyph: "arrow.uturn.forward", size: 14, tint: VF.text.opacity(0.35))
                Spacer()
                Button(action: onSearch) { SearchCommandsField() }.buttonStyle(.plain)
                    .padding(.trailing, 14)
                IconButton(glyph: "square.and.arrow.up", size: 16).padding(.trailing, 10)
                Avatar()
            }
            PillSegments(items: Workspace.allCases.map { ($0, $0.rawValue) }, selection: $workspace, height: 34, font: 12)
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .card(14)
    }
}

struct TrafficLights: View {
    var body: some View {
        HStack(spacing: 8) {
            ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { c in
                Circle().fill(Color(hex: UInt32(c))).frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
            }
        }
    }
}

struct SearchCommandsField: View {
    var width: CGFloat = 196
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13))
            Text("Search commands").font(.system(size: 12))
            Spacer(minLength: 0)
            Text("⌘K").font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(VF.secondary)
        .padding(.horizontal, 12)
        .frame(width: width, height: 30)
        .background(Capsule().fill(VF.track))
    }
}

// MARK: Viewport furniture

struct ViewportBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [VF.vpTop, VF.vpBottom], startPoint: .top, endPoint: .bottom)
            Canvas { ctx, size in
                // faint perspective grid: horizon above the window, lines converge to it
                let vp = CGPoint(x: size.width * 0.5, y: -size.height * 0.9)
                var p = Path()
                let n = 26
                for i in -n...n {
                    let bx = size.width * 0.5 + CGFloat(i) * size.width / 9
                    p.move(to: vp); p.addLine(to: CGPoint(x: bx, y: size.height))
                }
                var y = size.height * 0.02
                var step: CGFloat = 26
                while y < size.height { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)); y += step; step *= 1.045 }
                ctx.clip(to: Path(CGRect(origin: .zero, size: size)))
                ctx.stroke(p, with: .color(.white.opacity(0.55)), lineWidth: 1)
            }
        }
    }
}

/// About 70 pt, faces labelled Top, Front, Right. Faces snap to standard views,
/// edges and corners to iso views, drag orbits (OrbitCamera).
struct ViewCube: View {
    var size: CGFloat = 70
    var body: some View {
        Canvas { ctx, s in
            let c = CGPoint(x: s.width / 2, y: s.height / 2)
            let r = s.width * 0.46
            func pt(_ a: Double, _ k: CGFloat = 1) -> CGPoint {
                CGPoint(x: c.x + cos(a) * r * k, y: c.y + sin(a) * r * k)
            }
            let top = pt(-.pi / 2), ur = pt(-.pi / 6), lr = pt(.pi / 6), bot = pt(.pi / 2), ll = pt(5 * .pi / 6), ul = pt(7 * .pi / 6)
            let faces: [([CGPoint], Color)] = [
                ([top, ur, c, ul], Color(hex: 0xFBFBFC)),
                ([ul, c, bot, ll], Color(hex: 0xF0F1F4)),
                ([c, ur, lr, bot], Color(hex: 0xE6E8EC))
            ]
            var shadow = Path(ellipseIn: CGRect(x: c.x - r * 0.8, y: c.y + r * 0.72, width: r * 1.6, height: r * 0.4))
            ctx.fill(shadow, with: .color(.black.opacity(0.06)))
            shadow = Path()
            for (pts, col) in faces {
                var p = Path(); p.addLines(pts); p.closeSubpath()
                ctx.fill(p, with: .color(col))
                ctx.stroke(p, with: .color(.black.opacity(0.10)), lineWidth: 0.8)
            }
            func label(_ t: String, _ at: CGPoint, _ rot: Angle, _ shear: CGFloat) {
                var g = ctx
                g.translateBy(x: at.x, y: at.y)
                g.concatenate(CGAffineTransform(a: 1, b: shear, c: 0, d: 1, tx: 0, ty: 0))
                g.rotate(by: rot)
                g.draw(Text(t).font(.system(size: s.width * 0.12, weight: .medium)).foregroundColor(VF.text.opacity(0.65)), at: .zero)
            }
            label("Top", CGPoint(x: c.x, y: c.y - r * 0.5), .degrees(0), 0)
            label("Front", CGPoint(x: c.x - r * 0.45, y: c.y + r * 0.27), .degrees(0), 0.55)
            label("Right", CGPoint(x: c.x + r * 0.45, y: c.y + r * 0.27), .degrees(0), -0.55)
        }
        .frame(width: size, height: size)
    }
}

struct AxisTriad: View {
    var body: some View {
        Canvas { ctx, s in
            let o = CGPoint(x: 14, y: s.height - 14)
            let axes: [(CGPoint, Color, String)] = [
                (CGPoint(x: o.x, y: o.y - 44), Color(hex: 0x3B6FE0), "Z"),
                (CGPoint(x: o.x + 32, y: o.y - 22), Color(hex: 0x30A85A), "Y"),
                (CGPoint(x: o.x + 36, y: o.y + 8), VF.red, "X")
            ]
            for (end, col, name) in axes {
                var p = Path(); p.move(to: o); p.addLine(to: end)
                ctx.stroke(p, with: .color(col), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                let d = CGPoint(x: end.x - o.x, y: end.y - o.y)
                let len = sqrt(d.x * d.x + d.y * d.y)
                ctx.draw(Text(name).font(.system(size: 10, weight: .semibold)).foregroundColor(col),
                         at: CGPoint(x: end.x + d.x / len * 9, y: end.y + d.y / len * 9))
            }
        }
        .frame(width: 70, height: 70)
    }
}

struct NavCapsule: View {
    var active = "orbit"
    var body: some View {
        HStack(spacing: 6) {
            item("orbit", "rotate.3d")
            item("pan", "hand.raised")
            item("zoom", "plus.magnifyingglass")
            item("fit", "viewfinder")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .card(22)
    }
    func item(_ id: String, _ g: String) -> some View {
        Image(systemName: g).font(.system(size: 16))
            .foregroundStyle(id == active ? VF.accent : VF.text)
            .frame(width: 40, height: 34)
    }
}

// MARK: Anchored placement

/// Places its single child relative to an anchor (the selection's projected screen point),
/// then clamps it inside the viewport with a margin. A Layout, so it is correct on the
/// first pass (ImageRenderer has no second pass) and needs no GeometryReader.
struct AnchorLayout: Layout {
    enum Side { case above, below, trailing, leading }
    var anchor: CGPoint
    var side: Side = .above
    var gap: CGFloat = 14
    var margin: CGFloat = 16
    var insets = EdgeInsets(top: 70, leading: 16, bottom: 16, trailing: 16)

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let v = subviews.first else { return }
        let s = v.sizeThatFits(.unspecified)
        var o: CGPoint
        switch side {
        case .above: o = CGPoint(x: anchor.x - s.width / 2, y: anchor.y - gap - s.height)
        case .below: o = CGPoint(x: anchor.x - s.width / 2, y: anchor.y + gap)
        case .trailing: o = CGPoint(x: anchor.x + gap, y: anchor.y - s.height / 2)
        case .leading: o = CGPoint(x: anchor.x - gap - s.width, y: anchor.y - s.height / 2)
        }
        o.x = min(max(o.x, bounds.minX + insets.leading), bounds.maxX - insets.trailing - s.width)
        o.y = min(max(o.y, bounds.minY + insets.top), bounds.maxY - insets.bottom - s.height)
        v.place(at: CGPoint(x: bounds.minX + o.x, y: bounds.minY + o.y), proposal: ProposedViewSize(s))
    }
}

// MARK: Sidebar

/// Right sidebar card: Items | History switch, then the tree (or the history list) in place.
struct ItemsHistoryCard: View {
    @Binding var mode: SidebarMode
    let items: [TreeNode]
    let history: [TreeNode]
    var selected: String?
    var device: Device = .mac
    var onSelect: (String) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 10) {
            PillSegments(items: [(SidebarMode.items, "Items"), (.history, "History")], selection: $mode,
                         height: 36, font: 13, activeTint: VF.accent, activeWeight: .semibold, expand: true)
            VStack(spacing: 2) {
                ForEach(mode == .items ? items : history) { n in
                    TreeRow(node: n, selected: n.id == selected, device: device)
                        .onTapGesture { onSelect(n.id) }
                }
            }
        }
        .padding(10)
        .card()
    }
}
