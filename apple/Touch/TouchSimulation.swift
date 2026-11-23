#if os(iOS)
import Charts
import SwiftUI
import simd

// The stage shell over the flight view on the iPad: the scenario card (what the flight is built
// from, at which revisions, with "Re-run on Frame vN" when an input moved) and the telemetry
// panel (attitude, speed and battery on one shared playhead). Both only read the flight model
// and the pipeline; the flight view itself is the simulation module's.

/// One telemetry sample, read from the flight's frame.
struct TelemetrySample: Identifiable, Equatable {
    let t: Double
    let roll: Double
    let pitch: Double
    let yaw: Double
    let speed: Double
    let battery: Double
    var id: Double { t }

    init?(_ f: SimFrame?) {
        guard let f, f.q.count == 4, f.v.count == 3 else { return nil }
        let w = f.q[0], x = f.q[1], y = f.q[2], z = f.q[3]
        t = f.t
        roll = atan2(2 * (w * x + y * z), 1 - 2 * (x * x + y * y)) * 180 / .pi
        pitch = asin(max(-1, min(1, 2 * (w * y - z * x)))) * 180 / .pi
        yaw = atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z)) * 180 / .pi
        speed = simd_length(SIMD3(f.v[0], f.v[1], f.v[2]))
        battery = f.soc * 100
    }
}

/// The flight's inputs at their revisions, and the re-run when one moved.
struct TouchScenarioCard: View {
    @Environment(\.viaFormTheme) private var theme
    let flow: FlowModel
    let sim: SimModel
    let open: (Workspace) -> Void
    let rerun: () -> Void

    var body: some View {
        let _ = flow.version
        let node = flow.node("simulate.flight")
        TouchInspectorCard(title: node?.name ?? "Flight", symbol: "wind", subtitle: node?.revisionName ?? "Not flown yet") {
            VFCaption("Scenario").padding(.top, 8)
            ForEach(node?.consumes ?? [], id: \.id) { i in
                let input = flow.node(i.id)
                Button { if let w = input.flatMap({ Workspace(stage: $0.stage) }) { open(w) } } label: {
                    HStack(spacing: 8) {
                        VFStatusDot(status: (i.current ? (input?.status ?? .empty) : .stale).vfStatus, size: 7)
                        Text(input?.label.isEmpty == false ? input!.label : (input?.name ?? i.id)).foregroundStyle(theme.inkSecondary)
                        Spacer()
                        Text(i.now > 0 ? (i.now_name ?? "") : "Not built").foregroundStyle(i.current ? theme.ink : theme.warning)
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(theme.inkTertiary)
                    }
                    .font(.system(size: 15))
                    .frame(minHeight: VFSize.touchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if let policy = flow.node("train.policy") {
                TouchKVRow(label: policy.label.isEmpty ? "Policy" : policy.label, value: policy.revisionName ?? "Not trained")
            }
            TouchKVRow(label: "Mission", value: sim.catalog?.missions.first { $0.id == sim.options.mission }?.name ?? sim.options.mission)
            if let a = node?.action, node?.status == .stale || node?.status == .failed {
                if let r = node?.reason, !r.isEmpty {
                    Text(r).font(.footnote).foregroundStyle(theme.inkSecondary).padding(.top, 6)
                }
                Button(action: rerun) {
                    Text(a.label).font(.system(size: 16, weight: .semibold)).frame(maxWidth: .infinity, minHeight: VFSize.touchTarget - 8)
                }
                .buttonStyle(.vfPrimary)
                .padding(.vertical, 8)
            }
        }
    }
}

/// Attitude, speed and battery against time, one chart a quantity, one playhead for all.
struct TouchTelemetryPanel: View {
    @Environment(\.viaFormTheme) private var theme
    let sim: SimModel
    @Binding var expanded: Bool
    @State private var samples: [TelemetrySample] = []
    @State private var playhead: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    VFCaption("Telemetry")
                    if let s = shown {
                        Text(String(format: "t %.1f s · roll %.0f° · pitch %.0f° · %.1f m/s · battery %.0f%%", s.t, s.roll, s.pitch, s.speed, s.battery))
                            .font(.system(size: 12)).monospacedDigit().foregroundStyle(theme.inkSecondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.down" : "chevron.up").font(.footnote.weight(.semibold)).foregroundStyle(theme.inkSecondary)
                }
                .frame(minHeight: VFSize.touchTarget - 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Hide telemetry" : "Show telemetry")
            if expanded {
                if samples.count < 2 {
                    Text("Fly to see the attitude, speed and battery here.").font(.footnote).foregroundStyle(theme.inkSecondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    HStack(spacing: 12) {
                        chart("Roll, pitch, yaw (deg)", series: [("Roll", \.roll, theme.accent), ("Pitch", \.pitch, Color.orange), ("Yaw", \.yaw, Color.purple)])
                        chart("Speed (m/s)", series: [("Speed", \.speed, Color.teal)])
                        chart("Battery (%)", series: [("Battery", \.battery, theme.success)])
                    }
                    .frame(height: 110)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .vfSurface(.floating, radius: 18)
        .onChange(of: sim.tick) { _, _ in record() }
        .onChange(of: sim.worldVersion) { _, _ in samples = []; playhead = nil }
    }

    private var shown: TelemetrySample? {
        guard let p = playhead else { return samples.last }
        return samples.min { abs($0.t - p) < abs($1.t - p) }
    }

    private func record() {
        guard let s = TelemetrySample(sim.frame) else { return }
        if let last = samples.last, s.t < last.t { samples = [] }
        if samples.last?.t != s.t { samples.append(s) }
        if samples.count > 900 { samples.removeFirst(samples.count - 900) }
    }

    private func chart(_ title: String, series: [(String, KeyPath<TelemetrySample, Double>, Color)]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(theme.inkSecondary)
            Chart {
                ForEach(series, id: \.0) { name, key, color in
                    ForEach(samples) { s in
                        LineMark(x: .value("Time", s.t), y: .value(name, s[keyPath: key]), series: .value("Series", name))
                            .foregroundStyle(color)
                            .lineStyle(StrokeStyle(lineWidth: 1.4))
                    }
                }
                if let s = shown {
                    RuleMark(x: .value("Playhead", s.t)).foregroundStyle(theme.ink.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartLegend(.hidden)
            .chartXAxis(.hidden)
            .chartOverlay { proxy in
                GeometryReader { g in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                guard let plot = proxy.plotFrame else { return }
                                playhead = proxy.value(atX: v.location.x - g[plot].origin.x, as: Double.self)
                            }
                            .onEnded { _ in })
                        .onTapGesture(count: 2) { playhead = nil }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}
#endif
