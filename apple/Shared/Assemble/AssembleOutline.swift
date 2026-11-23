import SwiftUI

/// The BROWSER of the Assemble stage: the product, its components as a tree along the joints,
/// the joints, saved poses and grasps. A component or a joint row selects the joint.
struct AssembleOutline: View {
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: AssembleModel
    var title: String
    @State private var closed: Set<String> = []

    var body: some View {
        row(0, "cube.transparent", title, bold: true)
        folder("Components (\(model.components.count))", "square.stack.3d.up") {
            ForEach(tree, id: \.id) { item in
                let joint = model.joints.first { $0.child == item.id }
                row(2 + min(item.depth, 6), item.depth == 0 ? "pin" : "cube", item.title, selected: joint != nil && joint?.id == model.selectedJoint)
                    .onTapGesture { if let joint { model.selectedJoint = joint.id; if model.tool == .dragTip || model.tool == .grasp { model.tool = .select } } }
                    .accessibilityAddTraits(.isButton)
            }
        }
        folder("Joints (\(model.joints.count))", "link") {
            ForEach(Array(model.joints.enumerated()), id: \.element.id) { i, j in
                row(2, "arrow.triangle.2.circlepath", "J\(i + 1) \(j.title)", selected: j.id == model.selectedJoint,
                    detail: AsmFormat.deg(model.q[j.id] ?? 0))
                    .onTapGesture { model.selectedJoint = j.id; if model.tool == .dragTip || model.tool == .grasp { model.tool = .select } }
                    .accessibilityAddTraits(.isButton)
            }
        }
        if model.joints.contains(where: { $0.motor != nil }) {
            folder("Motors (\(model.joints.filter { $0.motor != nil }.count))", "gearshape") {
                ForEach(model.joints.filter { $0.motor != nil }) { j in
                    row(2, "gearshape", j.motor?.part.split(separator: "/").last.map(String.init) ?? "Motor", detail: j.title)
                }
            }
        }
        folder("Poses (\(model.doc?.poses?.count ?? 0))", "bookmark") {
            ForEach(model.doc?.poses ?? []) { p in
                row(2, "bookmark", p.id.replacingOccurrences(of: "_", with: " ").capitalized)
                    .onTapGesture(count: 2) { model.pose(named: p.id) }
                    .help("Double-click to move to this pose")
            }
        }
        if let g = model.doc?.grasps, !g.isEmpty {
            folder("Grasps (\(g.count))", "hand.raised") {
                ForEach(g) { x in row(2, "hand.raised", x.id, detail: "\(x.fingertips.count) tips") }
            }
        }
    }

    private struct Item { var id: String; var title: String; var depth: Int }

    /// Components in tree order with their depth along the joints.
    private var tree: [Item] {
        var out: [Item] = []
        let comps = model.components
        let rootID = model.doc?.ground ?? comps.first { c in !model.joints.contains { $0.child == c.id } }?.id
        func walk(_ id: String, _ d: Int) {
            guard let c = comps.first(where: { $0.id == id }), !out.contains(where: { $0.id == id }) else { return }
            out.append(Item(id: id, title: c.title, depth: d))
            for j in model.joints where j.parent == id { walk(j.child, d + 1) }
        }
        if let rootID { walk(rootID, 0) }
        for c in comps where !out.contains(where: { $0.id == c.id }) { out.append(Item(id: c.id, title: c.title, depth: 0)) }
        return out
    }

    @ViewBuilder private func folder<C: View>(_ name: String, _ symbol: String, @ViewBuilder _ content: () -> C) -> some View {
        let open = !closed.contains(name)
        HStack(spacing: VFSpace.s) {
            Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.inkTertiary).frame(width: 10)
            Image(systemName: symbol).foregroundStyle(theme.inkSecondary).frame(width: 16)
            Text(name).lineLimit(1)
            Spacer()
        }
        .font(VFFont.row).foregroundStyle(theme.ink)
        .padding(.leading, VFSpace.m).frame(height: 24)
        .contentShape(Rectangle())
        .onTapGesture { if open { closed.insert(name) } else { closed.remove(name) } }
        .accessibilityAddTraits(.isButton)
        if open { content() }
    }

    private func row(_ indent: Int, _ symbol: String, _ text: String, bold: Bool = false, selected: Bool = false, detail: String? = nil) -> some View {
        HStack(spacing: VFSpace.s) {
            Image(systemName: symbol).foregroundStyle(theme.inkSecondary).frame(width: 16)
            Text(text).font(bold ? VFFont.rowEmphasis : VFFont.row).lineLimit(1)
            Spacer(minLength: VFSpace.xs)
            if let detail { Text(detail).font(VFFont.small).foregroundStyle(theme.inkTertiary).lineLimit(1) }
        }
        .foregroundStyle(theme.ink)
        .padding(.leading, VFSpace.m + CGFloat(indent) * 10)
        .padding(.trailing, VFSpace.m)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: VFRadius.chip).fill(selected ? theme.selection : .clear))
        .contentShape(Rectangle())
    }
}
