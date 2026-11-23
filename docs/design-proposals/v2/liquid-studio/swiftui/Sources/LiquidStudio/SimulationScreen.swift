import Charts
import SwiftUI

enum Telemetry {
    struct S: Identifiable { var id: Int; var t: Double; var v: Double; var series: String }

    static let attitude: [S] = (0...220).flatMap { i -> [S] in
        let t = Double(i) * 0.2
        return [S(id: i * 3, t: t, v: 18 * sin(t * 0.55) + 5 * sin(t * 1.7 + 1), series: "roll"),
                S(id: i * 3 + 1, t: t, v: 10 * sin(t * 0.8 + 2) + 3 * cos(t * 1.9), series: "pitch"),
                S(id: i * 3 + 2, t: t, v: 6 * sin(t * 0.3 + 0.4) + 2 * sin(t * 1.2), series: "yaw")]
    }
    static let rpm: [S] = (0...220).map { i in
        let t = Double(i) * 0.2
        return S(id: i, t: t, v: 8200 + 1400 * sin(t * 0.5) + 500 * sin(t * 1.6 + 0.5) + (abs(t - 11) < 1.2 ? 2400 : 0), series: "rpm")
    }
    static let altitude: [S] = (0...220).map { i in
        let t = Double(i) * 0.2
        return S(id: i, t: t, v: min(3.6, t * 0.45) + 0.35 * sin(t * 0.7) + 0.15 * sin(t * 2.3), series: "alt")
    }
}

struct SimulationScreen: View {
    @Binding var workspace: Workspace
    @State private var time = 19.7
    static let plate = PlateLayout(name: "flight", zoom: 1, feather: false)

    var body: some View {
        MacWindow(project: "Racer 3in", workspace: $workspace, plate: Self.plate) { sidebar, inspector in
            VStack(spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    ToolRail(items: [("play.fill", nil), ("pause.fill", nil), ("forward.frame.fill", nil),
                                     ("camera", nil), ("wind", nil), ("scope", nil)], selected: 0)
                    if sidebar { ScenarioPanel() }
                    WindChip()
                    Spacer()
                    if inspector {
                        VStack(spacing: 8) {
                            FlightHUD()
                            Spacer(minLength: 0)
                            TelemetryPanel()
                        }
                    }
                }
                TransportBar(time: $time)
            }
        }
    }
}

/// Slim vertical tool rail (non-Design workspaces). The selected cell takes a neutral fill: accent is kept
/// for data and primary actions.
struct ToolRail: View {
    var items: [(String, String?)]
    var selected: Int?
    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                VStack(spacing: 2) {
                    Image(systemName: it.0).font(.system(size: 15, weight: .medium))
                    if let cap = it.1 { Text(cap).font(Tok.caption()) }
                }
                .foregroundStyle(Tok.primary)
                .frame(width: 40, height: it.1 == nil ? 40 : 52)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(i == selected ? 0.13 : 0)))
            }
        }
        .padding(6)
        .glass(16)
    }
}

struct ScenarioPanel: View {
    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(icon: "flag.checkered", title: "Scenario")
            Hairline()
            VStack(spacing: 0) {
                KVRow(key: "Course", value: "Obstacle A \u{00B7} 14 gates", mono: false, picker: true)
                KVRow(key: "Wind", value: "Breezy dusk", mono: false, picker: true)
                KVRow(key: "Airframe", value: "Frame v8 \u{00B7} 153 g", mono: false)
                KVRow(key: "Controller", value: "PID + Policy v5", mono: false, picker: true)
                KVRow(key: "Seed", value: "1")
                KVRow(key: "Step", value: "1 ms")
            }
            .padding(.vertical, 6)
        }
        .frame(width: 280)
        .glass()
    }
}

struct WindChip: View {
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1).frame(width: 30, height: 30)
                Image(systemName: "location.north.fill").font(.system(size: 11)).rotationEffect(.degrees(72))
            }
            .foregroundStyle(Tok.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Wind").font(Tok.caption()).foregroundStyle(Tok.secondary)
                HStack(spacing: 4) {
                    Text("6.2 m/s").font(Tok.mono(13, .medium))
                    Dot()
                    Text("gust 9.0").font(Tok.mono(12))
                }
                .foregroundStyle(Tok.primary)
            }
        }
        .padding(.horizontal, 12).frame(height: 50)
        .glass(14)
    }
}

struct FlightHUD: View {
    @Environment(\.accent) private var accent

    private func big(_ v: String, _ unit: String, _ cap: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(v).font(Tok.mono(22, .medium)).foregroundStyle(Tok.primary)
                Text(unit).font(Tok.mono(13)).foregroundStyle(Tok.secondary)
            }
            Text(cap).font(Tok.caption()).foregroundStyle(Tok.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack { big("19.7", "s", "Time"); big("14.2", "m/s", "Speed"); big("3.1", "m", "Altitude") }
            Hairline(inset: 0)
            HStack { big("9 / 14", "", "Gates"); big("15.2", "V", "Battery"); big("4.8", "Wh", "Used") }
            Hairline(inset: 0)
            HStack(spacing: 12) {
                ForEach(Array([0.72, 0.81, 0.66, 0.77].enumerated()), id: \.offset) { i, v in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("M\(i + 1)").font(Tok.caption(.medium)).foregroundStyle(Tok.secondary)
                            Spacer()
                            Text("\(Int(v * 100))").font(Tok.mono(10)).foregroundStyle(Tok.secondary)
                        }
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.10))
                                Capsule().fill(accent).frame(width: g.size.width * v)
                            }
                        }
                        .frame(height: 5)
                    }
                }
            }
        }
        .padding(16).frame(width: 360)
        .glass()
    }
}

struct TelemetryPanel: View {
    @Environment(\.accent) private var accent

    private func axes<C: View>(_ chart: C, _ y: [Double]) -> some View {
        chart
            .chartXScale(domain: 0...44)
            .chartXAxis {
                AxisMarks(values: [0, 10, 20, 30, 40]) { _ in
                    AxisGridLine().foregroundStyle(.white.opacity(0.06))
                    AxisValueLabel().font(Tok.mono(9)).foregroundStyle(Tok.secondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: y) { _ in
                    AxisGridLine().foregroundStyle(.white.opacity(0.06))
                    AxisValueLabel().font(Tok.mono(9)).foregroundStyle(Tok.secondary)
                }
            }
            .chartLegend(.hidden)
            .frame(height: 92)
    }

    private func title(_ t: String, _ unit: String) -> some View {
        HStack(spacing: 4) {
            Text(t).font(Tok.body(.medium)).foregroundStyle(Tok.primary)
            Text(unit).font(Tok.caption()).foregroundStyle(Tok.secondary)
            Spacer()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Telemetry").font(Tok.title).foregroundStyle(Tok.primary)
                Spacer()
                ForEach([("roll", accent), ("pitch", Color.white), ("yaw", Color(hex: 0xF5A524))], id: \.0) { n, c in
                    HStack(spacing: 4) { Circle().fill(c).frame(width: 6, height: 6); Text(n) }
                        .font(Tok.caption()).foregroundStyle(Tok.secondary)
                }
            }
            title("Attitude", "deg")
            axes(Chart(Telemetry.attitude) { s in
                LineMark(x: .value("t", s.t), y: .value("deg", s.v), series: .value("s", s.series))
                    .foregroundStyle(by: .value("s", s.series)).lineStyle(StrokeStyle(lineWidth: 1.3))
            }
            .chartForegroundStyleScale(["roll": accent, "pitch": Color.white.opacity(0.85), "yaw": Color(hex: 0xF5A524)])
            .chartYScale(domain: -45...45), [-45, 0, 45])
            Hairline(inset: 0)
            title("Motor RPM", "mean of 4")
            axes(Chart(Telemetry.rpm) { s in
                AreaMark(x: .value("t", s.t), y: .value("rpm", s.v))
                    .foregroundStyle(LinearGradient(colors: [accent.opacity(0.3), accent.opacity(0)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("t", s.t), y: .value("rpm", s.v)).foregroundStyle(accent).lineStyle(StrokeStyle(lineWidth: 1.3))
            }
            .chartYScale(domain: 4000...12000), [4000, 8000, 12000])
            Hairline(inset: 0)
            title("Altitude", "m")
            axes(Chart(Telemetry.altitude) { s in
                LineMark(x: .value("t", s.t), y: .value("m", s.v)).foregroundStyle(accent).lineStyle(StrokeStyle(lineWidth: 1.3))
                RuleMark(x: .value("now", 19.7)).foregroundStyle(.white.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
            .chartYScale(domain: 0...6), [0, 3, 6])
        }
        .padding(14).frame(width: 360)
        .glass()
    }
}

struct TransportBar: View {
    @Binding var time: Double
    @Environment(\.accent) private var accent
    let total = 42.0

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                ChromeButton(symbol: "backward.end.fill", size: 34)
                ChromeButton(symbol: "pause.fill", size: 34)
                ChromeButton(symbol: "forward.end.fill", size: 34)
            }
            Rectangle().fill(Tok.hairline).frame(width: 1, height: 28)
            Text(String(format: "00:%04.1f", time)).font(Tok.mono(13, .medium)).foregroundStyle(Tok.primary)
                + Text("  /  00:42.0").font(Tok.mono(13)).foregroundStyle(Tok.secondary)
            GeometryReader { g in
                let x = g.size.width * time / total
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12)).frame(height: 4)
                    Capsule().fill(accent).frame(width: x, height: 4)
                    // Gate ticks along the run.
                    ForEach(0..<14, id: \.self) { i in
                        Rectangle().fill(.white.opacity(0.35)).frame(width: 1, height: 8)
                            .offset(x: g.size.width * (2.4 + Double(i) * 2.85) / total)
                    }
                    Circle().fill(.white).frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(accent, lineWidth: 3))
                        .shadow(color: accent.opacity(0.8), radius: 5)
                        .offset(x: x - 7)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    time = min(total, max(0, v.location.x / g.size.width * total))
                })
            }
            .padding(.horizontal, 8)
            Text("1x").font(Tok.mono(12)).foregroundStyle(Tok.secondary)
                .padding(.horizontal, 8).frame(height: 24).background(Capsule().fill(.white.opacity(0.07)))
            PrimaryButton(title: "Re-run on Frame v8", symbol: "arrow.triangle.2.circlepath", height: 36).frame(width: 200)
        }
        .padding(.horizontal, 12).frame(height: 60)
        .glass()
    }
}
