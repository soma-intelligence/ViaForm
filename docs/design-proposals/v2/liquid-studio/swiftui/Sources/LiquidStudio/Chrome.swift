import SwiftUI

// MARK: - Title toolbar

struct TitleToolbar: View {
    var project: String
    @Binding var workspace: Workspace
    @Binding var showSidebar: Bool
    @Binding var showInspector: Bool
    var jobs = 2

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { c in
                    Circle().fill(Color(hex: UInt32(c))).frame(width: 12, height: 12)
                        .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
                }
            }
            .padding(.leading, 16).padding(.trailing, 14)
            Button { withAnimation(.snappy) { showSidebar.toggle() } } label: {
                ChromeButton(symbol: "sidebar.left", active: showSidebar)
            }.buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 1) {
                Text(project).font(Tok.body(.semibold)).foregroundStyle(Tok.primary)
                Text("Edited").font(Tok.caption()).foregroundStyle(Tok.secondary)
            }
            .padding(.leading, 10).frame(width: 150, alignment: .leading)
            ChromeButton(symbol: "arrow.uturn.backward")
            ChromeButton(symbol: "arrow.uturn.forward").opacity(0.5)
            Spacer(minLength: 12)
            WorkspaceCapsule(selection: $workspace)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                JobsChip(count: jobs)
                ChromeButton(symbol: "magnifyingglass")
                ChromeButton(symbol: "square.and.arrow.up")
                Button { withAnimation(.snappy) { showInspector.toggle() } } label: {
                    ChromeButton(symbol: "slider.horizontal.3", active: showInspector)
                }.buttonStyle(.plain)
            }
            .padding(.trailing, 10)
        }
        .frame(height: 52)
        .glass()
    }
}

struct JobsChip: View {
    var count: Int
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color(hex: 0x34C759)).frame(width: 6, height: 6)
                .shadow(color: Color(hex: 0x34C759).opacity(0.8), radius: 3)
            Text("\(count) jobs").font(Tok.caption(.medium)).foregroundStyle(Tok.primary)
        }
        .padding(.horizontal, 11).frame(height: 26)
        .background(Capsule().fill(.white.opacity(0.06)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1))
        .padding(.trailing, 4)
    }
}

/// Eight workspaces in one glass capsule; the active pill morphs between tabs with matchedGeometryEffect.
struct WorkspaceCapsule: View {
    @Binding var selection: Workspace
    var touch = false
    @Namespace private var pill

    var body: some View {
        HStack(spacing: touch ? 2 : 0) {
            ForEach(Workspace.allCases) { w in
                Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { selection = w } } label: {
                    label(w)
                        .background {
                            if w == selection {
                                Capsule(style: .continuous).fill(w.accent)
                                    .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 1))
                                    .shadow(color: w.accent.opacity(0.45), radius: 8, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(w.shortcut, modifiers: .command)
            }
        }
        .padding(touch ? 6 : 3)
        .background(Capsule(style: .continuous).fill(.black.opacity(0.18)))
        .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 1))
    }

    @ViewBuilder private func label(_ w: Workspace) -> some View {
        let on = w == selection
        if touch {
            VStack(spacing: 5) {
                Image(systemName: w.symbol).font(.system(size: 19, weight: .medium))
                Text(w.rawValue).font(.system(size: 12, weight: on ? .semibold : .medium))
            }
            .foregroundStyle(on ? w.onAccent : Tok.primary)
            .frame(width: 94, height: 58)
        } else {
            Text(w.rawValue).font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? w.onAccent : Tok.primary.opacity(0.86))
                .padding(.horizontal, 12).frame(height: 30)
        }
    }
}

// MARK: - Ribbon (Design only)

struct RibbonGroup: Identifiable {
    var id: String { name }
    var name: String
    var tools: [String]
}

struct Ribbon: View {
    static let groups = [
        RibbonGroup(name: "CREATE", tools: ["sketch", "extrude", "revolve", "box", "cylinder"]),
        RibbonGroup(name: "MODIFY", tools: ["presspull", "fillet", "chamfer", "shell", "combine"]),
        RibbonGroup(name: "ASSEMBLE", tools: ["component", "joint", "rigid_group", "fastener"]),
        RibbonGroup(name: "CONSTRUCT", tools: ["plane", "plane_angle", "axis_through_cylinder", "point_vertex"]),
        RibbonGroup(name: "INSPECT", tools: ["measure", "interference", "section", "configuration_table"]),
        RibbonGroup(name: "INSERT", tools: ["import", "library", "mount"]),
    ]
    var active = "joint"

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(Self.groups.enumerated()), id: \.element.id) { i, g in
                if i > 0 { Rectangle().fill(Tok.hairline).frame(width: 1, height: 44) }
                VStack(spacing: 3) {
                    HStack(spacing: 4) {
                        ForEach(g.tools, id: \.self) { t in
                            Asset.tool(t).resizable().interpolation(.high).frame(width: 26, height: 26)
                                .brightness(0.10).contrast(1.15)
                                .frame(width: 36, height: 34)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(.white.opacity(t == active ? 0.13 : 0)))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(.white.opacity(t == active ? 0.16 : 0), lineWidth: 1))
                        }
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Tok.tertiary)
                            .frame(width: 12)
                    }
                    HStack(spacing: 3) {
                        Text(g.name).font(.system(size: 10, weight: .semibold)).tracking(0.6)
                        Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                    }
                    .foregroundStyle(Tok.secondary)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 64)
        .glass()
    }
}

// MARK: - Browser tree

struct TreeRow: Identifiable {
    let id = UUID()
    var level: Int
    var label: String
    var tool: String? = nil
    var symbol: String? = nil
    var expanded: Bool? = nil
    var selected = false
    var detail: String? = nil
    var swatch: Color? = nil
    var dot: Color? = nil
    var eye = true
    var chevronRight = false
}

struct TreeRowView: View {
    var row: TreeRow
    @Environment(\.accent) private var accent
    @Environment(\.onAccent) private var onAccent

    var body: some View {
        let fg = row.selected ? onAccent : Tok.primary
        HStack(spacing: 6) {
            Group {
                if let e = row.expanded {
                    Image(systemName: e ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                } else { Color.clear }
            }
            .frame(width: 12).foregroundStyle(row.selected ? onAccent.opacity(0.8) : Tok.secondary)
            if let s = row.swatch {
                RoundedRectangle(cornerRadius: 3).fill(s).frame(width: 14, height: 14)
            }
            if let d = row.dot { Circle().fill(d).frame(width: 8, height: 8).frame(width: 14) }
            if let t = row.tool {
                Asset.tool(t).resizable().interpolation(.high).frame(width: 18, height: 18)
                    .background(Circle().fill(.white.opacity(row.selected ? 0.35 : 0.0)).blur(radius: 4))
            }
            if let s = row.symbol {
                Image(systemName: s).font(.system(size: 12)).foregroundStyle(fg.opacity(0.85)).frame(width: 18)
            }
            Text(row.label).font(Tok.body(row.selected ? .medium : .regular)).foregroundStyle(fg).lineLimit(1)
            Spacer(minLength: 4)
            if let d = row.detail { Text(d).font(Tok.mono(12)).foregroundStyle(row.selected ? fg : Tok.secondary) }
            if row.chevronRight { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(fg) }
            if row.eye {
                Image(systemName: "eye").font(.system(size: 11)).foregroundStyle(row.selected ? fg : Tok.secondary)
            }
        }
        .padding(.leading, 6 + CGFloat(row.level) * 16).padding(.trailing, 10)
        .frame(height: 28)
        .background {
            if row.selected {
                Capsule(style: .continuous).fill(accent)
                    .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.2), lineWidth: 1))
            }
        }
        .padding(.horizontal, 6)
    }
}

struct SectionHeader: View {
    var symbol: String
    var title: String
    var trailing: String? = nil
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(Tok.primary).frame(width: 18)
            Text(title).font(Tok.body(.semibold)).foregroundStyle(Tok.primary)
            Spacer()
            if let trailing { Text(trailing).font(Tok.mono(12)).foregroundStyle(Tok.secondary) }
        }
        .padding(.horizontal, Tok.pad).frame(height: 30)
    }
}

// MARK: - Viewport overlays

struct ViewCube: View {
    var size: CGFloat = 92
    var body: some View {
        Canvas { ctx, sz in
            let e = sz.width * 0.36
            let r = CGVector(dx: cos(.pi / 6) * e, dy: sin(.pi / 6) * e)
            let l = CGVector(dx: -r.dx, dy: r.dy)
            let d = CGVector(dx: 0, dy: e)
            let a = CGPoint(x: sz.width / 2, y: sz.height / 2 - e)
            func add(_ p: CGPoint, _ v: CGVector) -> CGPoint { CGPoint(x: p.x + v.dx, y: p.y + v.dy) }
            let c = add(add(a, r), l)
            let faces: [(CGPoint, CGVector, CGVector, String, Double)] = [
                (a, r, l, "TOP", 0.30), (add(a, l), r, d, "FRONT", 0.20),
                (c, CGVector(dx: -l.dx, dy: -l.dy), d, "RIGHT", 0.13),
            ]
            for (o, u, v, label, shade) in faces {
                ctx.drawLayer { g in
                    g.concatenate(CGAffineTransform(a: u.dx / 100, b: u.dy / 100, c: v.dx / 100, d: v.dy / 100, tx: o.x, ty: o.y))
                    let rect = Path(roundedRect: CGRect(x: 0, y: 0, width: 100, height: 100), cornerRadius: 6)
                    g.fill(rect, with: .color(Color(hex: 0x2A2D34).opacity(0.95)))
                    g.fill(rect, with: .color(.white.opacity(shade)))
                    g.stroke(rect, with: .color(.white.opacity(0.35)), lineWidth: 2.5)
                    g.draw(Text(label).font(.system(size: 21, weight: .semibold)).foregroundStyle(.white.opacity(0.85)),
                           at: CGPoint(x: 50, y: 50))
                }
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
    }
}

struct NavCapsule: View {
    var body: some View {
        HStack(spacing: 4) {
            ChromeButton(symbol: "rotate.3d", size: 40, active: true)
            ChromeButton(symbol: "hand.raised", size: 40)
            ChromeButton(symbol: "plus.magnifyingglass", size: 40)
            ChromeButton(symbol: "viewfinder", size: 40)
            Rectangle().fill(Tok.hairline).frame(width: 1, height: 22)
            ChromeButton(symbol: "display", size: 40)
            ChromeButton(symbol: "squareshape.split.3x3", size: 40)
        }
        .padding(.horizontal, 8).frame(height: 50)
        .glass(16)
    }
}

/// Status capsule used by Electronics, Generative progress and iPad summary.
struct StatusCapsule<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 10) { content }
            .font(Tok.body()).foregroundStyle(Tok.primary)
            .padding(.horizontal, 18).frame(height: 40)
            .glassCapsule()
    }
}

struct Dot: View {
    var body: some View { Text("\u{00B7}").font(Tok.body(.bold)).foregroundStyle(Tok.tertiary) }
}

/// Glass value chip next to a drag handle. Click to edit in place.
struct ValueChip: View {
    @Binding var value: Double
    var unit: String
    var large = false
    @State private var editing = false
    @Environment(\.accent) private var accent

    var body: some View {
        Group {
            if editing {
                TextField("", value: $value, format: .number.precision(.fractionLength(1)))
                    .textFieldStyle(.plain).frame(width: 48).onSubmit { editing = false }
            } else {
                Text(String(format: "%.1f %@", value, unit))
            }
        }
        .font(large ? .system(size: 17, weight: .semibold, design: .monospaced) : Tok.mono(13, .medium))
        .foregroundStyle(Tok.primary)
        .padding(.horizontal, large ? 14 : 9).frame(height: large ? 40 : 26)
        .glass(large ? 12 : 8, tint: 0.86)
        .overlay(RoundedRectangle(cornerRadius: large ? 12 : 8, style: .continuous).strokeBorder(accent.opacity(0.55), lineWidth: 1))
        .onTapGesture { editing = true }
    }
}

/// Floating context menu beside the selection (direction B's pill), placed from the projected anchor.
struct ContextMenuPill: View {
    var items: [(String, String)]
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items, id: \.1) { tool, label in
                HStack(spacing: 9) {
                    Asset.tool(tool).resizable().interpolation(.high).frame(width: 18, height: 18)
                    Text(label).font(Tok.body()).foregroundStyle(Tok.primary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(label == items.first?.1 ? 0.0 : 0)))
            }
        }
        .padding(6).frame(width: 152)
        .glass(12, tint: 0.84)
    }
}
