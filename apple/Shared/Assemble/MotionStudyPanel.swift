import Charts
import SwiftUI

/// The Assemble stage's bottom panel: the motion study. Joint angle curves over time with a
/// playhead to scrub, play and stop, and the steps where parts collide marked in red with the
/// first contact of each pair.
struct MotionStudyPanel: View {
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: AssembleModel
    var height: CGFloat = 210

    static let palette: [Color] = [
        Color(red: 0.18, green: 0.42, blue: 1.0), Color(red: 0.95, green: 0.58, blue: 0.12), Color(red: 0.18, green: 0.64, blue: 0.31),
        Color(red: 0.62, green: 0.32, blue: 0.85), Color(red: 0.88, green: 0.22, blue: 0.20), Color(red: 0.16, green: 0.68, blue: 0.80),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpace.s) {
            header
            if let s = model.study, !s.steps.isEmpty {
                HStack(alignment: .top, spacing: VFSpace.l) {
                    legend(s)
                    chart(s)
                }
            } else {
                Text(!model.isActive ? "No assembly yet." : model.studies.isEmpty ? "This assembly has no motion studies. The fingers move with the grasp editor." : "Pick a motion study to sample the joints over time.")
                    .font(VFFont.small).foregroundStyle(theme.inkSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, VFSpace.l)
        .padding(.vertical, VFSpace.s)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .background(theme.panel)
    }

    private var header: some View {
        HStack(spacing: VFSpace.m) {
            VFCaption("Motion study")
            Button { model.togglePlay() } label: {
                Image(systemName: model.playing ? "pause.fill" : "play.fill").frame(width: 22, height: 18)
            }
            .buttonStyle(.vfPrimary)
            .disabled(model.study == nil)
            .help(model.playing ? "Pause" : "Play the study")
            .accessibilityLabel(model.playing ? "Pause" : "Play")
            Button { model.stop(); model.scrub(to: 0); model.endScrub() } label: { Image(systemName: "stop.fill") }
                .disabled(model.study == nil)
                .help("Stop and go back to the live pose")
                .accessibilityLabel("Stop")
            Text(String(format: "%.2f s / %.2f s", model.playhead, model.study?.duration ?? 0))
                .font(VFFont.row).foregroundStyle(theme.inkSecondary)
            Spacer()
            if let s = model.study {
                let hits = s.steps.filter { !$0.collisions.isEmpty }.count
                Label(s.firstContacts.isEmpty ? "No interference" : "\(s.firstContacts.count) pair\(s.firstContacts.count == 1 ? "" : "s") collide, \(hits) steps",
                      systemImage: s.firstContacts.isEmpty ? "checkmark.circle" : "exclamationmark.octagon")
                    .font(VFFont.small)
                    .foregroundStyle(s.firstContacts.isEmpty ? theme.success : theme.danger)
                    .help(s.firstContacts.map { "\($0.a) and \($0.b) first touch at \(String(format: "%.2f s", $0.time))" }.joined(separator: "\n"))
            }
            Picker("Study", selection: $model.studyID) {
                ForEach(model.studies, id: \.id) { s in Text(s.title).tag(s.id) }
            }
            .labelsHidden()
            .frame(width: 170)
        }
        .frame(height: 24)
    }

    private func legend(_ s: AsmMotionStudy) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(model.joints.prefix(8).enumerated()), id: \.element.id) { i, j in
                HStack(spacing: VFSpace.s) {
                    Circle().fill(Self.palette[i % Self.palette.count]).frame(width: 7, height: 7)
                    Text("J\(i + 1) (\(j.title))").font(VFFont.small).foregroundStyle(theme.ink).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(AsmFormat.deg(model.q[j.id] ?? 0)).font(VFFont.small).foregroundStyle(theme.inkSecondary)
                }
            }
        }
        .frame(width: 180)
    }

    private struct Point: Identifiable {
        let id: Int
        let joint: String
        let t: Double
        let v: Double
    }

    private func chart(_ s: AsmMotionStudy) -> some View {
        let shown = Array(model.joints.prefix(8))
        var points: [Point] = []
        for (si, step) in s.steps.enumerated() {
            for (ji, j) in shown.enumerated() { points.append(Point(id: si * 100 + ji, joint: "J\(ji + 1)", t: step.time, v: step.q[j.id] ?? 0)) }
        }
        let hits = s.steps.filter { !$0.collisions.isEmpty }.map(\.time)
        let domain = shown.enumerated().map { "J\($0.offset + 1)" }
        return Chart {
            ForEach(points) { p in
                LineMark(x: .value("Time", p.t), y: .value("Angle", p.v))
                    .foregroundStyle(by: .value("Joint", p.joint))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
            }
            ForEach(Array(hits.enumerated()), id: \.offset) { _, t in
                RectangleMark(xStart: .value("Time", max(0, t - s.duration / Double(max(s.steps.count * 2, 1)))),
                              xEnd: .value("Time", min(s.duration, t + s.duration / Double(max(s.steps.count * 2, 1)))))
                    .foregroundStyle(theme.danger.opacity(0.18))
            }
            RuleMark(x: .value("Playhead", model.playhead))
                .foregroundStyle(theme.accent)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, j in
                PointMark(x: .value("Time", model.playhead), y: .value("Angle", value(j.id, at: model.playhead, in: s)))
                    .foregroundStyle(Self.palette[i % Self.palette.count])
                    .symbolSize(28)
            }
        }
        .chartForegroundStyleScale(domain: domain, range: Array(Self.palette.prefix(domain.count)))
        .chartLegend(.hidden)
        .chartXScale(domain: 0...max(s.duration, 0.01))
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { v in
            AxisGridLine().foregroundStyle(theme.hairline)
            AxisValueLabel { if let d = v.as(Double.self) { Text(String(format: "%.1f s", d)) } }
        } }
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
            AxisGridLine().foregroundStyle(theme.hairline)
            AxisValueLabel { if let d = v.as(Double.self) { Text(String(format: "%.0f°", d)) } }
        } }
        .chartOverlay { proxy in
            GeometryReader { g in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { e in
                        guard let plot = proxy.plotFrame else { return }
                        let x = e.location.x - g[plot].origin.x
                        if let t: Double = proxy.value(atX: x) { model.stop(); model.scrub(to: t) }
                    })
            }
        }
        .accessibilityLabel("Joint angles over time, playhead at \(String(format: "%.2f", model.playhead)) seconds")
    }

    private func value(_ joint: String, at t: Double, in s: AsmMotionStudy) -> Double {
        let i = s.steps.lastIndex { $0.time <= t + 1e-9 } ?? 0
        return s.steps[i].q[joint] ?? 0
    }
}
