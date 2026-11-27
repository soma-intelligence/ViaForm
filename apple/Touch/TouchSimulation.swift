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
        TouchInspectorCard(title: node?.name ?? String(localized: "Flight"), symbol: "wind",
                           subtitle: node?.revisionName ?? String(localized: "Not flown yet")) {
            VFCaption("Scenario").padding(.top, VFSpace.m)
            ForEach(node?.consumes ?? [], id: \.id) { i in
                let input = flow.node(i.id)
                Button { if let w = input.flatMap({ Workspace(stage: $0.stage) }) { open(w) } } label: {
                    HStack(spacing: 8) {
                        VFStatusDot(status: (i.current ? (input?.status ?? .empty) : .stale).vfStatus, size: 7)
                            .accessibilityHidden(true)
                        Text(input?.label.isEmpty == false ? input!.label : (input?.name ?? i.id)).foregroundStyle(theme.inkSecondary)
                        Spacer()
                        Text(i.now > 0 ? (i.now_name ?? "") : String(localized: "Not built")).foregroundStyle(theme.ink)
                        // A moved input says so in words, not only in colour.
                        if !i.current { Text("Stale").font(VFFont.micro).foregroundStyle(theme.warning) }
                        Image(systemName: "chevron.right").font(VFFont.small).foregroundStyle(theme.inkTertiary).accessibilityHidden(true)
                    }
                    .font(VFFont.row)
                    .frame(minHeight: VFSize.touchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.vfTouch)
                .accessibilityElement(children: .combine)
            }
            if let policy = flow.node("train.policy") {
                TouchKVRow(label: policy.label.isEmpty ? String(localized: "Policy") : policy.label, value: policy.revisionName ?? String(localized: "Not trained"))
            }
            TouchKVRow(label: String(localized: "Mission"), value: sim.catalog?.missions.first { $0.id == sim.options.mission }?.name ?? sim.options.mission)
            if let a = node?.action, node?.status == .stale || node?.status == .failed {
                if let r = node?.reason, !r.isEmpty {
                    Text(r).font(VFFont.small).foregroundStyle(theme.inkSecondary).padding(.top, VFSpace.s)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(action: rerun) {
                    Text(a.label).frame(maxWidth: .infinity, minHeight: VFSize.touchTarget)
                }
                .buttonStyle(.vfPrimary)
                .padding(.vertical, VFSpace.m)
            }
        }
    }
}

/// Attitude, speed and battery against time, one chart a quantity, one playhead for all.
struct TouchTelemetryPanel: View {
    @ObservedUnits private var units
    @Environment(\.viaFormTheme) private var theme
    let sim: SimModel
    @Binding var expanded: Bool
    @State private var samples: [TelemetrySample] = []
    @State private var playhead: Double?

    var body: some View {
        let _ = units
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: VFSpace.m) {
                    VFCaption("Telemetry")
                    if let s = shown {
                        Text(Self.readout(s)).font(VFFont.small).foregroundStyle(theme.inkSecondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.down" : "chevron.up").font(VFFont.small.weight(.semibold))
                        .foregroundStyle(theme.inkSecondary).accessibilityHidden(true)
                }
                .frame(minHeight: VFSize.touchTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.vfTouch)
            .accessibilityLabel(expanded ? String(localized: "Hide telemetry") : String(localized: "Show telemetry"))
            .accessibilityValue(shown.map(Self.readout) ?? "")
            if expanded {
                if samples.count < 2 {
                    Text("Fly to see the attitude, speed and battery here.").font(VFFont.small).foregroundStyle(theme.inkSecondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    // Each series has its own dash as well as its colour, and a legend.
                    HStack(spacing: VFSpace.l) {
                        chart(String(localized: "Roll, pitch, yaw (\(VFFormat.symbol(.angle)))"), scale: 1 / UnitSettings.current.inputFactor(for: .angle), series: [
                            (String(localized: "Roll"), \.roll, theme.accent, []),
                            (String(localized: "Pitch"), \.pitch, theme.warning, [5, 3]),
                            (String(localized: "Yaw"), \.yaw, theme.inkSecondary, [1.5, 2.5]),
                        ])
                        chart(String(localized: "Speed (m/s)"), series: [(String(localized: "Speed"), \.speed, theme.accent, [])])
                        chart(String(localized: "Battery (%)"), series: [(String(localized: "Battery"), \.battery, theme.success, [])])
                    }
                    .frame(height: 130)
                }
            }
        }
        .padding(.horizontal, VFSpace.l)
        .padding(.vertical, VFSpace.m)
        .vfSurface(.floating, radius: VFRadius.touchFloating)
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

    static func readout(_ s: TelemetrySample) -> String {
        let n = { (v: Double, d: Int) in VFFormat.number(v, digits: d) }
        return String(localized: "t \(n(s.t, 1)) s · roll \(AsmFormat.deg(s.roll)) · pitch \(AsmFormat.deg(s.pitch)) · \(n(s.speed, 1)) m/s · battery \(n(s.battery, 0)) %")
    }

    /// `scale` turns the samples into the shown unit (degrees into radians when the reader picked them).
    private func chart(_ title: String, scale: Double = 1, series: [(String, KeyPath<TelemetrySample, Double>, Color, [CGFloat])]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(VFFont.micro).foregroundStyle(theme.inkSecondary)
            Chart {
                ForEach(series, id: \.0) { name, key, _, dash in
                    ForEach(samples) { s in
                        LineMark(x: .value("Time", s.t), y: .value(name, s[keyPath: key] * scale), series: .value("Series", name))
                            .foregroundStyle(by: .value("Series", name))
                            .lineStyle(StrokeStyle(lineWidth: 1.4, dash: dash))
                    }
                }
                if let s = shown {
                    RuleMark(x: .value("Playhead", s.t)).foregroundStyle(theme.ink.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartForegroundStyleScale(domain: series.map(\.0), range: series.map(\.2))
            .chartLegend(position: .bottom, spacing: VFSpace.xs)
            .chartLegend(series.count > 1 ? .visible : .hidden)
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
        .accessibilityValue(shown.map { s in series.map { "\($0.0) \(VFFormat.number(s[keyPath: $0.1] * scale, digits: scale == 1 ? 1 : 3))" }.joined(separator: ", ") } ?? "")
    }
}
#endif
