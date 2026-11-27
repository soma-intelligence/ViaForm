import Charts
import SwiftUI

enum DroneStudy {
    struct Outcome: Identifiable {
        var id: Int
        var mass: Double
        var stiffness: Double
        var arm: CGFloat
        var lattice: Int
        var best = false
    }

    static let outcomes: [Outcome] = [
        Outcome(id: 14, mass: 11.6, stiffness: 52, arm: 0.11, lattice: 3, best: true),
        Outcome(id: 15, mass: 12.1, stiffness: 48, arm: 0.10, lattice: 4),
        Outcome(id: 16, mass: 12.8, stiffness: 55, arm: 0.12, lattice: 2),
        Outcome(id: 17, mass: 13.4, stiffness: 60, arm: 0.13, lattice: 3),
        Outcome(id: 18, mass: 14.2, stiffness: 68, arm: 0.14, lattice: 2),
        Outcome(id: 19, mass: 15.1, stiffness: 72, arm: 0.15, lattice: 4),
        Outcome(id: 20, mass: 16.3, stiffness: 76, arm: 0.16, lattice: 1),
        Outcome(id: 21, mass: 17.8, stiffness: 83, arm: 0.17, lattice: 2),
        Outcome(id: 22, mass: 19.6, stiffness: 91, arm: 0.19, lattice: 1),
    ]

    struct P: Identifiable { var id: Int; var m: Double; var k: Double }

    /// 74 candidates under a rising Pareto front (more mass buys more stiffness).
    static let candidates: [P] = {
        var seed: UInt64 = 7
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
        return (0..<74).map { i in
            let m = 9 + rnd() * 14
            let front = front(m)
            return P(id: i, m: m, k: front * (0.55 + 0.42 * rnd()))
        }
    }()

    static func front(_ m: Double) -> Double { 112 * (1 - exp(-(m - 7.2) / 7.5)) }
    static let pareto: [P] = stride(from: 9.0, through: 23.0, by: 1.0).enumerated().map { P(id: $0.offset, m: $0.element, k: front($0.element)) }
}

struct GenerativeScreen: View {
    @Binding var workspace: Workspace
    static let plate = PlateLayout(name: "frame", zoom: 0.74, shift: CGSize(width: -92, height: 40))

    var body: some View {
        MacWindow(project: "Racer 3in", workspace: $workspace, plate: Self.plate) { sidebar, inspector in
            ZStack(alignment: .bottom) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        if sidebar { StudySetup() }
                        Spacer(minLength: 8)
                        StressLegend()
                    }
                    Spacer()
                    if inspector { OutcomesPanel() }
                }
                GenerateProgress().padding(.bottom, 14).offset(x: -60)
            }
        }
    }
}

struct StudySetup: View {
    struct Item { var dot: Color; var label: String; var value: String? = nil }
    let sections: [(String, String, [Item])] = [
        ("shield.lefthalf.filled", "Preserve", [Item(dot: Color(hex: 0x3B82F6), label: "Motor pads", value: "x4"),
                                                 Item(dot: Color(hex: 0x8B5CF6), label: "Stack mount", value: "30.5 mm")]),
        ("circle.slash", "Obstacles", [Item(dot: Color(hex: 0x34C759), label: "Prop sweep", value: "x4"),
                                       Item(dot: Color(hex: 0xF5A524), label: "Battery bay"),
                                       Item(dot: Color(hex: 0x22B8E6), label: "Camera pod")]),
        ("bolt", "Load cases", [Item(dot: Color(hex: 0xFF453A), label: "Crash", value: "12 g"),
                                Item(dot: Color(hex: 0xF5A524), label: "Full thrust", value: "4 x 820 gf"),
                                Item(dot: Color(hex: 0x22B8E6), label: "Hover gust", value: "9 m/s")]),
        ("target", "Objectives", [Item(dot: Color(hex: 0x8B5CF6), label: "Minimise mass"),
                                  Item(dot: Color(hex: 0x34C759), label: "Stiffness at least", value: "40 N/mm")]),
        ("square.stack.3d.up", "Material", [Item(dot: Color(hex: 0x8E8E93), label: "Carbon PA12", value: "1.18 g/cc")]),
        ("gearshape", "Manufacturing", [Item(dot: Color(hex: 0x8E8E93), label: "Additive", value: "Z up")]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(tool: "component", title: "Study 2 \u{00B7} Frame")
            ForEach(sections, id: \.1) { sym, title, items in
                Hairline()
                VStack(spacing: 0) {
                    SectionHeader(symbol: sym, title: title)
                    ForEach(items, id: \.label) { it in
                        HStack(spacing: 10) {
                            Circle().fill(it.dot).frame(width: 8, height: 8)
                            Text(it.label).font(Tok.body()).foregroundStyle(Tok.primary.opacity(0.85))
                            Spacer()
                            if let v = it.value { Text(v).font(Tok.mono(12)).foregroundStyle(Tok.secondary) }
                        }
                        .padding(.leading, 20).padding(.trailing, Tok.pad).frame(height: 26)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(.bottom, 6)
        .frame(width: 280)
        .glass()
    }
}

struct StressLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Von Mises").font(Tok.body(.semibold)).foregroundStyle(Tok.primary)
                Text("MPa").font(Tok.caption()).foregroundStyle(Tok.secondary)
            }
            Capsule().fill(LinearGradient(colors: [Color(hex: 0x1D3BFF), Color(hex: 0x16B5F5), Color(hex: 0x2BD66B),
                                                   Color(hex: 0xF7E52B), Color(hex: 0xFF8A1F), Color(hex: 0xF0262A)],
                                          startPoint: .leading, endPoint: .trailing))
                .frame(height: 10)
            HStack {
                ForEach(["0", "45", "91", "136", "182"], id: \.self) { t in
                    Text(t).font(Tok.mono(11)).foregroundStyle(Tok.secondary)
                    if t != "182" { Spacer() }
                }
            }
        }
        .padding(Tok.pad).frame(width: 280)
        .glass(14)
    }
}

struct GenerateProgress: View {
    @Environment(\.accent) private var accent
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle").font(.system(size: 13, weight: .semibold)).foregroundStyle(Tok.primary)
                Text("Generating").font(Tok.body(.medium)).foregroundStyle(Tok.primary)
                Text("74 of 120").font(Tok.mono(13)).foregroundStyle(Tok.primary)
                Dot()
                Text("3 min left").font(Tok.body()).foregroundStyle(Tok.secondary)
                Spacer()
                Image(systemName: "pause.fill").font(.system(size: 10)).foregroundStyle(Tok.secondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.10))
                    Capsule().fill(accent).frame(width: g.size.width * 74 / 120).shadow(color: accent.opacity(0.6), radius: 4)
                }
            }
            .frame(height: 5)
        }
        .padding(.horizontal, 16).padding(.vertical, 12).frame(width: 380)
        .glass(16)
    }
}

struct OutcomesPanel: View {
    @Environment(\.accent) private var accent
    @State private var hovered: Int?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(icon: "sparkles", title: "Outcomes", trailing: "74 / 120")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(DroneStudy.outcomes) { o in card(o) }
            }
            .padding(.horizontal, Tok.pad)
            Hairline().padding(.top, 12)
            chart.padding(.horizontal, Tok.pad).padding(.top, 10)
            HStack(spacing: 8) {
                PrimaryButton(title: "Use as Frame")
                SecondaryButton(title: "Compare")
            }
            .padding(Tok.pad)
        }
        .frame(width: 392)
        .glass()
    }

    private func card(_ o: DroneStudy.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            FrameThumb(arm: o.arm, lattice: o.lattice, tinted: o.best).frame(height: 66)
            Text("#\(o.id)").font(Tok.mono(11, .semibold)).foregroundStyle(Tok.primary)
            HStack(spacing: 0) {
                Text(String(format: "%.1f g", o.mass))
                Spacer(minLength: 2)
                Text("\(Int(o.stiffness)) N/mm")
            }
            .font(Tok.mono(10)).foregroundStyle(Tok.secondary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.22)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(o.best ? accent : .white.opacity(hovered == o.id ? 0.3 : 0.09), lineWidth: o.best ? 2 : 1))
        .overlay(alignment: .topTrailing) {
            if o.best {
                Text("Best").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).frame(height: 16)
                    .background(Capsule().fill(accent)).padding(5)
            }
        }
        .shadow(color: o.best ? accent.opacity(0.35) : .clear, radius: 8)
        .onHover { hovered = $0 ? o.id : nil }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Mass vs stiffness").font(Tok.body(.semibold)).foregroundStyle(Tok.primary)
                Spacer()
                HStack(spacing: 4) { Capsule().fill(accent).frame(width: 12, height: 2); Text("Pareto") }
                HStack(spacing: 4) { Circle().fill(accent.opacity(0.55)).frame(width: 5, height: 5); Text("Candidates") }
            }
            .font(Tok.caption()).foregroundStyle(Tok.secondary)
            Chart {
                ForEach(DroneStudy.candidates) { p in
                    PointMark(x: .value("Mass", p.m), y: .value("Stiffness", p.k))
                        .foregroundStyle(accent.opacity(0.5)).symbolSize(12)
                }
                ForEach(DroneStudy.pareto) { p in
                    LineMark(x: .value("Mass", p.m), y: .value("Stiffness", p.k))
                        .foregroundStyle(accent).lineStyle(StrokeStyle(lineWidth: 2)).interpolationMethod(.catmullRom)
                }
                PointMark(x: .value("Mass", 11.6), y: .value("Stiffness", 52.0))
                    .foregroundStyle(.white).symbolSize(70)
                    .annotation(position: .top, alignment: .leading) {
                        Text("#14").font(Tok.mono(10, .semibold)).foregroundStyle(Tok.primary)
                    }
            }
            .chartXScale(domain: 8...24)
            .chartYScale(domain: 0...120)
            .chartXAxis {
                AxisMarks(values: [8, 12, 16, 20, 24]) { _ in
                    AxisGridLine().foregroundStyle(.white.opacity(0.07))
                    AxisValueLabel().font(Tok.mono(10)).foregroundStyle(Tok.secondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 30, 60, 90, 120]) { _ in
                    AxisGridLine().foregroundStyle(.white.opacity(0.07))
                    AxisValueLabel().font(Tok.mono(10)).foregroundStyle(Tok.secondary)
                }
            }
            .chartXAxisLabel(position: .bottom, alignment: .center) { Text("Mass g").font(Tok.caption()).foregroundStyle(Tok.secondary) }
            .chartYAxisLabel(position: .leading, alignment: .center) { Text("N/mm").font(Tok.caption()).foregroundStyle(Tok.secondary) }
            .frame(height: 168)
        }
    }
}

/// Top view of one generative frame outcome: centre stack, four branching arms with lattice holes.
struct FrameThumb: View {
    var arm: CGFloat
    var lattice: Int
    var tinted = false
    @Environment(\.accent) private var accent

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) * 0.46
            let w = max(2.5, r * arm * 1.5)
            let metal = GraphicsContext.Shading.linearGradient(Gradient(colors: [Color(hex: 0xC4C8CF), Color(hex: 0x5A5E66)]),
                                                                startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height))
            for k in 0..<4 {
                let a = CGFloat.pi / 4 + CGFloat(k) * .pi / 2
                let end = CGPoint(x: c.x + cos(a) * r * 1.25, y: c.y + sin(a) * r)
                // Tapered organic arm, wide at the stack, narrow at the motor pad.
                let n = CGVector(dx: -sin(a), dy: cos(a))
                let root = CGPoint(x: c.x + cos(a) * 8, y: c.y + sin(a) * 6)
                let w0 = w * 1.5, w1 = w * 0.6
                var arm = Path()
                arm.move(to: CGPoint(x: root.x + n.dx * w0, y: root.y + n.dy * w0))
                arm.addQuadCurve(to: CGPoint(x: end.x + n.dx * w1, y: end.y + n.dy * w1),
                                 control: CGPoint(x: (root.x + end.x) / 2 + n.dx * w * 0.5, y: (root.y + end.y) / 2 + n.dy * w * 0.5))
                arm.addLine(to: CGPoint(x: end.x - n.dx * w1, y: end.y - n.dy * w1))
                arm.addQuadCurve(to: CGPoint(x: root.x - n.dx * w0, y: root.y - n.dy * w0),
                                 control: CGPoint(x: (root.x + end.x) / 2 - n.dx * w * 0.5, y: (root.y + end.y) / 2 - n.dy * w * 0.5))
                arm.closeSubpath()
                ctx.fill(arm, with: metal)
                ctx.stroke(arm, with: .color(.white.opacity(0.18)), lineWidth: 0.6)
                // Brace to the next arm, the optimiser's typical web.
                let a2 = a + .pi / 2
                var brace = Path()
                brace.move(to: CGPoint(x: c.x + cos(a) * r * 0.55, y: c.y + sin(a) * r * 0.45))
                brace.addQuadCurve(to: CGPoint(x: c.x + cos(a2) * r * 0.55, y: c.y + sin(a2) * r * 0.45),
                                   control: CGPoint(x: c.x + cos(a + .pi / 4) * r * 0.25, y: c.y + sin(a + .pi / 4) * r * 0.2))
                if lattice % 2 == 1 { ctx.stroke(brace, with: metal, style: StrokeStyle(lineWidth: max(1.5, w * 0.35), lineCap: .round)) }
                for i in 0..<lattice {
                    let t = 0.35 + CGFloat(i) * 0.5 / CGFloat(max(lattice, 1))
                    let h = CGPoint(x: c.x + (end.x - c.x) * t, y: c.y + (end.y - c.y) * t)
                    ctx.fill(Path(ellipseIn: CGRect(x: h.x - w * 0.3, y: h.y - w * 0.3, width: w * 0.6, height: w * 0.6)),
                             with: .color(Color(hex: 0x15161A)))
                }
                let pad = CGRect(x: end.x - 7, y: end.y - 7, width: 14, height: 14)
                ctx.fill(Path(ellipseIn: pad), with: metal)
                ctx.stroke(Path(ellipseIn: pad.insetBy(dx: 3, dy: 3)), with: .color(Color(hex: 0x15161A)), lineWidth: 2)
                if tinted {
                    ctx.stroke(Path(ellipseIn: pad.insetBy(dx: -2, dy: -2)), with: .color(accent.opacity(0.7)), lineWidth: 1)
                }
            }
            let body = CGRect(x: c.x - 9, y: c.y - 12, width: 18, height: 24)
            ctx.fill(Path(roundedRect: body, cornerRadius: 3), with: .color(Color(hex: 0x2A2C31)))
            ctx.stroke(Path(roundedRect: body, cornerRadius: 3), with: .color(.white.opacity(0.25)), lineWidth: 0.8)
        }
    }
}
