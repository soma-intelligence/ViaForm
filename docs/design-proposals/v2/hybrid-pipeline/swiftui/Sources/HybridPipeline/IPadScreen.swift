import SwiftUI

/// iPad layout (Touch): no sidebar, floating rail, floating inspector card,
/// floating timeline pill, icon-only pipeline. All targets 44 pt or more.
struct IPadScreen: View {
    let states = DesignStage.states

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let topInset: CGFloat = 24 + 60
            let h = (size.height - topInset) * 0.86
            let w = h * 572 / 758
            let img = CGRect(x: (size.width - w) / 2 - 40, y: topInset + 6, width: w, height: h)
            let rel = { (x: CGFloat, y: CGFloat) in CGPoint(x: img.minX + x * img.width, y: img.minY + y * img.height) }
            let sel = CGRect(origin: rel(0.577, 0.455), size: CGSize(width: 0.218 * w, height: 0.231 * h))
            let card = CGRect(x: size.width - 16 - 320, y: topInset + 120, width: 320, height: 380)
            let pillSize = CGSize(width: 300, height: 92)
            ZStack(alignment: .topLeading) {
                ViewportBackground()
                Art.image("hand").resizable().frame(width: img.width, height: img.height).position(x: img.midX, y: img.midY)
                DimensionLine(a: rel(0.69, 0.75), b: rel(0.90, 0.53)).stroke(VF.accent, lineWidth: 1.5)
                DimensionCallout(text: "22.0 mm").position(rel(0.94, 0.67))

                VStack(spacing: 0) {
                    systemStatusBar
                    topBar
                }

                ToolRail().position(x: 16 + 30, y: topInset + 24 + 238)

                ContextPill(actions: [
                    .init(symbol: "arrow.up.and.down", title: "Push Pull", png: "presspull", isOn: true),
                    .init(symbol: "", title: "Fillet", png: "fillet"),
                    .init(symbol: "", title: "Joint", png: "joint"),
                    .init(symbol: "gearshape", title: "Motor"),
                ], header: nil, buttonSize: CGSize(width: 60, height: 64))
                .position(Anchor.place(pillSize, near: sel, in: size, avoid: [card]))

                ViewCube(s: 40).position(x: size.width - 16 - 35, y: topInset + 16 + 40)
                TouchInspectorCard().frame(width: 320).position(x: card.midX, y: card.midY)

                HStack(alignment: .bottom) {
                    ItemsButton()
                    Spacer()
                }
                .padding(16)
                .frame(maxHeight: .infinity, alignment: .bottom)
                TouchTimelinePill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 16)
            }
        }
        .foregroundStyle(VF.text)
        .environment(\.colorScheme, .dark)
    }

    private var systemStatusBar: some View {
        HStack {
            Text("9:41").font(.system(size: 15, weight: .semibold)).monospacedDigit()
            Spacer()
            Image(systemName: "wifi").font(.system(size: 13, weight: .semibold))
            Text("100%").font(.system(size: 14, weight: .medium)).monospacedDigit()
            Image(systemName: "battery.100").font(.system(size: 16))
        }
        .padding(.horizontal, 20)
        .frame(height: 24)
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            Text("Robotic Hand H1").font(.system(size: 22, weight: .semibold))
            Spacer()
            TouchPipelineStrip(active: .design, states: states)
            Spacer()
            HStack(spacing: 6) {
                Text("Jobs").font(.system(size: 17))
                Text("3").font(.system(size: 12, weight: .bold)).monospacedDigit()
                    .frame(width: 20, height: 20).background(Circle().fill(VF.accent))
            }
            .frame(minWidth: 64, minHeight: 44)
            Image(systemName: "person.fill").font(.system(size: 20))
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color(hex: 0x3A3B40)))
        }
        .padding(.horizontal, 20)
        .frame(height: 60)
        .background(VF.chrome.opacity(0.92))
        .overlay(alignment: .bottom) { Hairline() }
    }
}

/// Icon-only pipeline: circles joined by lines, state dots below,
/// only the active stage labelled.
struct TouchPipelineStrip: View {
    let active: Workspace
    let states: PipelineStates
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Workspace.allCases) { ws in
                if ws != .design { Rectangle().fill(VF.hairline).frame(width: 18, height: 1.5).offset(y: -8) }
                VStack(spacing: 3) {
                    Image(systemName: ws.symbol).font(.system(size: 16, weight: .medium))
                        .foregroundStyle(ws == active ? .white : VF.text.opacity(0.85))
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(ws == active ? VF.accent : VF.panel))
                        .overlay(Circle().strokeBorder(ws == active ? .clear : VF.hairline))
                    if ws == active {
                        Text(ws.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(VF.accent).fixedSize()
                    } else {
                        StatusDot(status: states[ws] ?? .idle, size: 7).frame(height: 13)
                    }
                }
            }
        }
        .padding(.top, 14)
    }
}

struct ToolRail: View {
    let tools = ["cursorarrow", "pencil", "cube", "arrow.turn.up.right", "link", "camera.viewfinder", "ruler"]
    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(tools.enumerated()), id: \.offset) { i, s in
                Image(systemName: s).font(.system(size: 19, weight: .medium))
                    .frame(width: 48, height: 48)
                    .background(RoundedRectangle(cornerRadius: 12).fill(i == 0 ? VF.accent.opacity(0.9) : Color.white.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(i == 0 ? Color.white.opacity(0.3) : VF.hairline))
            }
        }
        .padding(8)
        .floatingSurface(radius: 16)
    }
}

struct TouchInspectorCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "cube").font(.system(size: 20))
                Text("Thumb Proximal").font(.system(size: 19, weight: .semibold))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(VF.secondary)
            }
            .frame(height: 52)
            Hairline()
            row("Length", "22.0 mm")
            row("Wall", "1.20 mm")
            row("Motor", "Micro 8 mm")
            row("Torque", "0.12 N m")
            row("Material", "PA12", divider: false)
            HStack(spacing: 14) {
                GeometryReader { g in
                    let f: CGFloat = 0.6
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.16)).frame(height: 5)
                        Capsule().fill(VF.accent).frame(width: g.size.width * f, height: 5)
                        Circle().fill(.white).frame(width: 26, height: 26)
                            .overlay(Circle().fill(VF.accent).frame(width: 12, height: 12))
                            .shadow(color: .black.opacity(0.4), radius: 3)
                            .offset(x: g.size.width * f - 13)
                    }
                    .frame(maxHeight: .infinity)
                }
                Text("22.0 mm").font(.system(size: 15)).monospacedDigit()
            }
            .frame(height: 48)
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
        .floatingSurface(radius: 16)
    }
    private func row(_ l: String, _ v: String, divider: Bool = true) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(l).foregroundStyle(VF.text.opacity(0.75))
                Spacer()
                Text(v).monospacedDigit()
            }
            .font(.system(size: 16))
            .frame(height: 48)
            if divider { Hairline().opacity(0.7) }
        }
    }
}

struct ItemsButton: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 20))
            Text("Items").font(.system(size: 13, weight: .medium))
        }
        .frame(width: 84, height: 84)
        .background(Circle().fill(VF.floating))
        .overlay(Circle().strokeBorder(Color.white.opacity(0.10)))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }
}

struct TouchTimelinePill: View {
    let steps: [(String, String, StageStatus)] = [
        ("Base", "cube", .upToDate), ("Palm", "hand.raised", .upToDate), ("Fingers", "hand.point.up", .upToDate),
        ("Thumb", "hand.thumbsup", .running), ("Motors", "gearshape", .stale), ("Joints", "link", .upToDate),
        ("Cover", "arrow.turn.up.right", .upToDate), ("Assembly", "shippingbox", .failed),
    ]
    let current = 3
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                if i > 0 {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(VF.tertiary)
                }
                VStack(spacing: 4) {
                    Image(systemName: s.1).font(.system(size: 17, weight: .medium))
                        .foregroundStyle(i == current ? VF.accent : VF.text.opacity(0.88))
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(i == current ? VF.accent.opacity(0.16) : Color.white.opacity(0.06)))
                        .overlay(Circle().strokeBorder(i == current ? VF.accent : VF.hairline, lineWidth: i == current ? 2 : 1))
                    Text(s.0).font(.system(size: 12, weight: i == current ? .semibold : .regular))
                        .foregroundStyle(i == current ? VF.accent : VF.text.opacity(0.85))
                    StatusDot(status: s.2 == .running ? .upToDate : s.2, size: 6)
                        .opacity(s.2 == .running ? 0 : 1)
                        .overlay(s.2 == .running ? Circle().fill(VF.accent).frame(width: 6, height: 6) : nil)
                }
                .frame(minWidth: 64)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .floatingSurface(radius: 22)
    }
}
