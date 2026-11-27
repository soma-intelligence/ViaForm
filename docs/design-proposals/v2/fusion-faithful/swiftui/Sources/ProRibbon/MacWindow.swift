import Charts
import SwiftUI

/// The whole desktop window: application bar, ribbon, canvas with floating overlays, optional
/// docked panes, timeline. Switching workspace swaps ribbon, browser and docked panes only.
struct MacWindow: View {
    @State var workspace: Workspace
    @State private var tab: String
    @State private var marker: Int
    @State private var dialog = true
    @State private var dataPanel = false

    init(workspace: Workspace) {
        _workspace = State(initialValue: workspace)
        _tab = State(initialValue: workspace == .electronics ? "PCB" : workspace.tabs[0])
        _marker = State(initialValue: workspace == .electronics ? 7 : 10)
    }

    var document: String {
        switch workspace {
        case .generative, .simulation, .training: "FPV Drone 3in"
        case .electronics: "Flight Controller FC30"
        default: "Robotic Hand v12"
        }
    }

    var history: [Sample.FeatureKind] {
        switch workspace {
        case .generative, .simulation: Sample.droneHistory
        case .electronics: Sample.boardHistory
        default: Sample.handHistory
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            AppBar(document: document, jobs: workspace == .generative ? 2 : 3) { dataPanel.toggle() }
            Ribbon(workspace: workspace, tab: $tab, onWorkspace: switchTo) { dialog = false }
            canvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            if workspace == .simulation { TelemetryPane() }
            TimelineBar(features: history, marker: $marker)
        }
        .background(Color.white)
        .background(shortcuts)
    }

    private func switchTo(_ w: Workspace) {
        workspace = w
        tab = w == .electronics ? "PCB" : w.tabs[0]
        dialog = true
    }

    /// Cmd+1 to Cmd+8 switch workspace.
    private var shortcuts: some View {
        ZStack {
            ForEach(Workspace.allCases) { w in
                Button("") { switchTo(w) }
                    .keyboardShortcut(KeyEquivalent(Character("\(w.rawValue + 1)")), modifiers: .command)
                    .opacity(0)
            }
        }
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var canvas: some View {
        switch workspace {
        case .generative: GenerativeCanvas()
        case .simulation: SimulationCanvas()
        case .electronics: ElectronicsCanvas()
        default: DesignCanvas(dialog: $dialog)
        }
    }
}

// MARK: - Design

struct DesignCanvas: View {
    @Binding var dialog: Bool
    @State private var selected = "Index Finger"

    var body: some View {
        ZStack {
            ViewportBackground()
            ViewportImage(name: "hand_desk")
                .frame(height: 664)
                .overlay(alignment: .topLeading) {
                    // drag handle on the index knuckle, value badge tied to it
                    ZStack(alignment: .topLeading) {
                        Path { p in
                            p.move(to: CGPoint(x: 240, y: 156))
                            p.addLine(to: CGPoint(x: 268, y: 152))
                        }
                        .stroke(VF.accent, lineWidth: 1)
                        ValueBadge(text: "35 deg").offset(x: 268, y: 141)
                    }
                }
                .offset(x: -20, y: 22)
            VStack {
                HStack(alignment: .top) {
                    BrowserOverlay(rows: Sample.handTree.map { r in var r = r; r.selected = r.name == selected; return r }) { selected = $0.name }
                    Spacer()
                    ViewCube()
                }
                Spacer()
            }
            .padding(VF.overlayInset)
            if dialog {
                HStack {
                    Spacer()
                    CommandDialog(title: "REVOLUTE JOINT", symbol: "link", rows: [
                        DialogRow(label: "Component 1", value: "Index Proximal", symbol: "cube.fill"),
                        DialogRow(label: "Component 2", value: "Index Middle", symbol: "cube.fill"),
                        DialogRow(label: "Motion", value: "Revolute", symbol: "arrow.triangle.2.circlepath"),
                        DialogRow(label: "Axis", value: "Z", symbol: "arrow.up.to.line"),
                        DialogRow(label: "Limits", value: "0 to 90 deg", symbol: "angle"),
                        DialogRow(label: "Motor", value: "M1408", symbol: "gearshape.fill"),
                    ], onCancel: { dialog = false }, onOK: { dialog = false })
                }
                .padding(.trailing, 84)
                .padding(.top, 92)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            BottomOverlays()
        }
    }
}

struct BottomOverlays: View {
    var body: some View {
        VStack {
            Spacer()
            ZStack(alignment: .bottom) {
                HStack { Triad(); Spacer() }
                NavBar()
            }
        }
        .padding(VF.overlayInset)
    }
}

// MARK: - Generative

struct GenerativeCanvas: View {
    @State private var selected = 7

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ZStack {
                    ViewportBackground()
                    ViewportImage(name: "drone_stress")
                        .frame(height: 500)
                        .offset(x: 40, y: 10)
                    VStack {
                        HStack(alignment: .top) {
                            BrowserOverlay(rows: Sample.studyTree, width: 268)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 26) {
                                ViewCube(size: 86)
                                StressLegend()
                            }
                        }
                        Spacer()
                    }
                    .padding(VF.overlayInset)
                    BottomOverlays()
                }
                .frame(width: geo.size.width * 0.68)
                OutcomesPane(selected: $selected)
                    .frame(width: geo.size.width * 0.32)
            }
        }
    }
}

struct StressLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Von Mises\nMPa").font(.system(size: 12, weight: .semibold)).foregroundStyle(VF.ink)
            HStack(alignment: .top, spacing: 8) {
                LinearGradient(colors: [Color(hex: 0xE3141B), Color(hex: 0xFF8A00), Color(hex: 0xF4E41C),
                                        Color(hex: 0x34D36B), Color(hex: 0x1FC8E8), Color(hex: 0x1430F0)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: 18, height: 250)
                    .overlay(Rectangle().strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 0) {
                    ForEach([180, 150, 120, 90, 60, 30, 0], id: \.self) { v in
                        Text("\(v)").font(.system(size: 11).monospacedDigit()).foregroundStyle(VF.ink)
                        if v != 0 { Spacer(minLength: 0) }
                    }
                }
                .frame(height: 258)
                .offset(y: -6)
            }
        }
        .padding(.trailing, 6)
    }
}

struct OutcomesPane: View {
    @Binding var selected: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("OUTCOMES").font(.system(size: 13, weight: .semibold)).kerning(0.3)
                Spacer()
                Image(systemName: "ellipsis").foregroundStyle(VF.secondary)
            }
            .frame(height: 40)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(Sample.outcomes) { o in
                    OutcomeCard(outcome: o, selected: o.id == selected).onTapGesture { selected = o.id }
                }
            }
            Hairline(color: VF.separator.opacity(0.7)).padding(.vertical, 12)
            Text("Mass vs Safety Factor").font(.system(size: 13, weight: .semibold))
            ScatterChart(selected: Sample.outcomes.first { $0.id == selected }!)
                .frame(minHeight: 196, maxHeight: .infinity)
                .padding(.top, 8)
            HStack(spacing: 10) {
                Button("Compare") {}.buttonStyle(VFBordered(height: 34))
                Button("Create Design") {}.buttonStyle(VFProminent(height: 34))
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.white)
        .overlay(alignment: .leading) { Hairline(vertical: true) }
    }
}

struct OutcomeCard: View {
    let outcome: Sample.Outcome
    let selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewportImage(name: "outcome_\(outcome.image)", fill: true)
                .frame(height: 104)
                .frame(maxWidth: .infinity)
                .clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text("Outcome \(outcome.id)").font(.system(size: 12, weight: .medium))
                Text(String(format: "%.1f g  |  SF %.1f", outcome.mass, outcome.sf))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(VF.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0xF4F6F8)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? VF.accent : VF.separator, lineWidth: selected ? 2 : 1))
    }
}

struct ScatterChart: View {
    let selected: Sample.Outcome
    var body: some View {
        Chart {
            ForEach(Array(Sample.scatter.enumerated()), id: \.offset) { _, p in
                PointMark(x: .value("Mass", p.0), y: .value("SF", p.1))
                    .symbolSize(18)
                    .foregroundStyle(Color(hex: 0x9AA0A8))
            }
            ForEach(Sample.outcomes) { o in
                PointMark(x: .value("Mass", o.mass), y: .value("SF", o.sf))
                    .symbolSize(o.id == selected.id ? 110 : 26)
                    .foregroundStyle(o.id == selected.id ? VF.accent : Color(hex: 0x6B7079))
            }
        }
        .chartXScale(domain: 8...16)
        .chartYScale(domain: 1...3)
        .chartXAxisLabel("Mass (g)", position: .bottom, alignment: .center)
        .chartYAxisLabel("Safety Factor", position: .leading, alignment: .center)
        .chartXAxis { AxisMarks(values: [8, 10, 12, 14, 16]) { _ in AxisGridLine(); AxisValueLabel() } }
        .chartYAxis { AxisMarks(position: .leading, values: [1.0, 1.5, 2.0, 2.5, 3.0]) { _ in AxisGridLine(); AxisValueLabel() } }
        .padding(.trailing, 10)
    }
}

// MARK: - Simulation

struct SimulationCanvas: View {
    var body: some View {
        ZStack {
            // Color.clear takes the proposed size, so the aspect fill image never drives layout.
            Color.clear
                .overlay { ViewportImage(name: "sim_scene", fill: true) }
                .clipped()
            WindStreamlines()
            VStack {
                HStack(alignment: .top) {
                    BrowserOverlay(rows: Sample.simTree, closable: true, width: 316, trailingEye: true)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 10) {
                        ViewCube(size: 84)
                        FlightHUD()
                    }
                }
                Spacer()
                HStack { Spacer(); WindCompass() }
                    .padding(.bottom, 4)
            }
            .padding(VF.overlayInset)
            BottomOverlays()
        }
    }
}

/// Animated in the app (TimelineView); frozen at t = 0 in renders.
struct WindStreamlines: View {
    var body: some View {
        if RenderMode.active {
            lines(phase: 0.35)
        } else {
            TimelineView(.animation) { tl in
                lines(phase: tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 3)
            }
        }
    }

    private func lines(phase: Double) -> some View {
        Canvas { ctx, s in
            for i in 0..<7 {
                let y0 = s.height * (0.08 + Double(i) * 0.06)
                var p = Path()
                p.move(to: CGPoint(x: s.width * 0.22, y: y0))
                p.addCurve(to: CGPoint(x: s.width * 0.86, y: y0 + 26 + Double(i) * 6),
                           control1: CGPoint(x: s.width * 0.45, y: y0 + 18),
                           control2: CGPoint(x: s.width * 0.65, y: y0 - 8))
                ctx.stroke(p, with: .color(Color(hex: 0x7FC4FF, alpha: 0.55)),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [60, 26], dashPhase: -phase * 86 - Double(i) * 17))
                let tip = CGPoint(x: s.width * 0.86, y: y0 + 26 + Double(i) * 6)
                var h = Path()
                h.move(to: tip)
                h.addLine(to: CGPoint(x: tip.x - 10, y: tip.y - 5))
                h.addLine(to: CGPoint(x: tip.x - 10, y: tip.y + 5))
                h.closeSubpath()
                ctx.fill(h, with: .color(Color(hex: 0x7FC4FF, alpha: 0.75)))
            }
        }
        .allowsHitTesting(false)
    }
}

struct FlightHUD: View {
    let rows = [("Time", "19.7 s"), ("Speed", "12.4 m/s"), ("Altitude", "3.1 m"), ("Battery", "71 %"), ("Gate", "5 of 8")]
    var body: some View {
        VStack(spacing: 8) {
            ForEach(rows, id: \.0) { r in
                HStack {
                    Text(r.0).font(.system(size: 13)).foregroundStyle(VF.ink)
                    Spacer()
                    Text(r.1).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(VF.ink)
                }
            }
        }
        .padding(12)
        .frame(width: 156)
        .floatingCard()
    }
}

struct WindCompass: View {
    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.95))
            Circle().strokeBorder(Color(hex: 0x2B3240), lineWidth: 1.5)
            ForEach(0..<12) { i in
                Rectangle().fill(Color(hex: 0x2B3240).opacity(0.5)).frame(width: 1, height: i % 3 == 0 ? 6 : 3)
                    .offset(y: -42).rotationEffect(.degrees(Double(i) * 30))
            }
            Text("N").font(.system(size: 10, weight: .semibold)).offset(y: -34)
            Image(systemName: "arrow.right").font(.system(size: 22, weight: .bold)).foregroundStyle(VF.accent).offset(y: -8)
            VStack(spacing: 0) {
                Text("Wind").font(.system(size: 12, weight: .medium))
                Text("6.2 m/s").font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            .offset(y: 18)
        }
        .frame(width: 96, height: 96)
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

struct TelemetryPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "play.circle.fill").font(.system(size: 24)).foregroundStyle(VF.accent)
                DropMenu(items: ["0.25x", "0.5x", "1x", "2x", "4x"].map { DropItem(title: $0) }) {
                    HStack(spacing: 10) {
                        Text("1x").font(.system(size: 13, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 5).strokeBorder(VF.separator))
                }
                Spacer()
            }
            HStack(spacing: 0) {
                TelemetryChart(title: "Altitude", data: Sample.altitude, colors: [VF.accent], yDomain: 0...6, readout: ["3.1 m"])
                Hairline(vertical: true)
                TelemetryChart(title: "Roll  Pitch  Yaw", data: Sample.attitude, colors: [VF.accent, Color(hex: 0x2DBE60), Color(hex: 0xFF8A00)],
                               yDomain: -60...60, readout: ["Roll 2.4\u{00B0}", "Pitch -1.8\u{00B0}", "Yaw 12.6\u{00B0}"])
                Hairline(vertical: true)
                TelemetryChart(title: "Motor RPM", data: Sample.motors, colors: [VF.accent, Color(hex: 0x2DBE60), Color(hex: 0xFF8A00), Color(hex: 0x8E44EC)],
                               yDomain: 0...12000, readout: ["M1 9820", "M2 9650", "M3 10010", "M4 9780"])
                Hairline(vertical: true)
                TelemetryChart(title: "Battery Voltage", data: Sample.battery, colors: [Color(hex: 0x8E44EC)], yDomain: 10...16, readout: ["11.8 V"])
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(height: 200)
        .background(Color.white)
        .overlay(alignment: .top) { Hairline() }
    }
}

struct TelemetryChart: View {
    let title: String
    let data: [Sample.Sample1]
    let colors: [Color]
    let yDomain: ClosedRange<Double>
    let readout: [String]
    let playhead = 20.0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .semibold))
            HStack(alignment: .top, spacing: 6) {
                Chart {
                    ForEach(data) { s in
                        LineMark(x: .value("t", s.t), y: .value("v", s.v), series: .value("s", s.series))
                            .foregroundStyle(by: .value("s", s.series))
                            .lineStyle(StrokeStyle(lineWidth: 1.1))
                    }
                    RuleMark(x: .value("now", playhead))
                        .foregroundStyle(VF.accent)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .annotation(position: .top, spacing: 0) {
                            Circle().fill(VF.accent).frame(width: 7, height: 7)
                        }
                }
                .chartForegroundStyleScale(range: colors)
                .chartLegend(.hidden)
                .chartXScale(domain: 0...25)
                .chartYScale(domain: yDomain)
                .chartXAxis { AxisMarks(values: [0, 5, 10, 15, 20]) { _ in AxisGridLine(); AxisValueLabel() } }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in AxisGridLine(); AxisValueLabel() } }
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(Array(readout.enumerated()), id: \.offset) { i, r in
                        Text(r).font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(colors[min(i, colors.count - 1)])
                    }
                }
                .frame(width: readout.count > 1 ? 74 : 44, alignment: .trailing)
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 10)
    }
}

// MARK: - Electronics

struct ElectronicsCanvas: View {
    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                PCBCanvasView()
                LayersOverlay().padding(10)
                VStack { Spacer(); Triad().colorScheme(.dark) }.padding(VF.overlayInset)
            }
            .frame(width: 812)
            Hairline(vertical: true, color: Color.black.opacity(0.4))
            ZStack {
                ViewportBackground(floor: false)
                // board_3d is a 521 x 502 crop; it is drawn full width, sitting on the pane bottom,
                // and the link leader ends on the board's anchor point (201, 54) in crop pixels.
                GeometryReader { g in
                    let k = g.size.width / 521
                    let h = 502 * k
                    let top = g.size.height - h
                    ViewportImage(name: "board_3d")
                        .frame(width: g.size.width, height: h)
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08)],
                                             startPoint: .top, endPoint: .bottom))
                        .position(x: g.size.width / 2, y: top + h / 2)
                    LinkBadge(anchor: CGPoint(x: 201 * k, y: top + 54 * k))
                }
                .clipped()
                VStack {
                    HStack { Spacer(); ViewCube(size: 84) }
                    Spacer()
                    NavBar()
                }
                .padding(VF.overlayInset)
            }
            BoardInspector().frame(width: 220)
        }
    }
}

struct LayersOverlay: View {
    let layers: [(String, Color)] = [("F.Cu", Color(hex: 0xE5484D)), ("In1 GND", Color(hex: 0x46A758)),
                                     ("In2 PWR", Color(hex: 0xF5B400)), ("B.Cu", Color(hex: 0x1F6BFF)),
                                     ("Edge Cuts", Color(hex: 0xEDEDED))]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("LAYERS").font(.system(size: 13, weight: .semibold)).kerning(0.3)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(VF.accent)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            Hairline(color: VF.separator.opacity(0.6))
            ForEach(layers, id: \.0) { l in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2).fill(l.1).frame(width: 14, height: 14)
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
                    Text(l.0).font(.system(size: 13))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
            }
            .padding(.vertical, 2)
        }
        .frame(width: 150)
        .floatingCard()
    }
}

struct LinkBadge: View {
    /// Where the leader line lands on the board, in the 3D pane's coordinates.
    let anchor: CGPoint
    private let badgeBottom: CGFloat = 92

    var body: some View {
        // The leader follows the board's projected slope (0.264 horizontal per vertical point).
        let start = CGPoint(x: anchor.x - 0.264 * (anchor.y - badgeBottom), y: badgeBottom)
        ZStack(alignment: .topLeading) {
            Path { p in
                p.move(to: start)
                p.addLine(to: anchor)
            }
            .stroke(VF.accent, lineWidth: 1.2)
            Circle().fill(VF.accent).frame(width: 8, height: 8)
                .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
                .position(anchor)
            HStack(spacing: 8) {
                Image(systemName: "link").font(.system(size: 13, weight: .semibold))
                Text("Linked to Frame rev 7").font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(VF.accent)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Capsule().fill(Color.white))
            .overlay(Capsule().strokeBorder(VF.accent, lineWidth: 1))
            .offset(x: 40, y: badgeBottom - 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct BoardInspector: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("BOARD").font(.system(size: 12, weight: .semibold)).kerning(0.3).foregroundStyle(VF.secondary)
            Text("FC30").font(.system(size: 17, weight: .semibold)).padding(.top, 6)
            Hairline(color: VF.separator.opacity(0.7)).padding(.vertical, 12)
            kv("Layers", "4")
            kv("Thickness", "1.6 mm")
            kv("Outline", "From Frame")
            kv("Copper", "1 oz")
            Text("CHECKS").font(.system(size: 12, weight: .semibold)).kerning(0.3).foregroundStyle(VF.secondary).padding(.top, 18)
            HStack {
                Text("DRC").font(.system(size: 13))
                Spacer()
                Text("0 errors").font(.system(size: 13))
                Image(systemName: "checkmark.circle.fill").foregroundStyle(VF.success)
            }
            .frame(height: 30)
            HStack {
                Text("ERC").font(.system(size: 13))
                Spacer()
                Text("0 errors").font(.system(size: 13))
                Image(systemName: "checkmark.circle.fill").foregroundStyle(VF.success)
            }
            .frame(height: 30)
            Button("Push to 3D") {}.buttonStyle(VFProminent(height: 36)).padding(.top, 16)
            Spacer()
        }
        .padding(16)
        .frame(maxHeight: .infinity)
        .background(Color.white)
        .overlay(alignment: .leading) { Hairline(vertical: true) }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 13)).foregroundStyle(VF.ink)
            Spacer()
            Text(v).font(.system(size: 13)).foregroundStyle(VF.ink)
        }
        .frame(height: 30)
    }
}
