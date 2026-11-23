import SwiftUI

// MARK: - Single right inspector

struct InspectorPanel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                CapsLabel(text: "Inspector", color: VF.text.opacity(0.78))
                Spacer()
                Image(systemName: "sidebar.right").font(.system(size: 11)).foregroundStyle(VF.secondary)
            }
            .padding(.horizontal, 12).frame(height: 32)
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 12)
            Spacer(minLength: 0)
        }
        .panelWell()
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    var symbol: String? = nil
    var showsDivider = true
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsDivider { Hairline().padding(.bottom, 10) }
            HStack(spacing: 6) {
                if let s = symbol { Image(systemName: s).font(.system(size: 11)).foregroundStyle(VF.secondary) }
                CapsLabel(text: title)
            }
            .padding(.bottom, 4)
            content
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}

struct KVRow: View {
    let label: String
    let value: String
    var unit: String? = nil
    var valueColor: Color = VF.text
    var divider = true
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(label).font(.vfRow).foregroundStyle(VF.text.opacity(0.78))
                Spacer()
                Text(value).font(.vfRow).monospacedDigit().foregroundStyle(valueColor)
                if let unit {
                    Text(unit).font(.vfRow).foregroundStyle(VF.secondary).frame(minWidth: 22, alignment: .leading)
                }
            }
            .frame(height: 28)
            if divider { Hairline().opacity(0.6) }
        }
    }
}

struct SelectionCard: View {
    let symbol: String
    let title: String
    var subtitle: String? = nil
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(VF.text.opacity(0.85))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.vfRowSemibold)
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(VF.secondary) }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(VF.secondary)
        }
        .padding(.horizontal, 12).frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 8).fill(VF.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(VF.hairline))
    }
}

struct FlowRows: View {
    let consumes: String
    let produces: String
    var body: some View {
        VStack(spacing: 0) {
            link("Consumes", consumes, "arrow.down.left")
            link("Produces", produces, "arrow.up.right")
        }
    }
    private func link(_ label: String, _ value: String, _ symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(VF.secondary).frame(width: 14)
            Text(label).font(.vfRow).foregroundStyle(VF.text.opacity(0.78))
            Spacer()
            Text(value).font(.vfRow).foregroundStyle(VF.accent.opacity(0.95))
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(VF.secondary)
        }
        .frame(height: 28)
    }
}

/// Eight stage tags, wrapped; the dot is the stage state.
struct LinkedSelection: View {
    let states: PipelineStates
    var current: Workspace
    var body: some View {
        WrapLayout(spacing: 6, lineSpacing: 6) {
            ForEach(Workspace.allCases) { ws in
                HStack(spacing: 6) {
                    StatusDot(status: states[ws] ?? .idle, size: 7)
                    Text(ws.title).font(.system(size: 12))
                }
                .padding(.horizontal, 9).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(ws == current ? VF.accent.opacity(0.22) : VF.panel))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ws == current ? VF.accent.opacity(0.7) : VF.hairline))
            }
        }
        .padding(.vertical, 4)
    }
}

/// Flow layout for tags.
struct WrapLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += line + lineSpacing; line = 0 }
            x += s.width + spacing
            line = max(line, s.height)
        }
        return CGSize(width: width, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += line + lineSpacing; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}

struct CheckRow: View {
    let symbol: String
    let tint: Color
    let label: String
    var value: String? = nil
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(tint).frame(width: 18)
            Text(label).font(.vfRow)
            Spacer()
            if let value { Text(value).font(.vfRow).monospacedDigit().foregroundStyle(VF.secondary) }
        }
        .frame(height: 28)
    }
}
