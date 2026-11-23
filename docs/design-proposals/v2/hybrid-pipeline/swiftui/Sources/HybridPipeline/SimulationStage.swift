import SwiftUI
import Charts

struct Sample: Identifiable {
    let id: Int
    let t: Double
    let v: Double
    var series = "a"
}

enum Telemetry {
    /// Smooth, flight-like wobble: a few low frequencies over the 20 s window.
    static func noise(_ i: Int, _ k: Double) -> Double {
        let t = Double(i) / Double(n) * 20
        return sin(t * 0.55 * k + 0.4) * 0.55 + sin(t * 1.35 * k + 1.3) * 0.32 + sin(t * 3.1 * k + 2.1) * 0.12 + sin(t * 7.3 * k) * 0.04
    }
    static let n = 400
    static let altitude: [Sample] = (0..<n).map { i in
        let t = Double(i) / Double(n) * 20
        return Sample(id: i, t: t, v: 2.6 + noise(i, 1) * 1.3 + min(t, 1) * 0.2)
    }
    static let speed: [Sample] = (0..<n).map { i in
        let t = Double(i) / Double(n) * 20
        return Sample(id: i, t: t, v: 12.5 + noise(i, 1.4) * 7)
    }
    static let rpm: [Sample] = (0..<4).flatMap { m in
        (0..<n).map { i in
            let t = Double(i) / Double(n) * 20
            return Sample(id: m * 10_000 + i, t: t, v: 7400 + Double(m) * 650 + noise(i + m * 37, 1.6 + Double(m) * 0.15) * 1900, series: "M\(m + 1)")
        }
    }
}

enum SimulationStage {
    static let states: PipelineStates = [
        .design: .upToDate, .generative: .upToDate, .mechanics: .upToDate, .electronics: .upToDate,
        .simulation: .running, .training: .stale, .render: .upToDate, .manufacture: .upToDate,
    ]

    static var screen: StageScreen {
        StageScreen(
            project: "Drone 3in Mk2",
            workspace: .simulation,
            states: states,
            groups: [
                .init(title: "Scenario", tools: [.init(glyph: .symbol("doc"), caption: "New"), .init(glyph: .symbol("folder"), caption: "Open"), .init(glyph: .symbol("square.and.arrow.down"), caption: "Save")]),
                .init(title: "Weather", tools: [.init(glyph: .symbol("wind"), caption: "Wind", isOn: true), .init(glyph: .symbol("cloud.rain"), caption: "Rain"), .init(glyph: .symbol("cloud.fill"), caption: "Clouds")]),
                .init(title: "Control", tools: [.init(glyph: .symbol("scope"), caption: "Auto", isOn: true), .init(glyph: .symbol("gamecontroller"), caption: "Manual"), .init(glyph: .symbol("slider.horizontal.3"), caption: "Tune"), .init(glyph: .symbol("airplane"), caption: "Free")]),
                .init(title: "View", tools: [.init(glyph: .symbol("rotate.3d"), caption: "Orbit"), .init(glyph: .symbol("video"), caption: "Follow", isOn: true)]),
                .init(title: "Record", tools: [.init(glyph: .symbol("record.circle", VF.red), caption: "Record"), .init(glyph: .symbol("gobackward"), caption: "Replay")]),
            ],
            primary: [.init(title: "Fly", symbol: "play.fill", kind: .blue, stacked: true),
                      .init(title: "Stop", symbol: "stop.fill", kind: .neutral, stacked: true)],
            rows: [
                .init(indent: 0, disclosure: .open, symbol: "map", title: "Scenarios", eye: .none, section: true),
                .init(indent: 1, symbol: "flag.checkered", title: "Obstacle Course", selected: true),
                .init(indent: 1, symbol: "scope", title: "Hover Test"),
                .init(indent: 1, symbol: "flag", title: "Punch-out", eye: .off),
                .init(indent: 0, disclosure: .open, symbol: "cloud.sun", title: "Weather", eye: .none, section: true),
                .init(indent: 1, symbol: "cloud", title: "Calm Morning", eye: .off),
                .init(indent: 1, symbol: "wind", symbolTint: VF.accent, title: "Gusty Afternoon"),
                .init(indent: 1, symbol: "cloud.rain", title: "Rain", eye: .off),
                .init(indent: 0, disclosure: .open, symbol: "list.bullet", title: "Runs", eye: .none, section: true),
                .init(indent: 1, status: .running, title: "Run 24", detail: "live"),
                .init(indent: 1, status: .upToDate, title: "Run 23", detail: "21.4 s"),
                .init(indent: 1, status: .failed, title: "Run 22 crash", detail: "gate 9"),
            ],
            outputs: [
                .init(symbol: "waveform.path.ecg", title: "Sim data", status: .upToDate, value: "Ready"),
                .init(symbol: "doc.text", title: "Logs", status: .upToDate, value: "Ready"),
                .init(symbol: "film", title: "Video", status: .stale),
                .init(symbol: "graduationcap", title: "Training set", status: .running),
                .init(symbol: "doc.richtext", title: "Report", status: .failed),
            ],
            inspector: AnyView(inspector),
            viewport: AnyView(SimViewport()),
            bottom: AnyView(TelemetryPanel()),
            bottomHeight: 290,
            status: StatusBar(leading: statusLeading("Run 24 live", .upToDate),
                              trailing: ["18.8 s / 32.0 s"],
                              trailingDot: ("Simulation running", .upToDate))
        )
    }

    static var inspector: some View {
        InspectorPanel {
            InspectorSection(title: "Selection", showsDivider: false) {
                SelectionCard(symbol: "flag.checkered", title: "Run 24", subtitle: "Obstacle course, live")
            }
            flowAndLinked(consumes: "Frame #12 + FC rev C", produces: "Flights for Training", states: states, current: .simulation)
            InspectorSection(title: "Run setup") {
                KVRow(label: "Course", value: "Obstacle course")
                KVRow(label: "Weather", value: "Gusty afternoon")
                KVRow(label: "Controller", value: "PID v4")
                KVRow(label: "Seed", value: "1", divider: false)
            }
            InspectorSection(title: "Airframe") {
                KVRow(label: "Mass", value: "152.4", unit: "g")
                KVRow(label: "Thrust to weight", value: "4.5", divider: false)
            }
            InspectorSection(title: "Result") {
                KVRow(label: "Course time", value: "18.8", unit: "s")
                KVRow(label: "Gates", value: "6 of 14")
                KVRow(label: "Max tilt", value: "38", unit: "deg", divider: false)
            }
        }
    }
}

struct SimViewport: View {
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Art.image("course").resizable().aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                LinearGradient(colors: [.black.opacity(0.25), .clear, .clear, .black.opacity(0.25)], startPoint: .top, endPoint: .bottom)
                OverlayCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Gusty afternoon", systemImage: "cloud.sun").font(.system(size: 14, weight: .semibold))
                        Label("Obstacle course", systemImage: "flag.checkered").font(.system(size: 12.5))
                        Label { Text("Gate 6 of 14").monospacedDigit() } icon: { Image(systemName: "flag") }.font(.system(size: 12.5))
                    }
                    .labelStyle(.titleAndIcon)
                }
                .padding(14)
                HUDCard().frame(maxWidth: .infinity, alignment: .trailing).padding(14)
                OverlayCard {
                    HStack(spacing: 12) {
                        Image(systemName: "location.north.fill").font(.system(size: 18)).rotationEffect(.degrees(45)).foregroundStyle(VF.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("7.2 m/s NE").font(.system(size: 14, weight: .semibold)).monospacedDigit()
                            Text("gusts 11 m/s").font(.system(size: 11.5)).monospacedDigit().foregroundStyle(VF.secondary)
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottomLeading).padding(14)
            }
        }
    }
}

struct HUDCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("18.8 s").font(.vfHUD).monospacedDigit()
                Spacer()
                Text("FLYING").font(.system(size: 11, weight: .bold)).foregroundStyle(.black)
                    .padding(.horizontal, 8).frame(height: 20)
                    .background(Capsule().fill(VF.green))
            }
            hud("Speed", "14.2", "m/s")
            hud("Altitude", "2.4", "m")
            hud("Battery", "14.8", "V")
            hud("Throttle", "62", "%")
        }
        .frame(width: 196)
        .padding(12)
        .floatingSurface(radius: 12)
    }
    private func hud(_ l: String, _ v: String, _ u: String) -> some View {
        HStack {
            Text(l).foregroundStyle(VF.text.opacity(0.8))
            Spacer()
            Text(v).monospacedDigit()
            Text(u).foregroundStyle(VF.secondary).frame(width: 28, alignment: .leading)
        }
        .font(.system(size: 13))
    }
}

struct TelemetryPanel: View {
    let playhead = 18.8
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                CapsLabel(text: "Telemetry", color: VF.text.opacity(0.78))
                Spacer()
                ForEach(["backward.end.fill", "play.fill", "forward.end.fill"], id: \.self) { s in
                    Image(systemName: s).font(.system(size: 11)).frame(width: 28, height: 22)
                        .background(RoundedRectangle(cornerRadius: 5).fill(VF.panel))
                }
                HStack(spacing: 4) { Text("1x").monospacedDigit(); Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }
                    .font(.system(size: 11.5)).padding(.horizontal, 8).frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 5).fill(VF.panel))
                Image(systemName: "ellipsis").font(.system(size: 12)).frame(width: 24)
            }
            chart("Altitude", "m", Telemetry.altitude, domain: 0...6, ticks: [0, 3, 6], color: VF.accent, area: true)
            chart("Speed", "m/s", Telemetry.speed, domain: 0...25, ticks: [0, 12, 25], color: VF.green)
            rpmChart
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func label(_ name: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(name).font(.system(size: 11.5))
            Text(unit).font(.system(size: 10.5)).foregroundStyle(VF.secondary)
        }
        .frame(width: 70, alignment: .leading)
    }

    private func chart(_ name: String, _ unit: String, _ data: [Sample], domain: ClosedRange<Double>, ticks: [Double], color: Color, area: Bool = false) -> some View {
        HStack(spacing: 6) {
            label(name, unit)
            Chart {
                ForEach(data) { s in
                    if area {
                        AreaMark(x: .value("t", s.t), y: .value(name, s.v))
                            .foregroundStyle(LinearGradient(colors: [color.opacity(0.28), color.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                    }
                    LineMark(x: .value("t", s.t), y: .value(name, s.v)).foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.4))
                }
                RuleMark(x: .value("now", playhead)).foregroundStyle(.white.opacity(0.85)).lineStyle(StrokeStyle(lineWidth: 1))
            }
            .chartXScale(domain: 0...20)
            .chartYScale(domain: domain)
            .chartXAxis(.hidden)
            .chartPlotStyle { $0.background(Color.white.opacity(0.025)).border(VF.hairline.opacity(0.5), width: 0.5) }
            .chartYAxis { AxisMarks(position: .leading, values: ticks) { v in AxisGridLine().foregroundStyle(VF.hairline.opacity(0.6)); AxisValueLabel { Text(verbatim: "\(Int(v.as(Double.self) ?? 0))").foregroundStyle(VF.secondary).frame(width: 40, alignment: .trailing) } } }
            .font(.system(size: 10)).monospacedDigit()
        }
        .frame(height: 50)
    }

    private var rpmChart: some View {
        HStack(spacing: 6) {
            label("Motor RPM", "x4")
            Chart {
                ForEach(Telemetry.rpm) { s in
                    LineMark(x: .value("t", s.t), y: .value("rpm", s.v), series: .value("m", s.series))
                        .foregroundStyle(by: .value("Motor", s.series))
                        .lineStyle(StrokeStyle(lineWidth: 1.1))
                }
                RuleMark(x: .value("now", playhead)).foregroundStyle(.white.opacity(0.85)).lineStyle(StrokeStyle(lineWidth: 1))
            }
            .chartForegroundStyleScale(["M1": VF.red, "M2": VF.orange, "M3": VF.in2, "M4": VF.bCu])
            .chartLegend(.hidden)
            .chartXAxisLabel(position: .bottom, alignment: .center) { Text("Time (s)").font(.system(size: 10)).foregroundStyle(VF.secondary) }
            .chartPlotStyle { $0.background(Color.white.opacity(0.025)).border(VF.hairline.opacity(0.5), width: 0.5) }
            .chartXScale(domain: 0...20)
            .chartYScale(domain: 0...12000)
            .chartXAxis { AxisMarks(values: [0, 2.5, 5, 7.5, 10, 12.5, 15, 17.5, 20]) { v in AxisGridLine().foregroundStyle(VF.hairline.opacity(0.4)); AxisValueLabel { Text(String(format: "%.1f", v.as(Double.self) ?? 0)).foregroundStyle(VF.secondary) } } }
            .chartYAxis { AxisMarks(position: .leading, values: [0, 6000, 12000]) { v in AxisGridLine().foregroundStyle(VF.hairline.opacity(0.6)); AxisValueLabel { Text(verbatim: "\(Int(v.as(Double.self) ?? 0))").foregroundStyle(VF.secondary).frame(width: 40, alignment: .trailing) } } }
            .font(.system(size: 10)).monospacedDigit()
        }
        .frame(height: 84)
    }
}
