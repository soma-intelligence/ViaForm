import Charts
import SwiftUI

/// The Assemble stage's bottom panel: the motion study. Joint angle curves over time with a
/// playhead to scrub, play and stop, and the steps where parts collide marked in red with the
/// first contact of each pair (a band and the words in the header, never the colour alone).
struct MotionStudyPanel: View {
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: AssembleModel
    var height: CGFloat = 210

    /// Series colours of the joint curves, from the theme's stage hues (distinct in light and dark).
    static func palette(_ theme: ViaFormTheme) -> [Color] {
        [VFStage.generate, .electronics, .assemble, .simulate, .train, .render, .make, .robot].map(theme.stageFill)
    }

    private var palette: [Color] { Self.palette(theme) }

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpace.s) {
            header
            if let p = model.studyProgress {
                VStack(spacing: VFSpace.m) {
                    Text("Sampling \(model.studies.first { $0.id == model.studyID }?.title ?? String(localized: "the study"))")
                        .font(VFFont.row).foregroundStyle(theme.inkSecondary)
                    StudyProgressRow(progress: p) { model.stopWork() }
                        .frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let s = model.study, !s.steps.isEmpty {
                HStack(alignment: .top, spacing: VFSpace.l) {
                    legend(s)
                    chart(s)
                }
            } else {
                Group {
                    if !model.isActive {
                        EmptyState(String(localized: "No assembly yet"), systemImage: "cube.transparent")
                    } else if model.studies.isEmpty {
                        EmptyState(String(localized: "No motion studies"), systemImage: "waveform.path.ecg",
                                   message: String(localized: "The fingers move with the grasp editor."))
                    } else {
                        EmptyState(String(localized: "No study sampled"), systemImage: "waveform.path.ecg",
                                   message: String(localized: "Pick a motion study to sample the joints over time."),
                                   actionTitle: String(localized: "Sample Study")) { model.runStudy() }
                    }
                }
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
            VFIconButton(model.playing ? "pause.fill" : "play.fill",
                         label: model.playing ? String(localized: "Pause") : String(localized: "Play the study"), size: 12, isOn: model.playing) {
                model.togglePlay()
            }
            .vfDisabled(model.study == nil, reason: String(localized: "Sample a study first"))
            VFIconButton("backward.end.fill", label: String(localized: "Back to the live pose")) {
                model.stop(); model.scrub(to: 0); model.endScrub()
            }
            .vfDisabled(model.study == nil, reason: String(localized: "Sample a study first"))
            Text("\(VFFormat.value(model.playhead, .time)) / \(VFFormat.value(model.study?.duration ?? 0, .time))")
                .font(VFFont.row).foregroundStyle(theme.inkSecondary)
                .accessibilityLabel(Text("Playhead"))
            Spacer()
            if let s = model.study {
                let hits = s.steps.filter { !$0.collisions.isEmpty }.count
                Label(s.firstContacts.isEmpty ? String(localized: "No interference") : String(localized: "\(s.firstContacts.count) pairs collide, \(hits) steps"),
                      systemImage: s.firstContacts.isEmpty ? "checkmark.circle" : "exclamationmark.octagon.fill")
                    .font(VFFont.small)
                    .foregroundStyle(s.firstContacts.isEmpty ? theme.success : theme.danger)
                    .help(s.firstContacts.map { String(localized: "\(title($0.a)) and \(title($0.b)) first touch at \(VFFormat.value($0.time, .time))") }.joined(separator: "\n"))
            }
            Picker("Study", selection: $model.studyID) {
                ForEach(model.studies, id: \.id) { s in Text(s.title).tag(s.id) }
            }
            .labelsHidden()
            .frame(width: 170)
            .vfDisabled(model.studyProgress != nil, reason: String(localized: "Sampling the study"))
        }
        .frame(minHeight: VFSize.minTarget)
    }

    private func title(_ id: String) -> String { model.components.first { $0.id == id }?.title ?? id }

    private func legend(_ s: AsmMotionStudy) -> some View {
        VStack(alignment: .leading, spacing: VFSpace.xxs) {
            ForEach(Array(model.joints.prefix(8).enumerated()), id: \.element.id) { i, j in
                HStack(spacing: VFSpace.s) {
                    Circle().fill(palette[i % palette.count]).frame(width: 7, height: 7).accessibilityHidden(true)
                    Text("J\(i + 1) (\(j.title))").font(VFFont.small).foregroundStyle(theme.ink).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(AsmFormat.value(model.q[j.id] ?? 0, j)).font(VFFont.small).foregroundStyle(theme.inkSecondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(width: 180)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Legend"))
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
        let names = Dictionary(uniqueKeysWithValues: shown.enumerated().map { ("J\($0.offset + 1)", $0.element.title) })
        let hits = s.steps.filter { !$0.collisions.isEmpty }.map(\.time)
        let domain = shown.enumerated().map { "J\($0.offset + 1)" }
        return Chart {
            ForEach(points) { p in
                LineMark(x: .value("Time", p.t), y: .value("Angle", p.v))
                    .foregroundStyle(by: .value("Joint", p.joint))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                    .accessibilityLabel(Text("\(p.joint) \(names[p.joint] ?? "")"))
                    .accessibilityValue(Text("\(VFFormat.angle(p.v)) at \(VFFormat.value(p.t, .time))"))
            }
            ForEach(Array(hits.enumerated()), id: \.offset) { _, t in
                RectangleMark(xStart: .value("Time", max(0, t - s.duration / Double(max(s.steps.count * 2, 1)))),
                              xEnd: .value("Time", min(s.duration, t + s.duration / Double(max(s.steps.count * 2, 1)))))
                    .foregroundStyle(theme.danger.opacity(0.18))
                    .accessibilityLabel(Text("Collision"))
                    .accessibilityValue(Text("at \(VFFormat.value(t, .time))"))
            }
            RuleMark(x: .value("Playhead", model.playhead))
                .foregroundStyle(theme.accent)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, j in
                PointMark(x: .value("Time", model.playhead), y: .value("Angle", value(j.id, at: model.playhead, in: s)))
                    .foregroundStyle(palette[i % palette.count])
                    .accessibilityHidden(true)
                    .symbolSize(28)
            }
        }
        .chartForegroundStyleScale(domain: domain, range: Array(palette.prefix(domain.count)))
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
        .accessibilityLabel(Text("Joint angles over time"))
        .accessibilityValue(Text("Playhead at \(VFFormat.value(model.playhead, .time))"))
    }

    private func value(_ joint: String, at t: Double, in s: AsmMotionStudy) -> Double {
        let i = s.steps.lastIndex { $0.time <= t + 1e-9 } ?? 0
        return s.steps[i].q[joint] ?? 0
    }
}
