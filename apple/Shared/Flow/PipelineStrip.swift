import SwiftUI

/// The pipeline as a touch strip: icon chips with a status dot, the open stage labelled, five
/// stages in view and the rest under More, every target 44 points. Used by the iPad window;
/// the Mac window has the denser `PipelineBar`.
struct PipelineStrip: View {
    let flow: FlowModel
    /// The open stage's id (`design`, `simulate`...).
    let current: String
    var visible = 5
    let open: (Workspace) -> Void

    private var shown: [Workspace] {
        // The open stage is always in view.
        var list = Array(Workspace.allCases.prefix(visible))
        if let w = Workspace(stage: current), !list.contains(w) { list[list.count - 1] = w }
        return list
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(shown) { w in chip(w) }
            let rest = Workspace.allCases.filter { !shown.contains($0) }
            if !rest.isEmpty {
                Menu {
                    ForEach(rest) { w in
                        Button { open(w) } label: { Label("\(w.title), \(PipelineWords.describe(flow.stage(w)?.status ?? .empty))", systemImage: w.symbol) }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("More stages")
            }
            if let j = flow.queue.jobs.first {
                HStack(spacing: 6) {
                    ProgressView(value: j.determinate ? j.progress : nil).progressViewStyle(.circular).controlSize(.small)
                    Text(j.caption).font(.footnote).lineLimit(1)
                }
                .padding(.horizontal, 10)
                .frame(height: 44)
            }
        }
        .padding(.horizontal, 4)
        .background(.regularMaterial, in: Capsule())
    }

    private func chip(_ w: Workspace) -> some View {
        let on = w.stage == current
        let status = flow.stage(w)?.status ?? .empty
        return Button { open(w) } label: {
            HStack(spacing: 6) {
                Image(systemName: w.symbol).font(.system(size: 15, weight: .medium))
                if on { Text(w.title).font(.subheadline.weight(.semibold)) }
                Circle().fill(Self.color(status)).frame(width: 7, height: 7)
            }
            .padding(.horizontal, on ? 12 : 10)
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(on ? w.accent : Color.primary)
            .background(on ? w.accent.opacity(0.15) : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(w.title), \(PipelineWords.describe(status))")
    }

    static func color(_ s: FlowModel.Status) -> Color {
        switch s {
        case .current: .green
        case .empty: .gray.opacity(0.5)
        case .stale: .orange
        case .running: .blue
        case .failed: .red
        }
    }
}
