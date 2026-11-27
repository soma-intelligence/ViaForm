import SwiftUI

struct SimulationScreen: View {
    @Bindable var studio: Studio

    var body: some View {
        MacShell(studio: studio, title: "Racer 3in Flight") { cs in
            let progress = studio.time / 60
            ZStack(alignment: .topLeading) {
                FlightScene(cs: cs, progress: progress)
                ModelImage(name: "drone_sim", rect: cs.rect(722, 516, 816, 596))

                AnchorLayout(anchor: cs.p(870, 392), side: .above, gap: 0) {
                    ContextCapsule(actions: [
                        .init(id: "follow", glyph: "scope", title: "Follow", tinted: true),
                        .init(id: "stress", glyph: "waveform.path.ecg", title: "Stress here"),
                        .init(id: "rerun", glyph: "arrow.clockwise", title: "Re-run")
                    ], style: .inline)
                }

                WindBadge().position(cs.p(470, 226))
                RunCard(studio: studio).padding(.leading, 22).padding(.top, 78)

                ToolRail(tools: Rails.simulation, active: studio.activeTool[.simulation] ?? "play") { id in
                    studio.activeTool[.simulation] = id
                    if id == "play" { studio.playing.toggle() }
                }
                .padding(.leading, 22).padding(.top, cs.p(0, 312).y)

                RightColumn(width: 268) { TelemetryCard(cursor: progress) }

                VStack { Spacer(); HStack { Spacer(); WindCapsule(studio: studio); Spacer() } }
                    .padding(.bottom, 24)
            }
        }
    }
}

/// Bright daylight scene: sky, horizon, ground grid, orange numbered gates, flown path,
/// wind streamlines. In the app: the Metal viewport fed by vf_sim_world / vf_sim_episode.
struct FlightScene: View {
    let cs: ConceptSpace
    let progress: Double

    var body: some View {
        Canvas { ctx, size in
            let horizon = cs.p(0, 470).y
            // sky
            ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: horizon)),
                     with: .linearGradient(Gradient(colors: [Color(hex: 0xA9CBEE), Color(hex: 0xCFE1F3), Color(hex: 0xE6EEF6)]),
                                           startPoint: .zero, endPoint: CGPoint(x: 0, y: horizon)))
            // soft clouds
            for (x, y, w) in [(1050.0, 190.0, 220.0), (1250, 160, 160), (300, 320, 260), (1380, 300, 200)] {
                ctx.fill(Path(ellipseIn: CGRect(x: cs.p(x, 0).x, y: cs.p(0, y).y, width: w, height: w * 0.18)),
                         with: .color(.white.opacity(0.45)))
            }
            // distant hills
            var hills = Path()
            hills.move(to: CGPoint(x: 0, y: horizon))
            var x: CGFloat = 0
            while x <= size.width {
                let h = 6 + 5 * sin(x / 60) + 4 * sin(x / 23 + 1)
                hills.addLine(to: CGPoint(x: x, y: horizon - h)); x += 8
            }
            hills.addLine(to: CGPoint(x: size.width, y: horizon)); hills.closeSubpath()
            ctx.fill(hills, with: .color(Color(hex: 0x9FAEB8, opacity: 0.55)))
            // ground
            ctx.fill(Path(CGRect(x: 0, y: horizon, width: size.width, height: size.height - horizon)),
                     with: .linearGradient(Gradient(colors: [Color(hex: 0xDCE1E8), Color(hex: 0xEEF0F4)]),
                                           startPoint: CGPoint(x: 0, y: horizon), endPoint: CGPoint(x: 0, y: size.height)))
            var grid = Path()
            let vp = CGPoint(x: size.width * 0.55, y: horizon - 10)
            for i in -40...40 {
                grid.move(to: vp); grid.addLine(to: CGPoint(x: vp.x + CGFloat(i) * 120, y: size.height))
            }
            var gy = horizon + 4, step: CGFloat = 4
            while gy < size.height { grid.move(to: CGPoint(x: 0, y: gy)); grid.addLine(to: CGPoint(x: size.width, y: gy)); gy += step; step *= 1.22 }
            var g2 = ctx
            g2.clip(to: Path(CGRect(x: 0, y: horizon, width: size.width, height: size.height - horizon)))
            g2.stroke(grid, with: .color(.white.opacity(0.7)), lineWidth: 1)

            // wind streamlines
            for k in 0..<9 {
                var s = Path()
                let y0 = cs.p(0, 250 + CGFloat(k) * 22).y
                s.move(to: CGPoint(x: -20, y: y0))
                for i in stride(from: 0, through: Int(size.width) + 40, by: 20) {
                    let xx = CGFloat(i)
                    s.addLine(to: CGPoint(x: xx, y: y0 + 18 * sin(xx / 260 + CGFloat(k) * 0.7) + xx * 0.05))
                }
                ctx.stroke(s, with: .color(.white.opacity(0.55 - Double(k) * 0.03)), lineWidth: 1.4)
            }

            // gates: concept rect, thickness
            let gates: [(CGRect, CGFloat, Int)] = [
                (cs.rect(190, 518, 326, 724), 24, 1), (cs.rect(480, 525, 589, 668), 18, 2),
                (cs.rect(681, 450, 830, 648), 20, 3), (cs.rect(930, 489, 1016, 606), 14, 4),
                (cs.rect(1100, 487, 1180, 571), 12, 5)
            ]
            // shadows first
            for (r, _, _) in gates {
                var sh = Path()
                sh.move(to: CGPoint(x: r.minX, y: r.maxY)); sh.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
                sh.addLine(to: CGPoint(x: r.maxX - r.width * 0.5, y: r.maxY + r.height * 0.16))
                sh.addLine(to: CGPoint(x: r.minX - r.width * 0.5, y: r.maxY + r.height * 0.16)); sh.closeSubpath()
                ctx.fill(sh, with: .color(.black.opacity(0.08)))
            }
            // pylons
            for (px, top, bottom, w) in [(228.0, 242.0, 545.0, 18.0), (1140, 258, 548, 12)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
                let r = cs.rect(px - w / 2, top, px + w / 2, bottom)
                ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .linearGradient(
                    Gradient(colors: [Color(hex: 0xF29B52), Color(hex: 0xE57A2E)]), startPoint: CGPoint(x: r.minX, y: 0), endPoint: CGPoint(x: r.maxX, y: 0)))
                for f in [0.22, 0.42] {
                    ctx.fill(Path(CGRect(x: r.minX, y: r.minY + r.height * f, width: r.width, height: r.height * 0.06)), with: .color(Color(hex: 0xF2F2F2)))
                }
            }
            func drawGate(_ r: CGRect, _ t: CGFloat, _ n: Int) {
                let depth = CGPoint(x: t * 0.35, y: -t * 0.25)
                var outer = Path(roundedRect: r, cornerRadius: 3)
                outer.addRect(r.insetBy(dx: t, dy: t))
                var back = outer; back = back.applying(CGAffineTransform(translationX: depth.x, y: depth.y))
                ctx.fill(back, with: .color(Color(hex: 0xC9661F)), style: FillStyle(eoFill: true))
                ctx.fill(outer, with: .linearGradient(Gradient(colors: [Color(hex: 0xF5A05A), Color(hex: 0xEC8337)]),
                                                     startPoint: CGPoint(x: r.minX, y: r.minY), endPoint: CGPoint(x: r.maxX, y: r.maxY)),
                         style: FillStyle(eoFill: true))
                // feet
                for fx in [r.minX + t / 2, r.maxX - t / 2] {
                    ctx.fill(Path(roundedRect: CGRect(x: fx - t * 0.6, y: r.maxY - 2, width: t * 1.2, height: t * 0.45), cornerRadius: 2),
                             with: .color(Color(hex: 0xB4B8BF)))
                }
                ctx.draw(Text("\(n)").font(.system(size: max(10, t * 0.75), weight: .bold)).foregroundColor(.white),
                         at: CGPoint(x: r.midX, y: r.minY + t / 2))
            }
            // path behind gate 3 belongs between gates: draw gates 1, 2, then path, then 3 to 5 on top (depth order simplified)
            for (r, t, n) in gates where n <= 2 { drawGate(r, t, n) }

            // flown path: solid behind the drone, dashed ahead
            let pts: [CGPoint] = [cs.p(0, 718), cs.p(190, 655), cs.p(480, 610), cs.p(700, 578), cs.p(770, 560)]
            var flown = Path(); flown.move(to: pts[0])
            for i in 1..<pts.count {
                let a = pts[i - 1], b = pts[i]
                flown.addQuadCurve(to: b, control: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 + 6))
            }
            ctx.stroke(flown, with: .color(VF.accent), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            var ahead = Path(); ahead.move(to: cs.p(800, 562))
            ahead.addQuadCurve(to: cs.p(1160, 524), control: cs.p(980, 540))
            ctx.stroke(ahead, with: .color(VF.accent), style: StrokeStyle(lineWidth: 2.4, lineCap: .round, dash: [10, 9]))

            for (r, t, n) in gates where n >= 3 { drawGate(r, t, n) }
        }
    }
}

struct WindBadge: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wind").font(.system(size: 14))
            Text("Wind").font(.system(size: 13))
            Text("6 m/s").font(.system(size: 13)).monospacedDigit()
        }
        .foregroundStyle(VF.text)
        .padding(.horizontal, 14).frame(height: 34)
        .card(17)
    }
}

struct RunCard: View {
    @Bindable var studio: Studio
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Run 12").font(.system(size: 17, weight: .semibold))
                Text("Obstacle course").font(.system(size: 13)).foregroundStyle(VF.secondary)
            }
            .foregroundStyle(VF.text)
            HStack(spacing: 12) {
                Button { studio.playing.toggle() } label: {
                    Circle().fill(VF.accent).frame(width: 36, height: 36)
                        .overlay(Image(systemName: studio.playing ? "pause.fill" : "play.fill").font(.system(size: 14)).foregroundStyle(.white))
                }
                .buttonStyle(.plain)
                Text(String(format: "%.1f s", studio.time)).font(.system(size: 13)).monospacedDigit().frame(width: 44, alignment: .leading)
                TrackSlider(value: Binding(get: { studio.time / 60 }, set: { studio.time = $0 * 60 }), width: 190)
                Text("60.0 s").font(.system(size: 11)).monospacedDigit().foregroundStyle(VF.secondary)
            }
        }
        .padding(16)
        .frame(width: 372, alignment: .leading)
        .card()
    }
}

struct TelemetryCard: View {
    let cursor: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Telemetry").font(.system(size: 17, weight: .semibold)).foregroundStyle(VF.text)
            chart("Altitude", "1.69 m", [Sample.altitude], [VF.accent], ["3.0", "1.5", "0.0"], 0...3)
            chart("Speed", "7.4 m/s", [Sample.speed], [VF.accent], ["12", "6", "0"], 0...12)
            chart("Motor RPM", nil, Sample.rpm, [VF.accent, VF.orange, Color(hex: 0x3DBE67), Color(hex: 0xB07CE8)],
                  ["25000", "15000", "5000"], 5000...25000)
            KeyValueRows(rows: [("Gates", "3 of 5"), ("Battery", "14.8 V"), ("Controller", "PID v4")])
                .padding(.horizontal, 10)
        }
        .padding(12)
        .card()
    }

    func chart(_ title: String, _ value: String?, _ s: [[Double]], _ c: [Color], _ ticks: [String], _ r: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer()
                if let v = value { Text(v).font(.system(size: 13)).monospacedDigit() }
            }
            .foregroundStyle(VF.text)
            MiniChart(series: s, colors: c, ticks: ticks, range: r, cursor: cursor).frame(height: 62)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(hex: 0xF6F7F9)))
    }
}

struct WindCapsule: View {
    @Bindable var studio: Studio
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "wind").font(.system(size: 17)).foregroundStyle(VF.text)
            Text("Wind").font(.system(size: 13)).foregroundStyle(VF.text)
            TrackSlider(value: $studio.wind, width: 160)
            Text("Gusts").font(.system(size: 13)).foregroundStyle(VF.text).padding(.leading, 8)
            PillToggle(isOn: $studio.gusts)
        }
        .padding(.horizontal, 22).frame(height: 54)
        .card(18)
    }
}
