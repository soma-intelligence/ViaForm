import SwiftUI
import Charts

struct Outcome: Identifiable {
    let id: Int
    let mass: Double
    let sf: Double
}

enum GenerativeStage {
    static let states: PipelineStates = [
        .design: .upToDate, .generative: .upToDate, .mechanics: .stale, .electronics: .stale,
        .simulation: .stale, .training: .stale, .render: .upToDate, .manufacture: .idle,
    ]

    static let outcomes: [Outcome] = [
        .init(id: 1, mass: 8.7, sf: 2.12), .init(id: 2, mass: 9.1, sf: 2.24), .init(id: 3, mass: 9.8, sf: 2.37),
        .init(id: 4, mass: 10.2, sf: 2.28), .init(id: 5, mass: 10.4, sf: 2.16), .init(id: 6, mass: 10.7, sf: 2.32),
        .init(id: 7, mass: 11.3, sf: 2.47), .init(id: 8, mass: 11.8, sf: 2.36), .init(id: 9, mass: 12.1, sf: 2.21),
        .init(id: 12, mass: 10.4, sf: 2.31), .init(id: 10, mass: 12.8, sf: 2.18), .init(id: 11, mass: 13.4, sf: 2.09),
    ]

    /// 64 converged outcomes for the trade-off plot (deterministic).
    static let cloud: [Outcome] = (0..<64).map { i in
        let t = Double(i) / 63
        let mass = 6.3 + t * 7.2 + sin(Double(i) * 2.7) * 0.6
        let sf = 3.55 - t * 1.6 + cos(Double(i) * 1.9) * 0.28
        return Outcome(id: 100 + i, mass: mass, sf: sf)
    }

    static var screen: StageScreen {
        StageScreen(
            project: "Drone 3in Mk2",
            workspace: .generative,
            states: states,
            jobs: 2,
            groups: [
                .init(title: "Setup", tools: [.init(glyph: .png("cube3d")), .init(glyph: .png("plane")), .init(glyph: .png("select")), .init(glyph: .png("point_vertex"))]),
                .init(title: "Loads", tools: [.init(glyph: .symbol("arrow.down.to.line")), .init(glyph: .symbol("arrow.down")), .init(glyph: .symbol("arrow.up.to.line")), .init(glyph: .symbol("bolt.fill"))]),
                .init(title: "Objectives", tools: [.init(glyph: .symbol("scope")), .init(glyph: .symbol("leaf")), .init(glyph: .symbol("chart.bar.xaxis"))]),
                .init(title: "Study", tools: [.init(glyph: .symbol("play.fill")), .init(glyph: .symbol("stop.fill")), .init(glyph: .symbol("gearshape.fill"))]),
                .init(title: "Explore", tools: [.init(glyph: .symbol("square.stack.3d.up.fill"), isOn: true), .init(glyph: .symbol("chart.xyaxis.line")), .init(glyph: .symbol("point.3.connected.trianglepath.dotted"))]),
            ],
            primary: [.init(title: "Generate", symbol: "play.fill", kind: .blue)],
            rows: [
                .init(indent: 0, disclosure: .open, symbol: "folder", title: "Studies", eye: .none, section: true),
                .init(indent: 1, disclosure: .open, symbol: "folder", title: "3-inch Frame", eye: .none),
                .init(indent: 2, disclosure: .open, symbol: "gearshape", title: "Setup", eye: .none, section: true),
                .init(indent: 3, disclosure: .closed, symbol: "cube", title: "Design Space"),
                .init(indent: 3, disclosure: .closed, symbol: "cube.fill", symbolTint: VF.green, title: "Preserves", detail: "4"),
                .init(indent: 3, disclosure: .closed, symbol: "cube.fill", symbolTint: VF.red, title: "Keep-outs", detail: "3"),
                .init(indent: 2, disclosure: .open, symbol: "bolt", title: "Load Cases", eye: .none, section: true),
                .init(indent: 3, disclosure: .closed, status: .upToDate, title: "Hover"),
                .init(indent: 3, disclosure: .closed, status: .stale, title: "Punch-out"),
                .init(indent: 3, disclosure: .closed, status: .stale, title: "Crash 6 m/s side"),
                .init(indent: 2, disclosure: .open, symbol: "chart.bar", title: "Outcomes", eye: .none, section: true),
                .init(indent: 3, disclosure: .closed, status: .upToDate, title: "Converged", detail: "64"),
                .init(indent: 3, disclosure: .none, symbol: "star.fill", symbolTint: VF.accent, title: "Outcome #12", selected: true),
            ],
            outputs: [
                .init(symbol: "checkmark.circle", title: "Study complete", status: .upToDate, value: "64 / 64"),
                .init(symbol: "exclamationmark.triangle", title: "Warnings", status: .stale, value: "3"),
                .init(symbol: "xmark.octagon", title: "Errors", status: .failed, value: "0"),
                .init(symbol: "arrow.triangle.2.circlepath", title: "Running", status: .running, value: "0"),
            ],
            inspector: AnyView(inspector),
            viewport: AnyView(GenerativeViewport()),
            bottom: AnyView(OutcomesGallery()),
            bottomHeight: 268,
            status: StatusBar(
                leading: AnyView(HStack(spacing: 8) {
                    StatusDot(status: .running, size: 8)
                    Text("Study finished")
                    Text("64 of 64").monospacedDigit().foregroundStyle(VF.secondary)
                    Capsule().fill(VF.accent).frame(width: 320, height: 4)
                        .overlay(alignment: .leading) { Capsule().fill(VF.accent).frame(width: 320, height: 4) }
                }),
                trailing: ["10:24 AM"],
                trailingDot: ("Up to date", .upToDate))
        )
    }

    static var inspector: some View {
        InspectorPanel {
            InspectorSection(title: "Selection", showsDivider: false) {
                SelectionCard(symbol: "circle.hexagongrid", title: "Outcome #12", subtitle: "Applied to Frame, rev 12")
            }
            flowAndLinked(consumes: "Design space v3", produces: "Frame #12 for Design", states: states, current: .generative)
            InspectorSection(title: "Result") {
                KVRow(label: "Mass", value: "10.4", unit: "g")
                KVRow(label: "Safety factor", value: "2.31")
                KVRow(label: "Max displacement", value: "0.071", unit: "mm")
                KVRow(label: "Material", value: "Carbon 3K")
                KVRow(label: "Method", value: "Lattice", divider: false)
            }
            InspectorSection(title: "Trade-off") {
                TradeOffChart().frame(height: 168)
            }
        }
    }
}

struct TradeOffChart: View {
    var body: some View {
        Chart {
            ForEach(GenerativeStage.cloud) { o in
                PointMark(x: .value("Mass", o.mass), y: .value("Safety factor", o.sf))
                    .symbolSize(14)
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            PointMark(x: .value("Mass", 10.4), y: .value("Safety factor", 2.31))
                .symbolSize(90)
                .foregroundStyle(VF.accent)
                .annotation(position: .top, spacing: 4) {
                    Text("#12").font(.system(size: 10, weight: .semibold)).foregroundStyle(VF.accent)
                }
            RuleMark(y: .value("Target", 2.0))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(VF.amber.opacity(0.8))
        }
        .chartXScale(domain: 6...14)
        .chartYScale(domain: 1.5...4)
        .chartXAxisLabel("Mass (g)", alignment: .center)
        .chartYAxisLabel("Safety factor")
        .chartXAxis { AxisMarks(values: [6, 8, 10, 12, 14]) { _ in AxisGridLine().foregroundStyle(VF.hairline); AxisValueLabel().foregroundStyle(VF.secondary) } }
        .chartYAxis { AxisMarks(position: .leading, values: [1.5, 2, 2.5, 3, 3.5, 4]) { _ in AxisGridLine().foregroundStyle(VF.hairline); AxisValueLabel().foregroundStyle(VF.secondary) } }
        .font(.system(size: 10)).monospacedDigit()
    }
}

struct StressLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Von Mises").font(.system(size: 11, weight: .semibold))
            Text("MPa").font(.system(size: 10)).foregroundStyle(VF.secondary)
            HStack(alignment: .top, spacing: 6) {
                LinearGradient(colors: [Color(hex: 0xFF2D20), Color(hex: 0xFFD60A), Color(hex: 0x30D158), Color(hex: 0x32D2F5), Color(hex: 0x1E5BFF)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: 10, height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(["148", "120", "90", "60", "30", "0"], id: \.self) { v in
                        Text(v).font(.system(size: 10.5)).monospacedDigit()
                        if v != "0" { Spacer(minLength: 0) }
                    }
                }
                .frame(height: 226)
                .offset(y: -6)
            }
        }
        .padding(10)
        .floatingSurface(radius: 10)
    }
}

struct GenerativeViewport: View {
    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let h = size.height * 0.78
            let w = h * 667 / 462
            let img = CGRect(x: (size.width - w) / 2 - 30, y: (size.height - h) / 2 - 18, width: w, height: h)
            let pill = CGSize(width: 330, height: 42)
            ZStack(alignment: .topLeading) {
                ViewportBackground()
                Art.image("frame").resizable().frame(width: img.width, height: img.height)
                    .position(x: img.midX, y: img.midY)
                let k = img.width / 667
                LoadLabel(text: "Crash 6 m/s", symbol: "arrow.right")
                    .position(x: img.minX + 62 * k, y: img.minY + 40 * k)
                LoadLabel(text: "Thrust 4 x 9.6 N", symbol: "arrow.up")
                    .position(x: img.minX + 580 * k, y: img.minY + 20 * k)
                StressLegend().position(x: size.width - 16 - 42, y: 16 + 150)
                ContextPill(actions: [
                    .init(symbol: "cube", title: "Use in Design"),
                    .init(symbol: "square.split.2x1", title: "Compare"),
                    .init(symbol: "square.and.arrow.down", title: "Export"),
                ], header: nil, horizontalLabels: true)
                .position(Anchor.place(pill, near: img.insetBy(dx: 40, dy: 8), in: size))
                Triad().position(x: 16 + 32, y: size.height - 16 - 36)
                ViewCube(s: 30).position(x: size.width - 16 - 140, y: 16 + 30)
            }
        }
    }
}

struct OutcomesGallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CapsLabel(text: "Outcomes", color: VF.text.opacity(0.78))
                Text("64 converged").font(.system(size: 11)).monospacedDigit().foregroundStyle(VF.secondary)
                Spacer()
                HStack(spacing: 6) {
                    Text("Sorted by mass").font(.system(size: 12))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(VF.secondary)
                }
                .padding(.horizontal, 10).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(VF.panel))
                VFSegmented(items: ["Grid", "Plot"], selected: 0, height: 24, fontSize: 11.5)
            }
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(0..<2) { r in
                    GridRow {
                        ForEach(0..<6) { c in
                            OutcomeTile(outcome: GenerativeStage.outcomes[r * 6 + c], index: r * 6 + c)
                        }
                    }
                }
            }
        }
        .padding(12)
    }
}

struct OutcomeTile: View {
    let outcome: Outcome
    let index: Int
    var applied: Bool { outcome.id == 12 }
    var body: some View {
        VStack(spacing: 4) {
            (applied ? Art.image("tile_applied") : Art.image("tile"))
                .resizable().aspectRatio(contentMode: .fit)
                .scaleEffect(applied ? 1.0 : 0.92 + 0.02 * Double(index % 4))
                .rotationEffect(.degrees(applied ? 0 : Double((index % 3) - 1) * 4))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text("#\(outcome.id)").foregroundStyle(VF.secondary)
                Spacer()
                Text(String(format: "%.1f g", outcome.mass))
                Spacer()
                Text(String(format: "SF %.2f", outcome.sf))
            }
            .font(.system(size: 11)).monospacedDigit()
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 100, maxHeight: 104)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0x17181B)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(applied ? VF.accent : VF.hairline, lineWidth: applied ? 2 : 1))
        .overlay(alignment: .topTrailing) {
            if applied {
                Text("Applied").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 7).frame(height: 18)
                    .background(UnevenRoundedRectangle(bottomLeadingRadius: 6, topTrailingRadius: 8).fill(VF.accent))
            }
        }
    }
}

/// Load-case callout drawn live over the viewport (orange, like the load arrows).
struct LoadLabel: View {
    let text: String
    let symbol: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            Text(text).font(.system(size: 12, weight: .medium)).monospacedDigit()
        }
        .foregroundStyle(VF.orange)
        .padding(.horizontal, 8).frame(height: 22)
        .background(Capsule().fill(Color.black.opacity(0.35)))
        .overlay(Capsule().strokeBorder(VF.orange.opacity(0.35), lineWidth: 1))
        .fixedSize()
    }
}
