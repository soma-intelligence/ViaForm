import SwiftUI

struct GenerativeScreen: View {
    @Bindable var studio: Studio

    var body: some View {
        MacShell(studio: studio, title: "Racer 3in Frame") { cs in
            ZStack(alignment: .topLeading) {
                ModelImage(name: "frame_stress", rect: cs.rect(220, 150, 1085, 712))
                LoadArrows(cs: cs)
                StressLegend().position(x: cs.p(1150, 0).x, y: cs.p(0, 360).y)

                AnchorLayout(anchor: cs.p(705, 150), side: .above, gap: 6) {
                    ContextCapsule(actions: [
                        .init(id: "use", glyph: "square.on.square.dashed", title: "Use as Frame", primary: true),
                        .init(id: "compare", glyph: "rectangle.on.rectangle", title: "Compare"),
                        .init(id: "refine", glyph: "slider.horizontal.3", title: "Refine")
                    ], style: .inline) { id in if id == "use" { studio.promotedVariant = studio.variant } }
                }

                ToolRail(tools: Rails.generative, active: studio.activeTool[.generative] ?? "load", labelled: true) {
                    studio.activeTool[.generative] = $0
                }
                .padding(.leading, 20).padding(.top, 108)

                RightColumn { StudyCard() }
                ViewCubeSlot()
                VStack { Spacer(); VariantsStrip(studio: studio) }
                    .padding(.horizontal, 40).padding(.bottom, 22)
            }
        }
    }
}

/// Load arrows drawn in the viewport, from the study's load cases projected to screen.
struct LoadArrows: View {
    let cs: ConceptSpace
    var body: some View {
        Canvas { ctx, _ in
            let blue = Color(hex: 0x2F5BE0)
            let thrust: [(CGFloat, CGFloat)] = [(380, 196), (954, 232), (275, 560), (992, 625)]
            for (x, y) in thrust {
                arrow(ctx, from: cs.p(x, y), to: cs.p(x, y - 62), color: blue)
                label(ctx, ["Thrust", "4 x 380 g"], at: cs.p(x + 18, y - 56), color: blue)
            }
            arrow(ctx, from: cs.p(668, 272), to: cs.p(668, 340), color: VF.red)
            label(ctx, ["Crash", "12 g"], at: cs.p(648, 230), color: VF.red)
        }
        .allowsHitTesting(false)
    }

    func arrow(_ ctx: GraphicsContext, from a: CGPoint, to b: CGPoint, color: Color) {
        var p = Path(); p.move(to: a); p.addLine(to: b)
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        let up = b.y < a.y
        var h = Path()
        h.move(to: CGPoint(x: b.x, y: b.y + (up ? -4 : 4)))
        h.addLine(to: CGPoint(x: b.x - 7, y: b.y + (up ? 12 : -12)))
        h.addLine(to: CGPoint(x: b.x + 7, y: b.y + (up ? 12 : -12)))
        h.closeSubpath()
        ctx.fill(h, with: .color(color))
    }

    func label(_ ctx: GraphicsContext, _ lines: [String], at p: CGPoint, color: Color) {
        for (i, l) in lines.enumerated() {
            ctx.draw(Text(l).font(.system(size: 14)).monospacedDigit().foregroundColor(color),
                     at: CGPoint(x: p.x, y: p.y + CGFloat(i) * 18), anchor: .topLeading)
        }
    }
}

struct StressLegend: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(LinearGradient(colors: [Color(hex: 0xE23A2E), Color(hex: 0xF6A623), Color(hex: 0xF2E33A),
                                              Color(hex: 0x3BCB6B), Color(hex: 0x22B3E6), Color(hex: 0x1F3FE0)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 12, height: 230)
            VStack(alignment: .leading) {
                Text("182 MPa"); Spacer(); Text("0 MPa")
            }
            .font(.system(size: 12)).monospacedDigit().foregroundStyle(VF.text)
            .frame(height: 236)
        }
        .frame(width: 90)
    }
}

struct StudyCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Study 2").font(.system(size: 20, weight: .semibold)).foregroundStyle(VF.text)
            CardDivider()
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "Load cases").padding(.bottom, 2)
                ChoiceRow(glyph: nil, title: "Crash", value: "12 g", dot: VF.accent, selected: true)
                ChoiceRow(glyph: nil, title: "Full thrust", dot: Color(hex: 0xB9BBC2))
                ChoiceRow(glyph: nil, title: "Hover gust", dot: Color(hex: 0xB9BBC2))
            }
            CardDivider()
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "Objectives").padding(.bottom, 2)
                ChoiceRow(glyph: "target", title: "Minimise mass")
                ChoiceRow(glyph: "shield", title: "Safety factor 2.0")
            }
            CardDivider()
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "Material").padding(.bottom, 2)
                ChoiceRow(glyph: "square.3.layers.3d", title: "Carbon nylon")
            }
            CardDivider()
            VStack(alignment: .leading, spacing: 10) {
                (Text("Generating ").foregroundColor(VF.text) + Text("74 of 120").foregroundColor(VF.secondary))
                    .font(.system(size: 13)).monospacedDigit()
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(VF.track)
                        Capsule().fill(VF.accent).frame(width: g.size.width * 74 / 120)
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(16)
        .card()
    }
}

struct VariantsStrip: View {
    @Bindable var studio: Studio
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Variants").font(.system(size: 17, weight: .semibold)).foregroundStyle(VF.text)
            HStack(spacing: 14) {
                ForEach(Array(Sample.variants.enumerated()), id: \.offset) { i, v in
                    let on = studio.variant == i
                    VStack(alignment: .leading, spacing: 6) {
                        Asset.image("variant_\(i)").resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity).frame(height: 104)
                        HStack(spacing: 8) {
                            Text("#\(v.0)").font(.system(size: 13, weight: .semibold))
                            Text(String(format: "%.1f g", v.1)).font(.system(size: 13)).foregroundStyle(VF.text.opacity(0.75))
                            Spacer()
                            if studio.promotedVariant == i {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(VF.accent)
                            }
                        }
                        .monospacedDigit().foregroundStyle(VF.text)
                        .padding(.horizontal, 10)
                    }
                    .padding(.vertical, 10)
                    .frame(minWidth: 200, maxWidth: .infinity).frame(height: 148)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(on ? VF.accent : VF.hairline, lineWidth: on ? 2 : 1))
                    .onTapGesture { studio.variant = i }
                }
            }
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
